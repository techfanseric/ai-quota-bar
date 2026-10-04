import Foundation
import Observation

/// 一台被关注的 Mac。
///
/// 这里只存「去哪找它」这类非敏感信息；访问令牌不进这个结构，
/// 而是按 `id` 单独存在钥匙串里。
struct CodexWatchPeer: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// 用户给这台设备起的名字，默认用 owner 回报的主机名。
    var name: String
    var host: String
    var port: UInt16

    init(id: UUID = UUID(), name: String, host: String, port: UInt16) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
    }

    /// 钥匙串里存令牌的 binding。与本机自己的绑定空间隔离，
    /// 免得一条对端记录被误当成设备凭据。
    var credentialBinding: String { "codexWatch.peer.\(id.uuidString)" }
}

/// 一台对端的当前可见状态。
///
/// 刻意区分「没连上」和「连上了但没授权」：这两种情况用户的动作完全相反，
/// 合成一个错误提示只会让人反复点没用的按钮。
struct CodexWatchPeerStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// 还没抓过。
        case idle
        /// 正在抓。
        case loading
        /// 已授权，附账号额度。
        case ok(updatedAt: Date)
        /// 对端在线，但没授权任何账号 / 没开这个功能。
        case notAuthorized(hostName: String?)
        /// 对端没开「被关注」。
        case disabled(hostName: String?)
        /// 令牌不对。
        case invalidToken
        /// 设备不可达。
        case unreachable
    }

    var state: State
    /// owner 回报的主机名，用于在列表里显示真实设备名。
    var hostName: String?
    /// 最近一次成功抓到的时刻。不可达时状态会退化成 `.unreachable`，
    /// 但这份时刻必须留着——它是「这个数字是什么时候的」的唯一依据，
    /// 界面上要靠它标出陈旧程度。
    var updatedAt: Date?

    static let idle = CodexWatchPeerStatus(
        state: .idle, hostName: nil, updatedAt: nil)
}

/// Watcher 侧的「我关注了哪些 Mac」。
///
/// 令牌一律走钥匙串（复用 `deviceCredentials` 那条既有通道），
/// UserDefaults 里只有地址和显示名。
@MainActor
@Observable
final class CodexWatchPeerStore {
    static let shared = CodexWatchPeerStore()

    private(set) var peers: [CodexWatchPeer]
    /// 按 peer id 索引的状态，供 UI 直接渲染。
    private(set) var statuses: [UUID: CodexWatchPeerStatus]
    /// 每个 peer 最近一次成功抓到的账号额度。
    private(set) var accountsByPeer: [UUID: [CodexWatchAccount]]

    /// 测试用：塞入一台对端，不触碰钥匙串。
    /// 只给纯内存状态用，所以刻意不写 UserDefaults。
    func seedForTesting(_ peer: CodexWatchPeer) {
        peers = [peer]
        statuses[peer.id] = .idle
        accountsByPeer[peer.id] = []
    }

    private let defaults: UserDefaults
    private let client: CodexWatchPeerClient
    private let credentialStore: KeychainService
    private var refreshTask: Task<Void, Never>?

    /// 轮询间隔。额度本身变化很慢（5h/周窗口），60 秒足够；
    /// 更快只是徒增局域网流量和 owner 的唤醒次数。
    static let refreshInterval: TimeInterval = 60

    private static let peersKey = "codexWatch.peers.v1"

    init(
        defaults: UserDefaults = .standard,
        client: CodexWatchPeerClient = CodexWatchPeerClient(),
        credentialStore: KeychainService = .shared
    ) {
        self.defaults = defaults
        self.client = client
        self.credentialStore = credentialStore
        self.peers = Self.decodePeers(defaults)
        self.statuses = [:]
        self.accountsByPeer = [:]
    }

    // MARK: - 名单维护

    /// 添加一台对端。返回 false 表示地址不合法（这时不会留下半条记录）。
    @discardableResult
    func addPeer(
        name: String,
        host: String,
        port: UInt16,
        token: String
    ) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty,
              CodexWatchPeerClient.makeURL(host: host, port: port) != nil
        else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let peer = CodexWatchPeer(
            name: trimmedName.isEmpty ? host : trimmedName,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: port)
        // 同一个地址重复添加会让菜单里出现两条一模一样的账号，
        // 用户很难分辨，索性按 host:port 去重。
        guard !peers.contains(where: {
            $0.host.caseInsensitiveCompare(peer.host) == .orderedSame
                && $0.port == peer.port
        }) else { return false }

