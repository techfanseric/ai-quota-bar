import Foundation

/// Activity snapshot from a passive local detector (ZCode, MiniMax CLI,
/// Claude Code). Only lifecycle metadata is read; message bodies and tool
/// output are never retained.
///
/// Session IDs are pre-prefixed with their provider and client (for example
/// `glm:zcode:<id>` or `minimax:claude:<id>`) so the protection coordinator
/// can merge, count, and label them without knowing each client's storage
/// format.
struct ProviderLocalActivitySnapshot: Equatable, Sendable {
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

    static let empty = ProviderLocalActivitySnapshot(
        activeSessionIDs: [],
        lastEventAt: nil)
}

protocol ProviderLocalActivityProviding: Sendable {
    func snapshot() async -> ProviderLocalActivitySnapshot
}
