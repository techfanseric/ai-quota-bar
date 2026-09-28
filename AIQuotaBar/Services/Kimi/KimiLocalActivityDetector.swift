import Foundation

struct KimiLocalActivitySnapshot: Equatable, Sendable {
    var activeSessionIDs: Set<String>
    var lastEventAt: Date?
    var lastEventBySession: [String: Date]

    init(
        activeSessionIDs: Set<String>,
        lastEventAt: Date?,
        lastEventBySession: [String: Date] = [:]
    ) {
        self.activeSessionIDs = activeSessionIDs
        self.lastEventAt = lastEventAt
        self.lastEventBySession = lastEventBySession
    }

    static let empty = KimiLocalActivitySnapshot(
        activeSessionIDs: [],
        lastEventAt: nil)
}

protocol KimiLocalActivityProviding: Sendable {
    func snapshot() async -> KimiLocalActivitySnapshot
}

/// Detects active Kimi tasks from all three local runtimes:
///
/// - **Kimi desktop agent**: `kimi-agent/conversation-statuses.json` is the
///   authoritative per-conversation lifecycle ledger — a `running` entry
///   starts and ends with the actual turn, so detection no longer waits out
///   the freshness window after completion. `conversation-context-usage.json`
///   `updatedAt` acts as the crash guard (a `running` status whose
///   `updatedAt` went quiet past the silence window means the runtime died
///   mid-turn) and as the fallback signal when the status ledger is missing
///   or carries an unknown value (schema drift).
/// - **Kimi CLI**: `~/.kimi-code/sessions/wd_*/session_*/agents/*/wire.jsonl`
///   turn lifecycle records. A wire counts while its turn is open
///   (`turn.prompt` without `turn.ended`) **and** the file was touched inside
///   the silence window; the mtime requirement replaces the old
///   running-process gate, which no longer matched once the desktop runtime
///   (cwd `/`) took over and `session_index.jsonl` stopped being maintained.
/// - **Kimi Work (daimon) desktop runtime**: the desktop app's agent sessions
///   live under the managed runtime home
///   (`kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions`)
///   with `conv-*` / `ctitle-*` session directories instead of `session_*`.
///   Same wire lifecycle, reported with a `kimi:work:` prefix.
///
/// Message bodies, model output, and command output are never retained.
final class KimiLocalActivityDetector: KimiLocalActivityProviding,
    @unchecked Sendable
{
    static let defaultFreshnessWindow: TimeInterval = 120

    /// How long an open turn (CLI/Work wire) or a `running` desktop status
    /// may go without any write before the runtime is assumed killed
    /// mid-turn. Turn lifecycle records still drive start/end; this is only
    /// the crash guard, so it is deliberately longer than the freshness
    /// window — a quiet-but-alive turn (long tool call, waiting on the model)
    /// must not flap out of the active set.
    static let defaultOpenTurnSilenceWindow: TimeInterval = 10 * 60

    let codeHomeURL: URL
    let agentDataURL: URL
    let workSessionsRootURL: URL
    let freshnessWindow: TimeInterval
    let openTurnSilenceWindow: TimeInterval

    private struct WireState {
        var size: UInt64 = 0
        /// Bytes consumed through the last complete newline; the next poll
        /// resumes turn-lifecycle parsing from here instead of re-reading
        /// the whole transcript.
        var parsedOffset: UInt64 = 0
        var isActive = false
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()

    private static let internetDateFormatter = ISO8601DateFormatter()

    private let lock = NSLock()
    private var wireStates: [String: WireState] = [:]

    init(
        codeHomeURL: URL = KimiLocalActivityDetector.defaultCodeHomeURL(),
        agentDataURL: URL = KimiLocalActivityDetector.defaultAgentDataURL(),
        workSessionsRootURL: URL = KimiLocalActivityDetector
            .defaultWorkSessionsRootURL(),
        freshnessWindow: TimeInterval = KimiLocalActivityDetector
            .defaultFreshnessWindow,
        openTurnSilenceWindow: TimeInterval = KimiLocalActivityDetector
            .defaultOpenTurnSilenceWindow
    ) {
        self.codeHomeURL = codeHomeURL
        self.agentDataURL = agentDataURL
        self.workSessionsRootURL = workSessionsRootURL
        self.freshnessWindow = freshnessWindow
        self.openTurnSilenceWindow = openTurnSilenceWindow
    }

    static func defaultCodeHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["KIMI_CODE_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    static func defaultAgentDataURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(
                "Library/Application Support/kimi-desktop/kimi-agent",
                isDirectory: true)
    }

    /// Sessions root of the Kimi Work (daimon) managed runtime — the desktop
    /// app's own agent home, distinct from the user-facing `~/.kimi-code`.
    static func defaultWorkSessionsRootURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(
                "Library/Application Support/kimi-desktop/daimon-share"
                    + "/daimon/runtime/kimi-code/home/sessions",
                isDirectory: true)
    }

    func snapshot() async -> KimiLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot()
        }.value
    }

    func detectSnapshot(now: Date = Date()) -> KimiLocalActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = now.addingTimeInterval(-freshnessWindow)
        let silenceCutoff = now.addingTimeInterval(-openTurnSilenceWindow)
        var activeSessionIDs = Set<String>()
        var lastEventBySession: [String: Date] = [:]
        var lastEventAt: Date?

        func record(_ prefixedID: String, _ activityAt: Date) {
            activeSessionIDs.insert(prefixedID)
            let existing = lastEventBySession[prefixedID] ?? .distantPast
            lastEventBySession[prefixedID] = max(existing, activityAt)
            if lastEventAt == nil || activityAt > lastEventAt! {
                lastEventAt = activityAt
            }
        }

        for conversation in desktopConversationActivity(
            now: now,
            cutoff: cutoff,
            silenceCutoff: silenceCutoff
        ) {
            record("kimi:desktop:\(conversation.key)", conversation.updatedAt)
        }

        let currentWireURLs = wireURLs()
        for wire in currentWireURLs {
            let state = readWireState(at: wire.url)
            guard state.isActive else { continue }
            // A wire whose turn is open but that has gone quiet past the
            // silence window was most likely killed mid-turn.
            guard let touchedAt = fileModificationDate(at: wire.url),
                  touchedAt >= silenceCutoff, touchedAt <= now else {
                continue
            }
            let sessionID = wire.url
                .deletingLastPathComponent()  // …/agents/<agent>
                .deletingLastPathComponent()  // …/agents
                .deletingLastPathComponent()  // …/<session dir>
                .lastPathComponent
            record("\(wire.origin.sessionPrefix)\(sessionID)", touchedAt)
        }
        // Keep parse offsets for every wire still on disk. Pruning down to
        // active sessions instead would drop the offsets of idle wires and
        // force a full-history re-parse on every poll — exactly the state an
        // idle machine sits in, where re-parsing hundreds of transcripts
        // pegged a core at 100%.
        let currentWirePaths = Set(currentWireURLs.map(\.url.path))
        wireStates = wireStates.filter {
            currentWirePaths.contains($0.key)
        }
        return KimiLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt,
            lastEventBySession: lastEventBySession)
    }

    // MARK: - Desktop agent conversations

    /// Status values observed in `conversation-statuses.json` that mean the
    /// conversation's turn is over (verified live: `running` while a turn
    /// executes, `completed` afterwards). Anything in this set wins over
    /// `updatedAt` freshness, so a completed turn drops out of the active set
    /// on the next poll instead of lingering for the whole window.
    private static let terminalDesktopStatuses: Set<String> = [
        "completed", "stopped", "error", "failed",
        "cancelled", "canceled", "interrupted", "aborted",
    ]
    /// Explicit in-progress values. Unlisted values fall back to `updatedAt`
    /// freshness so an unfamiliar new status never reads as "definitely
    /// idle" nor as an unconditional "active".
    private static let activeDesktopStatuses: Set<String> = [
        "running", "generating", "streaming", "pending", "queued",
    ]

    private func desktopConversationActivity(
        now: Date,
        cutoff: Date,
        silenceCutoff: Date
    ) -> [(key: String, updatedAt: Date)] {
        let contextUsageURL = agentDataURL
            .appendingPathComponent("conversation-context-usage.json")
        guard let data = try? Data(contentsOf: contextUsageURL),
              let entries = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any] else {
            return []
        }
        let statuses = desktopConversationStatuses()
        var result: [(key: String, updatedAt: Date)] = []
        for (conversationKey, payload) in entries {
            guard let details = payload as? [String: Any],
                  let updatedAtText = details["updatedAt"] as? String,
                  let updatedAt = Self.parseDate(updatedAtText),
                  updatedAt <= now else {
                continue
            }
            if let status = statuses?[conversationKey]?
                .lowercased() {
                if Self.terminalDesktopStatuses.contains(status) {
                    // Authoritative end signal: the turn is over regardless
                    // of how fresh the last context-usage write was.
                    continue
                }
                if Self.activeDesktopStatuses.contains(status) {
                    // Crash guard: a `running` status whose context-usage
                    // heartbeat stopped means the runtime died mid-turn.
                    guard updatedAt >= silenceCutoff else { continue }
                } else {
                    // Unknown status (schema drift): freshness fallback.
                    guard updatedAt >= cutoff else { continue }
                }
            } else {
                // No status ledger, or this conversation predates it:
                // freshness-only behavior.
                guard updatedAt >= cutoff else { continue }
            }
            let identifier = conversationKey.split(separator: ":").last
                .map(String.init) ?? conversationKey
            result.append((identifier, updatedAt))
        }
        return result
    }

    /// Reads `conversation-statuses.json`; nil when the file is missing or
    /// unreadable, which callers treat as "no ledger available" rather than
    /// "every conversation idle".
    private func desktopConversationStatuses() -> [String: String]? {
        let statusesURL = agentDataURL
            .appendingPathComponent("conversation-statuses.json")
        guard let data = try? Data(contentsOf: statusesURL),
              let entries = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any] else {
            return nil
        }
        var statuses: [String: String] = [:]
        for (key, value) in entries {
            if let status = value as? String {
                statuses[key] = status
            }
        }
        return statuses
    }

    private static func parseDate(_ text: String) -> Date? {
        fractionalDateFormatter.date(from: text)
            ?? internetDateFormatter.date(from: text)
    }

    // MARK: - CLI / Kimi Work wire transcripts

    /// Which runtime a wire transcript belongs to; determines the session-ID
    /// prefix the coordinator uses for labeling.
    enum WireOrigin: Sendable {
        case cli
        case work

        var sessionPrefix: String {
            switch self {
            case .cli: return "kimi:cli:"
            case .work: return "kimi:work:"
            }
        }
    }

    private func wireURLs() -> [(url: URL, origin: WireOrigin)] {
        let cliRoot = codeHomeURL
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
        var roots: [(sessionsRoot: URL, origin: WireOrigin)] = [
            (cliRoot, .cli),
        ]
        // Defensive: a custom KIMI_CODE_HOME pointed at the managed runtime
        // home would otherwise double-count every wire.
        let workRoot = workSessionsRootURL.standardizedFileURL
        if workRoot != cliRoot {
            roots.append((workRoot, .work))
        }
        var urls: [(url: URL, origin: WireOrigin)] = []
        for root in roots {
            urls.append(contentsOf: wireURLs(
                inSessionsRoot: root.sessionsRoot,
                origin: root.origin))
        }
        return urls
    }

    private func wireURLs(
        inSessionsRoot sessionsRoot: URL,
        origin: WireOrigin
    ) -> [(url: URL, origin: WireOrigin)] {
        guard let workspaces = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var urls: [(url: URL, origin: WireOrigin)] = []
        for workspace in workspaces
        where (try? workspace.resourceValues(forKeys: [.isDirectoryKey]))?
            .isDirectory == true {
            guard let sessions = try? FileManager.default
                .contentsOfDirectory(
                    at: workspace,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else {
                continue
            }
            for session in sessions {
                // The CLI names session directories `session_*`; the Kimi
                // Work runtime uses `conv-*` / `ctitle-*`. Instead of
                // matching names, accept any directory that actually carries
                // an agents tree.
                guard (try? session.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true else {
                    continue
                }
                let agentsURL = session
                    .appendingPathComponent("agents", isDirectory: true)
                guard let agents = try? FileManager.default
                    .contentsOfDirectory(
                        at: agentsURL,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]) else {
                    continue
                }
                for agent in agents {
                    let wireURL = agent
                        .appendingPathComponent("wire.jsonl", isDirectory: false)
                    if FileManager.default.fileExists(atPath: wireURL.path) {
                        urls.append((wireURL, origin))
                    }
                }
            }
        }
        return urls
    }

    private func readWireState(at url: URL) -> WireState {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if let cached = wireStates[url.path], cached.size == size {
            return cached
        }

        // Incremental parse: resume from the last consumed newline so a
        // growing wire is parsed only for the appended bytes. A shrunk file
        // (truncation) falls back to a full re-read.
        var state = WireState(size: size)
        var offset: UInt64 = 0
        if let cached = wireStates[url.path],
           cached.parsedOffset > 0,
           size >= cached.parsedOffset {
            state = cached
            state.size = size
            offset = cached.parsedOffset
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            wireStates[url.path] = state
            return state
        }
        defer { try? handle.close() }
        if offset > 0 {
            try? handle.seek(toOffset: offset)
        }
        guard let data = try? handle.readToEnd() else {
            wireStates[url.path] = state
            return state
        }

        // The trailing partial line (a record whose newline has not been
        // appended yet) is parsed now but not consumed; it is parsed again
        // once complete, which is harmless because turn lifecycle records
        // only set a boolean.
        for line in data.split(separator: 0x0A) {
            guard let record = try? JSONSerialization.jsonObject(
                with: Data(line)) as? [String: Any],
                  let type = record["type"] as? String else {
                continue
            }
            switch type {
            case "turn.prompt":
                state.isActive = true
            case "turn.ended":
                state.isActive = false
            default:
                break
            }
        }
        if let lastNewline = data.lastIndex(of: 0x0A) {
            state.parsedOffset = offset + UInt64(data[...lastNewline].count)
        }
        wireStates[url.path] = state
        return state
    }

    private func fileModificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}
