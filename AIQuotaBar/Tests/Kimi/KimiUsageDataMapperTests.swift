import CodexBarCore
import XCTest
@testable import AIQuotaBar

final class KimiUsageDataMapperTests: XCTestCase {
    func testLiveCLICredentialWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AIQUOTABAR_LIVE_KIMI_TEST"] == "1" else {
            throw XCTSkip("Set AIQUOTABAR_LIVE_KIMI_TEST=1 to run Kimi Code CLI /status.")
        }

        let result = try await KimiService.shared.fetchUsage(apiKey: nil)

        XCTAssertEqual(result.provider, .kimi)
        XCTAssertEqual(result.models.map(\.modelName), ["5h", "7d"])
        XCTAssertTrue(result.models.allSatisfy { (0...100).contains($0.currentIntervalPercentageRemaining) })
    }

    func testMapsSessionBeforeWeeklyUsingRemainingPercent() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionReset = now.addingTimeInterval(2 * 60 * 60)
        let weeklyReset = now.addingTimeInterval(6 * 24 * 60 * 60)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 3,
                windowMinutes: 7 * 24 * 60,
                resetsAt: weeklyReset,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 17,
                windowMinutes: 5 * 60,
                resetsAt: sessionReset,
                resetDescription: nil),
            updatedAt: now)

        let result = try KimiUsageDataMapper.map(
            snapshot,
            source: "Kimi Code CLI",
            now: now)

        XCTAssertEqual(result.provider, .kimi)
        XCTAssertEqual(result.timestamp, now)
        XCTAssertEqual(result.models.map(\.modelName), ["5h", "7d"])
        XCTAssertEqual(result.models.map(\.currentIntervalRemainingPercent), [83, 97])
        XCTAssertEqual(result.models.map(\.currentIntervalUsed), [83, 97])
        XCTAssertEqual(result.models.first?.startTime, sessionReset.addingTimeInterval(-5 * 60 * 60))
        XCTAssertEqual(result.models.first?.endTime, sessionReset)
        XCTAssertEqual(result.models.first?.detailText, "Kimi Code CLI")
    }

    func testParsesKimiCLIStatusWithoutModelSession() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try KimiCLIStatusProbe.parse(
            text: """
            Session      none
            Context window  0%  (0 / 1M)
            Weekly limit  ██████████████████░░  89% used  resets in 1d 18h 35m
            5h limit      ░░░░░░░░░░░░░░░░░░░░  0% used   resets in 1h 35m
            """,
            now: now)

        XCTAssertEqual(snapshot.primary?.remainingPercent, 11)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 100)
        XCTAssertEqual(
            snapshot.primary?.resetsAt,
            now.addingTimeInterval(1 * 86_400 + 18 * 3_600 + 35 * 60))
        XCTAssertEqual(
            snapshot.secondary?.resetsAt,
            now.addingTimeInterval(1 * 3_600 + 35 * 60))
    }

    func testParsesPercentLeftOutputForCLICompatibility() throws {
        let snapshot = try KimiCLIStatusProbe.parse(
            text: """
            Weekly limit  11% left  resets in 2d
            5-hour limit  100% remaining  resets in 4h
            """,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(snapshot.primary?.remainingPercent, 11)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 100)
    }

    func testRejectsWorkspaceTrustPromptAsQuota() {
        XCTAssertThrowsError(try KimiCLIStatusProbe.parse(
            text: "Trust this folder?",
            now: Date())) { error in
            XCTAssertEqual(
                error as? KimiCLIStatusProbeError,
                .workspaceTrustRequired)
        }
    }

    func testRejectsSnapshotWithoutQuotaWindows() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            updatedAt: Date())

        XCTAssertThrowsError(
            try KimiUsageDataMapper.map(snapshot, source: "Kimi Code API")) { error in
                guard let usageError = error as? AIQuotaBar.UsageError,
                      case .invalidResponse = usageError else {
                    return XCTFail("Expected invalidResponse, got \(error)")
                }
            }
    }
}
