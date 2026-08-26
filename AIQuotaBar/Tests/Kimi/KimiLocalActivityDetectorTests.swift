import Foundation
import XCTest
@testable import AIQuotaBar

final class KimiLocalActivityDetectorTests: XCTestCase {
    func testLatestCompletedSessionKeepsOlderAbandonedTurnIdle() throws {
        let fixture = try makeFixture(runningProcessCount: 1)
        try fixture.writeSession(
            id: "older-open",
            events: ["turn.prompt"],
            modifiedAt: Date(timeIntervalSince1970: 100))
        try fixture.writeSession(
            id: "latest-completed",
            events: ["turn.prompt", "turn.ended"],
            modifiedAt: Date(timeIntervalSince1970: 200))

        let snapshot = fixture.detector.detectSnapshot()

        XCTAssertTrue(snapshot.activeSessionIDs.isEmpty)
    }

    func testOpenSubagentTurnMarksLatestRunningSessionActive() throws {
        let fixture = try makeFixture(runningProcessCount: 1)
        try fixture.writeSession(
            id: "working",
            agentEvents: [
                "main": ["turn.prompt"],
                "agent-0": ["turn.prompt", "turn.ended"],
                "agent-1": ["turn.prompt"],
            ],
            modifiedAt: Date(timeIntervalSince1970: 300))

        let snapshot = fixture.detector.detectSnapshot()

        XCTAssertEqual(snapshot.activeSessionIDs, ["kimi:working"])
        XCTAssertEqual(
            try XCTUnwrap(snapshot.lastEventAt).timeIntervalSince1970,
            300.001,
            accuracy: 0.0001)
    }

    func testTwoProcessesAllowTwoLatestSessionsToParticipate() throws {
        let fixture = try makeFixture(runningProcessCount: 2)
        try fixture.writeSession(
            id: "second-open",
            events: ["turn.prompt"],
            modifiedAt: Date(timeIntervalSince1970: 200))
        try fixture.writeSession(
            id: "latest-completed",
            events: ["turn.prompt", "turn.ended"],
            modifiedAt: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(
            fixture.detector.detectSnapshot().activeSessionIDs,
            ["kimi:second-open"])
    }

    func testNoRunningKimiProcessReturnsIdle() throws {
        let fixture = try makeFixture(runningProcessCount: 0)
        try fixture.writeSession(
            id: "open",
            events: ["turn.prompt"],
            modifiedAt: Date())

        XCTAssertEqual(fixture.detector.detectSnapshot(), .empty)
    }

    private func makeFixture(
        runningProcessCount: Int
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let workDirectory = "/tmp/kimi-project"
        return Fixture(
            root: root,
            workDirectory: workDirectory,
            detector: KimiLocalActivityDetector(
                codeHomeURL: root,
                runningWorkDirectoriesProvider: {
                    runningProcessCount > 0
                        ? [workDirectory: runningProcessCount]
                        : [:]
                }))
    }
}

private struct Fixture {
    let root: URL
    let workDirectory: String
    let detector: KimiLocalActivityDetector

    func writeSession(
        id: String,
        events: [String],
        modifiedAt: Date
    ) throws {
        try writeSession(
            id: id,
            agentEvents: ["main": events],
            modifiedAt: modifiedAt)
    }

    func writeSession(
        id: String,
        agentEvents: [String: [String]],
        modifiedAt: Date
    ) throws {
        let sessionDirectory = root
            .appendingPathComponent("sessions/wd-test/\(id)", isDirectory: true)
        for (agent, events) in agentEvents {
            let agentDirectory = sessionDirectory
                .appendingPathComponent("agents/\(agent)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: agentDirectory,
                withIntermediateDirectories: true)
            let lines = events.enumerated().map { index, type in
                let time = Int(modifiedAt.timeIntervalSince1970 * 1_000)
                    + index
                return "{\"type\":\"\(type)\",\"time\":\(time)}"
            }
            let wireURL = agentDirectory.appendingPathComponent("wire.jsonl")
            try (lines.joined(separator: "\n") + "\n")
                .data(using: .utf8)?.write(to: wireURL)
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: wireURL.path)
        }

        let indexURL = root.appendingPathComponent("session_index.jsonl")
        let record = "{\"sessionId\":\"\(id)\",\"sessionDir\":\"\(sessionDirectory.path)\",\"workDir\":\"\(workDirectory)\"}\n"
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let handle = try FileHandle(forWritingTo: indexURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(record.utf8))
            try handle.close()
        } else {
            try Data(record.utf8).write(to: indexURL)
        }
    }
}
