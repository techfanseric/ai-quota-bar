import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexAccountQuotaStoreTests: XCTestCase {
    private func makeTemporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-quota-\(UUID().uuidString)")
        addTeardownBlock { [directory] in
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func testRecordComputesRemainingAndRoundTrips() throws {
        let directory = try makeTemporaryStoreURL()
        let store = CodexAccountQuotaStore(directoryURL: directory)
        let captured = Date(timeIntervalSince1970: 1_800_000_000)

        store.record(
            accountDigest: "digest-a",
            primaryUsedPercent: 32.4,
            primaryResetsAt: captured.addingTimeInterval(3_600),
            secondaryUsedPercent: 59,
            secondaryResetsAt: captured.addingTimeInterval(86_400),
            now: captured)

        let snapshot = try XCTUnwrap(store.snapshot(for: "digest-a"))
        XCTAssertEqual(snapshot.shortRemainingPercent, 68)
        XCTAssertEqual(snapshot.shortResetsAt, captured.addingTimeInterval(3_600))
        XCTAssertEqual(snapshot.longRemainingPercent, 41)
        XCTAssertEqual(snapshot.longResetsAt, captured.addingTimeInterval(86_400))
        XCTAssertEqual(snapshot.capturedAt, captured)

        // 落盘后新实例可读回（iso8601 日期）。
        let reloaded = CodexAccountQuotaStore(directoryURL: directory)
        XCTAssertEqual(reloaded.snapshot(for: "digest-a"), snapshot)
    }

    func testRecordWithoutPrimaryWindowIsNoOp() throws {
        let directory = try makeTemporaryStoreURL()
        let store = CodexAccountQuotaStore(directoryURL: directory)

        store.record(
            accountDigest: "digest-a",
            primaryUsedPercent: nil,
            primaryResetsAt: nil,
            secondaryUsedPercent: 10,
            secondaryResetsAt: nil)

        XCTAssertNil(store.snapshot(for: "digest-a"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("account-quota.json").path))
    }

    func testMissingDigestReturnsNilAndRecordOverwritesWithLatest() throws {
        let directory = try makeTemporaryStoreURL()
        let store = CodexAccountQuotaStore(directoryURL: directory)

        XCTAssertNil(store.snapshot(for: "missing"))

        store.record(
            accountDigest: "digest-a",
            primaryUsedPercent: 50,
            primaryResetsAt: nil,
            secondaryUsedPercent: nil,
            secondaryResetsAt: nil,
            now: Date(timeIntervalSince1970: 1_000))
        store.record(
            accountDigest: "digest-a",
            primaryUsedPercent: 80,
            primaryResetsAt: nil,
            secondaryUsedPercent: nil,
            secondaryResetsAt: nil,
            now: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(store.snapshot(for: "digest-a")?.shortRemainingPercent, 20)
        XCTAssertEqual(
            store.snapshot(for: "digest-a")?.capturedAt,
            Date(timeIntervalSince1970: 2_000))
    }

    func testPruneKeepsMostRecentAccountsOnly() throws {
        let directory = try makeTemporaryStoreURL()
        let store = CodexAccountQuotaStore(directoryURL: directory)
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 0..<40 {
            store.record(
                accountDigest: "digest-\(index)",
                primaryUsedPercent: Double(index),
                primaryResetsAt: nil,
                secondaryUsedPercent: nil,
                secondaryResetsAt: nil,
                now: base.addingTimeInterval(Double(index) * 60))
        }

        XCTAssertNil(store.snapshot(for: "digest-0"))
        XCTAssertNil(store.snapshot(for: "digest-7"))
        XCTAssertNotNil(store.snapshot(for: "digest-8"))
        XCTAssertNotNil(store.snapshot(for: "digest-39"))
    }
}
