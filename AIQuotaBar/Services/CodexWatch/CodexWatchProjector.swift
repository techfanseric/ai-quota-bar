import Foundation

/// 把本机已抓到的用量投影成一份「只含被授权账号」的对外应答。
///
/// 单独抽出来是因为这是整条链路上唯一有语义的地方：它是授权名单
/// 与真实数据之间的唯一交汇点。抽成纯函数后，授权逻辑可以脱离
/// HTTP 服务器与 UI 直接测。
enum CodexWatchProjector {
    /// 本机当前可见的 Codex 账号（用于把授权名单对应到真实数据）。
    struct SourceAccount {
        let accountName: String
        /// 首个模型可能没带套餐，后续模型带了就补上，所以是 var。
        var plan: String?
        var windows: [CodexWatchWindow]

        init(accountName: String, plan: String?, windows: [CodexWatchWindow]) {
            self.accountName = accountName
            self.plan = plan
            self.windows = windows
        }
    }

    /// 构造应答。
    ///
    /// - Parameters:
    ///   - sourceAccounts: 本机当前抓到的全部 Codex 账号数据。
    ///   - isServing: owner 的全局开关。
    ///   - isAllowed: 授权判定闭包（注入 `CodexWatchGrantStore.isAllowed`）。
    ///   - allowedAccountNames: 已放行的邮箱，用于报告「授权了但暂无数据」。
    static func response(
        sourceAccounts: [SourceAccount],
        isServing: Bool,
        isAllowed: (String) -> Bool,
        allowedAccountNames: [String],
        hostName: String?,
        appVersion: String?,
        generatedAt: Date = Date()
    ) -> CodexWatchResponse {
        guard isServing else {
            return CodexWatchResponse.failure(
                .disabled, hostName: hostName, appVersion: appVersion,
                generatedAt: generatedAt)
        }

        // 两个集合职责不同：`seen` 只负责去重，`emitted` 记录真正发出去
        // 的账号。把「已授权但没窗口」也算进 emitted 会让 pending 永远为空，
        // 对端就分不清「授权了但那台机器没数据」和「压根没授权」。
        var seen = Set<String>()
        var emitted = Set<String>()
        var accounts: [CodexWatchAccount] = []
        for source in sourceAccounts {
            let key = CodexWatchGrant.normalize(source.accountName)
            // 空账号名无法匹配授权名单，直接丢弃而不是放行。
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard isAllowed(source.accountName) else { continue }
            let windows = source.windows
                .filter { $0.remainingPercent >= 0 }
                .sorted { lhs, rhs in
                    // 短周期在前，和菜单、看板的顺序保持一致。
                    if lhs.isShortWindow != rhs.isShortWindow {
                        return lhs.isShortWindow
                    }
                    return lhs.name < rhs.name
                }
            // 授权了但一个窗口都没有，等于没有可分享的数据。
            guard !windows.isEmpty else { continue }
            emitted.insert(key)
            accounts.append(CodexWatchAccount(
                accountName: source.accountName,
                plan: source.plan,
                windows: windows))
        }

        // 已授权却没出现在结果里：要么那台设备现在没跑 Codex，
        // 要么它抓取失败了。两种都要让对端知道「等一下」，而不是
        // 让对端以为授权被撤销了。
        let pending = allowedAccountNames
            .filter { name in
                let key = CodexWatchGrant.normalize(name)
                guard !key.isEmpty else { return false }
                return !emitted.contains(key)
            }

        return CodexWatchResponse(
            status: .ok,
            hostName: hostName,
            appVersion: appVersion,
            generatedAt: generatedAt,
            accounts: accounts,
            pendingAccountNames: pending)
    }

    /// 从本机 `UsageData` 里抽出 Codex 账号列表。
    ///
    /// 只取 Codex provider：其他 provider（Kimi / GLM / …）走各自的
    /// 凭据模型，不在这次关注的语义范围内，混进来会让授权含义变模糊。
    static func sourceAccounts(
        from sections: [UsageData],
        now: Date = Date()
    ) -> [SourceAccount] {
        var result: [SourceAccount] = []
        var indexByAccount: [String: Int] = [:]

        for section in sections where section.provider == .codex {
            for model in section.models {
                guard let raw = model.accountName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !raw.isEmpty else { continue }
                let key = CodexWatchGrant.normalize(raw)
                guard !key.isEmpty else { continue }

                // 只分享「本机自己登录的」账号。
                //
                // `providerUsageSections` 里也混着本机从别的 Mac 关注来的
                // 账号。若不过滤，一台关注了 C 的 B 就能把 C 的额度再转手
                // 分享给 A —— C 从未授权 B 二次传播。把关注来的数据当成
                // 自己的数据再发出去，等于凭空造出一条未授权的读取路径。
                guard !CodexWatchPeerModel.isRelayed(model) else { continue }

                // 当前窗口已经过去的模型是历史残留，分享出去只会让对端
                // 看到一个早就该重置的额度。
                guard model.containsCurrentInterval(at: now) else { continue }
                let window = CodexWatchWindow(
                    name: model.modelName,
                    remainingPercent: Int(
                        model.currentIntervalPercentageRemaining.rounded()),
                    resetsAt: model.endTime,
                    sampledAt: model.sampledAt ?? section.timestamp)

                let plan = model.parsedDetail.plan
                if let existing = indexByAccount[key] {
                    result[existing].windows.append(window)
                    // 首个模型没带套餐、后续带了就补上。
                    if result[existing].plan == nil {
                        result[existing].plan = plan
                    }
                } else {
                    indexByAccount[key] = result.count
                    result.append(SourceAccount(
                        accountName: raw,
                        plan: plan,
                        windows: [window]))
                }
            }
        }
        return result
    }
}
