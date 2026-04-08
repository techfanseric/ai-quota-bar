import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusBarController: StatusBarController?
    private var warningPanelController: WarningPanelController?
    private var settingsWindowController: SettingsWindowController?
    private var dailyUpdateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set LSUIElement to hide from Dock
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().delegate = self

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

        scheduleDailyUpdateChecks()
        Task {
            await runAutomaticUpdateCheckIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController?.viewModel.stopAutoRefresh()
        dailyUpdateTimer?.invalidate()
        dailyUpdateTimer = nil
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

    // MARK: - Automatic Update Checks

    private func scheduleDailyUpdateChecks() {
        dailyUpdateTimer?.invalidate()
        dailyUpdateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task {
                await self?.runAutomaticUpdateCheckIfNeeded()
            }
        }
    }

    private func runAutomaticUpdateCheckIfNeeded() async {
        let checker = UpdateChecker.shared
        guard checker.shouldRunAutomaticDailyCheck() else { return }
        checker.markAutomaticCheck()

        do {
            let result = try await checker.checkForUpdates()
            guard case let .updateAvailable(currentVersion, latestVersion, releaseURL) = result else { return }
            guard checker.shouldNotifyUpdate(latestVersion: latestVersion) else { return }

            checker.markNotifiedUpdate(latestVersion: latestVersion)

            let language = await MainActor.run { statusBarController?.viewModel.appLanguage ?? AppLanguage.current }
            await UpdateNotificationService.shared.notifyUpdateAvailable(
                language: language,
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseURL: releaseURL
            )
        } catch {
            // Keep silent for background checks.
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard let releaseURLString = response.notification.request.content.userInfo["releaseURL"] as? String,
              let releaseURL = URL(string: releaseURLString) else {
            return
        }

        NSWorkspace.shared.open(releaseURL)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let showWarningPanel = Notification.Name("showWarningPanel")
}
