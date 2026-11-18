import Foundation

/// Model identity is independent of the client running it. Routing-group
/// aliases (auto/k3, custom aliases) intentionally have no family guess.
enum ModelActivityAttribution {
    static func provider(model: String, provider: String? = nil) -> UsageProvider? {
        let parts = model.lowercased().split(separator: "/").map(String.init)
        if parts.first != "auto", let name = parts.last {
            if name.hasPrefix("minimax-") { return .miniMax }
            if name.hasPrefix("glm-") { return .glm }
            if name.hasPrefix("kimi-") || name.hasPrefix("moonshot-") { return .kimi }
            if name.hasPrefix("gpt-") || ["o1", "o3", "o4"].contains(name)
                || ["o1-", "o3-", "o4-"].contains(where: name.hasPrefix) { return .codex }
        }
        let owner = provider?.lowercased() ?? ""
        switch owner {
        case "codex", "openai", "chatgpt": return .codex
        case "kimi", "kimi-code", "kimi-coding", "moonshot": return .kimi
        case "glm", "zcode", "zcode-plugin", "zai", "zhipu": return .glm
        case "minimax", "minimax-cn", "minimax-coding-plan": return .miniMax
        default: break
        }
        return nil
    }
}

struct ProviderModelActivity: Equatable {
    var localTasks: [UsageProvider: [String: Int]] = [:]
    var requests: [UsageProvider: [String: Int]] = [:]
    var gatewayUnavailable = false
    var unattributedTasks = 0

    var counts: [UsageProvider: Int] {
        var out: [UsageProvider: Int] = [:]
        for map in [localTasks, requests] {
            for (provider, models) in map {
                out[provider, default: 0] += models.values.reduce(0, +)
            }
        }
        return out
    }

    static func codex(
        turns: [CodexActivityTracker.TurnKey: CodexLocalActivitySnapshot.ActiveTurn],
        gateway: MagpieModelActivitySnapshot
    ) -> Self {
        var out = Self(gatewayUnavailable: gateway.isConfigured && !gateway.isAvailable)
        var grouped: [UsageProvider: [String: Set<String>]] = [:]
        let gatewaySessions = Set(gateway.requests.compactMap(\.sessionID))
        for (key, turn) in turns {
            // A gateway can replace even a seemingly explicit model with a
            // fallback. Its requested model is never the actual-model source.
            let owner = turn.modelProvider?.lowercased() ?? ""
            if owner == "magpie" || gateway.providerIDs.contains(owner)
                || owner.isEmpty && gateway.isConfigured
                || gatewaySessions.contains(key.sessionID)
                || gatewaySessions.contains(turn.rootSessionID) {
                if !gateway.isAvailable { out.gatewayUnavailable = true }
                continue
            }
            guard let model = turn.model,
                  let provider = ModelActivityAttribution.provider(model: model)
            else { out.unattributedTasks += 1; continue }
            grouped[provider, default: [:]][model, default: []].insert(turn.rootSessionID)
        }
        out.localTasks = grouped.mapValues { $0.mapValues(\.count) }
        if gateway.isAvailable {
            for request in gateway.requests {
                out.requests[request.provider, default: [:]][request.model, default: 0] += 1
            }
        }
        return out
    }

    func tooltip(language: AppLanguage, providers: Set<UsageProvider>) -> String {
        let zh = language == .simplifiedChinese
        var lines: [String] = []
        for (source, heading) in [
            (requests, zh ? "当前模型请求 · Magpie" : "Live model requests · Magpie"),
            (localTasks, zh ? "本地模型任务" : "Local model tasks"),
        ] {
            let rows = UsageProvider.allCases.filter { providers.contains($0) }
                .flatMap { provider in
                    (source[provider] ?? [:]).sorted { $0.key < $1.key }.map {
                        "\(provider.displayName) · \($0.key) × \($0.value)"
                    }
                }
            if !rows.isEmpty { lines.append(([heading] + rows).joined(separator: "\n")) }
        }
        if gatewayUnavailable {
            lines.append(zh ? "Magpie 模型活动暂不可用；未按客户端猜测归属"
                : "Magpie model activity unavailable; client identity is not used as a model guess")
        }
        if unattributedTasks > 0 {
            lines.append(zh ? "\(unattributedTasks) 个本地任务的模型尚未确认"
                : "Model unconfirmed for \(unattributedTasks) local tasks")
        }
        return lines.joined(separator: "\n\n")
    }
}
