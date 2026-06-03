import Foundation
import Observation

/// 持有 Settings 窗口的 tab 状态。SettingsWindowController / PreferencesView 共享一份。
@MainActor
@Observable
final class PreferencesSelection {
    var tab: PreferencesTab = .general
}
