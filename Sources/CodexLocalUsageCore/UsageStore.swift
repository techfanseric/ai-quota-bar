import Foundation
import SQLite3

/// Actor-owned SQLite connection: event persistence and durable delivery state commit together.
public actor UsageStore {
    private var db: OpaquePointer?
    private let databaseURL: URL
    private var lastScan: Scan?
    private var lastEventWindow: String?
    private var eventsRevision = 0
    private var loadedRevision = -1
    private var catalogLoaded = false
    private struct FileEntry {
        let stamp: String
        let session: String?
        let parent: String?
        let issues: Int
        let incomplete: Bool
    }
    private var catalog: [String: FileEntry] = [:]
    private var deferredSessions = Set<String>()
    public init(url: URL) throws {
        databaseURL = url
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
        public let revision: Int
        public let sourceLogBytes: Int64
        public let parsedFileCount: Int
        public let resolvedFileCount: Int
        public let files: Int
        public let deferred: Int
        public let issues: Int
        public let incomplete: Int
        public let events: [LocalUsageEvent]
    }

    /// Persisted headers let us resolve only the changed session family. Full parser
    /// records live on disk, not permanently beside a second decoded event history.
    public func scan(root: URL, binding: String? = nil, since: Date = .distantFuture,
                     observation: UsageAccountObservation? = nil, eventsSince: Date = .distantPast) throws -> Scan {
        var timeline = try accountTimeline()
        if let observation {
            timeline.observe(observation)
            try setMetadata("account-timeline-v1", value: String(decoding: JSONEncoder().encode(timeline), as: UTF8.self))
        }
        let needsInitialResolution = try loadCatalog()
        var changed: [String: ParsedUsageFile] = [:]
        var nextCatalog = catalog
        var paths = Set<String>()
        var readErrors = 0
        var sourceLogBytes: Int64 = 0
        for name in ["sessions", "archived_sessions"] {
            let dir = root.appendingPathComponent(name)
            do {
                let values = try dir.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { readErrors += 1; continue }
            } catch {
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { continue }
                readErrors += 1; continue
            }
            if let enumerator = FileManager.default.enumerator(at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in readErrors += 1; return true }) {
                for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                    paths.insert(file.path)
                    do {
                        let attr = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                        guard attr.isRegularFile == true else { continue }
                        sourceLogBytes += Int64(attr.fileSize ?? 0)
                        let stamp = "v2:\(attr.fileSize ?? 0):\(attr.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                        if catalog[file.path]?.stamp != stamp {
                            let parsed = try UsageParser.parse(url: file)
                            changed[file.path] = parsed
                            nextCatalog[file.path] = FileEntry(stamp: stamp, session: parsed.sessionID,
                                parent: parsed.parentID, issues: parsed.issues, incomplete: parsed.incomplete)
                        }
                    } catch { readErrors += 1 }
                }
            }
        }
        // An inaccessible directory is not evidence that its history disappeared.
        let removed = readErrors == 0 ? Set(catalog.keys).subtracting(paths) : []
        for path in removed { nextCatalog.removeValue(forKey: path) }
        var affected = Set(changed.keys.compactMap { nextCatalog[$0]?.session })
        affected.formUnion(changed.keys.compactMap { catalog[$0]?.session })
        affected.formUnion(removed.compactMap { catalog[$0]?.session })
        if needsInitialResolution { affected.formUnion(nextCatalog.values.compactMap(\.session)) }
        // Include both ancestors and descendants (forks, continuations, archive copies).
        // This preserves the original resolver's billing and deduplication semantics.
        var neighbors: [String: Set<String>] = [:]
        for entry in nextCatalog.values {
            if let session = entry.session, let parent = entry.parent {
                neighbors[session, default: []].insert(parent)
                neighbors[parent, default: []].insert(session)
            }
        }
        var queue = Array(affected)
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for neighbor in neighbors[id] ?? [] where affected.insert(neighbor).inserted { queue.append(neighbor) }
        }
        let decoder = JSONDecoder()
        var parsed: [ParsedUsageFile] = []
        for (path, entry) in nextCatalog where entry.session.map(affected.contains) ?? false {
            if let value = changed[path] { parsed.append(value) }
            else if let body = try rows("SELECT body FROM parsed_files WHERE path=?", [path]).first?.first {
                parsed.append(try decoder.decode(ParsedUsageFile.self, from: Data(body.utf8)))
            }
        }
        let result = UsageParser.resolve(parsed)
        let earliest = timeline.intervals.first.map { UsageTime.string($0.start) } ?? UsageTime.string(.distantFuture)
        let attributed = result.events.map { event -> LocalUsageEvent in
            guard event.accountID == nil, event.occurredAt >= earliest,
                  let time = UsageTime.parse(event.occurredAt), let account = timeline.account(at: time) else { return event }
            return LocalUsageEvent(id: event.id, occurredAt: event.occurredAt, model: event.model, tokens: event.tokens,
                quality: event.quality, parserVersion: event.parserVersion, accountID: account, accountSource: "login-observation")
        }
        try insert(attributed, binding: binding, since: since)
        let nextDeferred = deferredSessions.subtracting(affected).union(result.deferredSessionIDs)
        // Commit parser stamps only after event persistence. A crash safely replays.
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for (path, value) in changed {
                guard let entry = nextCatalog[path] else { continue }
                let body = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                try run("INSERT INTO parsed_files(path,stamp,body) VALUES(?,?,?) ON CONFLICT(path) DO UPDATE SET stamp=excluded.stamp,body=excluded.body", [path, entry.stamp, body])
                try run("INSERT OR REPLACE INTO parsed_file_headers(path,stamp,session,parent,issues,incomplete) VALUES(?,?,?,?,?,?)",
                    [path, entry.stamp, entry.session, entry.parent, String(entry.issues), entry.incomplete ? "1" : "0"])
            }
            for path in removed {
                try run("DELETE FROM parsed_files WHERE path=?", [path])
                try run("DELETE FROM parsed_file_headers WHERE path=?", [path])
            }
            try setMetadata("deferred-sessions-v1", value: String(decoding: JSONEncoder().encode(nextDeferred), as: UTF8.self))
            try setMetadata("incremental-resolution-v1", value: "1")
            try Self.exec(db, "COMMIT")
        } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        catalog = nextCatalog; deferredSessions = nextDeferred
        let window = UsageTime.string(eventsSince)
        let visibleEvents: [LocalUsageEvent]
        if let previous = lastScan, loadedRevision == eventsRevision, lastEventWindow == window {
            visibleEvents = previous.events
        } else {
            visibleEvents = try events(since: eventsSince)
            loadedRevision = eventsRevision
            lastEventWindow = window
        }
        let scan = Scan(revision: eventsRevision, sourceLogBytes: sourceLogBytes, parsedFileCount: changed.count, resolvedFileCount: parsed.count,
            files: paths.count, deferred: deferredSessions.count,
            issues: nextCatalog.values.reduce(readErrors) { $0 + $1.issues },
            incomplete: nextCatalog.values.filter(\.incomplete).count, events: visibleEvents)
        lastScan = scan
        return scan
    }

    private func loadCatalog() throws -> Bool {
        if catalogLoaded { return try metadata("incremental-resolution-v1") == nil }
        try Self.exec(db, "CREATE INDEX IF NOT EXISTS usage_chronological ON usage_events(occurred_at,id); CREATE TABLE IF NOT EXISTS parsed_file_headers(path TEXT PRIMARY KEY, stamp TEXT NOT NULL, session TEXT, parent TEXT, issues INTEGER NOT NULL, incomplete INTEGER NOT NULL);")
        // One-time lightweight header migration; SQLite extracts one JSON body at a time.
        if try metadata("parsed-headers-v1") == nil {
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                try Self.exec(db, "INSERT OR REPLACE INTO parsed_file_headers SELECT path,stamp,json_extract(body,'$.sessionID'),json_extract(body,'$.parentID'),COALESCE(json_extract(body,'$.issues'),0),COALESCE(json_extract(body,'$.incomplete'),0) FROM parsed_files;")
                try setMetadata("parsed-headers-v1", value: "1")
                try Self.exec(db, "COMMIT")
            } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        }
        for row in try rows("SELECT path,stamp,session,parent,issues,incomplete FROM parsed_file_headers") {
            catalog[row[0]] = FileEntry(stamp: row[1], session: row[2].isEmpty ? nil : row[2],
                parent: row[3].isEmpty ? nil : row[3], issues: Int(row[4]) ?? 0, incomplete: row[5] == "1")
        }
        if let value = try metadata("deferred-sessions-v1") {
            deferredSessions = try JSONDecoder().decode(Set<String>.self, from: Data(value.utf8))
        }
        catalogLoaded = true
        return try metadata("incremental-resolution-v1") == nil
    }

    public func insert(_ events: [LocalUsageEvent], binding: String? = nil, since: Date = .distantFuture) throws {
        let insert = try statement("INSERT OR IGNORE INTO usage_events(id,occurred_at,body,binding) VALUES(?,?,?,?)", [])
        defer { sqlite3_finalize(insert) }
        let existing = try statement("SELECT 1 FROM usage_events WHERE id=?", [])
        defer { sqlite3_finalize(existing) }
        let encoder = JSONEncoder()
        let cutoff = UsageTime.string(since)
        var added = 0
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for event in events {
                sqlite3_reset(existing); sqlite3_clear_bindings(existing)
                bind(existing, [event.id])
                let status = sqlite3_step(existing)
                if status == SQLITE_ROW { continue }
                guard status == SQLITE_DONE else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
                let body = String(decoding: try encoder.encode(event), as: UTF8.self)
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                bind(insert, [event.id, event.occurredAt, body, event.occurredAt >= cutoff ? binding : nil])
                guard sqlite3_step(insert) == SQLITE_DONE else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
                added += Int(sqlite3_changes(db))
            }
            if let binding { try assignUnowned(binding: binding, since: since) }
            try Self.exec(db, "COMMIT")
            if added > 0 { eventsRevision += 1 }
        } catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }
    private func assignUnowned(binding: String, since: Date) throws {
        try run("UPDATE usage_events SET binding=? WHERE binding IS NULL AND occurred_at>=?", [binding, UsageTime.string(since)])
    }
    public func accountTimeline() throws -> UsageAccountTimeline {
        guard let value = try metadata("account-timeline-v1") else { return UsageAccountTimeline() }
        return try JSONDecoder().decode(UsageAccountTimeline.self, from: Data(value.utf8))
    }
    public func events(since: Date = .distantPast) throws -> [LocalUsageEvent] {
        let s = try statement("SELECT body FROM usage_events WHERE occurred_at>=? ORDER BY occurred_at,id", [UsageTime.string(since)])
        defer { sqlite3_finalize(s) }
        var result: [LocalUsageEvent] = []
        let decoder = JSONDecoder()
        while true {
            let status = sqlite3_step(s)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { throw UsageFailure.invalid(String(cString: sqlite3_errmsg(db))) }
            // Decode a single row; never accumulate a second full array of JSON strings.
            result.append(try decoder.decode(LocalUsageEvent.self, from: Data(bytes: text, count: Int(sqlite3_column_bytes(s, 0)))))
        }
    }
    public struct StorageStats: Sendable {
        public let databaseBytes: Int64
        public let journalBytes: Int64
        public let sharedMemoryBytes: Int64
        public let totalRecords: Int
        public let localOnlyRecords: Int
        public let confirmedRecords: Int
        public let pendingRecords: Int
        public let rejectedRecords: Int
        public let oldestPendingAt: String?
        public let latestConfirmedEventAt: String?
        public var totalBytes: Int64 { databaseBytes + journalBytes + sharedMemoryBytes }
    }

    public func storageStats() throws -> StorageStats {
        func bytes(_ suffix: String) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: databaseURL.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0
        }
        let counts = try rows("SELECT binding IS NULL,delivery,COUNT(*) FROM usage_events GROUP BY binding IS NULL,delivery")
        var total = 0, local = 0, sent = 0, pending = 0, rejected = 0
        for row in counts {
            let count = Int(row[2]) ?? 0; total += count
            if row[0] == "1" { local += count }
            else if row[1] == "sent" { sent += count }
            else if row[1] == "pending" { pending += count }
            else if row[1] == "rejected" { rejected += count }
        }
        let pendingAt = try rows("SELECT MIN(occurred_at) FROM usage_events WHERE binding IS NOT NULL AND delivery='pending'").first?.first
        let confirmedAt = try rows("SELECT MAX(occurred_at) FROM usage_events WHERE binding IS NOT NULL AND delivery='sent'").first?.first
        return StorageStats(databaseBytes: bytes(""), journalBytes: bytes("-wal"), sharedMemoryBytes: bytes("-shm"),
            totalRecords: total, localOnlyRecords: local, confirmedRecords: sent, pendingRecords: pending,
            rejectedRecords: rejected, oldestPendingAt: pendingAt?.isEmpty == false ? pendingAt : nil,
            latestConfirmedEventAt: confirmedAt?.isEmpty == false ? confirmedAt : nil)
    }

    public func confirmedEvents(binding: String) throws -> [LocalUsageEvent] {
        let decoder = JSONDecoder()
        return try rows("SELECT body FROM usage_events WHERE binding=? AND delivery='sent' ORDER BY occurred_at,id", [binding])
            .map { try decoder.decode(LocalUsageEvent.self, from: Data($0[0].utf8)) }
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
        bind(s, values)
        return s
    }
    private func bind(_ s: OpaquePointer?, _ values: [String?]) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            if let value { sqlite3_bind_text(s, Int32(i + 1), value, -1, transient) }
            else { sqlite3_bind_null(s, Int32(i + 1)) }
        }
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
