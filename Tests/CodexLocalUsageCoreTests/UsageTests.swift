import XCTest
@testable import CodexLocalUsageCore

final class UsageTests: XCTestCase {
    func json(_ value: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    func meta(_ id: String = "session", parent: String? = nil, time: String = "2026-09-01T00:00:00Z") -> String {
        var payload: [String: Any] = ["id": id]
        if let parent { payload["forked_from_id"] = parent }
        return json(["type": "session_meta", "timestamp": time, "payload": payload])
    }
    func context(_ model: String = "gpt-test") -> String { json(["type": "turn_context", "payload": ["model": model]]) }
    func counter(_ input: Int, cached: Int = 0, write: Int = 0, output: Int = 10) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write, "output_tokens": output, "reasoning_output_tokens": 0]
    }
    func token(_ total: [String: Any]?, last: [String: Any]?, time: String = "2026-09-01T00:00:01Z", source: String = "default") -> String {
        var info: [String: Any] = [:]; info["total_token_usage"] = total; info["last_token_usage"] = last
        return json(["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": info, "rate_limits": ["limit_id": source]]])
    }
    func parse(_ lines: [String]) -> [LocalUsageEvent] { UsageParser.resolve([UsageParser.parse(lines: lines)]).events }
    func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testRepeatedQuotaSnapshotsAndIdenticalRealRequests() {
        let first = token(counter(100), last: counter(100, cached: 50))
        let repeated = token(counter(100), last: counter(100, cached: 50), source: "other")
        let second = token(counter(200, output: 20), last: counter(100, cached: 50), time: "2026-09-01T00:00:02Z")
        let events = parse([meta(), context(), first, repeated, first, second])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(UsageSummary(events: events).tokens.total, 220)
        XCTAssertEqual(UsageSummary(events: events).cacheHitRate, 0.5)
    }
    func testLastOnlyEqualEventsAreNotDeduplicated() {
        let event = token(nil, last: counter(100))
        let result = parse([meta(), event, event])
        XCTAssertEqual(result.count, 2); XCTAssertNotEqual(result[0].id, result[1].id)
    }
    func testModelChangeAndCumulativeReset() {
        let result = UsageParser.parse(lines: [meta(), context("a"), token(counter(100), last: nil), context("b"),
            token(counter(150, output: 15), last: nil, time: "2026-09-01T00:00:02Z"),
            token(counter(10, output: 1), last: nil, time: "2026-09-01T00:00:03Z"),
            token(counter(30, output: 2), last: nil, time: "2026-09-01T00:00:04Z")])
        XCTAssertEqual(result.records.map(\.event.tokens.input), [100, 50, 20])
        XCTAssertEqual(result.records.map(\.event.model), ["a", "b", "b"])
        XCTAssertEqual(result.issues, 1)
    }
    func testInvalidCountersDoNotFallBackToInflatedTotals() {
        let result = UsageParser.parse(lines: [meta(), token(counter(1000), last: counter(20, cached: 30)),
            token(counter(20), last: ["input_tokens": true, "output_tokens": 10]), "not json"])
        XCTAssertTrue(result.records.isEmpty); XCTAssertEqual(result.issues, 3)
    }
    func testForkAndNestedForkAndMissingParent() {
        let a = token(counter(100), last: counter(100))
        let b = token(counter(140, output: 20), last: counter(40), time: "2026-09-01T00:00:03Z")
        let c = token(counter(160, output: 30), last: counter(20), time: "2026-09-01T00:00:05Z")
        let parent = UsageParser.parse(lines: [meta("p"), a])
        let child = UsageParser.parse(lines: [meta("c", parent: "p", time: "2026-09-01T00:00:02Z"), a, b])
        let grandchild = UsageParser.parse(lines: [meta("g", parent: "c", time: "2026-09-01T00:00:04Z"), a, b, c])
        let result = UsageParser.resolve([grandchild, child, parent])
        XCTAssertEqual(result.events.count, 3); XCTAssertEqual(result.deferred, 0)
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.tokens.input }, 160)
        XCTAssertEqual(UsageParser.resolve([child]).deferred, 1)
        XCTAssertTrue(UsageParser.resolve([child]).events.isEmpty)
    }
    func testForkNeverDropsNewMatchingUsageAfterForkTime() {
        let p = UsageParser.parse(lines: [meta("p"), token(counter(100), last: counter(100))])
        let c = UsageParser.parse(lines: [meta("c", parent: "p", time: "2026-09-01T00:00:02Z"), token(counter(100), last: counter(100), time: "2026-09-01T00:00:03Z")])
        XCTAssertEqual(UsageParser.resolve([p,c]).events.count, 2)
    }
    func testArchiveCopiesAndOverlappingPagesDeduplicate() {
        let a = token(counter(100), last: counter(100))
        let b = token(counter(200, output: 20), last: counter(100), time: "2026-09-01T00:00:02Z")
        let page1 = UsageParser.parse(lines: [meta(), a])
        let page2 = UsageParser.parse(lines: [meta(), a, b])
        XCTAssertEqual(UsageParser.resolve([page1, page2, page2]).events.count, 2)
    }
    func testPricesAndWeightedCacheAndRange() throws {
        let events = parse([meta(), context(), token(counter(100), last: counter(100, cached: 90, write: 10)),
            token(counter(1000, output: 20), last: counter(900), time: "2026-09-02T00:00:00Z")])
        let price = UsagePrice(model: "gpt-test", version: "test", source: "fixture", effectiveFrom: "2026-01-01T00:00:00Z", input: 2, cached: 1, cacheWrite: 3, output: 10)
        try UsagePrice.validate([price])
        let summary = UsageSummary(events: events, prices: [price])
        XCTAssertEqual(summary.cacheHitRate!, 0.09, accuracy: 0.00001)
        XCTAssertEqual(summary.cost, Decimal(string: "0.00212"))
        XCTAssertEqual(summary.pricedRecords, 2)
        XCTAssertEqual(UsageSummary(events: events, prices: []).pricedRecords, 0)
        XCTAssertEqual(UsageSummary(events: events, from: UsageTime.parse("2026-09-01T00:00:00Z")!, to: UsageTime.parse("2026-09-02T00:00:00Z")!).records, 1)
        XCTAssertNil(UsageSummary().cacheHitRate)
        XCTAssertThrowsError(try UsagePrice.validate([price, price]))
    }
    func testDurableOutboxOwnershipAndAcknowledgement() async throws {
        let dir = try temp(); let url = dir.appendingPathComponent("usage.sqlite")
        let events = parse([meta(), token(counter(100), last: counter(100))])
        let store = try UsageStore(url: url)
        try await store.insert(events, binding: "alice", since: .distantPast)
        try await store.insert(events, binding: "bob", since: .distantPast)
        let bob = try await store.pending(binding: "bob"); XCTAssertTrue(bob.isEmpty)
        let reopened = try UsageStore(url: url)
        let pending = try await reopened.pending(binding: "alice"); XCTAssertEqual(pending, events)
        try await reopened.acknowledge(binding: "bob", ids: events.map(\.id))
        let unchanged = try await reopened.pending(binding: "alice"); XCTAssertEqual(unchanged.count, 1)
        try await reopened.acknowledge(binding: "alice", ids: events.map(\.id))
        try await reopened.insert(events, binding: "alice", since: .distantPast)
        let delivered = try await reopened.pending(binding: "alice"); XCTAssertTrue(delivered.isEmpty)
    }
    func testScanningPartialWritesArchiveAndRestart() async throws {
        let dir = try temp(); let sessions = dir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout.jsonl")
        let prefix = [meta(), context(), token(counter(100), last: counter(100))].joined(separator: "\n") + "\n"
        try Data((prefix + "{\"type\":").utf8).write(to: file)
        let url = dir.appendingPathComponent("usage.sqlite"); let store = try UsageStore(url: url)
        let first = try await store.scan(root: dir); XCTAssertEqual(first.events.count, 1); XCTAssertEqual(first.incomplete, 1)
        let next = token(counter(200, output: 20), last: counter(100), time: "2026-09-01T00:00:02Z")
        try Data((prefix + next + "\n").utf8).write(to: file)
        let second = try await store.scan(root: dir); XCTAssertEqual(second.events.count, 2)
        let archived = dir.appendingPathComponent("archived_sessions"); try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archived.appendingPathComponent("renamed.jsonl"))
        let restarted = try UsageStore(url: url); let third = try await restarted.scan(root: dir)
        XCTAssertEqual(third.events.count, 2)
        let fourth = try await restarted.scan(root: dir); XCTAssertEqual(third.events, fourth.events)
    }
    func testCumulativeOnlyContinuationPageUsesPreviousPageBaseline() {
        let a = UsageParser.parse(lines: [meta(), token(counter(100), last: nil)])
        let b = UsageParser.parse(lines: [meta(), token(counter(150, output: 15), last: nil, time: "2026-09-01T00:00:02Z")])
        let result = UsageParser.resolve([b, a])
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.tokens.input }, 150)
    }
    func testCumulativeForkWithoutCopiedPrefixSubtractsParent() {
        let parent = UsageParser.parse(lines: [meta("p"), token(counter(100), last: counter(100))])
        let child = UsageParser.parse(lines: [meta("c", parent: "p", time: "2026-09-01T00:00:02Z"),
            token(counter(150, output: 15), last: nil, time: "2026-09-01T00:00:03Z")])
        let result = UsageParser.resolve([parent, child])
        XCTAssertEqual(result.events.reduce(0) { $0 + $1.tokens.input }, 150)
    }
    func testRejectedReasonsSurviveRestart() async throws {
        let dir = try temp(), id = usageDigest("fixture")
        let url = dir.appendingPathComponent("audit.sqlite")
        let store = try UsageStore(url: url)
        try await store.insert([LocalUsageEvent(id: id, occurredAt: "2026-01-01T00:00:00.000Z", model: "fixture", tokens: UsageTokens(input: 1))], binding: "person", since: .distantPast)
        try await store.acknowledge(binding: "person", ids: [], rejected: [id], reasons: [id: "ownership_conflict"])
        let restarted = try UsageStore(url: url)
        let reasons = try await restarted.rejectionReasons(binding: "person")
        XCTAssertEqual(reasons, ["ownership_conflict": 1])
        let pending = try await restarted.pending(binding: "person")
        XCTAssertTrue(pending.isEmpty)
    }
    func testLargePricedSummaryUsesExactAggregatedDecimalCosts() {
        let e = LocalUsageEvent(id: "fixture", occurredAt: "2026-01-02T00:00:00.000Z", model: "fixture", tokens: UsageTokens(input: 100, cached: 50, output: 10))
        let price = UsagePrice(model: "fixture", version: "v1", source: "fixture", effectiveFrom: "2026-01-01T00:00:00Z", input: 2, cached: 1, output: 10)
        let result = UsageSummary(events: Array(repeating: e, count: 100_000), prices: [price])
        XCTAssertEqual(result.pricedRecords, 100_000)
        XCTAssertEqual(result.cost, 25)
    }
    func testClientRejectsUnsafeEndpoints() {
        XCTAssertThrowsError(try UsageClient(endpoint: "http://example.com", token: "fixture"))
        XCTAssertThrowsError(try UsageClient(endpoint: "https://user:pass@example.com", token: "fixture"))
        XCTAssertThrowsError(try UsageClient(endpoint: "https://example.com?token=x", token: "fixture"))
        XCTAssertNoThrow(try UsageClient(endpoint: "http://127.0.0.1:8787", token: "fixture"))
    }
}
