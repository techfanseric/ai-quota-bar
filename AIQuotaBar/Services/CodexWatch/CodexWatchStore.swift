import Foundation
import Observation

/// 「关注账号」的本机状态。两侧各一份名单，存的都只是邮箱。
///
/// 传输走 app 自带的公共服务端点上的 `/v1/watch/*`，**不经过团队体系**：
/// 关注一个账号不需要建团队、不需要邀请码、不需要密钥。登录了那个账号的 Mac
/// 自己抓额度并发布，任何装了本 app、知道这个邮箱的 Mac 都能读到。
///
/// 名单里没有任何凭据，明文存 UserDefaults 是安全的。
@MainActor
@Observable
final class CodexWatchStore {
    static let shared = CodexWatchStore()

    // MARK: - 分享侧（本机是被关注的那一方）

    /// 「允许其他 Mac 关注我的账号」。
    ///
    /// 关着的时候**完全不做任何发布**：Codex 额度照旧按「共享账号额度」的原有
    /// 行为走团队通道。已经开了团队同步的老用户升级后行为不变，只有主动打开
    /// 这个开关的人才开始把额度发到这个公开的地址索引里。
    var isSharing: Bool {
        didSet {
            guard isSharing != oldValue else { return }
            defaults.set(isSharing, forKey: Self.sharingKey)
            onChange?()
        }
    }

    private(set) var sharedAccountNames: [String]

    // MARK: - 关注侧（本机在看别人的账号）

    private(set) var watchedAccountNames: [String]

    /// 每个被关注地址最近一次拿到的快照。key 是归一后的邮箱。
    private(set) var snapshots: [String: CodexWatchSnapshot] = [:]
    /// 正在获取的地址，避免重复打网络。
    private(set) var loadingAccountNames: Set<String> = []
    /// 最近一次失败的原因，按地址存。
    private(set) var lastErrors: [String: String] = [:]
    /// **这一轮真的拉到了新数据**的地址。
    ///
    /// 「没读回来」和「读回来只有一个点」必须分开：失败或过期时缓存里的旧快照会
    /// 继续留在 `snapshots` 里（行不能凭空消失），如果照单全收地拿去采样，等于
    /// 把同一个旧数字当成一次新读数再记一遍，画出来是一条比真实更平的假曲线。
    private(set) var freshlyFetchedAccountNames: Set<String> = []
    /// 本机发布的账号各被读取过多少次。
    private(set) var readCounts: [String: CodexWatchReadCount] = [:]

    /// 名单变化。上报侧挂它来重新发布，关注侧挂它来重新解析。
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored let client: CodexWatchCloudClient

    private let defaults: UserDefaults

    private static let sharingKey = "codexWatch.isSharing"
    private static let sharedKey = "codexWatch.shared.v1"
    private static let watchedKey = "codexWatch.watched.v1"

    init(
        defaults: UserDefaults = .standard,
        client: CodexWatchCloudClient = CodexWatchCloudClient()
    ) {
        self.defaults = defaults
        self.client = client
        // v1.32.x 用的是「局域网 + 访问密钥」那套开关/授权键。直接沿用，
        // 用户已经勾好的账号不用重新勾一遍。
        let stored = defaults.object(forKey: Self.sharingKey) as? Bool
        let legacy = defaults.object(forKey: "codexWatch.isServing") as? Bool
        self.isSharing = stored ?? legacy ?? false
        let legacyShared = Self.legacyAllowedNames(defaults).joined(separator: "\n")
        self.sharedAccountNames = Self.decode(
            defaults.string(forKey: Self.sharedKey) ?? legacyShared)
        self.watchedAccountNames = Self.decode(defaults.string(forKey: Self.watchedKey))
    }

    // MARK: - 分享侧查询 / 变更

    func isShared(_ accountName: String) -> Bool {
        contains(sharedAccountNames, accountName)
    }

