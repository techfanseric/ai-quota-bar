import XCTest
@testable import CodexLocalUsageCore

final class UsageAccountTests: XCTestCase {
    func testLoginSwitchGapAndRestartNeverRewriteOldAccount() throws {
        var timeline = UsageAccountTimeline()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func observe(_ seconds: Double, _ id: String?, _ generation: String?) {
            timeline.observe(.init(at: base.addingTimeInterval(seconds), accountID: id, generation: generation))
        }
        observe(0, "a", "v1"); observe(60, "a", "v1")
        XCTAssertEqual(timeline.account(at: base.addingTimeInterval(30)), "a")
        XCTAssertNil(timeline.account(at: base.addingTimeInterval(-1)))
        observe(120, "b", "v2")
        XCTAssertNil(timeline.account(at: base.addingTimeInterval(90)))
        observe(180, "b", "v2")
        XCTAssertEqual(timeline.account(at: base.addingTimeInterval(150)), "b")
        observe(240, "a", "v3") // A -> B -> A is a new interval, not a reassignment.
        observe(300, "a", "v3")
        observe(600, "a", "v3") // Sleep/restart gap stays unknown.
        XCTAssertNil(timeline.account(at: base.addingTimeInterval(450)))
        XCTAssertEqual(timeline.account(at: base.addingTimeInterval(150)), "b")
        let loaded = try JSONDecoder().decode(UsageAccountTimeline.self, from: JSONEncoder().encode(timeline))
        XCTAssertEqual(loaded.account(at: base.addingTimeInterval(270)), "a")
        observe(660, nil, nil)
        XCTAssertNil(timeline.account(at: base.addingTimeInterval(630)))
    }
    func testAuthRewriteEvenWithSameAccountLeavesGap() {
        var timeline = UsageAccountTimeline()
        let now = Date()
        timeline.observe(.init(at: now, accountID: "a", generation: "1"))
        timeline.observe(.init(at: now.addingTimeInterval(60), accountID: "a", generation: "2"))
        XCTAssertNil(timeline.account(at: now.addingTimeInterval(30)))
    }
    func testLegacyEventDecodesWithoutAccountAndRetainsIdentity() throws {
        let event = LocalUsageEvent(id: "id", occurredAt: "2026-01-01T00:00:00.000Z", model: "test", tokens: UsageTokens(input: 10))
        let data = try JSONEncoder().encode(event)
        let value = try JSONDecoder().decode(LocalUsageEvent.self, from: data)
        XCTAssertNil(value.accountID)
        XCTAssertNil(value.accountSource)
        XCTAssertEqual(value.id, "id")
    }
    func testStoreKeepsHistoricalUnknownAndAttributedEventsImmutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(url: root.appendingPathComponent("test.sqlite"))
        let e = LocalUsageEvent(id: "a", occurredAt: "2026-01-01T00:00:00.000Z", model: "test", tokens: UsageTokens(input: 10))
        try await store.insert([e])
        let changed = LocalUsageEvent(id: e.id, occurredAt: e.occurredAt, model: e.model, tokens: e.tokens, accountID: "later", accountSource: "login-observation")
        try await store.insert([changed])
        let result = try await store.events()
        XCTAssertNil(result[0].accountID)
    }
}

extension UsageAccountTests {
    func testCloudMigrationPreservesSentAndPendingStatesAndReportingOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(url: root.appendingPathComponent("test.sqlite"))
        let events = ["a", "b"].map { LocalUsageEvent(id: $0, occurredAt: "2026-01-01T00:00:00.000Z", model: "test", tokens: UsageTokens(input: 10)) }
        try await store.insert(events, binding: "old", since: .distantPast)
        try await store.acknowledge(binding: "old", ids: ["a"])
        try await store.migrateBinding(from: "old", to: "new")
        try await store.migrateBinding(from: "old", to: "new")
        let counts = try await store.deliveryCounts(binding: "new")
        XCTAssertEqual(counts, ["sent": 1, "pending": 1])
        let old = try await store.deliveryCounts(binding: "old")
        XCTAssertTrue(old.isEmpty)
    }
}

extension UsageAccountTests {
    func testAPIKeyModeDoesNotAttributeStaleChatGPTTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth: [String: Any] = ["auth_mode": "apikey", "OPENAI_API_KEY": "fixture-key", "tokens": ["account_id": "stale-account"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("auth.json"))
        XCTAssertNil(UsageAccountObservation.read(root: root).accountID)
    }
    func testAuthObservationContainsNoCredentialOrRawAccountIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["account_id": "raw-account-fixture", "access_token": "secret-fixture-access", "refresh_token": "secret-fixture-refresh"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: root.appendingPathComponent("auth.json"))
        let observation = UsageAccountObservation.read(root: root)
        XCTAssertEqual(observation.accountID?.count, 64)
        let persisted = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(persisted.contains("secret-fixture"))
        XCTAssertFalse(persisted.contains("raw-account-fixture"))
    }
}
