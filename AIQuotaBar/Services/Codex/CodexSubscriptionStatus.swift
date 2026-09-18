import Foundation
import Observation
import CodexBarCore
import CodexLocalUsageCore

struct CodexSubscriptionMarker: Equatable {
    let date: Date
    let renews: Bool
}

/// Only verified web billing metadata is accepted. Token expiry and quota resets
/// are deliberately unrelated. Nothing here is uploaded or persisted.
@MainActor @Observable
final class CodexSubscriptionStatus {
    static let shared = CodexSubscriptionStatus()
    private var markers: [String: CodexSubscriptionMarker] = [:]
    private var observedAt: [String: Date] = [:]

    func receive(snapshot: UsageSnapshot, source: String,
                 before: UsageAccountObservation, after: UsageAccountObservation, now: Date = .now) {
        guard let id = before.accountID, id == after.accountID,
              before.generation == after.generation,
              let email = after.label?.lowercased(), !email.isEmpty,
              email == snapshot.identity?.accountEmail?.lowercased() else { return }
        guard source == "openai-web" else { return }
        if let renews = snapshot.subscriptionRenewsAt, snapshot.subscriptionExpiresAt == nil {
            markers[id] = CodexSubscriptionMarker(date: renews, renews: true)
        } else if let expires = snapshot.subscriptionExpiresAt, snapshot.subscriptionRenewsAt == nil {
            markers[id] = CodexSubscriptionMarker(date: expires, renews: false)
        } else { markers[id] = nil }
        observedAt[id] = now
    }
    func marker(accountID: String?, now: Date = .now) -> CodexSubscriptionMarker? {
        guard let accountID, let date = observedAt[accountID], now.timeIntervalSince(date) < 24 * 3600 else { return nil }
        return markers[accountID]
    }
}
