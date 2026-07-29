import Foundation
import SQLite3
import XCTest
@testable import AIQuotaBar

final class CodexLocalActivityDetectorTests: XCTestCase {
    func testDetectsAlreadyRunningTasksAndExcludesCompletedTasks() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let activeRollout = fixture.directory
            .appendingPathComponent("active.jsonl")
        let completedRollout = fixture.directory
            .appendingPathComponent("completed.jsonl")
        let staleRollout = fixture.directory
            .appendingPathComponent("stale.jsonl")

        try rollout(
            [
                event("task_started"),
                event("agent_reasoning"),
                event("token_count")
            ],
            repeatingMiddleLine: 40
        ).write(to: activeRollout, atomically: true, encoding: .utf8)
        try rollout([
            event("task_started"),
            event("agent_reasoning"),
            event("task_complete")
        ]).write(to: completedRollout, atomically: true, encoding: .utf8)
        try rollout([
            event("task_started")
        ]).write(to: staleRollout, atomically: true, encoding: .utf8)

        try fixture.insert(
            id: "active-thread",
            rolloutURL: activeRollout,
            updatedAt: 9_990
        )
        try fixture.insert(
            id: "completed-thread",
            rolloutURL: completedRollout,
            updatedAt: 9_995
        )
        try fixture.insert(
            id: "stale-thread",
            rolloutURL: staleRollout,
            updatedAt: 1_000
        )

        let detector = CodexLocalActivityDetector(
            stateDatabaseURL: fixture.databaseURL,
            recentActivityWindow: 3_600,
            candidateLimit: 32,
            maximumRolloutScanBytes: 64 * 1_024,
            rolloutReadChunkBytes: 64
        )

        let snapshot = detector.detectSnapshot(
            now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertEqual(snapshot.activeSessionIDs, ["active-thread"])
        XCTAssertEqual(
            snapshot.lastEventAt,
            Date(timeIntervalSince1970: 9_990)
        )
    }

    func testDefaultDatabaseFollowsConfiguredCodexHome() {
        let url = CodexLocalActivityDetector.defaultStateDatabaseURL(
            environment: ["CODEX_HOME": "/tmp/custom-codex-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/unused")
        )

        XCTAssertEqual(
            url.path,
            "/tmp/custom-codex-home/state_5.sqlite"
        )
    }

    private func event(_ type: String) -> String {
        """
        {"timestamp":"2026-07-29T10:00:00Z","type":"event_msg","payload":{"type":"\(type)"}}
        """
    }

    private func rollout(
        _ lines: [String],
        repeatingMiddleLine: Int = 0
    ) -> String {
        guard repeatingMiddleLine > 0, lines.count >= 2 else {
            return lines.joined(separator: "\n") + "\n"
        }
        var expanded = [lines[0]]
        expanded.append(
            contentsOf: Array(
                repeating: lines[1],
                count: repeatingMiddleLine
            )
        )
        expanded.append(contentsOf: lines.dropFirst(2))
        return expanded.joined(separator: "\n") + "\n"
    }

    private func makeFixture() throws -> SQLiteFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexLocalActivityDetectorTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try SQLiteFixture(directory: directory)
    }
}

private final class SQLiteFixture {
    let directory: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init(directory: URL) throws {
        self.directory = directory
        databaseURL = directory.appendingPathComponent("state_5.sqlite")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 1
            )
        }
        try execute(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                archived INTEGER NOT NULL DEFAULT 0
            );
            """,
            database: database
        )
    }

    func insert(
        id: String,
        rolloutURL: URL,
        updatedAt: Int64
    ) throws {
        guard let database else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 2
            )
        }
        let sql = """
        INSERT INTO threads (id, rollout_path, updated_at, archived)
        VALUES (?, ?, ?, 0);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 3
            )
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )
        sqlite3_bind_text(statement, 1, id, -1, transient)
        sqlite3_bind_text(
            statement,
            2,
            rolloutURL.path,
            -1,
            transient
        )
        sqlite3_bind_int64(statement, 3, updatedAt)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 4
            )
        }
    }

    func cleanup() {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    private func execute(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(
                domain: "CodexLocalActivityDetectorTests",
                code: 5
            )
        }
    }
}
