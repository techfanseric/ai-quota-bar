import Foundation
import SQLite3
import XCTest
@testable import AIQuotaBar

final class ZcodeActivityDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testFreshInteractiveSessionIsTheOnlyActiveTask() throws {
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-fresh",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now),
                archived: false),
            Session(
                id: "sess-stale",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 10 * 60 * 1_000,
                archived: false),
            Session(
                id: "sess-subagent",
                taskType: "subagent_child",
                timeUpdatedMs: milliseconds(now),
                archived: false),
            Session(
                id: "sess-side-chat",
                taskType: "selection_side_chat",
                timeUpdatedMs: milliseconds(now),
                archived: false),
            Session(
                id: "sess-archived",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now),
                archived: true),
        ])

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["glm:zcode:sess-fresh"])
        XCTAssertEqual(
            try XCTUnwrap(
                snapshot.lastEventBySession["glm:zcode:sess-fresh"]
            ).timeIntervalSince1970,
            TimeInterval(milliseconds(now)) / 1_000,
            accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.lastEventAt).timeIntervalSince1970,
            TimeInterval(milliseconds(now)) / 1_000,
            accuracy: 0.001)
    }

    func testFreshnessWindowExcludesQuietSessions() throws {
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-borderline",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 119 * 1_000,
                archived: false),
            Session(
                id: "sess-expired",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 121 * 1_000,
                archived: false),
        ])

        let snapshot = fixture.detector.detectSnapshot(now: now)

        XCTAssertEqual(snapshot.activeSessionIDs, ["glm:zcode:sess-borderline"])
    }

    func testMissingDatabaseReturnsIdle() throws {
        let detector = ZcodeActivityDetector(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))

        XCTAssertEqual(detector.detectSnapshot(now: now), .empty)
    }

    func testUnexpectedSchemaReturnsIdleInsteadOfFailing() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        let connection = try Self.openDatabase(at: databaseURL)
        defer { sqlite3_close(connection) }
        try Self.execute(
            "CREATE TABLE session (id text primary key);",
            on: connection)

        let detector = ZcodeActivityDetector(databaseURL: databaseURL)

        XCTAssertEqual(detector.detectSnapshot(now: now), .empty)
    }

    // MARK: - Fixtures

    private struct Session {
        let id: String
        let taskType: String
        let timeUpdatedMs: Int64
        let archived: Bool
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func makeFixture(
        sessions: [Session]
    ) throws -> (detector: ZcodeActivityDetector, databaseURL: URL) {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL)
        }
        let connection = try Self.openDatabase(at: databaseURL)
        defer { sqlite3_close(connection) }
        try Self.execute(
            """
            CREATE TABLE session (
                id text primary key,
                task_type text not null default 'interactive',
                time_updated integer not null,
                time_archived integer
            );
            """,
            on: connection)
        for session in sessions {
            let archivedValue = session.archived ? "\(milliseconds(now))" : "NULL"
            try Self.execute(
                """
                INSERT INTO session (id, task_type, time_updated, time_archived)
                VALUES ('\(session.id)', '\(session.taskType)', \(session.timeUpdatedMs), \(archivedValue));
                """,
                on: connection)
        }
        return (
            ZcodeActivityDetector(
                databaseURL: databaseURL,
                freshnessWindow: 120),
            databaseURL
        )
    }

    private static func openDatabase(at url: URL) throws -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw NSError(
                domain: "ZcodeActivityDetectorTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "cannot open fixture db"])
        }
        return database
    }

    private static func execute(
        _ sql: String,
        on database: OpaquePointer?
    ) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(
                domain: "ZcodeActivityDetectorTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
