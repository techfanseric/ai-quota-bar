import XCTest
@testable import AIQuotaBar

final class ModelUtilizationCycleMergerTests: XCTestCase {
    func testHistoryCyclesMergeNearbyResetBoundaries() {
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let history = ModelUtilizationHistory(
            modelId: "codex:user@example.com:5h",
            entries: [
                UtilizationHistoryEntry(
                    capturedAt: reset.addingTimeInterval(-2_000),
                    usedPercent: 59,
                    resetsAt: reset
                ),
                UtilizationHistoryEntry(
                    capturedAt: reset.addingTimeInterval(-1_000),
                    usedPercent: 8,
                    resetsAt: reset.addingTimeInterval(20)
                )
            ]
        )

        let cycles = history.cycles(limit: 30, now: reset.addingTimeInterval(1), mode: .includeCurrent)

        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].resetsAt, reset.addingTimeInterval(20))
        XCTAssertEqual(cycles[0].peakPercent, 59)
    }

    func testIncludeCurrentOverwritesStaleHistoricalCycle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3_600)
        let model = weeklyModel(
            startTime: reset.addingTimeInterval(-7 * 24 * 3_600),
            endTime: reset,
            remainingPercent: 6
        )

        let cycles = ModelUtilizationCycleMerger.mergeLiveCurrentCycle(
            [(resetsAt: reset, peakPercent: 89)],
            model: model,
            limit: 12,
            now: now,
            mode: .includeCurrent
        )

        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].resetsAt, reset)
        XCTAssertEqual(cycles[0].peakPercent, 94)
    }

    func testIncludeCurrentRemovesNearbyStaleResetBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3_600)
        let staleResetInSameDisplayedMinute = reset.addingTimeInterval(20)
        let model = weeklyModel(
            startTime: reset.addingTimeInterval(-5 * 3_600),
            endTime: reset,
            remainingPercent: 44
        )

        let cycles = ModelUtilizationCycleMerger.mergeLiveCurrentCycle(
            [(resetsAt: staleResetInSameDisplayedMinute, peakPercent: 8)],
            model: model,
            limit: 12,
            now: now,
            mode: .includeCurrent
        )

        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].resetsAt, reset)
        XCTAssertEqual(cycles[0].peakPercent, 56)
    }

    func testCompletedOnlyDoesNotInsertInProgressCycle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval(3_600)
        let model = weeklyModel(
            startTime: reset.addingTimeInterval(-7 * 24 * 3_600),
            endTime: reset,
            remainingPercent: 6
        )

        let cycles = ModelUtilizationCycleMerger.mergeLiveCurrentCycle(
            [],
            model: model,
            limit: 12,
            now: now,
            mode: .completedOnly
        )

        XCTAssertTrue(cycles.isEmpty)
    }

    private func weeklyModel(startTime: Date, endTime: Date, remainingPercent: Int) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: "user@example.com",
            modelName: "Weekly",
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: Int(endTime.timeIntervalSince(Date()) * 1_000),
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil
        )
    }
}
