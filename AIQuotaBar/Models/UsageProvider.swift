import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable {
    case miniMax = "minimax"
    case glm = "glm"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMax: return "MiniMax"
        case .glm: return "GLM"
        case .codex: return "Codex"
        }
    }

    var keychainAccount: String {
        switch self {
        case .miniMax: return "apiKey"
        case .glm: return "glmCredential"
        case .codex: return "codexCredential"
        }
    }

    /// 老 chatGPTCredential keychain account，用于一次性迁移
    static let legacyChatGPTKeychainAccount = "chatGPTCredential"

    static let storageKey = "usageProvider"
}
