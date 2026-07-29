import Foundation
import SQLite3

struct CodexLocalActivitySnapshot: Equatable, Sendable {
    var activeSessionIDs: Set<String>
    var lastEventAt: Date?

    static let empty = CodexLocalActivitySnapshot(
        activeSessionIDs: [],
        lastEventAt: nil
    )
}

protocol CodexLocalActivityProviding: Sendable {
    func snapshot() async -> CodexLocalActivitySnapshot
}

struct CodexLocalActivityDetector: CodexLocalActivityProviding, Sendable {
    private struct Candidate {
        let sessionID: String
        let rolloutURL: URL
        let updatedAt: Date
    }

    let stateDatabaseURL: URL
    let recentActivityWindow: TimeInterval
    let candidateLimit: Int32
    let maximumRolloutScanBytes: Int
    let rolloutReadChunkBytes: Int

    init(
        stateDatabaseURL: URL = CodexLocalActivityDetector
            .defaultStateDatabaseURL(),
        recentActivityWindow: TimeInterval = 12 * 60 * 60,
        candidateLimit: Int32 = 256,
        maximumRolloutScanBytes: Int = 16 * 1_024 * 1_024,
        rolloutReadChunkBytes: Int = 256 * 1_024
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.recentActivityWindow = recentActivityWindow
        self.candidateLimit = candidateLimit
        self.maximumRolloutScanBytes = maximumRolloutScanBytes
        self.rolloutReadChunkBytes = rolloutReadChunkBytes
    }

    func snapshot() async -> CodexLocalActivitySnapshot {
        await Task.detached(priority: .utility) {
            detectSnapshot(now: Date())
        }.value
    }

    func detectSnapshot(now: Date) -> CodexLocalActivitySnapshot {
        let candidates = recentCandidates(now: now)
        var activeSessionIDs: Set<String> = []
        var lastEventAt: Date?

        for candidate in candidates
        where latestTaskState(in: candidate.rolloutURL) == .active {
            activeSessionIDs.insert(candidate.sessionID)
            if lastEventAt == nil || candidate.updatedAt > lastEventAt! {
                lastEventAt = candidate.updatedAt
            }
        }

        return CodexLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt
        )
    }

    static func defaultStateDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let codexHome: URL
        if let configuredHome = environment["CODEX_HOME"],
           !configuredHome.isEmpty {
            codexHome = URL(
                fileURLWithPath: configuredHome,
                isDirectory: true
            )
        } else {
            codexHome = homeDirectory.appendingPathComponent(
                ".codex",
                isDirectory: true
            )
        }
        return codexHome.appendingPathComponent("state_5.sqlite")
    }

    private enum TaskState {
        case active
        case inactive
        case unknown
    }

    private func recentCandidates(now: Date) -> [Candidate] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(
            stateDatabaseURL.path,
            &database,
            flags,
            nil
        ) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let query = """
        SELECT id, rollout_path, updated_at
        FROM threads
        WHERE archived = 0 AND updated_at >= ?
        ORDER BY updated_at DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            query,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        let cutoff = Int64(
            now.timeIntervalSince1970 - recentActivityWindow
        )
        sqlite3_bind_int64(statement, 1, cutoff)
        sqlite3_bind_int(statement, 2, candidateLimit)

        var candidates: [Candidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let pathText = sqlite3_column_text(statement, 1) else {
                continue
            }
            let sessionID = String(cString: idText)
            let rolloutPath = String(cString: pathText)
            guard !sessionID.isEmpty, !rolloutPath.isEmpty else {
                continue
            }
            candidates.append(Candidate(
                sessionID: sessionID,
                rolloutURL: URL(fileURLWithPath: rolloutPath),
                updatedAt: Date(
                    timeIntervalSince1970: TimeInterval(
                        sqlite3_column_int64(statement, 2)
                    )
                )
            ))
        }
        return candidates
    }

    private func latestTaskState(in rolloutURL: URL) -> TaskState {
        guard let file = try? FileHandle(forReadingFrom: rolloutURL) else {
            return .unknown
        }
        defer { try? file.close() }

        let fileSize = (try? file.seekToEnd()) ?? 0
        var cursor = fileSize
        var scannedBytes = 0
        var laterLineFragment = Data()

        while cursor > 0 && scannedBytes < maximumRolloutScanBytes {
            let byteCount = min(
                rolloutReadChunkBytes,
                Int(cursor),
                maximumRolloutScanBytes - scannedBytes
            )
            cursor -= UInt64(byteCount)
            do {
                try file.seek(toOffset: cursor)
                guard let chunk = try file.read(
                    upToCount: byteCount
                ) else {
                    return .unknown
                }
                scannedBytes += chunk.count

                var combined = chunk
                combined.append(laterLineFragment)
                let lines = combined.split(
                    separator: 0x0A,
                    omittingEmptySubsequences: true
                )

                let startsAtLineBoundary = cursor == 0
                    || chunk.first == 0x0A
                let firstCompleteIndex = startsAtLineBoundary ? 0 : 1
                if lines.count > firstCompleteIndex {
                    for line in lines[firstCompleteIndex...].reversed() {
                        let state = taskState(fromJSONLine: Data(line))
                        if state != .unknown {
                            return state
                        }
                    }
                }

                if startsAtLineBoundary {
                    laterLineFragment.removeAll()
                } else if let first = lines.first {
                    laterLineFragment = Data(first)
                } else {
                    laterLineFragment = combined
                }
            } catch {
                return .unknown
            }
        }
        return .unknown
    }

    private func taskState(fromJSONLine data: Data) -> TaskState {
        guard let root = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
        root["type"] as? String == "event_msg",
        let payload = root["payload"] as? [String: Any],
        let type = payload["type"] as? String else {
            return .unknown
        }

        switch type {
        case "task_started":
            return .active
        case "task_complete", "turn_aborted", "task_aborted":
            return .inactive
        default:
            return .unknown
        }
    }
}
