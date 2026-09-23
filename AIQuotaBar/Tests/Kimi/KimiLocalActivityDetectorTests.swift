import Foundation
import XCTest
@testable import AIQuotaBar

final class KimiLocalActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFreshDesktopConversationIsActive() throws {
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

    func testEndedTurnAndKilledStaleTurnAreIgnored() throws {
        let fixture = try makeFixture()
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_completed",
            agent: "main",
            events: ["turn.prompt", "turn.ended"],
            modifiedAt: now - 30)
        // Killed mid-turn: the lifecycle never closed, but the file went
        // quiet beyond the freshness window.
        try fixture.writeWire(
            workspace: "wd_project_1",
            session: "session_killed",
            agent: "main",
            events: ["turn.prompt"],
            modifiedAt: now - 10 * 60)

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

    func testMissingRootsReturnIdle() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let detector = KimiLocalActivityDetector(
            codeHomeURL: missing,
            agentDataURL: missing)

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
        try FileManager.default.createDirectory(
            at: codeHomeURL,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: agentDataURL,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return Fixture(
            codeHomeURL: codeHomeURL,
            agentDataURL: agentDataURL,
            detector: KimiLocalActivityDetector(
                codeHomeURL: codeHomeURL,
                agentDataURL: agentDataURL,
                freshnessWindow: 120))
    }

    private struct Fixture {
        let codeHomeURL: URL
        let agentDataURL: URL
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

        @discardableResult
        func writeWire(
            workspace: String,
            session: String,
            agent: String,
            events: [String],
            modifiedAt: Date
        ) throws -> URL {
            let wireURL = codeHomeURL
                .appendingPathComponent(
                    "sessions/\(workspace)/\(session)/agents/\(agent)",
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
