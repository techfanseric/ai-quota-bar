import Foundation

struct ClashControllerConfiguration: Equatable, Sendable {
    let baseURL: URL
    let secret: String
    let clientName: String
    let configURL: URL
}

struct ClashProxyHistory: Decodable, Equatable, Sendable {
    let time: String?
    let delay: Int
}

struct ClashProxy: Decodable, Equatable, Sendable {
    let name: String?
    let type: String
    let now: String?
    let all: [String]?
    let history: [ClashProxyHistory]?
}

struct ClashProxiesResponse: Decodable, Equatable, Sendable {
    let proxies: [String: ClashProxy]
}

struct ClashRule: Decodable, Equatable, Sendable {
    let type: String
    let payload: String
    let proxy: String
}

struct ClashRulesResponse: Decodable, Equatable, Sendable {
    let rules: [ClashRule]
}

struct ClashVersionResponse: Decodable, Equatable, Sendable {
    let meta: Bool?
    let version: String
}

struct ClashRoute: Identifiable, Equatable, Sendable {
    let name: String
    let type: String
    var delay: Int?
    var isSelected: Bool

    var id: String { name }

    var hasUsableDelay: Bool {
        guard let delay else { return false }
        return delay > 0
    }
}

struct ClashRouteSnapshot: Equatable, Sendable {
    let groupName: String
    let selectedRouteName: String?
    let routes: [ClashRoute]
}

struct ClashRecoveryResult: Equatable, Sendable {
    let previousRoute: String
    let selectedRoute: String
    let delay: Int

    var didSwitchRoute: Bool {
        previousRoute != selectedRoute
    }
}

enum ClashRecoveryOutcome: Equatable, Sendable {
    case recovered(ClashRecoveryResult)
    case suppressed
    case needsAttention(shouldTestWhenShown: Bool)
}

enum ClashPanelPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable(String)
}

enum ClashIntegrationError: LocalizedError, Equatable, Sendable {
    case configurationNotFound
    case externalControllerDisabled
    case unsafeControllerHost(String)
    case invalidControllerAddress(String)
    case controllerUnavailable
    case incompatibleResponse
    case strategyGroupNotFound
    case apiFailure(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .configurationNotFound:
            return "Clash configuration was not found."
        case .externalControllerDisabled:
            return "Clash external controller is disabled."
        case let .unsafeControllerHost(host):
            return "Clash controller is not bound to a local address (\(host))."
        case let .invalidControllerAddress(address):
            return "Invalid Clash controller address: \(address)"
        case .controllerUnavailable:
            return "Clash controller is unavailable."
        case .incompatibleResponse:
            return "Clash returned an incompatible response."
        case .strategyGroupNotFound:
            return "No switchable OpenAI strategy group was found."
        case let .apiFailure(statusCode, message):
            return "Clash API \(statusCode): \(message)"
        }
    }
}
