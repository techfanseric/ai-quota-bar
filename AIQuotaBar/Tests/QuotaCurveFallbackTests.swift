import XCTest
@testable import AIQuotaBar

final class QuotaCurveFallbackTests: XCTestCase {
    func testWeeklyBecomesCurveOnlyForAccountWithoutVisibleShortCurve() {
        let now = Date()
        let accountAFiveHour = makeModel(
            account: "a@example.com",
            name: "5h",
            duration: 5 * 3_600,
            remainingPercent: 75,
            now: now)
        let accountAWeekly = makeModel(
            account: "a@example.com",
            name: "Weekly",
            duration: 7 * 86_400,
            remainingPercent: 80,
            now: now)
        let accountBWeekly = makeModel(
            account: "b@example.com",
            name: "Weekly",
            duration: 7 * 86_400,
            remainingPercent: 60,
            now: now)
        let models = [accountAFiveHour, accountAWeekly, accountBWeekly]

        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: models,
            renderableModelIDs: Set(models.map(\.id)))

        XCTAssertTrue(selected.contains(accountAFiveHour.id))
        XCTAssertFalse(selected.contains(accountAWeekly.id))
        XCTAssertTrue(selected.contains(accountBWeekly.id))
    }

    func testCollapsedOrExhaustedShortWindowDoesNotBlockWeeklyFallback() {
        let now = Date()
        for remainingPercent in [100, 0] {
            let fiveHour = makeModel(
                account: "account@example.com",
                name: "5h",
                duration: 5 * 3_600,
                remainingPercent: remainingPercent,
                now: now)
            let weekly = makeModel(
                account: "account@example.com",
                name: "Weekly",
                duration: 7 * 86_400,
                remainingPercent: 55,
                now: now)

            let selected = QuotaCurveModelSelector.curveModelIDs(
                in: [fiveHour, weekly],
                renderableModelIDs: [fiveHour.id, weekly.id])

            XCTAssertTrue(selected.contains(weekly.id))
        }
    }

    func testCanonicalWeeklyWinsOverExtraWeeklyWindow() {
        let now = Date()
        let weekly = makeModel(
            account: "account@example.com",
            name: "Weekly",
            duration: 7 * 86_400,
            remainingPercent: 55,
            now: now)
        let sparkWeekly = makeModel(
            account: "account@example.com",
            name: "Spark Weekly",
            duration: 7 * 86_400,
            remainingPercent: 90,
            now: now)

        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: [sparkWeekly, weekly],
            renderableModelIDs: [sparkWeekly.id, weekly.id])

        XCTAssertEqual(selected, [weekly.id])
    }

    func testChartTicksUseHoursForFiveHourAndDaysForWeekly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHourTicks = QuotaChartTimeTickBuilder.ticks(
            startTime: start,
            endTime: start.addingTimeInterval(5 * 3_600))
        XCTAssertEqual(fiveHourTicks.map(\.label), ["1h", "2h", "3h", "4h"])

        let weeklyTicks = QuotaChartTimeTickBuilder.ticks(
            startTime: start,
            endTime: start.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(
            weeklyTicks.map(\.label),
            ["1d", "2d", "3d", "4d", "5d", "6d"])
        XCTAssertEqual(weeklyTicks.last?.ratio ?? 0, 6.0 / 7.0, accuracy: 0.0001)
    }

    private func makeModel(
        account: String,
        name: String,
        duration: TimeInterval,
        remainingPercent: Int,
        now: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: Int(duration * 500),
            startTime: now.addingTimeInterval(-duration / 2),
            endTime: now.addingTimeInterval(duration / 2),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }
}
