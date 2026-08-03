import Foundation

enum CodexHookEventName: String, Codable, CaseIterable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
    case sessionEnd = "SessionEnd"
}

struct CodexHookEvent: Equatable {
    let name: CodexHookEventName
    let sessionID: String
    let turnID: String?
    let agentID: String?
    let date: Date

    init(
        name: CodexHookEventName,
        sessionID: String,
        turnID: String?,
        agentID: String?,
        date: Date = Date()
    ) {
        self.name = name
        self.sessionID = sessionID
        self.turnID = turnID
        self.agentID = agentID
        self.date = date
    }

    init?(notificationUserInfo: [AnyHashable: Any], date: Date = Date()) {
        guard let rawName = notificationUserInfo["hook_event_name"] as? String,
              let name = CodexHookEventName(rawValue: rawName),
              let sessionID = notificationUserInfo["session_id"] as? String,
              !sessionID.isEmpty else {
            return nil
        }

        self.init(
            name: name,
            sessionID: sessionID,
            turnID: notificationUserInfo["turn_id"] as? String,
            agentID: notificationUserInfo["agent_id"] as? String,
            date: date
        )
    }
}

/// A deliberately content-free projection of Codex lifecycle hooks. These
/// values may cross the LAN dashboard boundary; hook identifiers and payload
/// text must never be added here.
enum CodexSafeActivityEventKind: String, Codable, CaseIterable, Sendable {
    case taskStarted
    case toolStarted
    case permissionRequested
    case toolFinished
    case subtaskStarted
    case subtaskFinished
    case taskFinished
    case sessionEnded
}

struct CodexSafeActivityEvent: Equatable, Sendable {
    let kind: CodexSafeActivityEventKind
    let at: Date
}

enum CodexSafeActivityPhase: String, Codable, CaseIterable, Sendable {
    case thinking
    case usingTool
    case waitingForPermission
    case editing
    case testing
    case delegating
    case finishing
    case unknown
}

enum CodexSafeToolCategory: String, Codable, CaseIterable, Sendable {
    case shell
    case fileEdit
    case web
    case mcp
    case subagent
    case other
}

enum CodexSafeToolStatus: String, Codable, CaseIterable, Sendable {
    case inProgress
    case completed
    case failed
    case declined
    case unknown
}

struct CodexSafeActivitySemantic: Equatable, Sendable {
    let phase: CodexSafeActivityPhase
    let toolCategory: CodexSafeToolCategory?
    let toolStatus: CodexSafeToolStatus?
    let at: Date
}

struct CodexSafeProgressLine: Equatable, Sendable {
    let text: String
    let at: Date
}

struct CodexActivityTracker {
    struct TurnKey: Hashable {
        let sessionID: String
        let turnID: String
    }

    private struct TurnState {
        var activeSubagents: Set<String> = []
        var rootStopped = false
        var startedAt: Date?
        var lastEventAt: Date
    }

    private(set) var activeTurnCount = 0
    private(set) var lastEventAt: Date?
    private(set) var latestSemantic: CodexSafeActivitySemantic?
    private var latestSemanticSessionID: String?
    private var turns: [TurnKey: TurnState] = [:]
    private var safeRecentEvents: [CodexSafeActivityEvent] = []

    var isWorking: Bool {
        !turns.isEmpty
    }

    var activeSessionIDs: Set<String> {
        Set(turns.keys.map(\.sessionID))
    }

    /// Returns a start time only when every active session was observed from a
    /// real UserPromptSubmit hook. Local-detector-only sessions and partial
    /// hook streams intentionally make this nil rather than manufacturing a
    /// start time from database metadata.
    func reliableOldestStartedAt(
        for activeSessionIDs: Set<String>
    ) -> Date? {
        guard !activeSessionIDs.isEmpty else { return nil }
        var starts: [Date] = []
        for sessionID in activeSessionIDs {
            let sessionTurns = turns.filter {
                $0.key.sessionID == sessionID
            }.map(\.value)
            guard !sessionTurns.isEmpty,
                  sessionTurns.allSatisfy({ $0.startedAt != nil }) else {
                return nil
            }
            starts.append(contentsOf: sessionTurns.compactMap(\.startedAt))
        }
        return starts.min()
    }

