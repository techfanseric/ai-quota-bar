import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import AIQuotaBar

@MainActor
final class LightweightModeTests: XCTestCase {
    func testDefaultIsOneMinuteAndExplicitOffPersists() throws {
        let defaults = try isolatedDefaults()
        XCTAssertEqual(LightweightModeController.defaultIdleDelay, 60)
        let mode = LightweightModeController(defaults: defaults)
        XCTAssertTrue(mode.isEnabled)
        mode.isEnabled = false
        XCTAssertFalse(LightweightModeController(defaults: defaults).isEnabled)
        mode.isEnabled = true
        XCTAssertTrue(LightweightModeController(defaults: defaults).isEnabled)
        mode.stop()
    }

    func testClosedResourceReleasesAtSixtySecondsExactlyOnce() throws {
        var now: TimeInterval = 0
        var released = 0
        let mode = LightweightModeController(defaults: try isolatedDefaults(), now: { now })
        defer { mode.stop() }
        mode.register("panel", isOpen: { false }, release: { released += 1 })
        now = 59.99
        mode.reclaimDueResources()
        XCTAssertEqual(released, 0)
        now = 60
        mode.reclaimDueResources()
        XCTAssertEqual(released, 1)
        now = 120
        mode.reclaimDueResources()
        XCTAssertEqual(released, 1)
    }

    func testRealIdleTimerReleasesResourceWithoutPolling() async throws {
        let mode = LightweightModeController(defaults: try isolatedDefaults(), idleDelay: 0.05)
        defer { mode.stop() }
        let released = expectation(description: "closed presentation released")
        mode.register("panel", isOpen: { false }, release: { released.fulfill() })
        await fulfillment(of: [released], timeout: 3)
        XCTAssertEqual(mode.releasedResourceCount, 1)
    }

    func testReopeningCancelsReleaseAndNextCloseStartsFreshMinute() throws {
        var now: TimeInterval = 0
        var open = false
        var released = false
        let mode = LightweightModeController(defaults: try isolatedDefaults(), now: { now })
        defer { mode.stop() }
        mode.register("panel", isOpen: { open }, release: { released = true })
        now = 59
        open = true
        mode.didShow("panel")
        now = 100
        mode.reclaimDueResources()
        XCTAssertFalse(released)
        open = false
        mode.didHide("panel")
        now = 159
        mode.reclaimDueResources()
        XCTAssertFalse(released)
        now = 160
        mode.reclaimDueResources()
        XCTAssertTrue(released)
    }

    func testOpenRecheckAndDisabledModeProtectResources() throws {
        var now: TimeInterval = 0
        var open = false
        var released = false
        let mode = LightweightModeController(defaults: try isolatedDefaults(), now: { now })
        defer { mode.stop() }
        mode.register("panel", isOpen: { open }, release: { released = true })
        open = true // Even a missed show callback must not destroy an open window.
        now = 61
        mode.reclaimDueResources()
        XCTAssertFalse(released)
        open = false
        mode.didHide("panel")
        mode.isEnabled = false
        now = 200
        mode.reclaimDueResources()
        XCTAssertFalse(released)
        mode.isEnabled = true
        now = 259
        mode.reclaimDueResources()
        XCTAssertFalse(released)
        now = 260
        mode.reclaimDueResources()
        XCTAssertTrue(released)
    }