    func setShared(_ shared: Bool, for accountName: String) {
        guard let name = Self.displayName(accountName) else { return }
        // SwiftUI 的 Toggle 在视图重建时会重复投递同一个值。不去重的话
        // 每一次重建都会触发一次全量用量刷新，白白打云端。
        guard isShared(name) != shared else { return }
        sharedAccountNames = Self.replacing(sharedAccountNames, name, include: shared)
        persist(sharedAccountNames, key: Self.sharedKey)
        if !shared {
            // 取消勾选要立刻反映在「被读取次数」里，否则用户会看到一个
            // 已经不再分享的账号的历史计数。
            readCounts.removeValue(forKey: Self.normalize(name))
        }
        onChange?()
    }

    /// 把本机 Codex 额度投影成可发布的快照，**只含勾选的账号**。
    ///
    /// - 非 Codex 供应商不参与：这里只管 Codex 的关注开关，不改变
    ///   Kimi / GLM / MiniMax 原有的团队共享行为。
    /// - `isSharing == false` 时返回空数组，语义是「一个都不发布」。
    /// - 账号名为空的未归属额度不发布：它没法被按邮箱关注。
    func publishableSnapshots(from usageData: UsageData?) -> [CodexWatchAccountSnapshot] {
        guard isSharing, let usageData, usageData.provider == .codex else { return [] }
        var result: [CodexWatchAccountSnapshot] = []
        var seen = Set<String>()

        for account in sharedAccountNames {
            let key = Self.normalize(account)
            guard seen.insert(key).inserted else { continue }
            let models = usageData.models.filter {
                Self.normalize($0.accountName ?? "") == key
            }
            guard !models.isEmpty else { continue }
            // One account collapses into a few windows (5h / Weekly / …); the
            // same window name can appear on several models, so keep the one with
            // the freshest sample rather than whichever came last.
            var windows: [String: CodexWatchWindow] = [:]
            for model in models {
                guard let percent = model.currentIntervalRemainingPercent ?? nil else {
                    continue
                }
                let name = model.modelName
                // 采样时间只能来自「这条数据是什么时候量的」。endTime 是窗口边界
                // （周窗口就是 resetsAt，可能在几天之后），拿它兜底会把一个未来的
                // 时刻发布出去，读侧菜单显示「更新于 10/11 23:59」—— 数据是新的，
                // 时间却是错的。宁可没有时间，也不要一个错的时间。
                let sampled = model.sampledAt ?? usageData.timestamp
                if let existing = windows[name],
                   let existingDate = existing.sampledAt,
                   sampled < existingDate { continue }
                windows[name] = CodexWatchWindow(
                    name: name,
                    remainingPercent: percent,
                    resetsAt: model.endTime,
                    sampledAt: sampled,
                    startsAt: model.startTime)
            }
            guard !windows.isEmpty else { continue }
            result.append(CodexWatchAccountSnapshot(
                account: key,
                plan: usageData.models.compactMap { model in
                    Self.normalize(model.accountName ?? "") == key
                        ? CodexWatchStore.planName(from: model) : nil
                }.first,
                windows: windows.values.sorted { $0.name < $1.name }))
        }
        return result
    }

    /// 发布 + 拉取本机关注的所有地址 + 拉取被读取次数。一次刷新做完三件事。
    func refresh(usageData: UsageData?) async {
        // `usageData == nil` means this cycle produced no local Codex quota (provider
        // error, or Codex is not signed in here). Publishing then would send an empty
        // set and delete every account -- so a transient network blip would silently
        // un-share the account. Only publish when we actually have data to publish;
        // "uncheck everything" is expressed by an empty share list, not by nil data.
        if isSharing {
            if let usageData {
                _ = await client.publish(
                    publisher: CloudWatchPublisher.current,
                    snapshots: publishableSnapshots(from: usageData))
            }
            readCounts = await client.fetchReadCounts(accounts: sharedAccountNames)
        } else {
            readCounts = [:]
        }
        freshlyFetchedAccountNames = []
        for account in watchedAccountNames {
            await refreshOne(account)
        }
    }

    // MARK: - 关注侧查询 / 变更

