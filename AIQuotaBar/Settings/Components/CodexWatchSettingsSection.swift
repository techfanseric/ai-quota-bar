import SwiftUI

/// 「关注账号」设置区。两侧都在这里，因为它们是一次操作的两半：
///
/// - **分享侧**（owner）：勾选哪些 Codex 账号允许被别的 Mac 看到。
///   打开后这些账号的额度会跟着团队云同步一起上云。
/// - **关注侧**（watcher）：只填一个邮箱，就能看到那台 Mac 分享的额度。
///
/// 传输走的是已有的团队云端通道，所以关注侧**不需要地址、端口或访问密钥**，
/// 对方也**不需要在这台 Mac 上登录 Codex**。
@MainActor
struct CodexWatchSettingsSection: View {
    let language: AppLanguage
    /// 本机登录着的 Codex 账号，供分享侧勾选。
    let localCodexAccounts: [String]
    let viewModel: UsageViewModel
    @State private var emailInput = ""
    @State private var errorText: String?
    @FocusState private var emailFieldFocused: Bool

    private var store: CodexWatchStore { .shared }

    private func t(_ zh: String, _ en: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    /// 是否已经接上云端通道。没有它，关注和分享都无从谈起。
    private var hasTeam: Bool { CodexLocalUsageModel.shared.connection != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            shareSide
            Divider()
            watchSide
        }
    }

    // MARK: - 分享侧

    private var shareSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { store.isSharing },
                set: { store.isSharing = $0 })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("允许其他 Mac 关注我的账号", "Let other Macs watch my accounts"))
                    Text(t(
                        "开启后，下面勾选的账号额度会随「共享账号额度」一起同步到团队云端。别人在他们的「我关注的账号」里填这个邮箱就能看到，不需要密钥，也不需要在这台 Mac 上登录 Codex。Codex 登录凭据始终不离开这台 Mac。",
                        "When on, the accounts checked below sync to your team's cloud alongside Share account quota. Anyone can then enter that email under \"Accounts I watch\" to see the quota — no access key, and no Codex sign-in on this Mac. Codex credentials never leave this Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if store.isSharing {
                if !hasTeam {
                    cloudPrerequisiteWarning
                }
                if localCodexAccounts.isEmpty {
                    Text(t(
                        "这台 Mac 还没有登录任何 Codex 账号。",
                        "No Codex account is signed in on this Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(localCodexAccounts, id: \.self) { account in
                        Toggle(isOn: Binding(
                            get: { store.isShared(account) },
                            set: { store.setShared($0, for: account) })
                        ) {
                            Text(account).font(.callout)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(t(
                        "默认一个都不共享，只有勾选的账号会上传。取消勾选后，它会在下一次用量刷新时从云端消失。",
                        "Nothing is shared by default — only checked accounts are uploaded. Unchecking one makes it disappear from the cloud on the next quota refresh."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var cloudPrerequisiteWarning: some View {
        Text(t(
            "⚠︎ 还没加入团队，额度没有地方可同步。请先在「设置 → 团队」里创建或加入一个团队，并打开「共享账号额度」。",
            "⚠︎ Not in a team yet, so there is nowhere to sync to. Create or join a team under Settings → Team first, and turn on Share account quota."))
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 关注侧

    private var watchSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("我关注的账号", "Accounts I watch"))
                .font(.headline)

            Text(t(
                "填一个邮箱就行。两台 Mac 在同一个团队里，对方勾了这个邮箱，这里就会显示它的额度。",
                "Just enter an email. With both Macs in the same team and the other one sharing that address, its quota shows up here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !hasTeam {
                Text(t(
                    "⚠︎ 还没加入团队，现在看不到任何别人的账号。请先在「设置 → 团队」里用邀请码加入。",
                    "⚠︎ Not in a team yet, so no one else's account can be seen. Join one with an invite code under Settings → Team first."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField(t("对方 Codex 账号的邮箱", "Their Codex account email"), text: $emailInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($emailFieldFocused)
                    .onSubmit(addWatched)
                    .onChange(of: emailInput) { _, _ in errorText = nil }
                Button(t("添加", "Add"), action: addWatched)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    // 只在完全为空时禁用。输入不合法或已关注过时保持可点，
                    // 让 addWatched 给出具体原因 —— 一个不会解释自己为什么
                    // 灰着的按钮，比点一下看到一句「格式不对」更让人卡住。
                    .disabled(emailInput.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.watchedAccountNames.isEmpty {
                Text(t("还没有关注任何账号。", "No accounts watched yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.watchedAccountNames, id: \.self) { account in
                    watchedRow(account)
                }
            }
        }
    }

    private func watchedRow(_ account: String) -> some View {
        let status = viewModel.watchStatus(for: account)
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusDot(status))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(account)
                    .font(.callout.weight(.medium))
                Text(statusText(status))
                    .font(.caption)
                    .foregroundStyle(statusTint(status))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.refresh(showIconSelfTest: false) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(Text(t("刷新", "Refresh")))

            Button(role: .destructive) {
                store.unwatch(account)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(Text(t("移除", "Remove")))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: - 状态文案

    private func addWatched() {
        let trimmed = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.isWatched(trimmed) {
            errorText = t("这个邮箱已经在关注列表里了。",
                          "This email is already in your watch list.")
            return
        }
        guard CodexWatchStore.isValidAccountName(trimmed) else {
            errorText = t("这看起来不是一个完整的邮箱地址。",
                          "That does not look like a complete email address.")
            return
        }
        guard store.watch(trimmed) else {
            errorText = t("添加失败，请重试。", "Could not add it. Please retry.")
            return
        }
        errorText = nil
        emailInput = ""
        emailFieldFocused = false
        // 刚加的邮箱可能已经在云端有数据了，立刻解析一次，
        // 免得用户盯着一个「还没数据」要等下一轮刷新。
        Task { await viewModel.refresh(showIconSelfTest: false) }
    }

    private func statusDot(_ status: CodexWatchStore.WatchStatus) -> Color {
        switch status {
        case .available: return .green
        case .noTeam: return .orange
        case .waitingForPublisher: return .secondary
        }
    }

    private func statusTint(_ status: CodexWatchStore.WatchStatus) -> Color {
        switch status {
        case .available: return .secondary
        case .noTeam, .waitingForPublisher: return .orange
        }
    }

    private func statusText(_ status: CodexWatchStore.WatchStatus) -> String {
        switch status {
        case .noTeam:
            return t("还没加入团队，暂时读不到别人的账号。",
                     "Not in a team yet, so no one else's account can be read.")
        case .waitingForPublisher:
            return t(
                "还没数据。让对方在这台 Mac 上勾选这个邮箱，并确认那台 Mac 在运行且已加入同一个团队。",
                "No data yet. Ask them to tick this address on their Mac, and check that Mac is running and in the same team.")
        case let .available(sampledAt, modelCount):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(
                for: sampledAt, relativeTo: Date())
            return t("团队云端 · \(modelCount) 条 · 更新于 \(relative)",
                     "Team cloud · \(modelCount) entries · updated \(relative)")
        }
    }
}
