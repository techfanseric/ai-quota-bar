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

/// Detects active Kimi tasks from both local runtimes:
///
/// - **Kimi desktop agent**: `kimi-agent/conversation-context-usage.json`
///   carries one entry per conversation with an `updatedAt` that refreshes
///   while the agent consumes context. Fresh conversations count as working.
/// - **Kimi CLI**: `~/.kimi-code/sessions/wd_*/session_*/agents/*/wire.jsonl`
///   turn lifecycle records. A wire counts while its turn is open
///   (`turn.prompt` without `turn.ended`) **and** the file was touched inside
///   the freshness window; the mtime requirement replaces the old
///   running-process gate, which no longer matched once the desktop runtime
///   (cwd `/`) took over and `session_index.jsonl` stopped being maintained.
///
/// Message bodies, model output, and command output are never retained.
final class KimiLocalActivityDetector: KimiLocalActivityProviding,
    @unchecked Sendable
{
    static let defaultFreshnessWindow: TimeInterval = 120

    let codeHomeURL: URL
    let agentDataURL: URL
    let freshnessWindow: TimeInterval

    private struct WireState {
        var size: UInt64 = 0
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
        freshnessWindow: TimeInterval = KimiLocalActivityDetector
            .defaultFreshnessWindow
    ) {
        self.codeHomeURL = codeHomeURL
        self.agentDataURL = agentDataURL
        self.freshnessWindow = freshnessWindow
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

    func snapshot() async -> KimiLocalActivitySnapshot {
        await Task.detached(priority: .utility) { [self] in
            detectSnapshot()
        }.value
    }

    func detectSnapshot(now: Date = Date()) -> KimiLocalActivitySnapshot {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = now.addingTimeInterval(-freshnessWindow)
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

        for conversation in desktopConversationActivity() {
            guard conversation.updatedAt >= cutoff,
                  conversation.updatedAt <= now else {
                continue
            }
            record("kimi:desktop:\(conversation.key)", conversation.updatedAt)
        }

        for wireURL in wireURLs() {
            let state = readWireState(at: wireURL)
            guard state.isActive else { continue }
            // A wire whose turn is open but that has gone quiet for the whole
            // freshness window was most likely killed mid-turn.
            guard let touchedAt = fileModificationDate(at: wireURL),
                  touchedAt >= cutoff, touchedAt <= now else {
                continue
            }
            let sessionID = wireURL
                .deletingLastPathComponent()  // …/agents/<agent>
                .deletingLastPathComponent()  // …/agents
                .deletingLastPathComponent()  // …/session_<uuid>
                .lastPathComponent
            record("kimi:cli:\(sessionID)", touchedAt)
        }
        wireStates = wireStates.filter {
            activeSessionIDs.contains("kimi:cli:\($0.key)")
        }
        return KimiLocalActivitySnapshot(
            activeSessionIDs: activeSessionIDs,
            lastEventAt: lastEventAt,
            lastEventBySession: lastEventBySession)
    }

    // MARK: - Desktop agent conversations

    private func desktopConversationActivity()
        -> [(key: String, updatedAt: Date)] {
        let contextUsageURL = agentDataURL
            .appendingPathComponent("conversation-context-usage.json")
        guard let data = try? Data(contentsOf: contextUsageURL),
              let entries = try? JSONSerialization.jsonObject(
                with: data) as? [String: Any] else {
            return []
        }
        var result: [(key: String, updatedAt: Date)] = []
        for (conversationKey, payload) in entries {
            guard let details = payload as? [String: Any],
                  let updatedAtText = details["updatedAt"] as? String,
                  let updatedAt = Self.parseDate(updatedAtText) else {
                continue
            }
            let identifier = conversationKey.split(separator: ":").last
                .map(String.init) ?? conversationKey
            result.append((identifier, updatedAt))
        }
        return result
    }

    private static func parseDate(_ text: String) -> Date? {
        fractionalDateFormatter.date(from: text)
            ?? internetDateFormatter.date(from: text)
    }

    // MARK: - CLI wire transcripts

    private func wireURLs() -> [URL] {
        let sessionsRoot = codeHomeURL
            .appendingPathComponent("sessions", isDirectory: true)
        guard let workspaces = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        var urls: [URL] = []
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
            for session in sessions
            where session.lastPathComponent.hasPrefix("session_")
                && (try? session.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true {
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
                        urls.append(wireURL)
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

        guard let data = try? Data(contentsOf: url) else {
            let empty = WireState(size: size)
            wireStates[url.path] = empty
            return empty
        }

        var state = WireState(size: size)
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
        wireStates[url.path] = state
        return state
    }

    private func fileModificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}
