import Foundation
import XCTest
@testable import AIQuotaBar

final class MiniMaxActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFreshTranscriptActivityMarksSessionActiveEvenWithStaleManifest()
        throws
    {
        let fixture = try makeFixture()
        // Regression: the CLI can lag manifest.json minutes behind the
        // transcript while a turn is still working. Activity must come from
        // the session directory's files, not the manifest field.
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_working",
            manifestUpdatedAtMs: milliseconds(now - 10 * 60),
            fileModifiedAt: now - 30)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["minimax:cli:mvs_working"])
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.lastEventBySession["minimax:cli:mvs_working"]
            ).timeIntervalSince1970,
            (now - 30).timeIntervalSince1970,
            accuracy: 0.001)
    }

    func testQuietSessionIsIgnored() throws {
        let fixture = try makeFixture()
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_old",
            manifestUpdatedAtMs: milliseconds(now - 10 * 60),
            fileModifiedAt: now - 10 * 60)

        XCTAssertEqual(fixture.detector.detectSnapshot(now: now), .empty)
    }

    func testFreshBackgroundTaskIsActive() throws {
        let fixture = try makeFixture()
        try fixture.writeBackgroundTask(
            taskID: "bg_running",
            modifiedAt: now - 20)
        try fixture.writeBackgroundTask(
            taskID: "bg_finished",
            modifiedAt: now - 10 * 60)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs,
            ["minimax:bg:bg_running"])
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.lastEventBySession["minimax:bg:bg_running"]
            ).timeIntervalSince1970,
            (now - 20).timeIntervalSince1970,
            accuracy: 0.001)
    }

    func testMalformedManifestFallsBackToDirectoryName() throws {
        let fixture = try makeFixture()
        let brokenDirectory = fixture.sessionsRootURL
            .appendingPathComponent("2026/09/24", isDirectory: true)
            .appendingPathComponent(
                "12-00-00-000-session_broken",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: brokenDirectory,
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: brokenDirectory.appendingPathComponent("manifest.json"))
        try FileManager.default.setAttributes(
            [.modificationDate: now - 30],
            ofItemAtPath: brokenDirectory.appendingPathComponent(
                "manifest.json").path)
        try FileManager.default.setAttributes(
            [.modificationDate: now - 30],
            ofItemAtPath: brokenDirectory.path)
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_good",
            manifestUpdatedAtMs: milliseconds(now - 30),
            fileModifiedAt: now - 30)

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(
            snapshot.activeSessionIDs.sorted(),
            [
                "minimax:cli:12-00-00-000-session_broken",
                "minimax:cli:mvs_good",
            ])
    }

    func testDayFoldersBeyondTheScanLimitAreIgnored() throws {
        let fixture = try makeFixture()
        // File activity alone would keep the history session active; the
        // day-folder scan limit (newest two) is what excludes it.
        try fixture.writeSession(
            day: "2026/09/01",
            sessionID: "mvs_history",
            manifestUpdatedAtMs: milliseconds(now - 30),
            fileModifiedAt: now - 30)
        try fixture.writeSession(
            day: "2026/09/15",
            sessionID: "mvs_recent",
            manifestUpdatedAtMs: milliseconds(now - 30),
            fileModifiedAt: now - 30)
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_current",
            manifestUpdatedAtMs: milliseconds(now - 30),
            fileModifiedAt: now - 30)

        let detector = MiniMaxActivityDetector(
            sessionsRootURL: fixture.sessionsRootURL,
            backgroundTasksRootURL: fixture.backgroundTasksRootURL,
            freshnessWindow: 10 * 60)

        XCTAssertEqual(
            detector.detectSnapshot(now: now).activeSessionIDs.sorted(),
            ["minimax:cli:mvs_current", "minimax:cli:mvs_recent"])
    }

    func testMissingRootsReturnIdle() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let detector = MiniMaxActivityDetector(
            sessionsRootURL: missing,
            backgroundTasksRootURL: missing)

        XCTAssertEqual(detector.detectSnapshot(now: now), .empty)
    }

    // MARK: - Fixtures

    private func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1_000
    }

    private func makeFixture() throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRootURL = rootURL
            .appendingPathComponent("v2/sessions", isDirectory: true)
        let backgroundTasksRootURL = rootURL
            .appendingPathComponent("background-tasks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionsRootURL,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: backgroundTasksRootURL,
            withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return Fixture(
            sessionsRootURL: sessionsRootURL,
            backgroundTasksRootURL: backgroundTasksRootURL,
            detector: MiniMaxActivityDetector(
                sessionsRootURL: sessionsRootURL,
                backgroundTasksRootURL: backgroundTasksRootURL,
                freshnessWindow: 120))
    }

    private struct Fixture {
        let sessionsRootURL: URL
        let backgroundTasksRootURL: URL
        let detector: MiniMaxActivityDetector

        func writeSession(
            day: String,
            sessionID: String,
            manifestUpdatedAtMs: Double,
            fileModifiedAt: Date
        ) throws {
            let sessionDirectory = sessionsRootURL
                .appendingPathComponent(day, isDirectory: true)
                .appendingPathComponent(
                    "13-58-25-445-session_\(sessionID)",
                    isDirectory: true)
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "sessionId": sessionID,
                "createdAtMs": manifestUpdatedAtMs - 60_000,
                "updatedAtMs": manifestUpdatedAtMs,
                "schemaVersion": 1,
            ]
            let manifestURL = sessionDirectory
                .appendingPathComponent("manifest.json")
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys])
            try manifestData.write(to: manifestURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(
                    timeIntervalSince1970: manifestUpdatedAtMs / 1_000)],
                ofItemAtPath: manifestURL.path)
            let transcriptURL = sessionDirectory
                .appendingPathComponent("messages.jsonl")
            try Data("{\"type\":\"message\"}\n".utf8).write(to: transcriptURL)
            try FileManager.default.setAttributes(
                [.modificationDate: fileModifiedAt],
                ofItemAtPath: transcriptURL.path)
        }

        func writeBackgroundTask(
            taskID: String,
            modifiedAt: Date
        ) throws {
            let taskDirectory = backgroundTasksRootURL
                .appendingPathComponent(taskID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: taskDirectory,
                withIntermediateDirectories: true)
            try Data("chunk".utf8).write(
                to: taskDirectory.appendingPathComponent("output.log"))
            try Data("summary".utf8).write(
                to: taskDirectory.appendingPathComponent("summary.txt"))
            for entry in ["output.log", "summary.txt"] {
                try FileManager.default.setAttributes(
                    [.modificationDate: modifiedAt],
                    ofItemAtPath: taskDirectory.appendingPathComponent(
                        entry).path)
            }
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: taskDirectory.path)
        }
    }
}
