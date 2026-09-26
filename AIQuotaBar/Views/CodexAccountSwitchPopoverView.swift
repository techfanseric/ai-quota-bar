import SwiftUI

/// 右键面板「Codex 账号」分区：列出 auth.json 当前账号与账号池备份，
/// 免登录切换、登录新账号、重命名 / 删除 / 导入备份。
@MainActor
struct CodexAccountSwitchPopoverView: View {
    @Bindable var store: CodexAuthAccountStore
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    @State private var renamingLabel: String?
    @State private var renameText = ""
    @State private var deleteCandidate: CodexStashedAccount?

    private var language: AppLanguage { .current }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !isCollapsed {
                Divider()
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 5) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 5) {
                    Image(
                        systemName: isCollapsed
                            ? "chevron.right" : "chevron.down"
                    )
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 9)

                    Text(language.codexAccountsSectionTitle())
                        .font(.system(size: 13, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            if !isCollapsed {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    Text(language.codexAccountsRefreshAccessibilityLabel()))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    // MARK: - 内容

    private var content: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if store.pendingRequest != nil {
                    pendingBanner
                    Divider()
                        .padding(.leading, 42)
                }

                currentRow

                ForEach(store.stashedAccounts) { stash in
                    Divider()
                        .padding(.leading, 42)
                    stashRow(stash)
                }

                ForEach(store.legacyBackupFileNames, id: \.self) { fileName in
                    Divider()
                        .padding(.leading, 42)
                    legacyRow(fileName)
                }

                Divider()
                    .padding(.leading, 42)
                loginNewRow

                if let message = store.statusMessage {
                    Divider()
                        .padding(.leading, 42)
                    statusRow(message)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .confirmationDialog(
            deleteCandidate.map {
                language.codexAccountsDeleteConfirmationTitle($0.label)
            } ?? "",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button(
                language.codexAccountsDeleteConfirmationButton(),
                role: .destructive
            ) {
                if let candidate = deleteCandidate {
                    store.deleteStashedAccount(candidate.label)
                }
                deleteCandidate = nil
            }
            Button(language.codexAccountsCancelButtonTitle(), role: .cancel) {
                deleteCandidate = nil
            }
        } message: {
            Text(language.codexAccountsDeleteConfirmationMessage())
        }
    }

    // MARK: - 当前账号行

    private var currentRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.green)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(currentAccountTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(language.codexAccountsCurrentBadge())
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if store.currentQuotaSnapshot != nil {
                    quotaText(store.currentQuotaSnapshot!)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .frame(height: ClashPopoverLayout.accountRowHeight)
    }

    private var currentAccountTitle: String {
        switch store.currentStatus {
        case let .chatgptLogin(login):
            return login.email ?? language.codexAccountsUnrecognizedFile()
        case .unauthenticated:
            return language.codexAccountsNotLoggedIn()
        case .apiKeyMode:
            return language.codexAccountsAPIKeyMode()
        case .unreadable:
            return language.codexAccountsNotLoggedIn()
        }
    }

    // MARK: - 备份行

    private func stashRow(_ stash: CodexStashedAccount) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundStyle(stash.isLoggedIn ? Color.secondary : Color.orange)
                .frame(width: 18)

            if isRenaming(stash) {
                TextField(
                    language.codexAccountsRenamePlaceholder(),
                    text: $renameText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit { commitRename(stash) }

                Button {
                    renamingLabel = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stash.label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle(for: stash))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if let quota = stash.quota {
                        quotaText(quota)
                    }
                }

                Spacer(minLength: 8)

                if stash.isLoggedIn {
                    Button(language.codexAccountsSwitchButtonTitle()) {
                        store.requestSwitch(to: stash.label)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.borderless)
                }

                Button {
                    beginRename(stash)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    Text(language.codexAccountsRenameAccessibilityLabel()))

                Button {
                    deleteCandidate = stash
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    Text(language.codexAccountsDeleteAccessibilityLabel()))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: ClashPopoverLayout.accountRowHeight)
    }

    private func subtitle(for stash: CodexStashedAccount) -> String {
        switch stash.status {
        case let .chatgptLogin(login):
            return login.email ?? language.codexAccountsUnrecognizedFile()
        case .unauthenticated:
            return language.codexAccountsNotLoggedIn()
        case .apiKeyMode:
            return language.codexAccountsAPIKeyMode()
        case .unreadable:
            return language.codexAccountsUnrecognizedFile()
        }
    }

    // MARK: - 配额行

    /// 单行紧凑摘要：「5h 68%→16:41 · wk 41%→09/29」。
    /// minimumScaleFactor 兜底：任何语言/数据组合下都不允许出现省略号。
    private func quotaLine(_ quota: CodexAccountQuotaSnapshot) -> String? {
        guard let short = quota.shortRemainingPercent else { return nil }
        var parts = [language.codexAccountsQuotaShort(
            percent: short,
            resetText: quota.shortResetsAt.map(resetTimeText) ?? "—")]
        if let long = quota.longRemainingPercent {
            parts.append(language.codexAccountsQuotaWeekly(
                percent: long,
                resetText: quota.longResetsAt.map(resetTimeText) ?? "—"))
        }
        return parts.joined(separator: language.codexAccountsQuotaSeparator())
    }

    private func quotaText(_ quota: CodexAccountQuotaSnapshot) -> some View {
        Group {
            if let line = quotaLine(quota) {
                Text(line)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .allowsTightening(true)
                    .minimumScaleFactor(0.85)
                    .help(quotaTooltip(quota))
            }
        }
    }

    private func quotaTooltip(_ quota: CodexAccountQuotaSnapshot) -> String {
        language.codexAccountsQuotaDetail(
            shortRemaining: quota.shortRemainingPercent ?? 0,
            shortReset: quota.shortResetsAt.map(fullTimeText) ?? "—",
            longRemaining: quota.longRemainingPercent,
            longReset: quota.longResetsAt.map(fullTimeText),
            capturedAt: fullTimeText(quota.capturedAt))
    }

    /// 当天只显示时刻，跨天显示日期（完整日期+时间在悬停提示里）。
    /// 备份行右侧按钮挤压了文字区，行内摘要必须保持最短。
    private func resetTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
        if Calendar.current.isDateInTomorrow(date) {
            formatter.dateFormat = "'\(AppLanguage.current.codexAccountsTomorrowPrefix())'HH:mm"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }

    /// 悬停提示用的完整时间。
    private func fullTimeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 待接力横幅

    private var pendingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)

            Text(pendingBannerText)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(language.codexAccountsCancelButtonTitle()) {
                store.cancelPendingRequest()
            }
            .controlSize(.mini)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 28)
        .background(Color.orange.opacity(0.08))
    }

    private var pendingBannerText: String {
        language.codexAccountsPendingBanner(
            desktopAppRunning: store.pendingBlockers.contains(.desktopApp),
            cliRunning: store.pendingBlockers.contains(.cliProcess))
    }

    // MARK: - 旧备份导入行

    private func legacyRow(_ fileName: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Text(language.codexAccountsLegacyImportTitle(fileName))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button(language.codexAccountsLegacyImportButton()) {
                store.importLegacyBackup(fileName)
            }
            .controlSize(.mini)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    // MARK: - 登录新账号

    private var loginNewRow: some View {
        Button {
            store.requestLoginNewAccount()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                Text(language.codexAccountsLoginNewButtonTitle())
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 状态行

    private func statusRow(_ message: CodexAccountSwitchStatusMessage) -> some View {
        Text(message.text)
            .font(.system(size: 9))
            .foregroundStyle(message.isError ? Color.red : Color.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(minHeight: 20)
    }

    // MARK: - 重命名

    private func isRenaming(_ stash: CodexStashedAccount) -> Bool {
        renamingLabel == stash.label
    }

    private func beginRename(_ stash: CodexStashedAccount) {
        renamingLabel = stash.label
        renameText = stash.label
    }

    private func commitRename(_ stash: CodexStashedAccount) {
        store.renameStashedAccount(stash.label, to: renameText)
        renamingLabel = nil
    }
}
