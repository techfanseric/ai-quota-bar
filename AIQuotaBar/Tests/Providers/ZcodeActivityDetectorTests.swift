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

    // MARK: - Terminal-turn end events (hybrid lifecycle)

    func testFirstPollSkipsHistoricalCompletionLedger() throws {
        // A long-finished turn must not read as a fresh end event at launch:
        // the session's stale-but-windowed write predates the turn end, yet
        // the first poll initializes the cursor past the historical ledger.
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-historical",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 30 * 1_000,
                archived: false),
        ], turns: [
            Turn(
                sessionID: "sess-historical",
                status: "completed",
                startedAtMs: milliseconds(now) - 60 * 1_000,
                completedAtMs: milliseconds(now) - 5 * 1_000),
        ])

        XCTAssertEqual(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs,
            ["glm:zcode:sess-historical"])
    }

    func testTerminalTurnRowEndsSessionDespiteFreshTimestamp() throws {
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-running",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 3 * 1_000,
                archived: false),
            Session(
                id: "sess-ended",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 30 * 1_000,
                archived: false),
        ])

        // Before the terminal row lands, freshness alone keeps both active.
        XCTAssertEqual(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs,
            ["glm:zcode:sess-running", "glm:zcode:sess-ended"])

        // The turn ends now: its terminal row lands after the detector has
        // already been polling, and the session's freshest write is still the
        // turn's own last write (30s ago, inside the window).
        let connection = try Self.openDatabase(at: fixture.databaseURL)
        defer { sqlite3_close(connection) }
        try Self.execute(
            """
            INSERT INTO turn_usage
                (session_id, turn_id, status, started_at, completed_at)
            VALUES ('sess-ended', 'turn-1', 'completed',
                    \(milliseconds(now) - 60 * 1_000), \(milliseconds(now) - 1 * 1_000));
            """,
            on: connection)

        XCTAssertEqual(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs,
            ["glm:zcode:sess-running"])
    }

    func testWritesAfterTurnEndKeepSessionActive() throws {
        // Cancel-then-continue: the newest write postdates the ended turn,
        // so the immediately continued turn must not be cut off.
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-continued",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 2 * 1_000,
                archived: false),
        ])
        XCTAssertFalse(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs.isEmpty)

        let connection = try Self.openDatabase(at: fixture.databaseURL)
        defer { sqlite3_close(connection) }
        try Self.execute(
            """
            INSERT INTO turn_usage
                (session_id, turn_id, status, started_at, completed_at)
            VALUES ('sess-continued', 'turn-1', 'cancelled',
                    \(milliseconds(now) - 60 * 1_000), \(milliseconds(now) - 10 * 1_000));
            """,
            on: connection)

        XCTAssertEqual(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs,
            ["glm:zcode:sess-continued"])
    }

    func testRunningTurnRowsDoNotEndSessions() throws {
        // Future-proofing: if a ZCode update starts inserting 'running' rows
        // at turn start, those rows must be ignored, not read as end events.
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-live",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 3 * 1_000,
                archived: false),
        ])
        XCTAssertFalse(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs.isEmpty)

        let connection = try Self.openDatabase(at: fixture.databaseURL)
        defer { sqlite3_close(connection) }
        try Self.execute(
            """
            INSERT INTO turn_usage
                (session_id, turn_id, status, started_at, completed_at)
            VALUES ('sess-live', 'turn-1', 'running',
                    \(milliseconds(now) - 5 * 1_000), NULL);
            """,
            on: connection)

        XCTAssertEqual(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs,
            ["glm:zcode:sess-live"])
    }

    func testMissingTurnUsageTableFallsBackToFreshnessOnly() throws {
        let fixture = try makeFixture(sessions: [
            Session(
                id: "sess-fresh",
                taskType: "interactive",
                timeUpdatedMs: milliseconds(now) - 5 * 1_000,
                archived: false),
        ], withTurnUsage: false)

        XCTAssertEqual(
            fixture.detector.detectSnapshot(now: now).activeSessionIDs,
            ["glm:zcode:sess-fresh"])
    }

    // MARK: - Fixtures

    private struct Session {
        let id: String
        let taskType: String
        let timeUpdatedMs: Int64
        let archived: Bool
    }

    private struct Turn {
        let sessionID: String
        let status: String
        let startedAtMs: Int64
        let completedAtMs: Int64?
    }

    private func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private func makeFixture(
        sessions: [Session],
        turns: [Turn] = [],
        withTurnUsage: Bool = true
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
        if withTurnUsage {
            try Self.execute(
                """
                CREATE TABLE turn_usage (
                    session_id text not null,
                    turn_id text not null,
                    status text not null,
                    started_at integer not null,
                    completed_at integer,
                    primary key(session_id, turn_id)
                );
                """,
                on: connection)
            for turn in turns {
                let completedValue = turn.completedAtMs.map { "\($0)" } ?? "NULL"
                try Self.execute(
                    """
                    INSERT INTO turn_usage
                        (session_id, turn_id, status, started_at, completed_at)
                    VALUES ('\(turn.sessionID)', 'turn-\(UUID().uuidString)',
                            '\(turn.status)', \(turn.startedAtMs), \(completedValue));
                    """,
                    on: connection)
            }
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
