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

    func testPruneDeliveredDeletesOnlyOldConfirmedRows() async throws {
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
        try await store.acknowledge(
            binding: binding, ids: ["old-sent", "recent-sent"])

        let cutoff = Date().addingTimeInterval(-40 * 86_400)
        let deleted = try await store.pruneDelivered(olderThan: cutoff)

        XCTAssertEqual(deleted, 1)
        let remaining = try await store.events()
        XCTAssertEqual(
            remaining.map(\.id).sorted(),
            ["old-pending", "recent-sent"])
        // The pending row keeps its delivery state: it has no cloud copy and
        // must survive pruning forever.
        let counts = try await store.deliveryCounts(binding: binding)
        XCTAssertEqual(counts["pending"], 1)
        XCTAssertEqual(counts["sent"], 1)
    }

    func testPruneDeliveredWithoutConfirmedRowsIsNoOp() async throws {
        let store = try UsageStore(
            url: temp().appendingPathComponent("test.sqlite"))
        try await store.insert([event("pending", daysAgo: 90)])

        let deleted = try await store.pruneDelivered(
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
