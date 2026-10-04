import Foundation
import Observation

/// Owner 侧的「谁可以看我的哪个 Codex 账号」授权名单。
///
/// 这份名单是本机唯一的授权事实来源：**默认拒绝**。任何一个账号想被
/// 局域网其他 Mac 读到，都必须先在这里显式放行；未列出的邮箱一律 403。
/// 名单本身不含任何凭据，所以明文存 UserDefaults 是安全的
/// （被读到的也只是一份额度快照）。
@MainActor
@Observable
final class CodexWatchGrantStore {
    static let shared = CodexWatchGrantStore()

    /// 全局开关。关掉之后即便名单里有放行项也不对外提供任何数据，
    /// 这样「临时不想被任何人看」不需要逐条撤销。
    var isServing: Bool {
        didSet {
            guard isServing != oldValue else { return }
            defaults.set(isServing, forKey: Self.servingKey)
            onChange?()
        }
    }

    /// 授权发生变化。`StatusBarController` 挂上它来重算对外应答，
    /// 这样设置页不必把局域网服务一路透传下来。
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    private(set) var grants: [CodexWatchGrant]

    private let defaults: UserDefaults

    private static let servingKey = "codexWatch.isServing"
    private static let grantsKey = "codexWatch.grants.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isServing = defaults.object(forKey: Self.servingKey) as? Bool ?? false
        self.grants = Self.decodeGrants(defaults)
    }

    // MARK: - 查询

    /// 该邮箱当前是否允许被局域网对端读取。
    func isAllowed(_ accountName: String) -> Bool {
        let key = CodexWatchGrant.normalize(accountName)
        guard !key.isEmpty else { return false }
        // 显式拒绝优先：允许名单里可能残留同名旧条目，
        // 语义上「拒绝」是更强的那个。
        if grants.contains(where: { $0.normalizedName == key && !$0.isAllowed }) {
            return false
        }
        return grants.contains { $0.normalizedName == key && $0.isAllowed }
    }

    /// 当前已放行的账号邮箱（用于设置页勾选框）。
    var allowedAccountNames: [String] {
        grants.filter(\.isAllowed).map(\.accountName)
    }

    // MARK: - 变更

    func setAllowed(_ allowed: Bool, for accountName: String) {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = CodexWatchGrant.normalize(trimmed)
        guard !key.isEmpty else { return }

        // 先清掉该账号的所有既有条目（含显式拒绝），
        // 否则 setAllowed(true) 后紧接一次 false 会留下两条同邮箱记录，
        // 读取时只能靠「拒绝优先」兜底，语义会变得难以推理。
        grants.removeAll { $0.normalizedName == key }
        grants.append(allowed ? .allowed(trimmed) : .denied(trimmed))
        persist()
        onChange?()
    }

    /// 撤销某个账号的全部授权痕迹（含显式拒绝）。
    func clear(_ accountName: String) {
        let key = CodexWatchGrant.normalize(accountName)
        guard !key.isEmpty else { return }
        let before = grants.count
        grants.removeAll { $0.normalizedName == key }
        guard grants.count != before else { return }
        persist()
        onChange?()
    }

    func removeAll() {
        guard !grants.isEmpty else { return }
        grants = []
        persist()
        onChange?()
    }

    private func persist() {
        defaults.set(
            grants.map { [$0.isAllowed ? 1 : 0, $0.accountName] },
            forKey: Self.grantsKey)
    }

    private static func decodeGrants(_ defaults: UserDefaults) -> [CodexWatchGrant] {
        guard let raw = defaults.array(forKey: grantsKey) as? [[Any]]
        else { return [] }
        var seen = Set<String>()
        var result: [CodexWatchGrant] = []
        for entry in raw {
            guard entry.count == 2,
                  let flag = entry[0] as? Int,
                  let name = entry[1] as? String
            else { continue }
            let key = CodexWatchGrant.normalize(name)
            // 同一邮箱只保留最后一条，与 setAllowed 的去重语义一致。
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(flag == 1 ? .allowed(name) : .denied(name))
        }
        return result
    }
}
