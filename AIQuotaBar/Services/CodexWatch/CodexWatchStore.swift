import Foundation
import Observation

/// 「关注账号」的本机状态。两侧各一份名单，存的都只是邮箱。
///
/// 传输复用 app 已有的**团队云端通道**（`/v1/quota-samples`），没有新开端口、
/// 也没有第二套凭据：额度本来就由登录了那个账号的 Mac 自己抓取并上报到团队云端，
/// 关注方按邮箱取回自己关心的那几个号。所以关注方要填的只有一个邮箱，
/// 不需要地址、端口或访问密钥。
///
/// 名单里没有任何凭据，明文存 UserDefaults 是安全的。
@MainActor
@Observable
final class CodexWatchStore {
    static let shared = CodexWatchStore()

    // MARK: - 分享侧（本机是被关注的那一方）

    /// 「允许其他 Mac 关注我的账号」。
    ///
    /// 关着的时候**完全不做任何过滤**：所有 Codex 额度照旧按「共享账号额度」
    /// 的原有行为上报。这样已经开了团队同步的老用户升级后行为不变，
    /// 只有主动打开这个开关的人才开始按下面的勾选名单逐个控制。
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

    /// 分享或关注名单变化。挂它来触发一次用量刷新：取消勾选要靠下一次
    /// 上报把该账号从云端抹掉，关注列表变化则要重新解析一次云端数据。
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults

    private static let sharingKey = "codexWatch.isSharing"
    private static let sharedKey = "codexWatch.shared.v1"
    private static let watchedKey = "codexWatch.watched.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        sharedAccountNames = Self.replacing(
            sharedAccountNames, name, include: shared)
        persist(sharedAccountNames, key: Self.sharedKey)
        onChange?()
    }

    /// 上报前过滤：这份名单决定哪些 Codex 额度可以离开这台 Mac。
    ///
    /// - 非 Codex 供应商不受影响：这里只管 Codex 的关注开关，
    ///   不去改变 Kimi / GLM / MiniMax 原有的团队共享行为。
    /// - `isSharing == false` 时原样返回，向后兼容既有团队用户。
    /// - 打开开关后默认拒绝：没勾的账号不上报，账号名为空的
    ///   未归属额度同样不上报（它没法被按邮箱关注，留着只会让人以为在共享）。
    func uploadableModels(_ models: [ModelUsageData]) -> [ModelUsageData] {
        guard isSharing else { return models }
        return models.filter { model in
            guard model.provider == .codex else { return true }
            return isShared(model.accountName ?? "")
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
        persist(watchedAccountNames, key: Self.watchedKey)
        onChange?()
    }

    /// 一个被关注的账号当前处于什么状态。
    ///
    /// 四种「看不到数据」的原因对应四种完全不同的用户动作，混成一个
    /// 「无数据」会让人以为该重装点什么，所以这里逐一分开。
    enum WatchStatus: Equatable {
        /// 本机还没加入团队，没有云端通道可读。
        case noTeam
        /// 团队通道正常，但对方还没分享这个邮箱 —— 要么没勾选，
        /// 要么那台 Mac 没在跑、还没上报过。
        case waitingForPublisher
        /// 有数据。`sampledAt` 是这份快照在云端的抓取时刻。
        case available(sampledAt: Date, modelCount: Int)
    }

    /// 邮箱格式校验。故意收得很紧：这里只接受看起来像邮箱的字符串，
    /// 免得用户粘进来一段带路径的 URL，被当成账号名上报到团队云端。
    static func isValidAccountName(_ raw: String) -> Bool {
        let value = normalize(raw)
        guard value.count <= 254, !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let (local, domain) = (parts[0], parts[1])
        guard !local.isEmpty, local.count <= 64, !domain.isEmpty,
              domain.contains("."), !domain.hasPrefix("."),
              !domain.hasSuffix("."), !domain.hasPrefix("-"),
              !domain.hasSuffix("-")
        else { return false }
        // 连续的点号只可能出现在拼错的域名里。
        guard !domain.contains("..") else { return false }
        // URL / 显示名残留物。RFC 5322 的 atext 本身允许 `/` `?` `#` 这些
        // 字符，但用户实际粘进来的「邮箱」如果带这些，多半是从地址栏复制的
        // 整条 URL —— 放进分享名单会让它作为一个假账号名上报到云端。
        let reject = CharacterSet(charactersIn: "/?#:\\\"<>()[],;")
        guard value.rangeOfCharacter(from: reject) == nil else { return false }
        // RFC 5322 的 atext 加 `@`。别漏掉 `@` 自己，否则每个合法邮箱
        // 都会在最后一个 allSatisfy 上被否掉。
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~@-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    // MARK: - 私有

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
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
