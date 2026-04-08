import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init() {
        let viewModel = UsageViewModel()
        let settingsView = SettingsView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "MiniMax Usage Monitor - Settings"
        window.setContentSize(NSSize(width: 480, height: 400))
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()

        self.init(window: window)
    }
}
