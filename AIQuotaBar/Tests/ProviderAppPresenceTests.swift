import struct CodexBarCore.RateWindow
import struct CodexBarCore.UsageSnapshot
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
        let viewModel = UsageViewModel(
            providerPresence: { _ in true },
            appPresenceMonitor: monitor)
        let previousMode = UserDefaults.standard.object(forKey: MenuBarRingDisplayMode.storageKey)
        addTeardownBlock { UserDefaults.standard.set(previousMode, forKey: MenuBarRingDisplayMode.storageKey) }
        viewModel.menuBarRingDisplayMode = .automatic
        return viewModel
    }

    @MainActor
    func testFollowRunningAppsHidesProvidersWhoseAppIsClosed() {
        let viewModel = makeViewModel(running: [.codex, .kimi])
        viewModel.followRunningApps = true
        defer { resetFollowAndCollapse(viewModel) }

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
    func testAlwaysVisibleRingsOverrideFollowWithEveryAppClosed() {
        let defaults = UserDefaults.standard
        let keys = [MenuBarAppearance.storageKey, MenuBarRingDisplayMode.storageKey,
                    MenuBarProviderRingWindows.storageKey,
                    MenuBarRingPreferences.providersKey, UsageViewModel.followRunningAppsKey,
                    UsageViewModel.pausedProvidersKey,
                    LeftClickMenuDisplayPreferences.storageKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.removeObject(forKey: UsageViewModel.pausedProvidersKey)
        let viewModel = makeViewModel(running: [])
        viewModel.followRunningApps = true
        viewModel.menuBarAppearance = .compactRing
        viewModel.menuBarRingDisplayMode = .all
        viewModel.menuBarProviderRingWindows = [.codex: .init(outer: .current, center: nil)]
        viewModel.selectAllMenuBarRingProviders()

        XCTAssertFalse(viewModel.isMenuBarDisplayIntentionallyHidden)
        XCTAssertEqual(viewModel.menuBarSnapshots.map(\.provider), MenuBarRingPreferences.providerOrder)
        XCTAssertTrue(UsageProvider.allCases.allSatisfy(viewModel.isProviderDisplayedInMenus))
        // Following still collapses the left-click sections independently.
        XCTAssertTrue(UsageProvider.allCases.allSatisfy(viewModel.isProviderCollapsed))

        viewModel.usageData = CodexUsageDataMapper.mapToUsageData(
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 35, windowMinutes: 300,
                                    resetsAt: Date().addingTimeInterval(3600), resetDescription: nil),
                secondary: nil, updatedAt: Date()),
            credits: nil, sourceLabel: "oauth")
        XCTAssertEqual(viewModel.menuBarSnapshots.first?.state, .ready)
        XCTAssertEqual(viewModel.menuBarSnapshots.first?.ringPercent, 65)
        viewModel.setProviderEnabled(false, provider: .codex)
        XCTAssertFalse(viewModel.menuBarSnapshots.contains { $0.provider == .codex })
        viewModel.setProviderEnabled(true, provider: .codex)

        viewModel.menuBarRingDisplayMode = .automatic
        XCTAssertTrue(viewModel.isMenuBarDisplayIntentionallyHidden)
        XCTAssertTrue(UsageProvider.allCases.allSatisfy { !viewModel.isProviderDisplayedInMenus($0) })
        viewModel.menuBarRingDisplayMode = .all
        viewModel.menuBarAppearance = .detailedText
        XCTAssertTrue(viewModel.isMenuBarDisplayIntentionallyHidden)
    }

    @MainActor
    func testClosedCodexAppStillRefreshesAndReportsErrors() async {
        let defaults = UserDefaults.standard
        let keys = [UsageViewModel.pausedProvidersKey, UsageViewModel.followRunningAppsKey,
                    LeftClickMenuDisplayPreferences.storageKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set(["kimi", "glm", "minimax"], forKey: UsageViewModel.pausedProvidersKey)
        let monitor = ProviderAppPresenceMonitor { [] }
        let viewModel = UsageViewModel(
            providerPresence: { $0 == .codex },
            appPresenceMonitor: monitor,
            fetchProviderUsage: { provider in
                XCTAssertEqual(provider, .codex)
                throw UsageError.apiError("test quota endpoint unavailable")
            })
        viewModel.followRunningApps = true
        await viewModel.refresh(showIconSelfTest: false)

        XCTAssertNotNil(viewModel.providerErrors[.codex], "A closed client must still query the quota source and surface its error.")
        viewModel.stopAutoRefresh()
    }

    @MainActor
    func testPausedProviderStaysHiddenEvenWhenAppIsRunning() {
        let viewModel = makeViewModel(running: [.codex])
        viewModel.followRunningApps = true
        defer {
            resetFollowAndCollapse(viewModel)
            viewModel.setProviderEnabled(true, provider: .codex)
        }
        viewModel.setProviderEnabled(false, provider: .codex)

        XCTAssertFalse(viewModel.isProviderDisplayedInMenus(.codex))
    }

    // MARK: - Left-click menu collapse state

    @MainActor
    private func resetFollowAndCollapse(_ viewModel: UsageViewModel) {
        viewModel.followRunningApps = false
        UsageProvider.allCases.forEach {
            viewModel.leftClickMenuDisplayPreferences
                .setProviderCollapsed(false, provider: $0)
        }
    }

    @MainActor
    func testEnablingFollowCollapsesProvidersWithoutRunningApps() {
        let viewModel = makeViewModel(running: [.codex])
        defer { resetFollowAndCollapse(viewModel) }

        viewModel.followRunningApps = true

        XCTAssertFalse(viewModel.isProviderCollapsed(.codex))
        XCTAssertTrue(viewModel.isProviderCollapsed(.kimi))
        XCTAssertTrue(viewModel.isProviderCollapsed(.glm))
        XCTAssertTrue(viewModel.isProviderCollapsed(.miniMax))
    }

    @MainActor
    func testAppQuitCollapsesOnlyTheAffectedProvider() {
        let running = LockedRunningApps([.codex, .kimi])
        let monitor = ProviderAppPresenceMonitor { running.snapshots() }
        let viewModel = UsageViewModel(
            providerPresence: { _ in true },
            appPresenceMonitor: monitor)
        defer { resetFollowAndCollapse(viewModel) }
        viewModel.followRunningApps = true
        viewModel.syncCollapsedProvidersWithRunningApps()

        // 用户手动展开应用未运行的 GLM。
        viewModel.toggleProviderCollapsed(.glm)
        XCTAssertFalse(viewModel.isProviderCollapsed(.glm))

        // Kimi 退出：只收起 Kimi，手动展开的 GLM 保持不变。
        running.set([.codex])
        monitor.refresh()
        viewModel.handleAppPresenceChanged()

        XCTAssertTrue(viewModel.isProviderCollapsed(.kimi))
        XCTAssertFalse(viewModel.isProviderCollapsed(.codex))
        XCTAssertFalse(viewModel.isProviderCollapsed(.glm))

        // Kimi 重新打开：自动展开。
        running.set([.codex, .kimi])
        monitor.refresh()
        viewModel.handleAppPresenceChanged()

        XCTAssertFalse(viewModel.isProviderCollapsed(.kimi))
    }

    @MainActor
    func testCollapsedStatePersistsThroughPreferences() throws {
        let suiteName = "ProviderAppPresenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var preferences = LeftClickMenuDisplayPreferences()
        preferences.setProviderCollapsed(true, provider: .glm)
        preferences.save(to: defaults)

        let restored = LeftClickMenuDisplayPreferences.load(from: defaults)
        XCTAssertTrue(restored.isProviderCollapsed(.glm))
        XCTAssertFalse(restored.isProviderCollapsed(.codex))
    }

    @MainActor
    func testLegacyPreferencesWithoutCollapseFieldDecodeExpanded() throws {
        let suiteName = "ProviderAppPresenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("{}".utf8), forKey: LeftClickMenuDisplayPreferences.storageKey)

        let restored = LeftClickMenuDisplayPreferences.load(from: defaults)
        XCTAssertFalse(restored.isProviderCollapsed(.codex))
    }
}

/// 测试用的可变运行应用集合，让 monitor 闭包能读到最新状态。
private final class LockedRunningApps: @unchecked Sendable {
    private var providers: Set<UsageProvider>

    init(_ providers: Set<UsageProvider>) {
        self.providers = providers
    }

    func set(_ providers: Set<UsageProvider>) {
        self.providers = providers
    }

    func snapshots() -> [RunningAppSnapshot] {
        providers.map { provider in
            RunningAppSnapshot(
                bundleIdentifier:
                    provider.companionAppMatcher.bundleIdentifiers.first,
                processName: nil)
        }
    }
}
