import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var warningPanelController: WarningPanelController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set LSUIElement to hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Initialize status bar
        statusBarController = StatusBarController()

        // Setup warning panel controller
        warningPanelController = WarningPanelController()

        // Observe view model for warning panel display
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showWarningIfNeeded),
            name: .showWarningPanel,
            object: nil
        )

        // Start auto-refresh
        statusBarController?.viewModel.startAutoRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.viewModel.stopAutoRefresh()
    }

    @objc private func showWarningIfNeeded(_ notification: Notification) {
        guard let usageData = notification.object as? UsageData else { return }
        warningPanelController?.show(usageData: usageData)
    }

    // MARK: - Window Controllers

    func openSettings() {
        guard let viewModel = statusBarController?.viewModel else { return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(viewModel: viewModel)
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showWarningPanel = Notification.Name("showWarningPanel")
}
