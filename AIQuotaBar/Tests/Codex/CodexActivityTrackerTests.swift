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

    func testSafeRecentEventsAreAllowlistedBoundedAndExpire() {
        var tracker = CodexActivityTracker()
        let now = Date(timeIntervalSince1970: 10_000)
        tracker.receive(event(.userPromptSubmit, date: now.addingTimeInterval(-601)))
        tracker.receive(event(.preToolUse, date: now.addingTimeInterval(-5)))
        tracker.receive(event(.permissionRequest, date: now.addingTimeInterval(-4)))
        tracker.receive(event(.postToolUse, date: now.addingTimeInterval(-3)))
        tracker.receive(event(.subagentStart, agentID: "private-agent", date: now.addingTimeInterval(-2)))
        tracker.receive(event(.subagentStop, agentID: "private-agent", date: now.addingTimeInterval(-1)))
        tracker.receive(event(.stop, date: now))

        let recent = tracker.recentEvents(
            now: now,
            maximumAge: 600,
            maximumCount: 5)

        XCTAssertEqual(
            recent.map(\.kind),
            [
                .permissionRequested,
                .toolFinished,
                .subtaskStarted,
                .subtaskFinished,
                .taskFinished,
            ])
        XCTAssertLessThanOrEqual(recent.count, 5)
        XCTAssertTrue(
            recent.allSatisfy {
                now.timeIntervalSince($0.at) <= 600
            })
    }

    func testReliableStartRequiresPromptForEveryActiveSession() {
        var tracker = CodexActivityTracker()
        let start = Date(timeIntervalSince1970: 100)
        tracker.receive(event(
            .userPromptSubmit,
            sessionID: "session-1",
            turnID: "turn-1",
            date: start))
        XCTAssertEqual(
            tracker.reliableOldestStartedAt(
                for: tracker.activeSessionIDs),
            start)

        tracker.receive(event(
            .preToolUse,
            sessionID: "session-2",
            turnID: "turn-2",
            date: start.addingTimeInterval(5)))
        XCTAssertNil(
            tracker.reliableOldestStartedAt(
                for: tracker.activeSessionIDs))
    }

    func testStaleTurnsPastTTLArePruned() {
        var tracker = CodexActivityTracker()
        let now = Date(timeIntervalSince1970: 10_000)
        tracker.receive(event(
            .userPromptSubmit,
            sessionID: "ghost-session",
            turnID: "ghost-turn",
            date: now.addingTimeInterval(-11 * 60)))
        tracker.receive(event(
            .userPromptSubmit,
            sessionID: "live-session",
            turnID: "live-turn",
            date: now.addingTimeInterval(-30)))
        XCTAssertEqual(tracker.activeTurnCount, 2)

        XCTAssertTrue(tracker.pruneStaleTurns(now: now))

        XCTAssertEqual(tracker.activeTurnCount, 1)
        XCTAssertEqual(tracker.activeSessionIDs, ["live-session"])
        XCTAssertFalse(tracker.pruneStaleTurns(now: now))
    }

    func testCompletedTurnCannotBeResurrectedByLateToolEvents() {
        var tracker = CodexActivityTracker()
        let start = Date(timeIntervalSince1970: 100)
        tracker.receive(event(.userPromptSubmit, date: start))
        tracker.receive(event(.stop, date: start + 10))
        tracker.receive(event(.postToolUse, date: start + 11))
        tracker.receive(event(.userPromptSubmit, date: start))
        XCTAssertEqual(tracker.activeTurnCount, 0)

        tracker.receive(event(.userPromptSubmit, turnID: "next", date: start + 12))
        tracker.receive(event(.stop, date: start + 13))
        XCTAssertEqual(tracker.activeTurnCount, 1, "the old turn cannot stop a new turn")
    }

    func testOlderTerminalEventDoesNotOverrideNewerWork() {
        var tracker = CodexActivityTracker()
        let start = Date(timeIntervalSince1970: 100)
        tracker.receive(event(.userPromptSubmit, date: start))
        tracker.receive(event(.preToolUse, date: start + 20))
        tracker.receive(event(.stop, date: start + 10))
        tracker.receive(event(.sessionEnd, turnID: nil, date: start + 15))
        XCTAssertEqual(tracker.activeTurnCount, 1)
        XCTAssertEqual(tracker.lastEventAt, start + 20)
    }

    func testSessionEndWithCompletedTurnIDStillClearsOtherTurns() {
        var tracker = CodexActivityTracker()
        let start = Date(timeIntervalSince1970: 100)
        tracker.receive(event(.userPromptSubmit, date: start))
        tracker.receive(event(.stop, date: start + 1))
        tracker.receive(event(.userPromptSubmit, turnID: "next", date: start + 2))
        tracker.receive(event(.sessionEnd, date: start + 3))
        XCTAssertEqual(tracker.activeTurnCount, 0)
    }

    func testLocalCompletionEndsMissingStopButKeepsActiveSubagents() {
        var tracker = CodexActivityTracker()
        let start = Date(timeIntervalSince1970: 100)
        let key = CodexActivityTracker.TurnKey(sessionID: "session-1", turnID: "turn-1")
        tracker.receive(event(.userPromptSubmit, date: start))
        tracker.receive(event(.subagentStart, agentID: "child", date: start + 1))
        tracker.reconcileCompletedTurns([key: start + 2])
        XCTAssertEqual(tracker.activeTurnCount, 1)
        tracker.receive(event(.postToolUse, date: start + 2.5))
        tracker.receive(event(.subagentStop, agentID: "child", date: start + 3))
        XCTAssertEqual(tracker.activeTurnCount, 0)

        tracker.receive(event(.userPromptSubmit, turnID: "next", date: start + 4))
        tracker.reconcileCompletedTurns([.init(sessionID: "session-1", turnID: "next"): start + 5])
        XCTAssertEqual(tracker.activeTurnCount, 0, "a logged completion replaces a missing Stop")
        tracker.receive(event(.postToolUse, turnID: "next", date: start + 6))
        XCTAssertEqual(tracker.activeTurnCount, 0)
    }

    private func event(
        _ name: CodexHookEventName,
        sessionID: String = "session-1",
        turnID: String? = "turn-1",
        agentID: String? = nil,
        date: Date = Date(timeIntervalSince1970: 100)
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
