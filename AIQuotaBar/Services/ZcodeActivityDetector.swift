import Foundation
import SQLite3

/// Detects active GLM coding tasks from the ZCode desktop/CLI session
/// database. Read-only: opens the shared `db.sqlite` and treats an
/// interactive session as active while its `time_updated` stays inside the
/// freshness window. Session titles, messages, and tool output are never read.
///
/// The database keeps updating while an agent turn works (tool calls write
/// continuously), and stops updating once the session idles, so a short
/// freshness window separates working sessions from merely open ones.
final class ZcodeActivityDetector: ProviderLocalActivityProviding,
    @unchecked Sendable
{
    static let defaultFreshnessWindow: TimeInterval = 120

    let databaseURL: URL
    let freshnessWindow: TimeInterval

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
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0) else {
                continue
            }
            let sessionID = String(cString: idText)
            guard !sessionID.isEmpty else { continue }
            let updatedAt = Date(
                timeIntervalSince1970: TimeInterval(
                    sqlite3_column_int64(statement, 1)) / 1_000)
            let prefixedID = "glm:zcode:\(sessionID)"
            activeSessionIDs.insert(prefixedID)
            lastEventBySession[prefixedID] = updatedAt
            if lastEventAt == nil || updatedAt > lastEventAt! {
                lastEventAt = updatedAt
            }
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
}