    func testNativeSettingsHostingTreeIsReleasedAndRebuiltWithSavedTabAndFrame() async throws {
        var now: TimeInterval = 0
        let defaults = try isolatedDefaults()
        let mode = LightweightModeController(defaults: defaults, now: { now })
        defer { mode.stop() }
        let service = MobileDashboardService(defaults: defaults,
            snapshotProvider: { _, _, _, _ in fatalError("disabled dashboard") },
            onViewerActivityChanged: { _ in }, refreshRoute: {}, testRoutes: {})
        let controller = SettingsWindowController(viewModel: UsageViewModel(),
            mobileDashboardService: service, lightweightMode: mode)
        weak var oldHost: NSViewController?
        var frame = NSRect.zero
        autoreleasepool {
            controller.selection.tab = .display
            controller.window?.animationBehavior = .none
            controller.showWindow(nil)
            if let visible = controller.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                controller.window?.setFrameOrigin(NSPoint(x: visible.minX + 24, y: visible.minY + 24))
            }
        }
        // Warm the actual native tree before measuring it; measuring before
        // SwiftUI's first render would mix framework startup with reclamation.
        try await Task.sleep(nanoseconds: 400_000_000)
        autoreleasepool {
            oldHost = controller.window?.contentViewController
            frame = controller.window?.frame ?? .zero
            controller.close()
        }
        let loadedFootprint = physicalFootprint()
        now = 61
        autoreleasepool { mode.reclaimDueResources() }
        // AppKit/SwiftUI can finish a detached hosting transaction on the
        // following run-loop turn; yield rather than blocking that executor.
        for _ in 0..<100 where oldHost != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.hasLoadedPresentation)
        XCTAssertNil(oldHost, "the hidden SwiftUI hosting controller is still retained")
        let releasedFootprint = physicalFootprint()
        print("Lightweight native settings footprint bytes: retained=\(loadedFootprint), released=\(releasedFootprint)")
        let started = ProcessInfo.processInfo.systemUptime
        controller.showWindow(nil)
        XCTAssertTrue(controller.hasLoadedPresentation)
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(controller.selection.tab, .display)
        XCTAssertEqual(controller.window?.frame, frame)
        print("Lightweight settings reconstruction ms: \((ProcessInfo.processInfo.systemUptime - started) * 1000)")
        controller.close()
    }

    func testCoveredWindowRemainsOpenWithoutDependingOnOcclusion() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.orderFront(nil)
        XCTAssertTrue(LightweightModeController.isOpen(window))
        // Losing key/focus does not close a window.
        window.resignKey()
        XCTAssertTrue(LightweightModeController.isOpen(window))
        window.close()
        XCTAssertFalse(LightweightModeController.isOpen(window))
    }

    func testControlPanelReleasesItsTreeWithoutStoppingLANViewerUpdates() async throws {
        var now: TimeInterval = 0
        let defaults = try isolatedDefaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mode = LightweightModeController(defaults: defaults, now: { now })
        defer { mode.stop() }
        let discovery = ClashConfigurationDiscovery(homeDirectory: root)
        let connections = ClashConnectionViewModel(discovery: discovery,
            historyStore: ClashConnectionHistoryStore(directoryURL: root))
        defer { connections.stop() }
        let activity = CodexSleepProtectionCoordinator(defaults: defaults,
            localActivityProvider: nil, kimiActivityProvider: nil,
            zcodeActivityProvider: nil, miniMaxActivityProvider: nil,
            claudeCodeActivityProvider: nil)
        let accounts = CodexAuthAccountStore(codexHome: root, defaults: defaults,
            authMirror: CodexAuthMirror(directory: root.appendingPathComponent("mirror")),
            companionAppsProvider: { [] }, cliProcessChecker: { false },
            notify: { _, _ in }, openCompanionApp: {}, quotaSnapshotProvider: { _ in nil },
            usageAccountRefresher: {})
        let controller = ClashRoutePopoverController(
            routeViewModel: ClashRouteViewModel(defaults: defaults, discovery: discovery),
            connectionViewModel: connections, sleepProtectionCoordinator: activity,
            displayStore: ClashPanelDisplayStore(defaults: defaults), accountStore: accounts,
            stepAwayDimController: StepAwayDimController(
                preferences: StepAwayPreferences(defaults: defaults), defaults: defaults),
            lightweightMode: mode)
        XCTAssertNil(controller.loadedPanel, "construction must not create a hidden tree")
        weak var oldHost: NSView?
        autoreleasepool {
            controller.loadPanelIfNeeded()
            oldHost = controller.loadedPanel?.contentView
            XCTAssertNotNil(oldHost)
        }
        connections.beginLiveUpdates(owner: "mobile-dashboard")
        connections.beginLiveUpdates()
        controller.close() // removes the popover owner, not the LAN owner
        now = 61
        autoreleasepool { mode.reclaimDueResources() }
        for _ in 0..<100 where oldHost != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(controller.loadedPanel)
        XCTAssertNil(oldHost)
        XCTAssertTrue(connections.isLive)
        controller.loadPanelIfNeeded()
        XCTAssertNotNil(controller.loadedPanel)
        XCTAssertTrue(connections.isLive)
    }

    func testReclamationKeepsRingCountsFramesAndModelTooltipIntact() throws {
        var now: TimeInterval = 0
        var presentation: NSView? = NSView()
        let mode = LightweightModeController(defaults: try isolatedDefaults(), now: { now })
        defer { mode.stop() }
        let activity = ProviderModelActivity.codex(turns: [:], gateway: .init(
            isConfigured: true, isAvailable: true, providerIDs: ["magpie"], requests: [
                .init(id: 1, provider: .miniMax, model: "MiniMax-M3"),
                .init(id: 2, provider: .glm, model: "GLM-5.3"),
            ]))
        let rings = StatusBarCompactRingsView()
        let snapshots = [UsageProvider.miniMax, .glm].map {
            MenuBarSnapshot(provider: $0, modelName: nil, remainingPercent: 70,
                ringPercent: 70, paceDeltaPercent: nil, ringTrend: nil, resetsAt: nil,
                state: .ready, isLowQuota: false, tooltip: $0.displayName)
        }
        let tip = activity.tooltip(language: .english, providers: [.miniMax, .glm])
        rings.setSnapshots(snapshots, codexConnectivity: .reachable, paceDisplayMode: .staged,
            isSelfTesting: false, activeTaskCounts: activity.counts, accessibilityLabel: tip)
        let before = rings.renderedFrames(scale: 2, height: 22).first?.tiffRepresentation
        mode.register("closed-presentation", isOpen: { false }, release: { presentation = nil })
        now = 61
        mode.reclaimDueResources()
        XCTAssertNil(presentation)
        XCTAssertEqual(rings.activeTaskCountsForTesting, [1, 1])
        XCTAssertEqual(rings.renderedFrames(scale: 2, height: 22).first?.tiffRepresentation, before)
        XCTAssertTrue(tip.contains("MiniMax-M3 × 1"))
        XCTAssertTrue(tip.contains("GLM-5.3 × 1"))
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "LightweightModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
