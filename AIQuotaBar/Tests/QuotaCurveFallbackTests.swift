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

    func testChartTicksUseHourBoundariesForFiveHourAndMidnightsForWeekly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        // 起点 = 2023-11-15 06:13:20 本地时间
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fiveHourTicks = QuotaChartTimeTickBuilder.ticks(
            startTime: start,
            endTime: start.addingTimeInterval(5 * 3_600),
            calendar: calendar)

        // 每个刻度都必须精确落在本地自然整点（07:00 … 11:00）
        XCTAssertEqual(fiveHourTicks.count, 5)
        for tick in fiveHourTicks {
            let tickDate = start.addingTimeInterval(tick.ratio * 5 * 3_600)
            XCTAssertEqual(tickDate, calendar.dateInterval(of: .hour, for: tickDate)?.start)
            XCTAssertGreaterThan(tickDate, start)
            XCTAssertLessThan(tickDate, start.addingTimeInterval(5 * 3_600))
        }

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

    func testFullDayTicksOnlyCoverCompleteDaysAtNoon() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        // 起点 = 2023-11-15 06:13:20 本地时间，7 天窗口 → 完整日为 11/16 … 11/21
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(7 * 86_400)
        let ticks = QuotaChartTimeTickBuilder.fullDayTicks(
            startTime: start,
            endTime: end,
            calendar: calendar)

        XCTAssertEqual(ticks.map(\.label), ["11/16", "11/17", "11/18", "11/19", "11/20", "11/21"])

        // 每个标签都落在当天正午（窗口内居中）
        for tick in ticks {
            let tickDate = start.addingTimeInterval(tick.ratio * 7 * 86_400)
            XCTAssertEqual(calendar.component(.hour, from: tickDate), 12)
            XCTAssertEqual(calendar.component(.minute, from: tickDate), 0)
        }

        // 窗口两端恰好对齐 0:00 时，7 天全部算完整日
        let alignedStart = calendar.startOfDay(for: start)
        let alignedTicks = QuotaChartTimeTickBuilder.fullDayTicks(
            startTime: alignedStart,
            endTime: alignedStart.addingTimeInterval(7 * 86_400),
            calendar: calendar)
        XCTAssertEqual(alignedTicks.count, 7)
        XCTAssertEqual(alignedTicks.first?.ratio ?? 0, 0.5 / 7, accuracy: 0.000_001)

        // 不足一天的窗口没有完整日
        XCTAssertTrue(QuotaChartTimeTickBuilder.fullDayTicks(
            startTime: start,
            endTime: start.addingTimeInterval(5 * 3_600),
            calendar: calendar).isEmpty)
    }

    func testFullHourTicksOnlyCoverCompleteHoursAtHalfPast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        // 起点 = 2023-11-15 06:13:20 本地时间，5 小时窗口 → 完整小时为 7AM … 10AM
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(5 * 3_600)
        let ticks = QuotaChartTimeTickBuilder.fullHourTicks(
            startTime: start,
            endTime: end,
            calendar: calendar)

        XCTAssertEqual(ticks.map(\.label), ["7AM", "8AM", "9AM", "10AM"])

        // 每个标签都落在该小时半点（窗口内居中）
        for tick in ticks {
            let tickDate = start.addingTimeInterval(tick.ratio * 5 * 3_600)
            XCTAssertEqual(calendar.component(.minute, from: tickDate), 30)
            XCTAssertEqual(calendar.component(.second, from: tickDate), 0)
        }

        // 窗口两端恰好对齐整点时，5 个小时全部算完整时段
        let alignedStart = calendar.dateInterval(of: .hour, for: start)!.start
        let alignedTicks = QuotaChartTimeTickBuilder.fullHourTicks(
            startTime: alignedStart,
            endTime: alignedStart.addingTimeInterval(5 * 3_600),
            calendar: calendar)
        XCTAssertEqual(alignedTicks.count, 5)
        XCTAssertEqual(alignedTicks.first?.ratio ?? 0, 0.5 / 5, accuracy: 0.000_001)

        // 不足一小时的窗口没有完整时段
        XCTAssertTrue(QuotaChartTimeTickBuilder.fullHourTicks(
            startTime: start,
            endTime: start.addingTimeInterval(30 * 60),
            calendar: calendar).isEmpty)
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
