import XCTest
@testable import CodexLocalUsageCore

final class UsageStorePruneTests: XCTestCase {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func event(_ id: String, daysAgo: Double) -> LocalUsageEvent {
        let at = Date().addingTimeInterval(-daysAgo * 86_400)
        return LocalUsageEvent(
            id: id,
            occurredAt: UsageTime.string(at),
            model: "gpt-test",
            tokens: UsageTokens(input: 1, output: 1))
    }

    func testPruneExpendableDeletesOldConfirmedAndLocalOnlyRows() async throws {
        let store = try UsageStore(
            url: temp().appendingPathComponent("test.sqlite"))
        let binding = "binding-1"
        // `.distantPast` mirrors how a live connection backfills history:
        // without it the rows stay unowned (local-only) and acknowledge()
        // would never match them.
        try await store.insert(
            [
                event("old-sent", daysAgo: 60),
                event("recent-sent", daysAgo: 5),
                event("old-pending", daysAgo: 60),
            ], binding: binding, since: .distantPast)
        // Unbound rows: pre-connection history that was never uploadable.
        try await store.insert(
            [
                event("old-local", daysAgo: 60),
                event("recent-local", daysAgo: 5),
            ])
        try await store.acknowledge(
            binding: binding, ids: ["old-sent", "recent-sent"])

        let cutoff = Date().addingTimeInterval(-40 * 86_400)
        let deleted = try await store.pruneExpendable(olderThan: cutoff)

        // old-sent (cloud has it) and old-local (no reader past 40 days) go;
        // everything within the horizon stays.
        XCTAssertEqual(deleted, 2)
        let remaining = try await store.events()
        XCTAssertEqual(
            remaining.map(\.id).sorted(),
            ["old-pending", "recent-local", "recent-sent"])
        // The bound pending row keeps its delivery state: it has no cloud
        // copy and must survive pruning forever.
        let counts = try await store.deliveryCounts(binding: binding)
        XCTAssertEqual(counts["pending"], 1)
        XCTAssertEqual(counts["sent"], 1)
    }

    func testPruneExpendableNeverTouchesBoundPendingRows() async throws {
        let store = try UsageStore(
            url: temp().appendingPathComponent("test.sqlite"))
        // Bound but never uploaded: no cloud copy, so age alone can never
        // make this row expendable.
        try await store.insert(
            [event("pending", daysAgo: 90)],
            binding: "binding-1", since: .distantPast)

        let deleted = try await store.pruneExpendable(
            olderThan: Date().addingTimeInterval(-40 * 86_400))

        XCTAssertEqual(deleted, 0)
        let remaining = try await store.events()
        XCTAssertEqual(remaining.map(\.id), ["pending"])
    }

    func testReclaimFreePagesBelowThresholdSkipsVacuum() async throws {
        let store = try UsageStore(
            url: temp().appendingPathComponent("test.sqlite"))

        // A fresh database has no meaningful freelist; the call must be a
        // cheap no-op rather than a full rewrite.
        let vacuumed = try await store.reclaimFreePagesIfWorthwhile()
        XCTAssertFalse(vacuumed)
    }
}
