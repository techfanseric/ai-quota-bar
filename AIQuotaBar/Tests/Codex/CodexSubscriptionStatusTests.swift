import XCTest
import CodexBarCore
import CodexLocalUsageCore
@testable import AIQuotaBar

@MainActor final class CodexSubscriptionStatusTests: XCTestCase {
    func testOnlyVerifiedAccountMatchedBillingDatesAreShownAndExpire() {
        let status = CodexSubscriptionStatus(), now = Date()
        let observation = UsageAccountObservation(at: now, accountID: "a", label: "demo@example.com", generation: "g")
        let other = UsageAccountObservation(at: now, accountID: "b", label: "demo@example.com", generation: "h")
        func snapshot(renews: Bool, email: String = "demo@example.com") -> UsageSnapshot {
            UsageSnapshot(primary: nil, secondary: nil,
                          subscriptionExpiresAt: renews ? nil : now,
                          subscriptionRenewsAt: renews ? now : nil, updatedAt: now,
                          identity: ProviderIdentitySnapshot(providerID: .codex, accountEmail: email, accountOrganization: nil, loginMethod: "pro"))
        }
        status.receive(snapshot: snapshot(renews: true), source: "oauth", before: observation, after: observation, now: now)
        XCTAssertNil(status.marker(accountID: "a", now: now))
        status.receive(snapshot: snapshot(renews: true), source: "openai-web", before: observation, after: other, now: now)
        XCTAssertNil(status.marker(accountID: "a", now: now))
        status.receive(snapshot: snapshot(renews: true, email: "wrong@example.com"), source: "openai-web", before: observation, after: observation, now: now)
        XCTAssertNil(status.marker(accountID: "a", now: now))
        status.receive(snapshot: snapshot(renews: true), source: "openai-web", before: observation, after: observation, now: now)
        XCTAssertEqual(status.marker(accountID: "a", now: now), CodexSubscriptionMarker(date: now, renews: true))
        XCTAssertNil(status.marker(accountID: "b", now: now))
        status.receive(snapshot: snapshot(renews: false), source: "openai-web", before: observation, after: observation, now: now)
        XCTAssertEqual(status.marker(accountID: "a", now: now)?.renews, false)
        XCTAssertNil(status.marker(accountID: "a", now: now.addingTimeInterval(86401)))
    }
}
