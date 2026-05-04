import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable {
    case miniMax = "minimax"
    case glm = "glm"
    case chatGPT = "chatgpt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMax:
            return "MiniMax"
        case .glm:
            return "GLM"
        case .chatGPT:
            return "ChatGPT"
        }
    }

    var keychainAccount: String {
        switch self {
        case .miniMax:
            return "apiKey"
        case .glm:
            return "glmCredential"
        case .chatGPT:
            return "chatGPTCredential"
        }
    }

    var usesCurlCredential: Bool {
        self == .glm || self == .chatGPT
    }

    static let storageKey = "usageProvider"
}
