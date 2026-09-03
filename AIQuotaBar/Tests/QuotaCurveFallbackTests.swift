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

    func testFiveHourRemainsPreferredWhenCollapsedOrExhausted() {
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

            XCTAssertEqual(selected, [fiveHour.id])
        }
    }

    func testFiveHourBecomesCurveWhenItIsTheOnlyWindowWithInvalidDurationMetadata() {
        let now = Date()
        let fiveHour = makeModel(
            account: "account@example.com",
            name: "5h",
            duration: 30 * 86_400,
            remainingPercent: 17,
            now: now)

        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: [fiveHour],
            renderableModelIDs: [fiveHour.id])

        XCTAssertEqual(selected, [fiveHour.id])
    }

    func testFiveHourStillWinsWhenItsDurationMetadataIsInvalid() {
        let now = Date()
        let fiveHour = makeModel(
            account: "account@example.com",
            name: "5h",
            duration: 30 * 86_400,
            remainingPercent: 17,
            now: now)
        let weekly = makeModel(
            account: "account@example.com",
            name: "Weekly",
            duration: 7 * 86_400,
            remainingPercent: 60,
            now: now)

        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: [fiveHour, weekly],
            renderableModelIDs: [fiveHour.id, weekly.id])

        XCTAssertEqual(selected, [fiveHour.id])
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

    func testUserCanForceNonCurveModelToAreaChart() {
        let now = Date()
        let monthly = makeModel(
            account: "account@example.com",
            name: "Monthly",
            duration: 30 * 86_400,
            remainingPercent: 55,
            now: now)
        var preferences = QuotaChartDisplayPreferences()
        preferences.setMode(.areaChart, for: monthly)

        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: [monthly],
            renderableModelIDs: [monthly.id],
            preferences: preferences)

        XCTAssertEqual(selected, [monthly.id])
    }

    func testUserCanForceDefaultCurveModelToProgressBar() {
        let now = Date()
        let fiveHour = makeModel(
            account: "account@example.com",
            name: "5h",
            duration: 5 * 3_600,
            remainingPercent: 55,
            now: now)
        var preferences = QuotaChartDisplayPreferences()
        preferences.setMode(.progressBar, for: fiveHour)

        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: [fiveHour],
            renderableModelIDs: [fiveHour.id],
            preferences: preferences)

        XCTAssertTrue(selected.isEmpty)
    }

    func testAutomaticModeRemovesStoredOverride() {
        let now = Date()
        let monthly = makeModel(
            account: "account@example.com",
            name: "Monthly",
            duration: 30 * 86_400,
            remainingPercent: 55,
            now: now)
        var preferences = QuotaChartDisplayPreferences()
        preferences.setMode(.areaChart, for: monthly)
        preferences.setMode(.automatic, for: monthly)

        XCTAssertEqual(preferences.mode(for: monthly), .automatic)
        let selected = QuotaCurveModelSelector.curveModelIDs(
            in: [monthly],
            renderableModelIDs: [monthly.id],
            preferences: preferences)
        XCTAssertTrue(selected.isEmpty)
    }

    func testChartTicksUseHoursForFiveHourAndMidnightsForWeekly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHourTicks = QuotaChartTimeTickBuilder.ticks(
            startTime: start,
            endTime: start.addingTimeInterval(5 * 3_600),
            calendar: calendar)
        XCTAssertEqual(fiveHourTicks.map(\.label), ["1h", "2h", "3h", "4h"])

        let weeklyEnd = start.addingTimeInterval(7 * 86_400)
        let weeklyTicks = QuotaChartTimeTickBuilder.ticks(
            startTime: start,
            endTime: weeklyEnd,
            calendar: calendar)

        // 每个刻度都必须精确落在本地 0:00，label 为 MM/dd
        XCTAssertFalse(weeklyTicks.isEmpty)
        let labelFormatter = DateFormatter()
        labelFormatter.timeZone = calendar.timeZone
        labelFormatter.dateFormat = "MM/dd"
        for tick in weeklyTicks {
            let tickDate = start.addingTimeInterval(tick.ratio * 7 * 86_400)
            XCTAssertEqual(tickDate, calendar.startOfDay(for: tickDate))
            XCTAssertGreaterThan(tickDate, start)
            XCTAssertLessThan(tickDate, weeklyEnd)
            XCTAssertEqual(tick.label, labelFormatter.string(from: tickDate))
        }

        // 相邻刻度相隔恰好一天
        let tickDates = weeklyTicks.map { start.addingTimeInterval($0.ratio * 7 * 86_400) }
        for (previous, next) in zip(tickDates, tickDates.dropFirst()) {
            XCTAssertEqual(next.timeIntervalSince(previous), 86_400, accuracy: 1)
        }
    }

    func testSampledModelsUnionDesktopCurvesWithTwoMobileSelections() {
        let now = Date()
        let desktopCurve = makeModel(
            account: "one",
            name: "5h",
            duration: 5 * 3_600,
            remainingPercent: 80,
            now: now)
        let mobileOnlyOne = makeModel(
            account: "one",
            name: "Daily",
            duration: 24 * 3_600,
            remainingPercent: 60,
            now: now)
        let mobileOnlyTwo = makeModel(
            account: "two",
            name: "Monthly",
            duration: 30 * 24 * 3_600,
            remainingPercent: 40,
            now: now)

        let result = UsageViewModel.sampledModelIDs(
            curveModelIDs: [desktopCurve.id],
            models: [
                desktopCurve,
                mobileOnlyOne,
                mobileOnlyTwo,
            ],
            mobileSelectionKeys: [
                mobileOnlyOne.mobileDashboardSelectionKey,
                mobileOnlyTwo.mobileDashboardSelectionKey,
            ])

        XCTAssertEqual(
            result,
            [
                desktopCurve.id,
                mobileOnlyOne.id,
                mobileOnlyTwo.id,
            ])
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
