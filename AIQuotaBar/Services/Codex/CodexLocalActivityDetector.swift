import Foundation
import SQLite3

struct CodexLocalSessionActivity: Equatable, Sendable {
    let title: String?
    let projectName: String?
    let gitBranch: String?
    let source: String?
    let model: String?
    let modelProvider: String?
    let reasoningEffort: String?
    let sandboxPolicy: String?
    let approvalMode: String?
    let tokensUsed: Int64?
    let activeSubtaskCount: Int
    let subtaskNames: [String]
    let createdAt: Date?
    let startedAt: Date?
    let lastEventAt: Date?
    let cliVersion: String?
    let semantic: CodexSafeActivitySemantic?
    let progressLines: [CodexSafeProgressLine]
    let recentEvents: [CodexSafeActivityEvent]

    init(
        title: String? = nil,
        projectName: String? = nil,
        gitBranch: String? = nil,
        source: String? = nil,
        model: String? = nil,
        modelProvider: String? = nil,
        reasoningEffort: String? = nil,
        sandboxPolicy: String? = nil,
        approvalMode: String? = nil,
        tokensUsed: Int64? = nil,
        activeSubtaskCount: Int = 0,
        subtaskNames: [String] = [],
        createdAt: Date? = nil,
        startedAt: Date?,
        lastEventAt: Date?,
        cliVersion: String? = nil,
        semantic: CodexSafeActivitySemantic?,
        progressLines: [CodexSafeProgressLine],
        recentEvents: [CodexSafeActivityEvent]
    ) {
        self.title = title
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.source = source
        self.model = model
        self.modelProvider = modelProvider
        self.reasoningEffort = reasoningEffort
        self.sandboxPolicy = sandboxPolicy
        self.approvalMode = approvalMode
        self.tokensUsed = tokensUsed
        self.activeSubtaskCount = activeSubtaskCount
        self.subtaskNames = subtaskNames
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.cliVersion = cliVersion
        self.semantic = semantic
        self.progressLines = progressLines
        self.recentEvents = recentEvents
    }
}

struct CodexLocalActivitySnapshot: Equatable, Sendable {
    var activeSessionIDs: Set<String>
    var lastEventAt: Date?
    var sessionActivities: [String: CodexLocalSessionActivity]

    init(
        activeSessionIDs: Set<String>,
        lastEventAt: Date?,
        sessionActivities: [String: CodexLocalSessionActivity] = [:]
    ) {
        self.activeSessionIDs = activeSessionIDs
        self.lastEventAt = lastEventAt
        self.sessionActivities = sessionActivities
    }

    static let empty = CodexLocalActivitySnapshot(
        activeSessionIDs: [],
        lastEventAt: nil)
}

protocol CodexLocalActivityProviding: Sendable {
    func snapshot() async -> CodexLocalActivitySnapshot
}

