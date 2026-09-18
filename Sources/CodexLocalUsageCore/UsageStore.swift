import Foundation
import SQLite3

/// Actor-owned SQLite connection: event persistence and durable delivery state commit together.
public actor UsageStore {
    private var db: OpaquePointer?
    private var knownIDs: Set<String>?
    private var lastScan: Scan?
    private var lastPaths = Set<String>()
    private var cacheLoaded = false
    private var cache: [String: (stamp: String, parsed: ParsedUsageFile)] = [:]
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw UsageFailure.invalid("Cannot open local usage database") }
        try Self.exec(db, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS usage_events(id TEXT PRIMARY KEY, occurred_at TEXT NOT NULL, body TEXT NOT NULL, binding TEXT, delivery TEXT NOT NULL DEFAULT 'pending', delivery_error TEXT); CREATE INDEX IF NOT EXISTS usage_delivery ON usage_events(binding,delivery,occurred_at); CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS parsed_files(path TEXT PRIMARY KEY, stamp TEXT NOT NULL, body TEXT NOT NULL);")
        // Ignore only the expected duplicate-column result on already migrated stores.
        var migrationError: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, "ALTER TABLE usage_events ADD COLUMN delivery_error TEXT", nil, nil, &migrationError)
        if let migrationError {
            let message = String(cString: migrationError); sqlite3_free(migrationError)
            if status != SQLITE_OK && !message.contains("duplicate column name") { throw UsageFailure.invalid(message) }
        }
    }
    deinit { sqlite3_close(db) }

    public struct Scan: Sendable {
        public let files: Int
        public let deferred: Int
        public let issues: Int
        public let incomplete: Int
        public let events: [LocalUsageEvent]
    }

    public func scan(root: URL, binding: String? = nil, since: Date = .distantFuture, observation: UsageAccountObservation? = nil) throws -> Scan {
        var timeline = try accountTimeline()
        if let observation {
            timeline.observe(observation)
            try setMetadata("account-timeline-v1", value: String(decoding: JSONEncoder().encode(timeline), as: UTF8.self))
        }
        if !cacheLoaded {
            for row in try rows("SELECT path,stamp,body FROM parsed_files") {
                if let value = try? JSONDecoder().decode(ParsedUsageFile.self, from: Data(row[2].utf8)) { cache[row[0]] = (row[1], value) }
            }
            cacheLoaded = true
        }
        var changed: [String] = []
        var files: [URL] = []
        var readErrors = 0
        for name in ["sessions", "archived_sessions"] {
            let dir = root.appendingPathComponent(name)
            if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in readErrors += 1; return true }) {
                for case let file as URL in enumerator where file.pathExtension == "jsonl" { files.append(file) }
            }
        }
        var parsed: [ParsedUsageFile] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            do {
                let attr = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard attr.isRegularFile == true else { continue }
                let stamp = "v2:\(attr.fileSize ?? 0):\(attr.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                if let cached = cache[file.path], cached.stamp == stamp { parsed.append(cached.parsed) }
                else {
                    let result = try UsageParser.parse(url: file)
                    cache[file.path] = (stamp, result); changed.append(file.path); parsed.append(result)
                }
            } catch { readErrors += 1 }
        }
        let paths = Set(files.map(\.path))
        cache = cache.filter { paths.contains($0.key) }
        if changed.isEmpty, readErrors == 0, paths == lastPaths, let previous = lastScan {
            if let binding { try assignUnowned(binding: binding, since: since) }
            return previous
        }
        let result = UsageParser.resolve(parsed)
        let earliest = timeline.intervals.first.map { UsageTime.string($0.start) } ?? UsageTime.string(.distantFuture)
        let attributed = result.events.map { event -> LocalUsageEvent in
            guard event.accountID == nil, event.occurredAt >= earliest, let time = UsageTime.parse(event.occurredAt), let account = timeline.account(at: time) else { return event }
            return LocalUsageEvent(id: event.id, occurredAt: event.occurredAt, model: event.model, tokens: event.tokens,
                quality: event.quality, parserVersion: event.parserVersion, accountID: account, accountSource: "login-observation")
        }
        try insert(attributed, binding: binding, since: since)
        // Cache only after event commit. A crash before this point safely replays inputs.
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for path in changed {
                guard let value = cache[path] else { continue }
                let body = String(decoding: try JSONEncoder().encode(value.parsed), as: UTF8.self)
                try run("INSERT INTO parsed_files(path,stamp,body) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET stamp=excluded.stamp,body=excluded.body", [path, value.stamp, body])
            }
            try Self.exec(db, "COMMIT")
        } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        let scan = Scan(files: files.count, deferred: result.deferred, issues: result.issues + readErrors,
                    incomplete: parsed.filter(\.incomplete).count, events: try events())
        lastScan = scan; lastPaths = paths
        return scan
    }

    public func insert(_ events: [LocalUsageEvent], binding: String? = nil, since: Date = .distantFuture) throws {
        if knownIDs == nil { knownIDs = Set(try rows("SELECT id FROM usage_events").map { $0[0] }) }
        var added = Set<String>()
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for e in events where !knownIDs!.contains(e.id) {
                let body = String(decoding: try JSONEncoder().encode(e), as: UTF8.self)
                let owner = (UsageTime.parse(e.occurredAt) ?? .distantPast) >= since ? binding : nil
                try run("INSERT OR IGNORE INTO usage_events(id,occurred_at,body,binding) VALUES(?,?,?,?)", [e.id, e.occurredAt, body, owner])
                added.insert(e.id)
            }
            // Explicitly selected historical import applies only to still-unassigned events.
            if let binding {
                try assignUnowned(binding: binding, since: since)
            }
            try Self.exec(db, "COMMIT")
            knownIDs!.formUnion(added)
        } catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }
    private func assignUnowned(binding: String, since: Date) throws {
        try run("UPDATE usage_events SET binding=? WHERE binding IS NULL AND occurred_at>=?", [binding, UsageTime.string(since)])
    }
    public func accountTimeline() throws -> UsageAccountTimeline {
        guard let value = try metadata("account-timeline-v1") else { return UsageAccountTimeline() }
        return try JSONDecoder().decode(UsageAccountTimeline.self, from: Data(value.utf8))
    }
    public func events() throws -> [LocalUsageEvent] {
        try rows("SELECT body FROM usage_events ORDER BY occurred_at,id").map { try JSONDecoder().decode(LocalUsageEvent.self, from: Data($0[0].utf8)) }
    }
    public func pending(binding: String, limit: Int = 50) throws -> [LocalUsageEvent] {
        try rows("SELECT body FROM usage_events WHERE binding=? AND delivery='pending' ORDER BY occurred_at,id LIMIT ?", [binding, String(limit)])
            .map { try JSONDecoder().decode(LocalUsageEvent.self, from: Data($0[0].utf8)) }
    }
    public func acknowledge(binding: String, ids: [String], rejected: [String] = [], reasons: [String: String] = [:]) throws {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for id in ids { try run("UPDATE usage_events SET delivery='sent' WHERE id=? AND binding=?", [id, binding]) }
            for id in rejected { try run("UPDATE usage_events SET delivery='rejected',delivery_error=? WHERE id=? AND binding=?", [reasons[id] ?? "rejected", id, binding]) }
            try Self.exec(db, "COMMIT")
        } catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }
    /// Only used after the destination verifies the same team/member/device identity.
    public func migrateBinding(from old: String, to new: String) throws {
        try run("UPDATE usage_events SET binding=? WHERE binding=?", [new, old])
    }
    public func deliveryCounts(binding: String) throws -> [String: Int] {
        Dictionary(uniqueKeysWithValues: try rows("SELECT delivery,COUNT(*) FROM usage_events WHERE binding=? GROUP BY delivery", [binding]).map { ($0[0], Int($0[1]) ?? 0) })
    }
    public func rejectionReasons(binding: String) throws -> [String: Int] {
        Dictionary(uniqueKeysWithValues: try rows("SELECT COALESCE(delivery_error,'rejected'),COUNT(*) FROM usage_events WHERE binding=? AND delivery='rejected' GROUP BY delivery_error", [binding]).map { ($0[0], Int($0[1]) ?? 0) })
    }
    public func metadata(_ key: String) throws -> String? { try rows("SELECT value FROM metadata WHERE key=?", [key]).first?.first }
    public func setMetadata(_ key: String, value: String) throws {
        try run("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }
    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
    }
    private func statement(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            if let value { sqlite3_bind_text(s, Int32(i + 1), value, -1, transient) }
            else { sqlite3_bind_null(s, Int32(i + 1)) }
        }
        return s
    }
    private func run(_ sql: String, _ values: [String?] = []) throws {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_DONE else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
    }
    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String]] {
        let s = try statement(sql, values); defer { sqlite3_finalize(s) }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
            result.append((0..<sqlite3_column_count(s)).map { index in
                sqlite3_column_text(s, index).map { String(cString: $0) } ?? ""
            })
        }
    }
}
