import Foundation
import XCTest
@testable import AIQuotaBar

final class ClaudeCodeActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testMiniMaxModelAttribution() throws {
        let fixture = try makeFixture()
        try fixture.writeTranscript(
            project: "-Users-ericyim-project",
            sessionID: "session-minimax",
            modifiedAt: now - 10,
            lines: [
                #"{"type":"user","message":{"role":"user"}}"#,
                #"{"type":"assistant","message":{"id":"msg_1","model":"MiniMax-M3"}}"#,
                #"{"type":"assistant","message":{"id":"msg_2","model":"MiniMax-M3"}}"#,
            ])

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["minimax:claude:session-minimax"])
    }

    func testGLMModelAttribution() throws {
        let fixture = try makeFixture()
        try fixture.writeTranscript(
            project: "-Users-ericyim-project",
            sessionID: "session-glm",
            modifiedAt: now - 10,
            lines: [
                #"{"type":"assistant","message":{"model":"glm-4.7"}}"#,
            ])

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["glm:claude:session-glm"])
    }

    func testUnrelatedModelsNeverTriggerProtection() throws {
        let fixture = try makeFixture()
        try fixture.writeTranscript(
            project: "-Users-ericyim-project",
            sessionID: "session-anthropic",
            modifiedAt: now - 10,
            lines: [
                #"{"type":"assistant","message":{"model":"claude-sonnet-4-5"}}"#,
            ])

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testLastRecognizedAssistantModelWins() throws {
        let fixture = try makeFixture()
        try fixture.writeTranscript(
            project: "-Users-ericyim-project",
            sessionID: "session-switched",
            modifiedAt: now - 10,
            lines: [
                #"{"type":"assistant","message":{"model":"MiniMax-M3"}}"#,
                #"{"type":"assistant","message":{"model":"glm-4.7"}}"#,
            ])

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["glm:claude:session-switched"])
    }

    func testQuietTranscriptsAreIgnored() throws {
        let fixture = try makeFixture()
        try fixture.writeTranscript(
            project: "-Users-ericyim-project",
            sessionID: "session-idle",
            modifiedAt: now - 10 * 60,
            lines: [
                #"{"type":"assistant","message":{"model":"MiniMax-M3"}}"#,
            ])

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testTruncatedTailLineIsSkipped() throws {
        let fixture = try makeFixture(tailScanBytes: 256)
        // Pad the file well past the tail window; the first line inside the
        // tail is intentionally cut mid-JSON and must be skipped.
        let filler = #"{"type":"file-history-snapshot","payload":"\#(String(repeating: "x", count: 512))"}"# + "\n"
        try fixture.writeTranscript(
            project: "-Users-ericyim-project",
            sessionID: "session-truncated",
            modifiedAt: now - 10,
            lines: [
                filler,
                #"{"type":"assistant","message":{"model":"MiniMax-M3"}}"#,
            ])

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["minimax:claude:session-truncated"])
    }

    func testMissingProjectsRootReturnsIdle() {
        let detector = ClaudeCodeActivityDetector(
            projectsRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true))

        XCTAssertEqual(detector.detectSnapshot(now: now), .empty)
    }

    // MARK: - Fixtures

    private func makeFixture(
        tailScanBytes: Int = ClaudeCodeActivityDetector.defaultTailScanBytes
    ) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return Fixture(
            rootURL: rootURL,
            detector: ClaudeCodeActivityDetector(
                projectsRootURL: rootURL,
                freshnessWindow: 120,
                tailScanBytes: tailScanBytes))
    }

    private struct Fixture {
        let rootURL: URL
        let detector: ClaudeCodeActivityDetector

        func writeTranscript(
            project: String,
            sessionID: String,
            modifiedAt: Date,
            lines: [String]
        ) throws {
            let projectDirectory = rootURL
                .appendingPathComponent(project, isDirectory: true)
            try FileManager.default.createDirectory(
                at: projectDirectory,
                withIntermediateDirectories: true)
            let transcriptURL = projectDirectory
                .appendingPathComponent("\(sessionID).jsonl")
            try lines.joined(separator: "\n").write(
                to: transcriptURL,
                atomically: true,
                encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: transcriptURL.path)
        }
    }
}
