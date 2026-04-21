import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    init(viewModel: UsageViewModel) {
        let hostingController = NSHostingController(
            rootView: SettingsView(viewModel: viewModel)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = viewModel.appLanguage.text(.preferences)
        window.setContentSize(NSSize(width: 700, height: 620))
        window.minSize = NSSize(width: 700, height: 620)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
