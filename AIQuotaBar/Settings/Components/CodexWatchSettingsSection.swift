import SwiftUI

/// 「关注账号」设置区。两侧都在这里，因为它们是一次操作的两半：
///
/// - **分享侧**（owner）：勾选哪些 Codex 账号允许被别的 Mac 看到。
/// - **关注侧**（watcher）：只填一个邮箱，就能看到对方分享的额度。
///
/// 不需要建团队、不需要邀请码、不需要密钥，也不需要在关注方登录 Codex。
/// 传输走 app 自带的云端服务，关注的地址本身就是查找键。
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
                        "开启后，下面勾选的账号额度会发布到云端。任何装了 AI Quota Bar、并且知道这个邮箱的 Mac 都能看到它——不需要密钥，也不需要在对方登录 Codex。Codex 登录凭据始终不离开这台 Mac。",
                        "When on, the quota of the accounts checked below is published to the cloud. Any Mac running AI Quota Bar that knows the address can read it — no access key, and no Codex sign-in on their side. Codex credentials never leave this Mac."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if store.isSharing {
                if localCodexAccounts.isEmpty {
                    // 刻意不说「没有登录任何 Codex 账号」：这个列表来自本机
                    // 这一轮抓到的额度，可能是根本没抓，而不是没登录。两者
                    // 的用户动作完全相反，混淆只会让人以为 app 坏了。
                    HStack(spacing: 6) {
                        Text(t(
                            "还没有拿到这台 Mac 的 Codex 额度数据，所以列不出可分享的账号。",
                            "No Codex quota has been fetched on this Mac yet, so there is nothing to share yet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(t("重试", "Retry")) {
                            Task { await viewModel.refresh(showIconSelfTest: false) }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                } else {
                    ForEach(localCodexAccounts, id: \.self) { account in
                        Toggle(isOn: Binding(
                            get: { store.isShared(account) },
                            set: { store.setShared($0, for: account) })
                        ) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account).font(.callout)
                                if let reads = store.readCounts[
                                    CodexWatchStore.normalize(account)] {
                                    Text(readSummary(reads))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(t(
                        "默认一个都不分享，只有勾选的账号会发布。取消勾选会立刻从云端删除。",
                        "Nothing is shared by default — only checked accounts are published. Unchecking one deletes it from the cloud immediately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 关注侧

    private var watchSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("我关注的账号", "Accounts I watch"))
                .font(.headline)

            Text(t(
                "填一个邮箱就行，不需要加团队、不需要邀请码、不需要密钥。对方在他们的设置里勾了这个邮箱，这里就会显示它的额度。",
                "Just enter an email — no team, no invite code, no access key. Once the other Mac ticks that address in their settings, its quota shows up here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                Task { await viewModel.refreshCodexWatch() }
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
        // 刚加的地址可能已经有人分享，立刻解析一次，免得用户盯着
        // 「还没数据」要等下一轮刷新。
        Task { await viewModel.refreshCodexWatch() }
    }

    private func statusDot(_ status: CodexWatchStore.Status) -> Color {
        switch status {
        case .available: return .green
        case .loading: return .secondary
        case .stale, .unreachable: return .orange
        case .notShared: return .secondary
        }
    }

    private func statusTint(_ status: CodexWatchStore.Status) -> Color {
        switch status {
        case .available, .loading: return .secondary
        case .stale, .unreachable: return .orange
        case .notShared: return .secondary
        }
    }

    private func statusText(_ status: CodexWatchStore.Status) -> String {
        switch status {
        case .loading:
            return t("正在获取…", "Fetching…")
        case .notShared:
            return t(
                "还没有人分享这个邮箱。让对方在「允许其他 Mac 关注我的账号」里勾选它。",
                "Nobody is sharing this address yet. Ask them to tick it under \"Let other Macs watch my accounts\".")
        case .stale:
            return t(
                "对方已经很久没上报了，上面的数字可能是旧的。确认那台 Mac 上的 AI Quota Bar 还在运行。",
                "The other Mac has not reported for a while, so these numbers may be old. Check that AI Quota Bar is still running there.")
        case let .available(sampledAt, windowCount):
            guard let sampledAt else {
                return t("已连接", "Connected")
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: sampledAt, relativeTo: Date())
            return t("云端 · \(windowCount) 条 · 更新于 \(relative)",
                     "Cloud · \(windowCount) entries · updated \(relative)")
        case .unreachable:
            return t(
                "取不到数据，检查网络后再试。",
                "Could not fetch. Check your connection and try again.")
        }
    }

    private func readSummary(_ reads: CodexWatchReadCount) -> String {
        guard reads.readCount > 0, let last = reads.lastReadAt else {
            return t("还没有人看过", "Not read yet")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relative = formatter.localizedString(for: last, relativeTo: Date())
        return t("被查看 \(reads.readCount) 次 · 最近 \(relative)",
                 "Read \(reads.readCount) times · last \(relative)")
    }
}