    func isWatched(_ accountName: String) -> Bool {
        contains(watchedAccountNames, accountName)
    }

    /// 加入关注列表。返回 false 表示重复添加或邮箱格式不可用。
    @discardableResult
    func watch(_ accountName: String) -> Bool {
        guard let name = Self.displayName(accountName), !isWatched(name) else {
            return false
        }
        watchedAccountNames.append(name)
        persist(watchedAccountNames, key: Self.watchedKey)
        onChange?()
        return true
    }

    func unwatch(_ accountName: String) {
        let key = Self.normalize(accountName)
        guard !key.isEmpty,
              let index = watchedAccountNames.firstIndex(
                where: { Self.normalize($0) == key })
        else { return }
        watchedAccountNames.remove(at: index)
        // 取消关注后必须丢掉快照，否则菜单里会继续显示一个已经不再关注的账号。
        snapshots.removeValue(forKey: key)
        loadingAccountNames.remove(key)
        lastErrors.removeValue(forKey: key)
        persist(watchedAccountNames, key: Self.watchedKey)
        onChange?()
    }

    func status(for accountName: String) -> Status {
        let key = Self.normalize(accountName)
        guard !key.isEmpty else { return .notShared }
        if loadingAccountNames.contains(key) { return .loading }
        // Staleness is checked *before* availability. A cached snapshot survives a
        // stale response on purpose (the row must not vanish), so testing presence
        // first would report those old numbers as current -- the exact thing the
        // stale state exists to prevent.
        if lastErrors[key] == "stale" { return .stale }
        if let snapshot = snapshots[key] {
            let sampledAt = snapshot.windows.compactMap(\.sampledAt).max()
                ?? snapshot.publishedAt
            return .available(sampledAt: sampledAt, windowCount: snapshot.windows.count)
        }
        // A snapshot can be absent because nobody publishes the address, or because
        // the last fetch failed. The two send the user to different places, so the
        // reason has to survive to the UI rather than collapsing into "no data".
        if let reason = lastErrors[key] { return .unreachable(reason) }
        return .notShared
    }

    /// 关注来的账号当前处于什么状态。
    ///
    /// 每一种「看不到数据」都对应完全不同的用户动作，混成一个「无数据」会让人
    /// 以为该重装点什么，所以这里逐一分开。
    enum Status: Equatable {
        /// 正在获取。
        case loading
        /// 有数据。
        case available(sampledAt: Date?, windowCount: Int)
        /// 没有任何人在分享这个邮箱 → 让对方去勾选。
        case notShared
        /// 对方分享了，但太久没上报，数字可能过期 → 让对方把 app 打开。
        case stale
        /// 网络失败 → 检查网络。
        case unreachable(String)
    }

    /// 关注来的额度，投影成菜单能直接渲染的模型行。
    ///
    /// 这些行**永远不会**被再发布出去：发布源是本机登录的账号仓库，不是菜单
    /// 这份合并后的数据，所以不存在把别人的额度当自己的转发。
    var watchedModels: [ModelUsageData] {
        watchedModels(onlyFreshlyFetched: false)
    }

    /// 只包含**这一轮真的拉回来**的那些账号。
    ///
    /// 采样专用：曲线是「用量随时间怎么走」的证据，把一次没读回来的旧数字
    /// 记成新点，得到的线会比真实情况平 —— 那是在编数据，不是缺数据。
    var freshlyFetchedModels: [ModelUsageData] {
        watchedModels(onlyFreshlyFetched: true)
    }

    private func watchedModels(onlyFreshlyFetched: Bool) -> [ModelUsageData] {
        var result: [ModelUsageData] = []
        for account in watchedAccountNames {
            let key = Self.normalize(account)
            if onlyFreshlyFetched, !freshlyFetchedAccountNames.contains(key) { continue }
            guard let snapshot = snapshots[key] else { continue }
            for window in snapshot.windows {
                result.append(Self.model(for: snapshot, window: window))
            }
        }
        return result
    }

    // MARK: - 测试支撑

