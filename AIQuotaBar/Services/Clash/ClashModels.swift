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

enum ClashRouteTypeBadge {
    static func text(for type: String) -> String {
        let normalized = type
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        switch normalized {
        case "hysteria2", "hy2": return "H2"
        case "hysteria": return "HY"
        case "vless": return "VL"
        case "vmess": return "VM"
        case "anytls": return "TLS"
        case "shadowsocks", "ss": return "SS"
        case "trojan": return "TR"
        case "wireguard", "wg": return "WG"
        case "tuic": return "TU"
        case "snell": return "SN"
        case "ssh": return "SSH"
        default:
            let fallback = normalized.isEmpty
                ? "—"
                : String(normalized.uppercased().prefix(3))
            return fallback
        }
    }
}

enum ClashRouteSwitchTimeFormat {
    static func text(
        for date: Date,
        relativeTo now: Date,
        language: AppLanguage,
        calendar: Calendar = .current
    ) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 {
            return language.clashRouteSwitchJustNow()
        }
        if elapsed < 3_600 {
            return language.clashRouteSwitchMinutesAgo(
                max(1, Int(elapsed / 60)))
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(
                date: .omitted,
                time: .shortened)
        }
        return date.formatted(
            .dateTime
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits))
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
