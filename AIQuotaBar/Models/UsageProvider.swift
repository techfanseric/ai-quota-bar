import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable {
    case miniMax = "minimax"
    case glm = "glm"
    case codex = "codex"
    case kimi = "kimi"

    static var allCases: [UsageProvider] {
        [.miniMax, .codex, .kimi, .glm]
    }

    /// 左键菜单的默认供应商顺序：Codex 置顶，MiniMax 垫底；
    /// 其余供应商保持 allCases 的相对顺序。
    static let leftClickMenuDefaultOrder: [UsageProvider] = [.codex, .kimi, .glm, .miniMax]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMax: return "MiniMax"
        case .glm: return "GLM"
        case .codex: return "Codex"
        case .kimi: return "Kimi"
        }
    }

    var keychainAccount: String {
        switch self {
        case .miniMax: return "apiKey"
        case .glm: return "glmCredential"
        case .codex: return "codexCredential"
        case .kimi: return "kimiCodeAPIKey"
        }
    }

    var usesCurlCredential: Bool {
        self == .glm
    }

    /// 老 chatGPTCredential keychain account，用于一次性迁移
    static let legacyChatGPTKeychainAccount = "chatGPTCredential"

    static let storageKey = "usageProvider"

    static func cloudProvider(rawValue: String) -> UsageProvider? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "chatgpt":
            return .codex
        default:
            return UsageProvider(rawValue: rawValue)
        }
    }
}