    func recentEvents(
        now: Date,
        maximumAge: TimeInterval,
        maximumCount: Int
    ) -> [CodexSafeActivityEvent] {
        guard maximumCount > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-maximumAge)
        return Array(
            safeRecentEvents.lazy
                .filter { $0.at >= cutoff && $0.at <= now }
                .suffix(maximumCount)
        )
    }

    func latestSemantic(
        for activeSessionIDs: Set<String>
    ) -> CodexSafeActivitySemantic? {
        guard let latestSemanticSessionID,
              activeSessionIDs.contains(latestSemanticSessionID) else {
            return nil
        }
        return latestSemantic
    }

    func lastEventAt(for sessionID: String) -> Date? {
        turns.lazy
            .filter { $0.key.sessionID == sessionID }
            .map(\.value.lastEventAt)
            .max()
    }

    func activeSubagentCount(for sessionID: String) -> Int {
        Set(turns.lazy
            .filter { $0.key.sessionID == sessionID }
            .flatMap(\.value.activeSubagents))
            .count
    }

    mutating func receive(_ event: CodexHookEvent) {
        lastEventAt = event.date
        appendSafeEvent(for: event)
        updateSafeSemantic(for: event)
        latestSemanticSessionID = event.sessionID

        if event.name == .sessionEnd {
            turns = turns.filter { $0.key.sessionID != event.sessionID }
            activeTurnCount = turns.count
            return
        }

        guard let turnID = event.turnID, !turnID.isEmpty else {
            return
        }

        let key = TurnKey(sessionID: event.sessionID, turnID: turnID)
        if turns[key] == nil
            && (event.name == .subagentStop || event.name == .stop) {
            return
        }
        var state = turns[key] ?? TurnState(lastEventAt: event.date)
        state.lastEventAt = event.date

        switch event.name {
        case .userPromptSubmit:
            state.rootStopped = false
            if state.startedAt == nil || event.date < state.startedAt! {
                state.startedAt = event.date
            }

        case .preToolUse, .permissionRequest, .postToolUse:
            if let agentID = event.agentID, !agentID.isEmpty {
                state.activeSubagents.insert(agentID)
            } else {
                state.rootStopped = false
            }

        case .subagentStart:
            if let agentID = event.agentID, !agentID.isEmpty {
                state.activeSubagents.insert(agentID)
            }

        case .subagentStop:
            if let agentID = event.agentID, !agentID.isEmpty {
                state.activeSubagents.remove(agentID)
            }

        case .stop:
            if let agentID = event.agentID, !agentID.isEmpty {
                state.activeSubagents.remove(agentID)
            } else {
                state.rootStopped = true
            }

        case .sessionEnd:
            break
        }

        if state.rootStopped && state.activeSubagents.isEmpty {
            turns.removeValue(forKey: key)
        } else {
            turns[key] = state
        }
        activeTurnCount = turns.count
    }

    mutating func reset() {
        turns.removeAll()
        safeRecentEvents.removeAll()
        activeTurnCount = 0
        lastEventAt = nil
        latestSemantic = nil
        latestSemanticSessionID = nil
    }

    private mutating func appendSafeEvent(for event: CodexHookEvent) {
        let kind: CodexSafeActivityEventKind
        switch event.name {
        case .userPromptSubmit:
            kind = .taskStarted
        case .preToolUse:
            kind = .toolStarted
        case .permissionRequest:
            kind = .permissionRequested
        case .postToolUse:
            kind = .toolFinished
        case .subagentStart:
            kind = .subtaskStarted
        case .subagentStop:
            kind = .subtaskFinished
        case .stop:
            kind = event.agentID == nil
                ? .taskFinished
                : .subtaskFinished
        case .sessionEnd:
            kind = .sessionEnded
        }
        safeRecentEvents.append(
            CodexSafeActivityEvent(kind: kind, at: event.date))
        // Keep a small in-memory ceiling even if no mobile viewer is active.
        if safeRecentEvents.count > 32 {
            safeRecentEvents.removeFirst(safeRecentEvents.count - 32)
        }
    }

    private mutating func updateSafeSemantic(for event: CodexHookEvent) {
        let semantic: CodexSafeActivitySemantic
        switch event.name {
        case .userPromptSubmit:
            semantic = CodexSafeActivitySemantic(
                phase: .thinking,
                toolCategory: nil,
                toolStatus: nil,
                at: event.date)
        case .preToolUse:
            semantic = CodexSafeActivitySemantic(
                phase: .usingTool,
                toolCategory: .other,
                toolStatus: .inProgress,
                at: event.date)
        case .permissionRequest:
            semantic = CodexSafeActivitySemantic(
                phase: .waitingForPermission,
                toolCategory: nil,
                toolStatus: nil,
                at: event.date)
        case .postToolUse:
            semantic = CodexSafeActivitySemantic(
                phase: .usingTool,
                toolCategory: .other,
                toolStatus: .completed,
                at: event.date)
        case .subagentStart:
            semantic = CodexSafeActivitySemantic(
                phase: .delegating,
                toolCategory: .subagent,
                toolStatus: .inProgress,
                at: event.date)
        case .subagentStop:
            semantic = CodexSafeActivitySemantic(
                phase: .delegating,
                toolCategory: .subagent,
                toolStatus: .completed,
                at: event.date)
        case .stop, .sessionEnd:
            semantic = CodexSafeActivitySemantic(
                phase: .finishing,
                toolCategory: nil,
                toolStatus: nil,
                at: event.date)
        }
        latestSemantic = semantic
    }
}