    /// 只给测试用：塞一份已获取的快照，绕开网络。
    func seedSnapshotForTesting(account: String, snapshot: CodexWatchSnapshot) {
        snapshots[Self.normalize(account)] = snapshot
    }

    /// 只给测试用：标记为过期，模拟服务端返回 410 之后的状态。
    func markStaleForTesting(_ account: String) {
        lastErrors[Self.normalize(account)] = "stale"
    }

    // MARK: - 私有

    private func refreshOne(_ accountName: String) async {
        let key = Self.normalize(accountName)
        guard !key.isEmpty, !loadingAccountNames.contains(key) else { return }
        loadingAccountNames.insert(key)
        let result = await client.fetch(account: key)
        loadingAccountNames.remove(key)
        switch result {
        case let .available(snapshot):
            snapshots[key] = snapshot
            lastErrors.removeValue(forKey: key)
            // Only a 200 counts as a reading. `.stale` keeps the row but its
            // numbers are older than `staleAfter`, and `.unreachable` means we
            // never got an answer at all.
            freshlyFetchedAccountNames.insert(key)
        case let .stale(snapshot):
            // 保留上一份数据并标 stale，而不是让行凭空消失：用户明确点名了这个
            // 账号，数字过期不等于额度清零。
            if let previous = snapshots[key], !snapshot.windows.isEmpty {
                snapshots[key] = previous
            }
            lastErrors[key] = "stale"
        case .notShared:
            snapshots.removeValue(forKey: key)
            lastErrors.removeValue(forKey: key)
        case let .unreachable(reason):
            lastErrors[key] = reason
        }
    }

    private static func model(
        for snapshot: CodexWatchSnapshot, window: CodexWatchWindow
    ) -> ModelUsageData {
        let resetsAt = window.resetsAt
        let remainingMs = resetsAt.map { $0.timeIntervalSinceNow * 1000 }
        let plan = snapshot.plan ?? "Codex"
        // The window start is what turns a bare percentage into a real window:
        // pace, curve bounds and "is this row still in its cycle" all read it.
        // A start that is in the future or after the reset is not a window at
        // all, and adopting it would make the row render as out-of-cycle --
        // i.e. invisible. Drop it and keep the bare percentage instead.
        let startsAt = window.startsAt.flatMap { start -> Date? in
            guard start < Date(), start < (resetsAt ?? .distantFuture) else { return nil }
            return start
        } ?? Self.derivedWeeklyWindowStart(name: window.name, resetsAt: resetsAt)
        return ModelUsageData(
            provider: .codex,
            accountName: snapshot.account,
            modelName: window.name,
            currentIntervalTotal: 100,
            currentIntervalUsed: window.remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: Int(max(0, remainingMs ?? 0)),
            startTime: startsAt,
            endTime: resetsAt,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            // "Watch" as the source keeps these rows from being read as team cloud
            // data, whose staleness and deletion rules are different.
            detailText: "\(plan) · Watch",
            currentIntervalRemainingPercent: window.remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: Self.coherentSampleTime(window.sampledAt, publishedAt: snapshot.publishedAt))
    }

    /// 采样时间不能晚于「云端收到这条数据的那一刻」。
    ///
    /// 发布方早于 v1.34.1 时把窗口结束时刻当采样时刻发上来（周窗口就是几天后的
    /// resetsAt）。菜单右端据此显示「更新于 10/11 23:59」—— 一个未来的时刻，
    /// 读起来像"五天后才更新"，实际数据是几分钟前的。这种时间比没有时间更糟：
    /// 用户会去判断是不是坏了。
    ///
    /// 所以未来的采样时刻按不可信处理，退回发布时刻（服务端自己打的时刻，一定
    /// 不晚于现在）。这样**对方不升级 app**，读侧也能立刻显示正确时间。
    nonisolated static func coherentSampleTime(_ sampledAt: Date?, publishedAt: Date?) -> Date? {
        guard let sampledAt else { return publishedAt }
        guard sampledAt <= Date() else { return publishedAt }
        return sampledAt
    }

