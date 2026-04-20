import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable {
    case miniMax = "minimax"
    case glm = "glm"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMax:
            return "MiniMax"
        case .glm:
            return "GLM"
        }
    }

    var keychainAccount: String {
        switch self {
        case .miniMax:
            return "apiKey"
        case .glm:
            return "glmCredential"
        }
    }

    var usesCurlCredential: Bool {
        self == .glm
    }

    static let storageKey = "usageProvider"
}
