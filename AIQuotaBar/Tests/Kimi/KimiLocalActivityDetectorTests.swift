import Foundation
import XCTest
@testable import AIQuotaBar

final class KimiLocalActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Desktop status ledger

    func testRunningDesktopStatusIsActive() throws {
        let fixture = try makeFixture()
        try fixture.writeDesktopConversation(
            conversationID: "conv-running",
            updatedAtText: Self.isoString(now - 30))
        try fixture.writeDesktopStatus(
            conversationID: "conv-running",
            status: "running")

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:desktop:conv-running"])
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.lastEventBySession["kimi:desktop:conv-running"]
            ).timeIntervalSince1970,
            (now - 30).timeIntervalSince1970,
            accuracy: 0.001)
    }

    func testCompletedDesktopStatusIsInactiveDespiteFreshHeartbeat() throws {
        let fixture = try makeFixture()
        // The heartbeat was refreshed seconds ago (an idle conversation can
        // still refresh context usage), but the ledger says the turn ended:
        // the conversation must drop out immediately.
        try fixture.writeDesktopConversation(
            conversationID: "conv-done",
            updatedAtText: Self.isoString(now - 5))
        try fixture.writeDesktopStatus(
            conversationID: "conv-done",
            status: "completed")

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testStaleRunningDesktopStatusIsCrashGuarded() throws {
        let fixture = try makeFixture()
        // Status says running, but the heartbeat stopped long past the
        // silence window: the runtime was killed mid-turn.
        try fixture.writeDesktopConversation(
            conversationID: "conv-crashed",
            updatedAtText: Self.isoString(now - 15 * 60))
        try fixture.writeDesktopStatus(
            conversationID: "conv-crashed",
            status: "running")

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testUnknownDesktopStatusFallsBackToFreshness() throws {
        let fixture = try makeFixture()
        try fixture.writeDesktopConversation(
            conversationID: "conv-fresh",
            updatedAtText: Self.isoString(now - 30))
        try fixture.writeDesktopStatus(
            conversationID: "conv-fresh",
            status: "some-future-status")
        try fixture.writeDesktopConversation(
            conversationID: "conv-stale",
            updatedAtText: Self.isoString(now - 10 * 60))
        try fixture.writeDesktopStatus(
            conversationID: "conv-stale",
            status: "some-future-status")

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:desktop:conv-fresh"])
    }

    func testFreshDesktopConversationWithoutStatusLedgerIsActive() throws {
        let fixture = try makeFixture()
        try fixture.writeDesktopConversation(
            conversationID: "conv-running",
            updatedAtText: Self.isoString(now - 30))
        try fixture.writeDesktopConversation(
            conversationID: "conv-done",
            updatedAtText: Self.isoString(now - 10 * 60))

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:desktop:conv-running"])
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.lastEventBySession["kimi:desktop:conv-running"]
            ).timeIntervalSince1970,
            (now - 30).timeIntervalSince1970,
            accuracy: 0.001)
    }

    // MARK: - CLI wires

    func testOpenCLIWireWithFreshActivityIsActive() throws {
        let fixture = try makeFixture()
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_abc",
            agent: "main",
            events: ["turn.prompt"],
            modifiedAt: now - 30)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:cli:session_abc"])
    }

    func testQuietOpenTurnStaysActiveWithinSilenceWindow() throws {
        let fixture = try makeFixture()
        // A long tool call or a slow model can leave an open turn quiet for
        // minutes; the silence window must not flap it out of the active set.
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_quiet",
            agent: "main",
            events: ["turn.prompt"],
            modifiedAt: now - 5 * 60)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:cli:session_quiet"])
    }

    func testEndedTurnAndKilledStaleTurnAreIgnored() throws {
        let fixture = try makeFixture()
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_completed",
            agent: "main",
            events: ["turn.prompt", "turn.ended"],
            modifiedAt: now - 30)
        // Killed mid-turn: the lifecycle never closed, and the file went
        // quiet beyond the open-turn silence window.
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_killed",
            agent: "main",
            events: ["turn.prompt"],
            modifiedAt: now - 15 * 60)

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testAgentsInOneSessionCollapseToASingleTask() throws {
        let fixture = try makeFixture()
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_multi",
            agent: "main",
            events: ["turn.prompt", "turn.ended"],
            modifiedAt: now - 60)
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_multi",
            agent: "agent-1",
            events: ["turn.prompt"],
            modifiedAt: now - 30)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:cli:session_multi"])
        XCTAssertEqual(snapshot.activeSessionIDs.count, 1)
    }

    // MARK: - Kimi Work (daimon) runtime wires

    func testWorkRuntimeWireIsDetectedWithWorkPrefix() throws {
        let fixture = try makeFixture()
        try fixture.writeWire(
            root: fixture.workSessionsRootURL,
            workspace: "wd_project_1",
            session: "conv-0123456789abcdef",
            agent: "main",
            events: ["turn.prompt"],
            modifiedAt: now - 30)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["kimi:work:conv-0123456789abcdef"])
    }

    func testWorkRuntimeEndedTurnIsIgnored() throws {
        let fixture = try makeFixture()
        try fixture.writeWire(
            root: fixture.workSessionsRootURL,
            workspace: "wd_project_1",
            session: "ctitle-0123456789abcdef",
            agent: "main",
            events: ["turn.prompt", "turn.ended"],
            modifiedAt: now - 30)

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testMissingRootsReturnIdle() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let detector = KimiLocalActivityDetector(
            codeHomeURL: missing,
            agentDataURL: missing,
            workSessionsRootURL: missing)

        XCTAssertEqual(detector.detectSnapshot(now: now), .empty)
    }

    // MARK: - Fixtures

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let codeHomeURL = rootURL
            .appendingPathComponent(".kimi-code", isDirectory: true)
        let agentDataURL = rootURL
            .appendingPathComponent("kimi-agent", isDirectory: true)
        let workSessionsRootURL = rootURL
            .appendingPathComponent("daimon-home/sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codeHomeURL,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: agentDataURL,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workSessionsRootURL,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return Fixture(
            codeHomeURL: codeHomeURL,
            agentDataURL: agentDataURL,
            workSessionsRootURL: workSessionsRootURL,
            detector: KimiLocalActivityDetector(
                codeHomeURL: codeHomeURL,
                agentDataURL: agentDataURL,
                workSessionsRootURL: workSessionsRootURL,
                freshnessWindow: 120))
    }

    private struct Fixture {
        let codeHomeURL: URL
        let agentDataURL: URL
        let workSessionsRootURL: URL
        let detector: KimiLocalActivityDetector

        func writeDesktopConversation(
            conversationID: String,
            updatedAtText: String
        ) throws {
            let url = agentDataURL
                .appendingPathComponent("conversation-context-usage.json")
            var entries: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(
                    with: data) as? [String: Any] {
                entries = existing
            }
            entries["agent:main:main:conversation:\(conversationID)"] = [
                "contextUsage": 0.3,
                "contextTokens": 80_000,
                "maxContextTokens": 262_144,
                "model": "k3-agent",
                "updatedAt": updatedAtText,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: entries,
                options: [.sortedKeys])
            try data.write(to: url)
        }

        func writeDesktopStatus(
            conversationID: String,
            status: String
        ) throws {
            let url = agentDataURL
                .appendingPathComponent("conversation-statuses.json")
            var entries: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(
                    with: data) as? [String: Any] {
                entries = existing
            }
            entries["agent:main:main:conversation:\(conversationID)"] = status
            let data = try JSONSerialization.data(
                withJSONObject: entries,
                options: [.sortedKeys])
            try data.write(to: url)
        }

        @discardableResult
        func writeWire(
            root: URL? = nil,
            workspace: String,
            session: String,
            agent: String,
            events: [String],
            modifiedAt: Date
        ) throws -> URL {
            let sessionsRoot = root
                ?? codeHomeURL.appendingPathComponent(
                    "sessions", isDirectory: true)
            let wireURL = sessionsRoot
                .appendingPathComponent(
                    "\(workspace)/\(session)/agents/\(agent)",
                    isDirectory: true)
                .appendingPathComponent("wire.jsonl")
            try FileManager.default.createDirectory(
                at: wireURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let lines = events.map { event -> String in
                let timestamp = Int(modifiedAt.timeIntervalSince1970 * 1_000)
                return "{\"type\":\"\(event)\",\"time\":\(timestamp)}"
            }
            try lines.joined(separator: "\n").write(
                to: wireURL,
                atomically: true,
                encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: wireURL.path)
            return wireURL
        }
    }
}
