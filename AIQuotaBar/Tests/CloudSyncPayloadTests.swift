import XCTest
@testable import AIQuotaBar

final class CloudSyncPayloadTests: XCTestCase {
    func test_modelQuotaPayload_usesPercentModeWhenRemainingPercentExists() {
        let model = ModelUsageData(
            provider: .miniMax,
            accountName: nil,
            modelName: "MiniMax Model",
            currentIntervalTotal: 0,
            currentIntervalUsed: 0,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_018_000),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: nil,
            detailText: nil,
            currentIntervalRemainingPercent: 83,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil
        )

        let payload = CloudModelQuotaPayload(model: model)

        XCTAssertEqual(payload.currentIntervalTotal, 100)
        XCTAssertEqual(payload.currentIntervalRemaining, 83)
        XCTAssertEqual(payload.currentIntervalRemainingPercent, 83)
        XCTAssertEqual(payload.valueSuffix, "%")
    }
}
