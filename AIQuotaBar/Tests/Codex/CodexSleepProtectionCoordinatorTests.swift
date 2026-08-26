import AppKit
import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexSleepProtectionCoordinatorTests: XCTestCase {
    func testActiveTurnAcquiresAndStopReleasesAssertions() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()

        fixture.coordinator.receive(event(.userPromptSubmit))
        XCTAssertTrue(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.assertions.acquireCalls.last, .init(true, true))
        XCTAssertEqual(fixture.coordinator.protectionStatus, .active)
        XCTAssertTrue(
            fixture.coordinator.keepDisplayAwakeEffective)
        XCTAssertTrue(
            fixture.coordinator.preventScreenSaverEffective)

        fixture.coordinator.receive(event(.stop))
        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .idle)
        XCTAssertFalse(
            fixture.coordinator.keepDisplayAwakeEffective)
        XCTAssertFalse(
            fixture.coordinator.preventScreenSaverEffective)
    }

    func testApplicationStopAlwaysReleasesAssertions() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.receive(event(.userPromptSubmit))

        fixture.coordinator.stop()

        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertGreaterThanOrEqual(fixture.assertions.releaseCount, 1)
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 0)
    }

    func testManualSessionLockStopsDisplayProtectionButKeepsSystemAwake() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.receive(event(.userPromptSubmit))

        fixture.workspaceCenter.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.assertions.acquireCalls.last, .init(false, false))
        XCTAssertFalse(
            fixture.coordinator.keepDisplayAwakeEffective)
        XCTAssertFalse(
            fixture.coordinator.preventScreenSaverEffective)
    }

    func testDisablingFeatureImmediatelyReleasesAssertions() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.receive(event(.userPromptSubmit))

        fixture.coordinator.isEnabled = false

        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .idle)
        XCTAssertFalse(
            fixture.coordinator.keepDisplayAwakeEffective)
        XCTAssertFalse(
            fixture.coordinator.preventScreenSaverEffective)
    }

    func testActivityCountRemainsAuthoritativeWhenProtectionIsOff()
        throws
    {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.isEnabled = false

        fixture.coordinator.receiveLocalSnapshot(
            CodexLocalActivitySnapshot(
                activeSessionIDs: ["thread-1"],
                lastEventAt: Date()))

        XCTAssertEqual(fixture.coordinator.activeTurnCount, 1)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .idle)
        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertFalse(
            fixture.coordinator.keepDisplayAwakeEffective)
        XCTAssertFalse(
            fixture.coordinator.preventScreenSaverEffective)
    }

    func testLocalSnapshotProtectsTasksWithoutHookEvents() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()

        fixture.coordinator.receiveLocalSnapshot(
            CodexLocalActivitySnapshot(
                activeSessionIDs: ["thread-1", "thread-2"],
                lastEventAt: Date()
            )
        )

        XCTAssertTrue(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 2)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .active)

        fixture.coordinator.receiveLocalSnapshot(.empty)

        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 0)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .idle)
    }

    func testKimiOnlyProtectionIgnoresCodexAndProtectsKimiTurns() throws {
        let fixture = try makeFixture()
        fixture.coordinator.setProtectedProviders([.kimi])
        fixture.coordinator.start()

        fixture.coordinator.receive(event(.userPromptSubmit))
        fixture.coordinator.receiveLocalSnapshot(
            CodexLocalActivitySnapshot(
                activeSessionIDs: ["codex-session"],
                lastEventAt: Date()))
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 0)
        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(
            fixture.coordinator.hookInstallationStatus,
            .notChecked)

        fixture.coordinator.receiveKimiSnapshot(
            KimiLocalActivitySnapshot(
                activeSessionIDs: ["kimi:session"],
                lastEventAt: Date()))
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 1)
        XCTAssertEqual(fixture.coordinator.activeTaskCount(for: .kimi), 1)
        XCTAssertEqual(fixture.coordinator.activeProviders, [.kimi])
        XCTAssertTrue(fixture.assertions.isHoldingAssertions)

        fixture.coordinator.receiveKimiSnapshot(.empty)
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 0)
        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
    }

    func testCombinedProtectionReleasesOnlyAfterBothProvidersFinish() throws {
        let fixture = try makeFixture()
        fixture.coordinator.setProtectedProviders([.codex, .kimi])
        fixture.coordinator.start()
        fixture.coordinator.receive(event(.userPromptSubmit))
        fixture.coordinator.receiveKimiSnapshot(
            KimiLocalActivitySnapshot(
                activeSessionIDs: ["kimi:session"],
                lastEventAt: Date()))

        XCTAssertEqual(fixture.coordinator.activeTurnCount, 2)
        XCTAssertEqual(fixture.coordinator.activeProviders, [.codex, .kimi])
        fixture.coordinator.receive(event(.stop))
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 1)
        XCTAssertTrue(fixture.assertions.isHoldingAssertions)

        fixture.coordinator.receiveKimiSnapshot(.empty)
        XCTAssertEqual(fixture.coordinator.activeTurnCount, 0)
        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
    }

    func testMobileActivitySummaryDeduplicatesHookAndLocalSessions()
        throws
    {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        let now = Date(timeIntervalSince1970: 10_000)
        fixture.coordinator.receive(event(
            .userPromptSubmit,
            sessionID: "shared-session",
            turnID: "turn",
            date: now.addingTimeInterval(-20)))
        fixture.coordinator.receiveLocalSnapshot(
            CodexLocalActivitySnapshot(
                activeSessionIDs: ["shared-session", "local-session"],
                lastEventAt: now.addingTimeInterval(-5)))

        let summary = fixture.coordinator.mobileActivitySummary(now: now)

        XCTAssertEqual(summary.state, .working)
        XCTAssertEqual(summary.activeTaskCount, 2)
        XCTAssertNil(
            summary.oldestStartedAt,
            "A local-only session has no reliable task start time.")
        XCTAssertNil(summary.elapsedSeconds)
    }

    func testMobileActivitySummaryBecomesStaleAndZeroClearsActiveMetadata()
        throws
    {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        let start = Date(timeIntervalSince1970: 20_000)
        fixture.coordinator.receive(event(
            .userPromptSubmit,
            sessionID: "sensitive-session",
            turnID: "sensitive-turn",
            date: start))

        let working = fixture.coordinator.mobileActivitySummary(
            now: start.addingTimeInterval(90))
        XCTAssertEqual(working.state, .working)
        XCTAssertEqual(working.oldestStartedAt, start)
        XCTAssertEqual(working.elapsedSeconds, 90)

        let staleNow = start.addingTimeInterval(
            CodexSleepProtectionCoordinator
                .mobileActivityFreshnessWindow + 1)
        let stale = fixture.coordinator.mobileActivitySummary(now: staleNow)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.activeTaskCount, 1)
        XCTAssertNil(stale.oldestStartedAt)
        XCTAssertNil(stale.elapsedSeconds)
        XCTAssertTrue(stale.recentEvents.isEmpty)

        fixture.coordinator.receive(event(
            .stop,
            sessionID: "sensitive-session",
            turnID: "sensitive-turn",
            date: staleNow))
        fixture.coordinator.receiveLocalSnapshot(.empty)
        let idle = fixture.coordinator.mobileActivitySummary(now: staleNow)
        XCTAssertEqual(idle.state, .idle)
        XCTAssertEqual(idle.activeTaskCount, 0)
        XCTAssertNil(idle.oldestStartedAt)
        XCTAssertNil(idle.elapsedSeconds)
    }

    func testMobileActivitySummaryBoundsTaskCount() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        let now = Date()
        fixture.coordinator.receiveLocalSnapshot(
            CodexLocalActivitySnapshot(
                activeSessionIDs: Set((0..<120).map { "session-\($0)" }),
                lastEventAt: now))

        let summary = fixture.coordinator.mobileActivitySummary(now: now)

        XCTAssertEqual(summary.state, .working)
        XCTAssertEqual(
            summary.activeTaskCount,
            CodexSleepProtectionCoordinator.mobileActivityTaskCountLimit)
        XCTAssertNil(summary.oldestStartedAt)
        XCTAssertNil(summary.elapsedSeconds)
    }

    private func makeFixture() throws -> (
        coordinator: CodexSleepProtectionCoordinator,
        assertions: FakePowerAssertionController,
        workspaceCenter: NotificationCenter
    ) {
        let suiteName = "CodexSleepProtectionCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: ClosedLidModeManager.enabledKey)
        let assertions = FakePowerAssertionController()
        let workspaceCenter = NotificationCenter()
        let missingHelper = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let installer = CodexHookInstaller(
            hooksURL: missingHelper.appendingPathComponent("hooks.json"),
            helperURL: missingHelper.appendingPathComponent("AIQuotaBarHook")
        )
        let closedLidManager = ClosedLidModeManager(
            defaults: defaults,
            bundle: .main
        )
        let coordinator = CodexSleepProtectionCoordinator(
            defaults: defaults,
            assertionController: assertions,
            hookInstaller: installer,
            localActivityProvider: nil,
            kimiActivityProvider: nil,
            closedLidModeManager: closedLidManager,
            workspaceNotificationCenter: workspaceCenter
        )
        addTeardownBlock {
            await MainActor.run {
                coordinator.stop()
                UserDefaults(suiteName: suiteName)?
                    .removePersistentDomain(forName: suiteName)
            }
        }
        return (coordinator, assertions, workspaceCenter)
    }

    private func event(
        _ name: CodexHookEventName,
        sessionID: String = "session",
        turnID: String? = "turn",
        agentID: String? = nil,
        date: Date = Date()
    ) -> CodexHookEvent {
        CodexHookEvent(
            name: name,
            sessionID: sessionID,
            turnID: turnID,
            agentID: agentID,
            date: date
        )
    }
}

private final class FakePowerAssertionController: PowerAssertionControlling {
    struct Call: Equatable {
        let keepDisplayAwake: Bool
        let declareUserActivity: Bool

        init(_ keepDisplayAwake: Bool, _ declareUserActivity: Bool) {
            self.keepDisplayAwake = keepDisplayAwake
            self.declareUserActivity = declareUserActivity
        }
    }

    var isHoldingAssertions = false
    var acquireCalls: [Call] = []
    var releaseCount = 0

    func acquire(keepDisplayAwake: Bool, declareUserActivity: Bool) throws {
        isHoldingAssertions = true
        acquireCalls.append(.init(keepDisplayAwake, declareUserActivity))
    }

    func update(keepDisplayAwake: Bool, declareUserActivity: Bool) throws {
        try acquire(
            keepDisplayAwake: keepDisplayAwake,
            declareUserActivity: declareUserActivity
        )
    }

    func release() {
        isHoldingAssertions = false
        releaseCount += 1
    }
}