        peers.append(peer)
        peers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        statuses[peer.id] = .idle
        accountsByPeer[peer.id] = []
        Task { await saveToken(trimmedToken, for: peer) }
        return true
    }

    func removePeer(_ id: UUID) {
        guard peers.contains(where: { $0.id == id }) else { return }
        peers.removeAll { $0.id == id }
        statuses[id] = nil
        accountsByPeer[id] = nil
        persist()
        Task { _ = await credentialStore.deleteDeviceCredential(binding: binding(for: id)) }
    }

    func peer(with id: UUID) -> CodexWatchPeer? {
        peers.first { $0.id == id }
    }

    func status(for id: UUID) -> CodexWatchPeerStatus {
        statuses[id] ?? .idle
    }

    // MARK: - 轮询

    /// 启动后台轮询。重复调用是安全的。
    func startPolling() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = await Self.refreshInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// 手动刷新单个对端（设置页的刷新按钮）。
    func refreshNow(id: UUID) async {
        await refresh(id: id)
    }

    func refreshAll() async {
        for peer in peers {
            await refresh(id: peer.id)
        }
    }

    private func refresh(id: UUID) async {
        guard let peer = peer(with: id) else { return }
        statuses[id] = CodexWatchPeerStatus(state: .loading, hostName: nil)
        guard let token = await credentialStore.deviceCredential(
            binding: binding(for: id))
        else {
            // 令牌读不出来（钥匙串失败 / 记录被清）时按失效处理，
            // 让用户重新填，而不是每 60 秒静默重试一次。
            statuses[id] = CodexWatchPeerStatus(
                state: .invalidToken,
                hostName: nil,
                updatedAt: nil)
            accountsByPeer[id] = []
            return
        }

        let result = await client.fetch(
            host: peer.host, port: peer.port, token: token)
        apply(result, for: id)
    }

    /// 把一次抓取结果落到状态机里。
    ///
    /// 单独抽出来是因为这段状态迁移是「断网 / 撤销授权 / 令牌失效」
    /// 三种情况唯一会分叉的地方，也是最需要被测的部分。
    /// 每种结果如何影响已有缓存都在这里决定，不散落在调用方。
    func apply(_ result: CodexWatchFetchResult, for id: UUID) {
        let previous = statuses[id]
        switch result {
        case let .ok(response):
            statuses[id] = CodexWatchPeerStatus(
                state: .ok(updatedAt: response.generatedAt),
                hostName: response.hostName,
                updatedAt: response.generatedAt)
            accountsByPeer[id] = response.accounts
        case let .notAuthorized(response):
            statuses[id] = CodexWatchPeerStatus(
                state: .notAuthorized(hostName: response.hostName),
                hostName: response.hostName,
                updatedAt: nil)
            // 授权可能刚被撤销，本地缓存必须一起清掉，
            // 否则菜单里会继续显示一份已经不获授权的额度。
            accountsByPeer[id] = []
        case let .disabled(response):
            statuses[id] = CodexWatchPeerStatus(
                state: .disabled(hostName: response.hostName),
                hostName: response.hostName ?? previous?.hostName,
                updatedAt: nil)
            accountsByPeer[id] = []
        case .invalidToken:
            statuses[id] = CodexWatchPeerStatus(
                state: .invalidToken,
                hostName: previous?.hostName,
                updatedAt: nil)
            accountsByPeer[id] = []
        case .unreachable:
            // 不可达时保留上一份数据：短暂断网时把额度从菜单里抹掉，
            // 会让用户以为额度突然清零了。状态单独用陈旧标记呈现。
            statuses[id] = CodexWatchPeerStatus(
                state: .unreachable,
                hostName: previous?.hostName,
                updatedAt: previous?.updatedAt)
        }
    }

    // MARK: - 显示数据

    /// 把所有对端的账号摊平成菜单可用的模型。
    ///
    /// `accountName` 加设备名前缀：同一个邮箱可能在两台被关注的 Mac 上
    /// 都登录着，不加前缀菜单里就会出现两行同名账号，用户无从分辨。
    func displayModels(now: Date = Date()) -> [ModelUsageData] {
        var models: [ModelUsageData] = []
        for peer in peers {
            let status = statuses[peer.id] ?? .idle
            // 只有明确「连上且已授权」或「暂时不可达但有陈旧数据」才产出模型。
            // 不可达时保留上一份额度：断网瞬间把数字抹掉，用户会误以为
            // 额度清零了，这比显示一个标了 offline 的旧数字糟糕得多。
            let updatedAt: Date
            switch status.state {
            case let .ok(at):
                updatedAt = at
            case .unreachable:
                updatedAt = status.updatedAt ?? .distantPast
            default:
                continue
            }
            let accounts = accountsByPeer[peer.id] ?? []
            guard !accounts.isEmpty else { continue }
            let label = displayLabel(for: peer, status: status)
            for account in accounts {
                for window in account.windows {
                    models.append(model(
                        account: account,
                        window: window,
                        peer: peer,
                        label: label,
                        updatedAt: updatedAt,
                        now: now))
                }
            }
        }
        return models
    }

    private func displayLabel(
        for peer: CodexWatchPeer,
        status: CodexWatchPeerStatus
    ) -> String {
        let host = status.hostName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (host?.isEmpty == false ? host! : peer.name)
        return "\(base) · \(peer.name == base ? peer.host : peer.name)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func model(
        account: CodexWatchAccount,
        window: CodexWatchWindow,
        peer: CodexWatchPeer,
        label: String,
        updatedAt: Date,
        now: Date
    ) -> ModelUsageData {
        let remaining = max(0, min(100, window.remainingPercent))
        // 对端安静下来时 `resetsAt` 会落到过去。若照搬，菜单会因为
        // 「不在当前区间内」把这条账号整条抹掉——而这恰恰是「关注」
        // 最不能接受的行为：用户明确要看它，它不该自己消失。
        // 这里把窗口下限撑到当下，并标记为陈旧。
        let expired = (window.resetsAt ?? .distantFuture) <= now
        let nominalEnd = window.resetsAt ?? now.addingTimeInterval(5 * 3600)
        let end = max(nominalEnd, now.addingTimeInterval(60))
        let start = min(
            end.addingTimeInterval(
                -(window.isShortWindow ? 5 * 3600 : 7 * 24 * 3600)),
            now)
        let stale = expired || status(for: peer.id).state == .unreachable
        let detail = Self.detailText(
            plan: account.plan,
            host: label,
            stale: stale)
        return ModelUsageData(
            provider: .codex,
            accountName: "\(account.accountName) @ \(label)",
            modelName: window.name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remaining,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: max(0, Int(end.timeIntervalSince(now) * 1000)),
            startTime: start,
            endTime: end,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: detail,
            currentIntervalRemainingPercent: remaining,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: window.sampledAt ?? updatedAt)
    }

    private static func detailText(
        plan: String?,
        host: String,
        stale: Bool
    ) -> String {
        var parts: [String] = []
        if let plan, !plan.isEmpty { parts.append(plan) }
        parts.append(CodexWatchPeerModel.sourcePrefix + host)
        // 两种陈旧的成因不同，用户要做的动作也不同：一个是对方设备
        // 暂时联系不上，一个是额度窗口已经过去需要对方再刷新一次。
        if stale { parts.append("stale") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 持久化

    private func binding(for id: UUID) -> String {
        CodexWatchPeer(id: id, name: "", host: "", port: 0).credentialBinding
    }

    private func saveToken(_ token: String, for peer: CodexWatchPeer) async {
        _ = await credentialStore.saveDeviceCredential(
            token, binding: peer.credentialBinding)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(peers) else { return }
        defaults.set(data, forKey: Self.peersKey)
    }

    private static func decodePeers(_ defaults: UserDefaults) -> [CodexWatchPeer] {
        guard let data = defaults.data(forKey: peersKey),
              let decoded = try? JSONDecoder().decode(
                [CodexWatchPeer].self, from: data)
        else { return [] }
        return decoded.filter { !$0.host.isEmpty }
    }
}