    /// 发布方还没带窗口起点时，按周窗口的长度反推一个。
    ///
    /// 只有名字明确是周/7 天窗口才这么做 —— 5h 窗口的长度取决于那台 Mac 什么时候
    /// 开的窗口，从重置时间反推会把节奏算错，而 7 天是周窗口定义上的长度，
    /// 配合同一个 `resetsAt` 就是它真实的起点。这条推导让**还没升级发布方**的
    /// 账号也能立刻拿到曲线，而不是等对方发版之后再重新累积历史。
    nonisolated static func derivedWeeklyWindowStart(name: String, resetsAt: Date?) -> Date? {
        guard let resetsAt else { return nil }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isWeekly = normalized.contains("weekly") || normalized == "7d"
        guard isWeekly else { return nil }
        let start = resetsAt.addingTimeInterval(-7 * 86_400)
        return start < Date() ? start : nil
    }

    private static func planName(from model: ModelUsageData) -> String? {        guard let detail = model.parsedDetail.plan else { return nil }
        return detail.isEmpty ? nil : detail
    }

    private func contains(_ list: [String], _ accountName: String) -> Bool {
        let key = Self.normalize(accountName)
        guard !key.isEmpty else { return false }
        return list.contains { Self.normalize($0) == key }
    }

    private func persist(_ list: [String], key: String) {
        defaults.set(list.joined(separator: "\n"), forKey: key)
    }

    private static func replacing(
        _ list: [String], _ name: String, include: Bool
    ) -> [String] {
        let key = normalize(name)
        var result = list.filter { normalize($0) != key }
        if include { result.append(name) }
        return result
    }

    private static func displayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isValidAccountName(trimmed) else { return nil }
        return trimmed
    }

    /// 大小写与首尾空白归一。邮箱在 ChatGPT 侧本身不区分大小写，
    /// 但用户手填时很容易带上空格或大写，不归一会导致「填了却不生效」。
    nonisolated static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 邮箱格式校验。故意收得很紧：这里只接受看起来像邮箱的字符串，
    /// 免得用户粘进来一段带路径的 URL，被当成账号名发布出去。
    nonisolated static func isValidAccountName(_ raw: String) -> Bool {
        let value = normalize(raw)
        guard value.count <= 254, !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }
        // 连续的点号只可能出现在拼错的域名里。
        guard !value.contains("..") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let (local, domain) = (parts[0], parts[1])
        guard !local.isEmpty, local.count <= 64, !domain.isEmpty,
              domain.contains("."), !domain.hasPrefix("."),
              !domain.hasSuffix("."), !domain.hasPrefix("-"),
              !domain.hasSuffix("-")
        else { return false }
        // URL / 显示名残留物。atext 本身允许 `/` `?` `#`，但用户粘进来的
        // 「邮箱」如果带这些，多半是整条地址栏 URL。
        let reject = CharacterSet(charactersIn: "/?#:\\\"<>()[],;")
        guard value.rangeOfCharacter(from: reject) == nil else { return false }
        // RFC 5322 的 atext 加 `@`。别漏掉 `@` 自己，否则每个合法邮箱
        // 都会在最后一个 allSatisfy 上被否掉。
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~@-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var seen = Set<String>()
        return raw.split(separator: "\n").compactMap { line in
            guard let name = displayName(String(line)) else { return nil }
            return seen.insert(normalize(name)).inserted ? name : nil
        }
    }

    /// v1.32.x 的 `codexWatch.grants.v1` 是 `[[1, "邮箱"], [0, "邮箱"]]`，
    /// 其中 flag==1 是「已授权」。只搬放行项。
    private static func legacyAllowedNames(_ defaults: UserDefaults) -> [String] {
        guard let raw = defaults.array(forKey: "codexWatch.grants.v1") as? [[Any]]
        else { return [] }
        return raw.compactMap { entry in
            guard entry.count == 2, entry[0] as? Int == 1 else { return nil }
            return entry[1] as? String
        }
    }
}
