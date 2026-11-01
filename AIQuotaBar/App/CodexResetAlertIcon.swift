import AppKit

struct CodexResetAlertRenderState: Equatable {
    let appearance: String
    let reduceMotion: Bool
    let isDimmingActive: Bool

    @MainActor init(button: NSStatusBarButton, isDimmingActive: Bool = false) {
        self.isDimmingActive = isDimmingActive
        appearance = button.effectiveAppearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua
        ])?.rawValue ?? ""
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
