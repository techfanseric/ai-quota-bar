import Foundation

enum MobileDashboardColorScheme: String, Codable, CaseIterable, Identifiable,
    Sendable
{
    case automatic = "auto"
    case dark
    case light

    var id: String { rawValue }

    var themeColorHex: String {
        switch self {
        case .automatic: return "#000000"
        case .dark: return "#000000"
        case .light: return "#f6f7f4"
        }
    }

    var colorSchemeMetaContent: String {
        switch self {
        case .automatic: return "light dark"
        case .dark: return "dark"
        case .light: return "light"
        }
    }

    var appleStatusBarStyle: String {
        switch self {
        case .automatic: return "black"
        case .dark: return "black"
        case .light: return "default"
        }
    }
}
