import Foundation

/// Codex 账号此刻的归属状态。
///
/// 回答的是"**哪个账号正在被用**"，不是"这个环属于哪个模型族"。两者正交：
/// 模型族归属决定流光画在哪个环上，账号归属决定 Codex 这一栏画几个环。
struct MagpieAccountUsage: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// 没有账号在服务。
        case idle
        /// 这些账号此刻在服务（邮箱，小写）。
        case active([String])
        /// 有请求在途，但归属不到具体账号。
        ///
        /// 账号不可知**不是**"没有在用"：环仍要显示额度，tooltip 要说明
        /// 为什么说不出是哪个账号。
        case ambiguous
        /// 网关读失败。读失败不等于空闲。
        case unavailable
    }

    var state: State
    /// 账号（邮箱，小写）→ 该账号此刻在流转的请求数。
    var busyCounts: [String: Int]
    /// 在途但归属不明的请求数。
    var unattributedRequests: Int

    static let idle = Self(
        state: .idle, busyCounts: [:], unattributedRequests: 0)
    static let unavailable = Self(
        state: .unavailable, busyCounts: [:], unattributedRequests: 0)

    /// 正在服务的账号，按请求数从多到少；同数按账号名定序，保证环的
    /// 位置不会因为负载波动而左右跳动。
    ///
    /// 排序在这里重算，而不是信任 `state` 里的数组顺序 —— 顺序是**显示**
    /// 的不变量，必须由消费者自己保证，不能指望每个生产者都记得排。
    var activeAccounts: [String] {
        switch state {
        case .active(let accounts):
            return accounts.sorted { lhs, rhs in
                let lhsCount = busyCounts[lhs] ?? 0
                let rhsCount = busyCounts[rhs] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        case .unavailable:
            // 读失败时 busyCounts 保留的是最后一次可信观测；顺序规则不变。
            return busyCounts.keys.sorted { lhs, rhs in
                let lhsCount = busyCounts[lhs] ?? 0
                let rhsCount = busyCounts[rhs] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        default: return []
        }
    }

    var isAvailable: Bool { state != .unavailable }
}

/// 把网关的并发与路由元数据解成"哪个账号正在被用"。
///
/// 两个证据源，按可信度叠加：
///
/// 1. **trace 的 seat `who`** —— 逐个在途请求归属到账号。这是**账号级**
///    的实时证据：实测 Codex 当前登录着的账号与网关共用 rest id `codex`，
///    但 seat 的 `who` 仍说出它是哪个邮箱。
/// 2. **concurrency 的车道 `busy`** —— 网关自己的按账号计数。它能覆盖
///    那些来不及在 trace 里归属的请求。
///
/// 两者都不猜：归属不到的请求计入 `unattributedRequests`，状态为
/// `.ambiguous` 而不是"空闲"。
enum MagpieAccountUsageResolver {
    /// 从活动快照解出账号归属。
    ///
    /// `requests` 只含 Codex 客户端的**上游**请求（`phase == "upstream"`），
    /// 与既有流光口径一致：排队、RPM 等待、脱敏都不算"模型在跑"。
    static func resolve(
        _ snapshot: MagpieModelActivitySnapshot,
        provider: UsageProvider = .codex
    ) -> MagpieAccountUsage {
        guard snapshot.isConfigured else { return .idle }
        guard snapshot.isAvailable else { return .unavailable }

        var busy: [String: Int] = [:]
        var unattributed = 0

        for request in snapshot.requests where request.provider == provider {
            if let account = request.accountKey, !account.isEmpty {
                busy[account, default: 0] += 1
            } else {
                unattributed += 1
            }
        }

        // 车道是网关自己的计数，比 trace 的归属更权威：它覆盖那些 trace
        // 还没落下座位、或座位不可分的请求。取两者较大值，不相加 ——
        // 同一个请求在两边都被数到是**同一个**请求，不是两个。
        for (who, count) in snapshot.lanes {
            guard let account = Self.accountKey(fromLane: who, provider: provider),
                  count > 0 else { continue }
            busy[account] = max(busy[account] ?? 0, count)
        }

        if !busy.isEmpty {
            return MagpieAccountUsage(
                state: .active(Self.ordered(busy)),
                busyCounts: busy,
                unattributedRequests: unattributed)
        }
        if unattributed > 0 {
            return MagpieAccountUsage(
                state: .ambiguous, busyCounts: [:],
                unattributedRequests: unattributed)
        }
        return .idle
    }

    /// 车道键 `provider@account` → 账号（邮箱，小写）。
    ///
    /// 裸 `codex`（没有 `@`）是 Codex **当前登录着**的那个账号：它与网关
    /// 共用 rest id，不可区分是哪个邮箱，所以解不出账号 —— 不猜。
    static func accountKey(fromLane who: String, provider: UsageProvider) -> String? {
        let parts = who.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == provider.rawValue else { return nil }
        let account = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return account.isEmpty ? nil : account
    }

    /// 请求数多的账号在前；同数按账号名定序。
    ///
    /// 环的位置是用户唯一能用来区分多个 C 环的线索，它必须在负载波动时
    /// 保持稳定 —— 否则"第二个环是那个账号"的空间记忆每次都失效。
    static func ordered(_ busy: [String: Int]) -> [String] {
        busy.sorted { lhs, rhs in
            let lhsCount = lhs.value
            let rhsCount = rhs.value
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.map(\.key)
    }
}
