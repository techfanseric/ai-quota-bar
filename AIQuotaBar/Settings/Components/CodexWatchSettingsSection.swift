import SwiftUI

/// 「关注账号」设置区。两侧都在这里，因为它们是一次操作的两半：
///
/// - **分享侧**（owner）：勾选哪些 Codex 账号允许被局域网其他 Mac 读取。
///   默认全关；凭据不会离开本机，对端拿到的只是额度数字。
/// - **关注侧**（watcher）：填对方的局域网地址与访问密钥，把它加进关注列表。
///
/// 两半互不依赖：只想被看的人只开分享，只想看别人的人只加对端。
@MainActor
struct CodexWatchSettingsSection: View {
    let language: AppLanguage
    /// 本机当前可见的 Codex 账号，供分享侧勾选。
    let localCodexAccounts: [String]
    @State private var showAddPeer = false

    private var grants: CodexWatchGrantStore { .shared }
    private var peers: CodexWatchPeerStore { .shared }

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
                get: { grants.isServing },
                set: { enabled in
                    grants.isServing = enabled
                })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("允许其他 Mac 关注我的账号", "Let other Macs watch my accounts"))
                    Text(t(
                        "开启后，同一局域网内持有访问密钥的 Mac 可以读取下面勾选账号的额度。只有额度数字会被读走，Codex 登录凭据不会离开这台 Mac，也不需要建团队。",
                        "When on, Macs on this LAN holding the access key can read the quota of the accounts checked below. Only quota numbers are shared — Codex credentials never leave this Mac, and no team is required."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            if grants.isServing {
                if localCodexAccounts.isEmpty {
                    Text(t(
                        "这台 Mac 还没有可分享的 Codex 账号。",
                        "This Mac has no shareable Codex account yet."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(localCodexAccounts, id: \.self) { account in
                        Toggle(isOn: Binding(
                            get: { grants.isAllowed(account) },
                            set: { allowed in
                                // 授权可以随时收紧；grant store 的
                                // onChange 会让服务立刻重算对外应答。
                                grants.setAllowed(allowed, for: account)
                            })
                        ) {
                            Text(account)
                                .font(.callout)
                        }
                        .toggleStyle(.checkbox)
                    }
                }

                Text(t(
                    "对方需要密钥才能读取。密钥在「手机看板」里生成或重置。",
                    "Peers need the access key. Generate or reset it in Mobile Dashboard."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 关注侧

    private var watchSide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t("我关注的账号", "Accounts I watch"))
                    .font(.headline)
                Spacer()
                Button {
                    showAddPeer = true
                } label: {
                    Label(t("添加设备", "Add device"),
                          systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text(t(
                "把另一台装了 AI Quota Bar 的 Mac 加进来，就能看到它授权给你的 Codex 额度。不需要建团队，连接只走局域网。",
                "Add another Mac running AI Quota Bar to see the Codex quota it shares with you. No team required; the connection stays on your LAN."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if peers.peers.isEmpty {
                Text(t("还没有关注任何设备。", "No devices watched yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(peers.peers) { peer in
                    peerRow(peer)
                }
            }
        }
        .sheet(isPresented: $showAddPeer) {
            AddCodexWatchPeerSheet(language: language)
        }
    }

    private func peerRow(_ peer: CodexWatchPeer) -> some View {
        let status = peers.status(for: peer.id)
        let accountCount = peers.accountsByPeer[peer.id]?.count ?? 0
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusDot(status.state))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .font(.callout.weight(.medium))
                Text("\(peer.host):\(peer.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(statusText(status, accountCount: accountCount))
                    .font(.caption)
                    .foregroundStyle(status.state == .ok(updatedAt: .distantPast)
                        ? Color.secondary : statusTint(status.state))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                Task { await peers.refreshNow(id: peer.id) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(status.state == .loading)
            .accessibilityLabel(Text(t("刷新", "Refresh")))

            Button(role: .destructive) {
                peers.removePeer(peer.id)
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

    private func statusDot(_ state: CodexWatchPeerStatus.State) -> Color {
        switch state {
        case .ok: return .green
        case .loading: return .secondary
        case .unreachable: return .orange
        case .notAuthorized, .disabled, .invalidToken: return .red
        case .idle: return .secondary
        }
    }

    private func statusTint(_ state: CodexWatchPeerStatus.State) -> Color {
        switch state {
        case .ok, .idle, .loading: return .secondary
        case .unreachable, .notAuthorized, .disabled, .invalidToken:
            return .orange
        }
    }

    private func statusText(
        _ status: CodexWatchPeerStatus,
        accountCount: Int
    ) -> String {
        switch status.state {
        case .idle:
            return t("等待首次获取", "Waiting for first fetch")
        case .loading:
            return t("正在获取…", "Fetching…")
        case let .ok(updatedAt):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(
                for: updatedAt, relativeTo: Date())
            return accountCount == 0
                ? t("已连接，但对方还没有可显示的额度 · \(relative)",
                     "Connected, but nothing to show yet · \(relative)")
                : t("已更新 · \(accountCount) 个账号 · \(relative)",
                     "Updated · \(accountCount) accounts · \(relative)")
        case .notAuthorized:
            return t(
                "对方还没授权任何账号。请在对方的「允许其他 Mac 关注我的账号」里勾选。",
                "The other Mac has not shared any account yet. Ask them to tick an account under \"Let other Macs watch my accounts\".")
        case .disabled:
            return t(
                "对方没有开启分享。",
                "The other Mac has not enabled sharing.")
        case .invalidToken:
            return t(
                "访问密钥无效，请向对方索取新的密钥。",
                "The access key is invalid. Ask the other Mac for a fresh one.")
        case .unreachable:
            return t(
                "连不上对方。确认它在同一局域网、地址正确，且 AI Quota Bar 在运行。",
                "Cannot reach the other Mac. Check it is on the same LAN, the address is right, and AI Quota Bar is running.")
        }
    }
}

/// 添加一台对端设备。
private struct AddCodexWatchPeerSheet: View {
    let language: AppLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var host = ""
    @State private var port = String(CodexWatchEndpoint.defaultPort)
    @State private var token = ""
    @State private var errorText: String?
    @State private var isTesting = false

    private var peers: CodexWatchPeerStore { .shared }

    private func t(_ zh: String, _ en: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("添加关注的设备", "Add a device to watch"))
                .font(.title2)

            Text(t(
                "在对方 Mac 的「手机看板」里找到访问地址与密钥，填到这里。密钥只保存在这台 Mac 的钥匙串里。",
                "Take the access address and key from the other Mac's Mobile Dashboard. The key is stored only in this Mac's Keychain."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(t("备注名（可选）", "Label (optional)"), text: $name)
            TextField(t("IP 地址或主机名", "IP address or host name"), text: $host)
            TextField(t("端口", "Port"), text: $port)
                .textFieldStyle(.roundedBorder)

            SecureField(t("访问密钥", "Access key"), text: $token)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(t("取消", "Cancel")) { dismiss() }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
                Button(t("测试并添加", "Test & add")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || !canSubmit)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var parsedPort: UInt16? {
        UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
    }

    private func submit() {
        guard let parsedPort, canSubmit else { return }
        isTesting = true
        errorText = nil
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // 先握手一次再入库：地址写错、对方没开分享、密钥不对，
            // 都在这一步变成一句明确的话，而不是加进去之后菜单里
            // 永远显示一个连不上的条目。
            let probe = CodexWatchPeerClient()
            let result = await probe.fetch(
                host: trimmedHost, port: parsedPort, token: trimmedToken)
            switch result {
            case .ok, .notAuthorized, .disabled:
                if peers.addPeer(
                    name: name, host: trimmedHost, port: parsedPort,
                    token: trimmedToken)
                {
                    await peers.refreshNow(
                        id: peers.peers.last?.id ?? UUID())
                    dismiss()
                } else {
                    errorText = t(
                        "这台设备已经在关注列表里了。",
                        "This device is already in your watch list.")
                }
            case .invalidToken:
                errorText = t(
                    "访问密钥不对。请确认复制的是「手机看板」里的那一个。",
                    "The access key is incorrect. Make sure you copied the one from Mobile Dashboard.")
            case let .unreachable(reason):
                errorText = reason == "incompatible"
                    ? t("对方版本太旧，无法支持关注功能。",
                         "The other Mac is too old to support watching.")
                    : t(
                        "连不上。确认两台 Mac 在同一局域网、地址和端口正确。",
                        "Cannot connect. Check both Macs are on the same LAN and the address and port are correct.")
            }
            isTesting = false
        }
    }
}
