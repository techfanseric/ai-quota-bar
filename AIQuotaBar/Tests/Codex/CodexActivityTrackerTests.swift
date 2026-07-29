import XCTest
@testable import AIQuotaBar

final class CodexActivityTrackerTests: XCTestCase {
    func testPromptStartsProtectionAndStopEndsIt() {
        var tracker = CodexActivityTracker()

        tracker.receive(event(.userPromptSubmit))
        XCTAssertTrue(tracker.isWorking)
        XCTAssertEqual(tracker.activeTurnCount, 1)

        tracker.receive(event(.stop))
        XCTAssertFalse(tracker.isWorking)
        XCTAssertEqual(tracker.activeTurnCount, 0)
    }

    func testPermissionRequestRemainsAnActiveTurn() {
        var tracker = CodexActivityTracker()

        tracker.receive(event(.permissionRequest))

        XCTAssertTrue(tracker.isWorking)
        XCTAssertEqual(tracker.activeTurnCount, 1)
    }

    func testRootStopWaitsForSubagentStop() {
        var tracker = CodexActivityTracker()
        tracker.receive(event(.userPromptSubmit))
        tracker.receive(event(.subagentStart, agentID: "agent-1"))

        tracker.receive(event(.stop))
        XCTAssertTrue(tracker.isWorking)

        tracker.receive(event(.subagentStop, agentID: "agent-1"))
        XCTAssertFalse(tracker.isWorking)
    }

    func testSessionEndClearsEveryTurnInSession() {
        var tracker = CodexActivityTracker()
        tracker.receive(event(.userPromptSubmit, turnID: "turn-1"))
        tracker.receive(event(.preToolUse, turnID: "turn-2"))
        tracker.receive(event(
            .userPromptSubmit,
            sessionID: "another-session",
            turnID: "turn-3"
        ))

        tracker.receive(event(.sessionEnd, turnID: nil))

        XCTAssertTrue(tracker.isWorking)
        XCTAssertEqual(tracker.activeTurnCount, 1)
    }

    func testDuplicateAndOutOfOrderTerminalEventsDoNotCreateWork() {
        var tracker = CodexActivityTracker()

        tracker.receive(event(.subagentStop, agentID: "agent-1"))
        tracker.receive(event(.stop))
        tracker.receive(event(.stop))

        XCTAssertFalse(tracker.isWorking)
        XCTAssertEqual(tracker.activeTurnCount, 0)
    }

    func testConcurrentTurnsAreTrackedIndependently() {
        var tracker = CodexActivityTracker()
        tracker.receive(event(.userPromptSubmit, turnID: "turn-1"))
        tracker.receive(event(.userPromptSubmit, turnID: "turn-2"))
        XCTAssertEqual(tracker.activeTurnCount, 2)

        tracker.receive(event(.stop, turnID: "turn-1"))
        XCTAssertEqual(tracker.activeTurnCount, 1)

        tracker.receive(event(.stop, turnID: "turn-2"))
        XCTAssertFalse(tracker.isWorking)
    }

    private func event(
        _ name: CodexHookEventName,
        sessionID: String = "session-1",
        turnID: String? = "turn-1",
        agentID: String? = nil
    ) -> CodexHookEvent {
        CodexHookEvent(
            name: name,
            sessionID: sessionID,
            turnID: turnID,
            agentID: agentID,
            date: Date(timeIntervalSince1970: 100)
        )
    }
}
