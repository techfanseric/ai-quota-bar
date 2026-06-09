import SwiftUI

/// Settings 窗口的 tab 枚举。对应 codexbar 的 PreferencesTab 风格。
enum PreferencesTab: String, CaseIterable, Hashable {
    case general
    case usage
    case sync
    case providers
    case about

    static let defaultWidth: CGFloat = 546
    static let providersWidth: CGFloat = 792
    static let windowHeight: CGFloat = 638

    var title: String {
        switch self {
        case .general: return AppLanguage.current.text(.tabGeneral)
        case .usage: return AppLanguage.current.text(.tabUsage)
        case .sync: return AppLanguage.current.text(.tabSync)
        case .providers: return AppLanguage.current.text(.tabProviders)
        case .about: return AppLanguage.current.text(.tabAbout)
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .usage: return "chart.line.uptrend.xyaxis"
        case .sync: return "icloud"
        case .providers: return "square.grid.2x2"
        case .about: return "info.circle"
        }
    }

    var preferredWidth: CGFloat {
        self == .providers ? Self.providersWidth : Self.defaultWidth
    }

    var preferredHeight: CGFloat {
        Self.windowHeight
    }
}
