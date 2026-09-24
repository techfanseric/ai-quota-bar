import Foundation
import SQLite3

/// Detects active GLM coding tasks from the ZCode desktop/CLI session
/// database. Read-only: opens the shared `db.sqlite` and treats an
/// interactive session as active while its `time_updated` stays inside the
/// freshness window. Session titles, messages, and tool output are never read.
///
/// Hybrid lifecycle (validated live on 2026-09-24): `turn_usage` rows are
/// INSERTed only when a turn reaches a terminal state (`completed`, `error`,
/// `cancelled`), with backfilled timestamps — no `running` row is observable
/// while a turn executes. So freshness still supplies the start/running
/// signal, and newly-seen terminal rows act as immediate end events: a
/// session drops out of the active set as soon as its turn's terminal row
/// lands instead of waiting out the whole freshness window. A session whose
/// `time_updated` is NEWER than its last terminal row has writes beyond that
/// turn (e.g. an immediately continued turn) and stays active.
final class ZcodeActivityDetector: ProviderLocalActivityProviding,
    @unchecked Sendable
{
    static let defaultFreshnessWindow: TimeInterval = 120

    let databaseURL: URL
    let freshnessWindow: TimeInterval

    private let lock = NSLock()
    /// Highest `turn_usage.rowid` already consumed; -1 until the first poll
    /// initializes it past the historical completion ledger.
    private var lastSeenTurnRowID: Int64 = -1
    /// Latest terminal-turn `completed_at` (ms) per session.
    private var lastTurnEndMsBySession: [String: Int64] = [:]

    init(
        databaseURL: URL = ZcodeActivityDetector.defaultDatabaseURL(),
        freshnessWindow: TimeInterval = ZcodeActivityDetector
            .defaultFreshnessWindow
    ) {
        self.databaseURL = databaseURL
        self.freshnessWindow = freshnessWindow
    }

    static func defaultDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let zcodeHome: URL
        if let configured = environment["ZCODE_HOME"],
           !configured.isEmpty {
            zcodeHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            zcodeHome = homeDirectory.appendingPathComponent(
                ".zcode",
                isDirectory: true)
        }
        return zcodeHome
            .appendingPathComponent("cli", isDirectory: true)
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent("db.sqlite")
    }

    /// Local presence check for task-protection eligibility: a ZCode
    /// installation exists when the shared session database is present.
    static func isClientInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        fileManager.fileExists(
            atPath: defaultDatabaseURL(environment: environment).path)
    }

    func snapshot() async -> ProviderLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot(now: Date())
        }.value
    }

    func detectSnapshot(now: Date) -> ProviderLocalActivitySnapshot {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .empty
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            flags,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return .empty
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        guard columnsNeeded(database: database) else { return .empty }

        lock.lock()
        defer { lock.unlock() }
        consumeTurnEndEvents(database: database)

        // Only main interactive sessions count: subagent children belong to
        // their parent session, and side chats are user-attended by
        // definition. `time_updated` is milliseconds since epoch.
        let cutoffMilliseconds = Int64(
            (now - freshnessWindow).timeIntervalSince1970 * 1_000)
        let query = """
        SELECT id, time_updated FROM session
        WHERE task_type = 'interactive'
          AND time_archived IS NULL
          AND time_updated >= ?
        ORDER BY time_updated DESC
        LIMIT 99;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return .empty }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, cutoffMilliseconds)

        var activeSessionIDs = Set<String>()
        var lastEventBySession: [String: Date] = [:]
        var lastEventAt: Date?
        var candidateIDs = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else {
                continue
            }
            let sessionID = String(cString: idText)
            guard !sessionID.isEmpty else { continue }
            candidateIDs.insert(sessionID)
            let updatedAtMs = sqlite3_column_int64(statement, 1)
            if let endedAtMs = lastTurnEndMsBySession[sessionID],
               updatedAtMs <= endedAtMs {
                // The freshest write is still the ended turn's own last
                // write: the turn finished and nothing has happened since.
                continue
            }
            let updatedAt = Date(
                timeIntervalSince1970: TimeInterval(updatedAtMs) / 1_000)
            let prefixedID = "glm:zcode:\(sessionID)"
            activeSessionIDs.insert(prefixedID)
            lastEventBySession[prefixedID] = updatedAt
            if lastEventAt == nil || updatedAt > lastEventAt! {
                lastEventAt = updatedAt
            }
        }
        lastTurnEndMsBySession = lastTurnEndMsBySession.filter {
            candidateIDs.contains($0.key)
        }
        return ProviderLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt,
            lastEventBySession: lastEventBySession)
    }

    /// The session table is created by ZCode, not by this app; a schema
    /// mismatch means the installation is newer/older than the supported
    /// shape and must yield "no activity" instead of an error.
    private func columnsNeeded(database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(session);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 1) {
            columns.insert(String(cString: name))
        }
        return Set(["id", "task_type", "time_updated", "time_archived"])
            .isSubset(of: columns)
    }

    /// Advances the terminal-turn cursor. Must be called with `lock` held.
    private func consumeTurnEndEvents(database: OpaquePointer) {
        guard turnUsageColumnsNeeded(database: database) else {
            // Schema drift: fall back to freshness-only behavior and re-arm
            // the cursor in case the table comes back in a supported shape.
            lastTurnEndMsBySession.removeAll()
            lastSeenTurnRowID = -1
            return
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        if lastSeenTurnRowID < 0 {
            // First poll after launch: skip the historical completion ledger
            // so long-finished turns never read as fresh end events.
            guard sqlite3_prepare_v2(
                database,
                "SELECT COALESCE(MAX(rowid), 0) FROM turn_usage;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else { return }
            guard sqlite3_step(statement) == SQLITE_ROW else { return }
            lastSeenTurnRowID = sqlite3_column_int64(statement, 0)
            return
        }

        guard sqlite3_prepare_v2(
            database,
            """
            SELECT rowid, session_id, status, completed_at FROM turn_usage
            WHERE rowid > ? ORDER BY rowid;
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, statement != nil else { return }
        sqlite3_bind_int64(statement, 1, lastSeenTurnRowID)
        var maxRowID = lastSeenTurnRowID
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            maxRowID = max(maxRowID, rowID)
            guard let idText = sqlite3_column_text(statement, 1) else {
                continue
            }
            let sessionID = String(cString: idText)
            let status = sqlite3_column_text(statement, 2)
                .map { String(cString: $0) } ?? ""
            // Rows land at turn termination today, but a future schema that
            // inserts 'running' rows early must not read as an end event.
            guard !sessionID.isEmpty, status != "running" else { continue }
            let completedAtMs = sqlite3_column_int64(statement, 3)
            lastTurnEndMsBySession[sessionID] = max(
                lastTurnEndMsBySession[sessionID] ?? Int64.min,
                completedAtMs)
        }
        lastSeenTurnRowID = maxRowID
    }

    /// Same defensive contract as `columnsNeeded`, for the end-event table.
    private func turnUsageColumnsNeeded(database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(turn_usage);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 1) {
            columns.insert(String(cString: name))
        }
        return Set(["session_id", "status", "completed_at"])
            .isSubset(of: columns)
    }
}
