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

        fixture.coordinator.receive(event(.stop))
        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .idle)
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
    }

    func testDisablingFeatureImmediatelyReleasesAssertions() throws {
        let fixture = try makeFixture()
        fixture.coordinator.start()
        fixture.coordinator.receive(event(.userPromptSubmit))

        fixture.coordinator.isEnabled = false

        XCTAssertFalse(fixture.assertions.isHoldingAssertions)
        XCTAssertEqual(fixture.coordinator.protectionStatus, .idle)
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

    private func event(_ name: CodexHookEventName) -> CodexHookEvent {
        CodexHookEvent(
            name: name,
            sessionID: "session",
            turnID: "turn",
            agentID: nil
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