/// Incrementally reads Codex JSONL rollout files. Only allow-listed lifecycle
/// semantics and aggressively sanitized assistant commentary survive parsing;
/// raw rollout records, tool arguments, commands, and outputs are never kept.
final class CodexLocalActivityDetector: CodexLocalActivityProviding,
    @unchecked Sendable
{
    private struct Candidate {
        let threadID: String
        let parentThreadID: String?
        let rolloutURL: URL
        let createdAt: Date
        let updatedAt: Date
        let title: String?
        let projectName: String?
        let gitBranch: String?
        let source: String?
        let model: String?
        let modelProvider: String?
        let reasoningEffort: String?
        let sandboxPolicy: String?
        let approvalMode: String?
        let tokensUsed: Int64?
        let agentNickname: String?
        let cliVersion: String?

        var isSubagent: Bool { parentThreadID != nil }
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private struct ParserState {
        var identity: FileIdentity?
        var offset: UInt64 = 0
        var partialLine = Data()
        var activeTurnIDs: Set<String> = []
        var startsByTurn: [String: Date] = [:]
        var latestSemantic: CodexSafeActivitySemantic?
        var progressLines: [CodexSafeProgressLine] = []
        var recentEvents: [CodexSafeActivityEvent] = []
        var inFlightTools: [String: CodexSafeToolCategory] = [:]
        var rootSessionID: String?
        var hasObservedOwnedTurn = false

        var isActive: Bool { !activeTurnIDs.isEmpty }

        mutating func resetForReplacement(identity: FileIdentity?) {
            self = ParserState(identity: identity)
        }

        mutating func resetContentAfterCompaction(at date: Date) {
            progressLines.removeAll()
            recentEvents.removeAll()
            inFlightTools.removeAll()
            latestSemantic = CodexSafeActivitySemantic(
                phase: activeTurnIDs.isEmpty ? .unknown : .thinking,
                toolCategory: nil,
                toolStatus: nil,
                at: date)
        }

        init(identity: FileIdentity? = nil) {
            self.identity = identity
        }
    }

    let stateDatabaseURL: URL
    let recentActivityWindow: TimeInterval
    let candidateLimit: Int32
    let maximumRolloutScanBytes: Int
    let rolloutReadChunkBytes: Int

    private let lock = NSLock()
    private var parserStates: [String: ParserState] = [:]
    private let fractionalDateFormatter: ISO8601DateFormatter
    private let internetDateFormatter: ISO8601DateFormatter

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
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        self.fractionalDateFormatter = fractionalDateFormatter
        internetDateFormatter = ISO8601DateFormatter()
    }

    func snapshot() async -> CodexLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot(now: Date())
        }.value
    }

    func detectSnapshot(now: Date) -> CodexLocalActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }

        let candidates = recentCandidates(now: now)
        let candidateByThread = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.threadID, $0) })
        let parentByThread = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { candidate in
                candidate.parentThreadID.map {
                    (candidate.threadID, $0)
                }
            })
        var rootByThread: [String: String] = [:]
        for candidate in candidates {
            rootByThread[candidate.threadID] = Self.rootThreadID(
                for: candidate.threadID,
                parentByThread: parentByThread)
        }

        var statesByThread: [String: ParserState] = [:]
        var livePaths = Set<String>()
        for candidate in candidates {
            let path = candidate.rolloutURL.path
            livePaths.insert(path)
            var state = parserStates[path] ?? ParserState()
            updateParserState(
                &state,
                for: candidate,
                now: now)
            parserStates[path] = state
            statesByThread[candidate.threadID] = state
            if let rootSessionID = state.rootSessionID,
               rootSessionID != candidate.threadID {
                rootByThread[candidate.threadID] = rootSessionID
            }
        }
        parserStates = parserStates.filter {
            livePaths.contains($0.key)
        }

        let cutoff = now.addingTimeInterval(-10 * 60)
        var grouped: [String: [(Candidate, ParserState)]] = [:]
        for candidate in candidates {
            guard let state = statesByThread[candidate.threadID],
                  state.isActive else { continue }
            let rootID = rootByThread[candidate.threadID]
                ?? candidate.threadID
            grouped[rootID, default: []].append((candidate, state))
        }

        var activities: [String: CodexLocalSessionActivity] = [:]
        for (rootID, members) in grouped {
            let representative = candidateByThread[rootID]
                ?? members.map(\.0).min { $0.createdAt < $1.createdAt }
            let starts = members.flatMap { $0.1.startsByTurn.values }
            let activeTurnCount = members.reduce(0) {
                $0 + $1.1.activeTurnIDs.count
            }
            let reliableStart = starts.count == activeTurnCount
                ? starts.min()
                : nil
            let lastEventAt = members.map(\.0.updatedAt).max()
            let semantic = members.compactMap(\.1.latestSemantic)
                .filter { $0.at >= cutoff && $0.at <= now }
                .max { $0.at < $1.at }
            let progressLines = Self.latestUniqueProgressLines(
                members.flatMap(\.1.progressLines),
                now: now,
                cutoff: cutoff)
            let recentEvents = Array(
                members.flatMap(\.1.recentEvents)
                    .filter { $0.at >= cutoff && $0.at <= now }
                    .sorted { $0.at < $1.at }
                    .suffix(16))
            let tokenCounts = members.compactMap { $0.0.tokensUsed }
            let subtaskNames = Array(Array(Set(members.compactMap { member in
                member.0.isSubagent ? member.0.agentNickname : nil
            })).sorted().prefix(5))
            activities[rootID] = CodexLocalSessionActivity(
                title: representative?.title,
                projectName: representative?.projectName,
                gitBranch: representative?.gitBranch,
                source: representative?.source,
                model: representative?.model,
                modelProvider: representative?.modelProvider,
                reasoningEffort: representative?.reasoningEffort,
                sandboxPolicy: representative?.sandboxPolicy,
                approvalMode: representative?.approvalMode,
                tokensUsed: tokenCounts.isEmpty ? nil : tokenCounts.reduce(0) {
                    $0 + max(0, $1)
                },
                activeSubtaskCount: members.filter { $0.0.isSubagent }.count,
                subtaskNames: subtaskNames,
                createdAt: representative.map(\.createdAt).flatMap {
                    $0 == .distantPast ? nil : $0
                },
                startedAt: reliableStart,
                lastEventAt: lastEventAt,
                cliVersion: representative?.cliVersion,
                semantic: semantic,
                progressLines: progressLines,
                recentEvents: recentEvents)
        }

        return CodexLocalActivitySnapshot(
            activeSessionIDs: Set(activities.keys),
            lastEventAt: activities.values
                .compactMap(\.lastEventAt).max(),
            sessionActivities: activities)
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
                isDirectory: true)
        } else {
            codexHome = homeDirectory.appendingPathComponent(
                ".codex",
                isDirectory: true)
        }
        return codexHome.appendingPathComponent("state_5.sqlite")
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
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let columns = Self.tableColumns(database: database, table: "threads")
        guard columns.contains("id"),
              columns.contains("rollout_path"),
              columns.contains("updated_at"),
              columns.contains("archived") else { return [] }
        let sourceExpression = columns.contains("source")
            ? "source" : "NULL"
        let createdAtExpression: String
        if columns.contains("created_at_ms") {
            createdAtExpression = columns.contains("created_at")
                ? "COALESCE(created_at_ms, created_at * 1000)"
                : "created_at_ms"
        } else if columns.contains("created_at") {
            createdAtExpression = "created_at * 1000"
        } else {
            createdAtExpression = "NULL"
        }
        let titleExpression = columns.contains("title")
            ? "title" : "NULL"
        let cwdExpression = columns.contains("cwd")
            ? "cwd" : "NULL"
        let modelExpression = columns.contains("model")
            ? "model" : "NULL"
        let reasoningEffortExpression = columns.contains("reasoning_effort")
            ? "reasoning_effort" : "NULL"
        let modelProviderExpression = columns.contains("model_provider")
            ? "model_provider" : "NULL"
        let sandboxPolicyExpression = columns.contains("sandbox_policy")
            ? "sandbox_policy" : "NULL"
        let approvalModeExpression = columns.contains("approval_mode")
            ? "approval_mode" : "NULL"
        let tokensUsedExpression = columns.contains("tokens_used")
            ? "tokens_used" : "NULL"
        let gitBranchExpression = columns.contains("git_branch")
            ? "git_branch" : "NULL"
        let cliVersionExpression = columns.contains("cli_version")
            ? "cli_version" : "NULL"
        let agentNicknameExpression = columns.contains("agent_nickname")
            ? "agent_nickname" : "NULL"
        let threadSourceExpression = columns.contains("thread_source")
            ? "thread_source" : "NULL"
        let query = """
        SELECT id, rollout_path, updated_at, \(sourceExpression),
               \(createdAtExpression), \(titleExpression), \(cwdExpression),
               \(modelExpression), \(reasoningEffortExpression),
               \(modelProviderExpression), \(sandboxPolicyExpression),
               \(approvalModeExpression), \(tokensUsedExpression),
               \(gitBranchExpression), \(cliVersionExpression),
               \(agentNicknameExpression), \(threadSourceExpression)
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
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }

        let cutoff = Int64(now.timeIntervalSince1970 - recentActivityWindow)
        sqlite3_bind_int64(statement, 1, cutoff)
        sqlite3_bind_int(statement, 2, candidateLimit)

        var candidates: [Candidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let pathText = sqlite3_column_text(statement, 1) else {
                continue
            }
            let threadID = String(cString: idText)
            let rolloutPath = String(cString: pathText)
            guard !threadID.isEmpty, !rolloutPath.isEmpty else { continue }
            let source = sqlite3_column_text(statement, 3).map {
                String(cString: $0)
            }
            let createdAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? .distantPast
                : Date(timeIntervalSince1970: TimeInterval(
                    sqlite3_column_int64(statement, 4)) / 1_000)
            let title = sqlite3_column_text(statement, 5).flatMap {
                CodexTaskProgressSanitizer.sanitize(String(cString: $0))
            }
            let projectName = sqlite3_column_text(statement, 6).flatMap {
                Self.safeProjectName(from: String(cString: $0))
            }
            let model = sqlite3_column_text(statement, 7).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let reasoningEffort = sqlite3_column_text(statement, 8).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let modelProvider = sqlite3_column_text(statement, 9).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let sandboxPolicy = sqlite3_column_text(statement, 10).flatMap {
                Self.safePolicyName(from: String(cString: $0))
            }
            let approvalMode = sqlite3_column_text(statement, 11).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let tokensUsed = sqlite3_column_type(statement, 12) == SQLITE_NULL
                ? nil
                : max(0, sqlite3_column_int64(statement, 12))
            let gitBranch = sqlite3_column_text(statement, 13).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let cliVersion = sqlite3_column_text(statement, 14).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let agentNickname = sqlite3_column_text(statement, 15).flatMap {
                CodexTaskMetadataSanitizer.sanitize(String(cString: $0))
            }
            let threadSource = sqlite3_column_text(statement, 16).map {
                String(cString: $0)
            }
            candidates.append(Candidate(
                threadID: threadID,
                parentThreadID: Self.parentThreadID(fromSource: source),
                rolloutURL: URL(fileURLWithPath: rolloutPath),
                createdAt: createdAt,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(
                    sqlite3_column_int64(statement, 2))),
                title: title,
                projectName: projectName,
                gitBranch: gitBranch,
                source: Self.safeTaskSource(
                    source: source,
                    threadSource: threadSource),
                model: model,
                modelProvider: modelProvider,
                reasoningEffort: reasoningEffort,
                sandboxPolicy: sandboxPolicy,
                approvalMode: approvalMode,
                tokensUsed: tokensUsed,
                agentNickname: agentNickname,
                cliVersion: cliVersion))
        }
        return candidates
    }

    private static func safeProjectName(from path: String) -> String? {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return CodexTaskMetadataSanitizer.sanitize(name)
    }

    private static func safePolicyName(from rawValue: String) -> String? {
        if let data = rawValue.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
           let type = object["type"] as? String {
            return CodexTaskMetadataSanitizer.sanitize(type)
        }
        return CodexTaskMetadataSanitizer.sanitize(rawValue)
    }

    private static func safeTaskSource(
        source: String?,
        threadSource: String?
    ) -> String? {
        var parts: [String] = []
        if let source,
           !source.trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("{"),
           let safeSource = CodexTaskMetadataSanitizer.sanitize(source) {
            parts.append(safeSource)
        }
        if let threadSource,
           let safeThreadSource = CodexTaskMetadataSanitizer.sanitize(
                threadSource),
           !parts.contains(safeThreadSource) {
            parts.append(safeThreadSource)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    private static func tableColumns(
        database: OpaquePointer,
        table: String
    ) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\(table));",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let name = sqlite3_column_text(statement, 1) {
            result.insert(String(cString: name))
        }
        return result
    }

    private static func parentThreadID(fromSource source: String?) -> String? {
        guard let source,
              let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let subagent = root["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any],
              let parent = spawn["parent_thread_id"] as? String,
              !parent.isEmpty else { return nil }
        return parent
    }

    private static func rootThreadID(
        for threadID: String,
        parentByThread: [String: String]
    ) -> String {
        var current = threadID
        var visited: Set<String> = [current]
        for _ in 0..<32 {
            guard let parent = parentByThread[current],
                  !parent.isEmpty,
                  visited.insert(parent).inserted else { break }
            current = parent
        }
        return current
    }

    private func updateParserState(
        _ state: inout ParserState,
        for candidate: Candidate,
        now: Date
    ) {
        let rolloutURL = candidate.rolloutURL
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: rolloutURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            // A missing/unreadable file is not evidence of activity.
            state.resetForReplacement(identity: nil)
            return
        }
        let identity = FileIdentity(device: device, inode: inode)
        let wasReplaced = state.identity != identity || fileSize < state.offset
        if wasReplaced {
            state.resetForReplacement(identity: identity)
        }

        var startOffset = state.offset
        var dropsLeadingFragment = false
        let unreadCount = fileSize >= startOffset ? fileSize - startOffset : 0
        if unreadCount > UInt64(maximumRolloutScanBytes) {
            state.resetForReplacement(identity: identity)
            startOffset = fileSize - UInt64(maximumRolloutScanBytes)
            dropsLeadingFragment = startOffset > 0
        }
        guard fileSize > startOffset,
              let file = try? FileHandle(forReadingFrom: rolloutURL) else {
            prune(&state, now: now)
            return
        }
        defer { try? file.close() }

        do {
            try file.seek(toOffset: startOffset)
            var incoming = Data()
            var remaining = Int(fileSize - startOffset)
            while remaining > 0 {
                let count = min(rolloutReadChunkBytes, remaining)
                guard let chunk = try file.read(upToCount: count),
                      !chunk.isEmpty else { break }
                incoming.append(chunk)
                remaining -= chunk.count
            }
            state.offset = fileSize
            if dropsLeadingFragment,
               let newline = incoming.firstIndex(of: 0x0A) {
                incoming.removeSubrange(...newline)
            } else if dropsLeadingFragment {
                incoming.removeAll()
            }
            var combined = state.partialLine
            combined.append(incoming)
            let endsAtBoundary = combined.last == 0x0A
            var lines = combined.split(
                separator: 0x0A,
                omittingEmptySubsequences: true)
            if !endsAtBoundary, let last = lines.popLast() {
                state.partialLine = Data(last)
            } else {
                state.partialLine.removeAll(keepingCapacity: true)
            }
            for line in lines {
                parseLine(
                    Data(line),
                    for: candidate,
                    into: &state,
                    fallbackDate: now)
            }
        } catch {
            state.resetForReplacement(identity: identity)
        }
        prune(&state, now: now)
    }

    private func parseLine(
        _ data: Data,
        for candidate: Candidate,
        into state: inout ParserState,
        fallbackDate: Date
    ) {
        guard let root = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              let rootType = root["type"] as? String else { return }
        let date = recordDate(root["timestamp"]) ?? fallbackDate
        if rootType == "compacted" {
            state.resetContentAfterCompaction(at: date)
            return
        }
        guard let payload = root["payload"] as? [String: Any] else {
            return
        }

        switch rootType {
        case "session_meta":
            if state.rootSessionID == nil,
               payload["id"] as? String == candidate.threadID,
               let rootID = payload["session_id"] as? String,
               !rootID.isEmpty {
                state.rootSessionID = rootID
            }
        case "event_msg":
            parseEventMessage(
                payload,
                candidate: candidate,
                date: date,
                into: &state)
        case "response_item":
            parseResponseItem(payload, date: date, into: &state)
        default:
            break
        }
    }

    private func parseEventMessage(
        _ payload: [String: Any],
        candidate: Candidate,
        date: Date,
        into state: inout ParserState
    ) {
        guard let type = payload["type"] as? String else { return }
        let turnID = (payload["turn_id"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "legacy"
        switch type {
        case "task_started":
            let startedAt = recordDate(payload["started_at"])
                ?? recordDate(payload["timestamp"])
                ?? date
            guard Self.isOwnedTurn(
                turnID: turnID,
                startedAt: startedAt,
                candidate: candidate
            ) else { return }
            if !state.hasObservedOwnedTurn {
                state.hasObservedOwnedTurn = true
                state.activeTurnIDs.removeAll()
                state.startsByTurn.removeAll()
                state.progressLines.removeAll()
                state.recentEvents.removeAll()
                state.inFlightTools.removeAll()
                state.latestSemantic = nil
            }
            state.activeTurnIDs.insert(turnID)
            state.startsByTurn[turnID] = startedAt
            setSemantic(.thinking, date: date, state: &state)
            appendEvent(.taskStarted, at: date, state: &state)
        case "task_complete", "turn_aborted", "task_aborted":
            if turnID == "legacy" {
                state.activeTurnIDs.removeAll()
                state.startsByTurn.removeAll()
            } else {
                state.activeTurnIDs.remove(turnID)
                state.startsByTurn.removeValue(forKey: turnID)
            }
            setSemantic(.finishing, date: date, state: &state)
            appendEvent(.taskFinished, at: date, state: &state)
        case "agent_reasoning":
            setSemantic(.thinking, date: date, state: &state)
        case "agent_message":
            if payload["phase"] as? String == "commentary",
               let message = payload["message"] as? String {
                appendProgress(message, at: date, state: &state)
            }
        case "patch_apply_begin":
            setSemantic(
                .editing,
                category: .fileEdit,
                status: .inProgress,
                date: date,
                state: &state)
            appendEvent(.toolStarted, at: date, state: &state)
        case "patch_apply_end":
            setSemantic(
                .editing,
                category: .fileEdit,
                status: Self.completionStatus(payload),
                date: date,
                state: &state)
            appendEvent(.toolFinished, at: date, state: &state)
        case "mcp_tool_call_begin":
            setSemantic(
                .usingTool,
                category: .mcp,
                status: .inProgress,
                date: date,
                state: &state)
            appendEvent(.toolStarted, at: date, state: &state)
        case "mcp_tool_call_end":
            setSemantic(
                .usingTool,
                category: .mcp,
                status: Self.completionStatus(payload),
                date: date,
                state: &state)
            appendEvent(.toolFinished, at: date, state: &state)
        case "web_search_begin":
            setSemantic(
                .usingTool,
                category: .web,
                status: .inProgress,
                date: date,
                state: &state)
            appendEvent(.toolStarted, at: date, state: &state)
        case "web_search_end":
            setSemantic(
                .usingTool,
                category: .web,
                status: Self.completionStatus(payload),
                date: date,
                state: &state)
            appendEvent(.toolFinished, at: date, state: &state)
        case "subagent_start", "subagent_started":
            setSemantic(
                .delegating,
                category: .subagent,
                status: .inProgress,
                date: date,
                state: &state)
            appendEvent(.subtaskStarted, at: date, state: &state)
        case "subagent_stop", "subagent_stopped":
            setSemantic(
                .delegating,
                category: .subagent,
                status: Self.completionStatus(payload),
                date: date,
                state: &state)
            appendEvent(.subtaskFinished, at: date, state: &state)
        case "context_compacted", "thread_rolled_back":
            state.resetContentAfterCompaction(at: date)
        default:
            break
        }
    }

    private static func isOwnedTurn(
        turnID: String,
        startedAt: Date,
        candidate: Candidate
    ) -> Bool {
        guard candidate.isSubagent else { return true }
        if let turnDate = uuidV7Date(turnID) {
            // Real Codex turn IDs preserve millisecond creation time. Prefer it
            // over `started_at`, which is only second precision and can make an
            // inherited parent turn look as new as the subagent itself.
            let uuidTolerance: TimeInterval = 0.25
            return turnDate.timeIntervalSince(candidate.createdAt)
                >= -uuidTolerance
        }
        let legacyTimestampTolerance: TimeInterval = 1
        return startedAt.timeIntervalSince(candidate.createdAt)
            >= -legacyTimestampTolerance
    }

    private static func uuidV7Date(_ value: String) -> Date? {
        let compact = value.replacingOccurrences(of: "-", with: "")
        guard compact.count >= 12,
              let milliseconds = UInt64(compact.prefix(12), radix: 16) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private func parseResponseItem(
        _ payload: [String: Any],
        date: Date,
        into state: inout ParserState
    ) {
        guard let type = payload["type"] as? String else { return }
        switch type {
        case "function_call", "custom_tool_call", "tool_search_call":
            let category = Self.toolCategory(
                from: payload["name"] as? String)
            let callID = Self.callID(payload)
            if let callID { state.inFlightTools[callID] = category }
            let phase: CodexSafeActivityPhase = category == .fileEdit
                ? .editing
                : category == .subagent ? .delegating : .usingTool
            setSemantic(
                phase,
                category: category,
                status: .inProgress,
                date: date,
                state: &state)
            appendEvent(
                category == .subagent ? .subtaskStarted : .toolStarted,
                at: date,
                state: &state)
        case "function_call_output", "custom_tool_call_output",
             "tool_search_call_output":
            let callID = Self.callID(payload)
            let category = callID.flatMap {
                state.inFlightTools.removeValue(forKey: $0)
            } ?? .other
            let phase: CodexSafeActivityPhase = category == .fileEdit
                ? .editing
                : category == .subagent ? .delegating : .usingTool
            setSemantic(
                phase,
                category: category,
                status: Self.completionStatus(payload),
                date: date,
                state: &state)
            appendEvent(
                category == .subagent ? .subtaskFinished : .toolFinished,
                at: date,
                state: &state)
        case "message":
            guard payload["role"] as? String == "assistant",
                  payload["phase"] as? String == "commentary",
                  let content = payload["content"] as? [[String: Any]]
            else { return }
            for item in content where item["type"] as? String == "output_text" {
                if let text = item["text"] as? String {
                    appendProgress(text, at: date, state: &state)
                }
            }
        case "compacted":
            state.resetContentAfterCompaction(at: date)
        default:
            break
        }
    }

    private func setSemantic(
        _ phase: CodexSafeActivityPhase,
        category: CodexSafeToolCategory? = nil,
        status: CodexSafeToolStatus? = nil,
        date: Date,
        state: inout ParserState
    ) {
        state.latestSemantic = CodexSafeActivitySemantic(
            phase: phase,
            toolCategory: category,
            toolStatus: status,
            at: date)
    }

    private func appendEvent(
        _ kind: CodexSafeActivityEventKind,
        at date: Date,
        state: inout ParserState
    ) {
        state.recentEvents.append(CodexSafeActivityEvent(kind: kind, at: date))
        if state.recentEvents.count > 32 {
            state.recentEvents.removeFirst(state.recentEvents.count - 32)
        }
    }

    private func appendProgress(
        _ rawText: String,
        at date: Date,
        state: inout ParserState
    ) {
        guard let text = CodexTaskProgressSanitizer.sanitize(rawText) else {
            return
        }
        state.progressLines.removeAll { $0.text == text }
        state.progressLines.append(CodexSafeProgressLine(text: text, at: date))
        if state.progressLines.count > 8 {
            state.progressLines.removeFirst(state.progressLines.count - 8)
        }
    }

    private func prune(_ state: inout ParserState, now: Date) {
        let cutoff = now.addingTimeInterval(-10 * 60)
        state.progressLines.removeAll { $0.at < cutoff || $0.at > now }
        state.recentEvents.removeAll { $0.at < cutoff || $0.at > now }
        if let semantic = state.latestSemantic,
           semantic.at < cutoff || semantic.at > now {
            state.latestSemantic = nil
        }
    }

    private static func latestUniqueProgressLines(
        _ lines: [CodexSafeProgressLine],
        now: Date,
        cutoff: Date
    ) -> [CodexSafeProgressLine] {
        var seen = Set<String>()
        return Array(lines
            .filter { $0.at >= cutoff && $0.at <= now }
            .sorted { $0.at > $1.at }
            .filter { seen.insert($0.text).inserted }
            .prefix(2)
            .reversed())
    }

    private static func callID(_ payload: [String: Any]) -> String? {
        for key in ["call_id", "id"] {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func toolCategory(from rawName: String?)
        -> CodexSafeToolCategory
    {
        let name = rawName?.lowercased() ?? ""
        if name == "apply_patch" || name.contains("file_edit") {
            return .fileEdit
        }
        if name.contains("exec_command") || name.contains("write_stdin")
            || name.contains("shell") || name.contains("terminal") {
            return .shell
        }
        if name.contains("web") || name.contains("search_query")
            || name.contains("browser") {
            return .web
        }
        if name.hasPrefix("mcp__") || name.contains("connector")
            || name.contains("codex_apps") {
            return .mcp
        }
        if name.contains("spawn_agent") || name.contains("subagent")
            || name.contains("followup_task")
            || name.contains("send_message")
            || name.contains("wait_agent") {
            return .subagent
        }
        return .other
    }

    private static func completionStatus(_ payload: [String: Any])
        -> CodexSafeToolStatus
    {
        if let success = payload["success"] as? Bool {
            return success ? .completed : .failed
        }
        if let isError = payload["is_error"] as? Bool {
            return isError ? .failed : .completed
        }
        if let status = payload["status"] as? String {
            switch status.lowercased() {
            case "completed", "complete", "success", "succeeded":
                return .completed
            case "failed", "error": return .failed
            case "declined", "denied", "cancelled", "canceled":
                return .declined
            case "in_progress", "running", "started": return .inProgress
            default: return .unknown
            }
        }
        return .completed
    }

    private func recordDate(_ value: Any?) -> Date? {
        if let seconds = value as? NSNumber {
            let raw = seconds.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000
                ? raw / 1_000 : raw)
        }
        guard let string = value as? String else { return nil }
        if let raw = Double(string) {
            return Date(timeIntervalSince1970: raw > 10_000_000_000
                ? raw / 1_000 : raw)
        }
        return fractionalDateFormatter.date(from: string)
            ?? internetDateFormatter.date(from: string)
    }
}

enum CodexTaskProgressSanitizer {
    private static let rejectedPatterns = [
        #"(?i)\bbearer\s+[a-z0-9._~+/=-]+"#,
        #"(?i)\bsk-[a-z0-9_-]{8,}"#,
        #"(?i)\b(api[\s_-]?key|access[\s_-]?token|secret|password)\s*[:=]"#,
        #"(?i)\btoken\s*[:=]\s*[a-z0-9._~+/=-]{6,}"#,
        #"(?i)\b[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+\b"#,
        #"(?i)https?://\S+\?\S*"#,
        #"(?:^|\s)~\/"#,
        #"(?<![A-Za-z0-9:/])\/(?!\/)(?:[^\s/]+\/)*[^\s/]+"#,
        #"(?i)(?<![a-z0-9])[a-z]:\\\S+"#,
        #"(?i)(?:^|\s)(?:\.\/|\.\.\/)?(?:workspace|workspaces)\/"#,
        #"(?i)[?&](?:token|key|secret|signature|credential)="#,
        #"(?i)\b(?:session|turn|agent)[-_ ]?id\s*[:=]"#,
        #"(?i)\b(?:session|turn|agent)[-_][a-z0-9_-]{8,}\b"#,
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}\b"#,
        #"(?i)\b[0-9a-hjkmnp-tv-z]{26}\b"#,
        #"(?i)\b(?:ghp_|github_pat_|xox[baprs]-|akia)[a-z0-9_-]{8,}\b"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#,
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#,
    ]

    static func sanitize(_ rawText: String) -> String? {
        var text = rawText.precomposedStringWithCanonicalMapping
        text = replacing(
            #"\x{1B}\[[0-?]*[ -/]*[@-~]"#,
            in: text,
            with: "")
        let scalars = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value < 0x20 { return value == 0x09 || value == 0x0A || value == 0x0D }
            if (0x7F...0x9F).contains(value) { return false }
            if value == 0x061C || value == 0x200E || value == 0x200F
                || (0x202A...0x202E).contains(value)
                || (0x2066...0x2069).contains(value) { return false }
            if (0xE000...0xF8FF).contains(value)
                || (0xF0000...0xFFFFD).contains(value)
                || (0x100000...0x10FFFD).contains(value) { return false }
            return true
        }
        text = String(String.UnicodeScalarView(scalars))
        text = replacing(#"\s+"#, in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for pattern in rejectedPatterns where matches(pattern, in: text) {
            return nil
        }

        text = String(text.prefix(120))
        while text.utf8.count > 512, !text.isEmpty {
            text.removeLast()
        }
        return text.isEmpty ? nil : text
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern)
        else { return true }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func replacing(
        _ pattern: String,
        in text: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern)
        else { return "" }
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement)
    }
}

enum CodexTaskMetadataSanitizer {
    static func sanitize(_ rawValue: String) -> String? {
        guard let value = CodexTaskProgressSanitizer.sanitize(rawValue) else {
            return nil
        }
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "._:+-/()[] ".unicodeScalars.contains(scalar)
              }) else { return nil }
        return String(value.prefix(64))
    }
}
