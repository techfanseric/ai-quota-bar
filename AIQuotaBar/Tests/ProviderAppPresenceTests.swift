import XCTest
@testable import AIQuotaBar

final class ProviderAppPresenceTests: XCTestCase {
    // MARK: - Matcher

    func testCodexMatchesChatGPTAppAndCodexBundleIDs() {
        let matcher = UsageProvider.codex.companionAppMatcher

        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "com.openai.codex", processName: "ChatGPT"))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "com.openai.chat", processName: "ChatGPT"))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "com.openai.Codex", processName: nil))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: nil, processName: "codex"))
        XCTAssertFalse(matcher.matches(
            bundleIdentifier: "com.example.unrelated", processName: "Notes"))
    }

    func testKimiMatchesDesktopAppOnly() {
        let matcher = UsageProvider.kimi.companionAppMatcher

        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "com.moonshot.kimichat", processName: "Kimi"))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: nil, processName: "kimi"))
        // KimiCU 等后台组件不算“打开了 Kimi”。
        XCTAssertFalse(matcher.matches(
            bundleIdentifier: nil, processName: "kimi-cu"))
        XCTAssertFalse(matcher.matches(
            bundleIdentifier: "com.moonshot.kimicu", processName: "KimiCU"))
    }

    func testMiniMaxMatchesMiniMaxCode() {
        let matcher = UsageProvider.miniMax.companionAppMatcher

        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "com.minimax.agent.cn", processName: "MiniMax Code"))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "com.minimax.agent", processName: nil))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: nil, processName: "MiniMax Code"))
        XCTAssertFalse(matcher.matches(
            bundleIdentifier: "com.minimax.design", processName: "MiniMax Design"))
    }

    func testGLMMatchesZCode() {
        let matcher = UsageProvider.glm.companionAppMatcher

        XCTAssertTrue(matcher.matches(
            bundleIdentifier: "dev.zcode.app", processName: "ZCode"))
        XCTAssertTrue(matcher.matches(
            bundleIdentifier: nil, processName: "zcode"))
        XCTAssertFalse(matcher.matches(
            bundleIdentifier: "dev.zcode.helper", processName: "ZCode Helper"))
    }

    // MARK: - Monitor

    @MainActor
    func testMonitorReflectsInjectedRunningApps() {
        var apps = [
            RunningAppSnapshot(
                bundleIdentifier: "com.openai.codex", processName: "ChatGPT"),
            RunningAppSnapshot(
                bundleIdentifier: "com.moonshot.kimichat", processName: "Kimi"),
        ]
        let monitor = ProviderAppPresenceMonitor { apps }

        XCTAssertEqual(monitor.runningProviders, [.codex, .kimi])
        XCTAssertTrue(monitor.isRunning(.codex))
        XCTAssertFalse(monitor.isRunning(.glm))

        apps = [RunningAppSnapshot(
            bundleIdentifier: "dev.zcode.app", processName: "ZCode")]
        monitor.refresh()

        XCTAssertEqual(monitor.runningProviders, [.glm])
        XCTAssertFalse(monitor.isRunning(.codex))
    }

    // MARK: - ViewModel display filter

    @MainActor
    private func makeViewModel(
        running: Set<UsageProvider>
    ) -> UsageViewModel {
        let monitor = ProviderAppPresenceMonitor {
            running.map { provider in
                RunningAppSnapshot(
                    bundleIdentifier:
                        provider.companionAppMatcher.bundleIdentifiers.first,
                    processName: nil)
            }
        }
        return UsageViewModel(
            providerPresence: { _ in true },
            appPresenceMonitor: monitor)
    }

    @MainActor
    func testFollowRunningAppsHidesProvidersWhoseAppIsClosed() {
        let viewModel = makeViewModel(running: [.codex, .kimi])
        viewModel.followRunningApps = true
        defer { viewModel.followRunningApps = false }

        XCTAssertTrue(viewModel.isProviderDisplayedInMenus(.codex))
        XCTAssertTrue(viewModel.isProviderDisplayedInMenus(.kimi))
        XCTAssertFalse(viewModel.isProviderDisplayedInMenus(.glm))
        XCTAssertFalse(viewModel.isProviderDisplayedInMenus(.miniMax))
    }

    @MainActor
    func testFollowRunningAppsOffShowsEveryEnabledProvider() {
        let viewModel = makeViewModel(running: [])
        viewModel.followRunningApps = false

        XCTAssertTrue(viewModel.isProviderDisplayedInMenus(.codex))
        XCTAssertTrue(viewModel.isProviderDisplayedInMenus(.glm))
        XCTAssertTrue(viewModel.isProviderDisplayedInMenus(.miniMax))
    }

    @MainActor
    func testPausedProviderStaysHiddenEvenWhenAppIsRunning() {
        let viewModel = makeViewModel(running: [.codex])
        viewModel.followRunningApps = true
        defer {
            viewModel.followRunningApps = false
            viewModel.setProviderEnabled(true, provider: .codex)
        }
        viewModel.setProviderEnabled(false, provider: .codex)

        XCTAssertFalse(viewModel.isProviderDisplayedInMenus(.codex))
    }
}
