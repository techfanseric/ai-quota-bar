import Foundation
import XCTest
@testable import AIQuotaBar

final class MiniMaxActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFreshManifestMarksSessionActive() throws {
        let fixture = try makeFixture()
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_fresh",
            updatedAtMs: milliseconds(now - 30))
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_old",
            updatedAtMs: milliseconds(now - 10 * 60))

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["minimax:cli:mvs_fresh"])
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.lastEventBySession["minimax:cli:mvs_fresh"]
            ).timeIntervalSince1970,
            (now - 30).timeIntervalSince1970,
            accuracy: 0.001)
    }

    func testMalformedManifestIsSkipped() throws {
        let fixture = try makeFixture()
        let brokenDirectory = fixture.rootURL
            .appendingPathComponent("2026/09/24", isDirectory: true)
            .appendingPathComponent(
                "12-00-00-000-session_broken",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: brokenDirectory,
            withIntermediateDirectories: true)
        try Data("not json".utf8).write(
            to: brokenDirectory.appendingPathComponent("manifest.json"))
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_good",
            updatedAtMs: milliseconds(now - 30))

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["minimax:cli:mvs_good"])
    }

    func testDayFoldersBeyondTheScanLimitAreIgnored() throws {
        let fixture = try makeFixture()
        // Freshness alone would keep the history session active; the
        // day-folder scan limit (newest two) is what excludes it.
        try fixture.writeSession(
            day: "2026/09/01",
            sessionID: "mvs_history",
            updatedAtMs: milliseconds(now - 30))
        try fixture.writeSession(
            day: "2026/09/15",
            sessionID: "mvs_recent",
            updatedAtMs: milliseconds(now - 30))
        try fixture.writeSession(
            day: "2026/09/24",
            sessionID: "mvs_current",
            updatedAtMs: milliseconds(now - 30))

        let detector = MiniMaxActivityDetector(
            sessionsRootURL: fixture.rootURL,
            freshnessWindow: 10 * 60)

        XCTAssertEqual(
            detector.detectSnapshot(now: now).activeSessionIDs,
            ["minimax:cli:mvs_current", "minimax:cli:mvs_recent"])
    }

    func testMissingSessionsRootReturnsIdle() {
        let detector = MiniMaxActivityDetector(
            sessionsRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true))

        XCTAssertEqual(detector.detectSnapshot(now: now), .empty)
    }

    // MARK: - Fixtures

    private func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1_000
    }

    private func makeFixture() throws -> Fixture {
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
            detector: MiniMaxActivityDetector(
                sessionsRootURL: rootURL,
                freshnessWindow: 120))
    }

    private struct Fixture {
        let rootURL: URL
        let detector: MiniMaxActivityDetector

        func writeSession(
            day: String,
            sessionID: String,
            updatedAtMs: Double
        ) throws {
            let sessionDirectory = rootURL
                .appendingPathComponent(day, isDirectory: true)
                .appendingPathComponent(
                    "13-58-25-445-session_\(sessionID)",
                    isDirectory: true)
            try FileManager.default.createDirectory(
                at: sessionDirectory,
                withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "sessionId": sessionID,
                "createdAtMs": updatedAtMs - 60_000,
                "updatedAtMs": updatedAtMs,
                "schemaVersion": 1,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.sortedKeys])
            try data.write(
                to: sessionDirectory.appendingPathComponent("manifest.json"))
        }
    }
}
