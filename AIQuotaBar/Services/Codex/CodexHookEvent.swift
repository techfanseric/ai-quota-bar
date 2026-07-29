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

struct CodexActivityTracker {
    struct TurnKey: Hashable {
        let sessionID: String
        let turnID: String
    }

    private struct TurnState {
        var activeSubagents: Set<String> = []
        var rootStopped = false
        var lastEventAt: Date
    }

    private(set) var activeTurnCount = 0
    private(set) var lastEventAt: Date?
    private var turns: [TurnKey: TurnState] = [:]

    var isWorking: Bool {
        !turns.isEmpty
    }

    var activeSessionIDs: Set<String> {
        Set(turns.keys.map(\.sessionID))
    }

    mutating func receive(_ event: CodexHookEvent) {
        lastEventAt = event.date

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
        activeTurnCount = 0
        lastEventAt = nil
    }
}
