import Foundation
import XCTest
import CodexLocalUsageCore
@testable import AIQuotaBar

@MainActor final class TeamSyncIsolationTests: XCTestCase {
    func testOutboxNeverAdoptsLegacyOrOtherTeamPayloadsAndCapacityIsPerTeam() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = CloudSyncQueue(directoryURL: directory)
        var payload = CloudUsageSnapshotPayload(deviceID: "same-device", sampledAt: Date(), retentionDays: 90, models: [], utilizationHistories: nil)
        queue.enqueue(payload: payload) // Missing team is quarantined, never queued.
        payload.teamBinding = "team-a"
        queue.enqueue(payload: payload)
        payload.teamBinding = "team-b"
        for _ in 0..<55 { queue.enqueue(payload: payload) }
        var a: [String] = [], b: [String] = []
        await queue.flush(binding: "team-a") { a.append($0.teamBinding ?? "legacy") }
        await queue.flush(binding: "team-b") { b.append($0.teamBinding ?? "legacy") }
        XCTAssertEqual(a, ["team-a"])
        XCTAssertEqual(b.count, CloudSyncQueue.maxQueueSize)
        XCTAssertEqual(Set(b), ["team-b"])
    }
    func testTeamRequiredBeforeAnyQuotaRead() async {
        let service = CloudSyncService(contextProvider: { throw CloudSyncError.missingToken }, bindingProvider: { nil })
        do { _ = try await service.fetchRemoteUsageData(); XCTFail("Personal mode must not read shared data") }
        catch { XCTAssertTrue(error is CloudSyncError) }
    }
    func testCredentialLookupCannotContinueAfterSwitchingTeam() async {
        var current = "a"
        let service = CloudSyncService(contextProvider: {
            current = "b" // Simulates switching while Keychain lookup suspends.
            return TeamQuotaContext(binding: "a", endpoint: "https://should-never-be-called.invalid", token: "a-token")
        }, bindingProvider: { current })
        do { _ = try await service.fetchRemoteUsageData(); XCTFail("Stale request must stop before networking") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSavedConnectionDecodeRemainsCompatibleWithoutTeamName() throws {
        let identity = try JSONDecoder().decode(UsageIdentity.self, from: Data("{\"team_id\":\"a\",\"member_id\":\"m\",\"member_name\":\"M\",\"device_id\":\"d\"}".utf8))
        XCTAssertNil(identity.team_name)
        let first = LocalUsageConnection(endpoint: "https://one.invalid", identity: identity, since: Date())
        let second = LocalUsageConnection(endpoint: "https://two.invalid", identity: identity, since: Date())
        XCTAssertNotEqual(first.binding, second.binding)
    }
}
