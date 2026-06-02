import CodexBarCore
import Foundation

enum CodexDataSourceMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case oauth
    case cli
    case web

    var id: String { rawValue }

    static let storageKey = "codexSourceMode"

    static let `default`: CodexDataSourceMode = .auto

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .oauth: return "OAuth"
        case .cli: return "CLI"
        case .web: return "Web dashboard"
        }
    }

    var codexbarSourceMode: CodexBarCore.ProviderSourceMode {
        switch self {
        case .auto: return .auto
        case .oauth: return .oauth
        case .cli: return .cli
        case .web: return .web
        }
    }
}
