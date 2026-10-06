import XCTest
@testable import AIQuotaBar

/// 「只有 Weekly、没有 5h」的 Codex 账号在菜单栏环与左键菜单里的表达。
///
/// 判据是**窗口名**里有没有 5h，而不是窗口时长：关注快照只带百分比，
/// 时长要靠 start/end 推，而窗口名是发布方直接给的稳定事实。
@MainActor
final class MenuBarWeeklyTrendTests: XCTestCase {

    // MARK: - 关注链路：窗口起点

    func testSharedWindowCarriesThePublishersWindowStart() {
        let (store, _) = makeStore()
        store.isSharing = true
        store.setShared(true, for: "a@example.com")

        let now = Date()
        let start = now.addingTimeInterval(-3 * 86_400)
        let published = store.publishableSnapshots(from: UsageData(
            provider: .codex, remains: 1, total: 1, timestamp: now,
            models: [makeCodexWindow(
                account: "a@example.com", name: "Weekly", remainingPercent: 42,
                start: start, end: now.addingTimeInterval(4 * 86_400))],
            subscribeTitle: nil, subscribeEndTime: nil))

        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].windows.first?.name, "Weekly")
        XCTAssertEqual(
            published[0].windows.first?.startsAt?.timeIntervalSince1970 ?? 0,
            start.timeIntervalSince1970, accuracy: 1)
    }

    func testWatchedRowAdoptsTheSharedWindowStartSoPaceAndCurvesWork() throws {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        let start = Date().addingTimeInterval(-3 * 86_400)
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro 5x",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 42,
                    resetsAt: Date().addingTimeInterval(4 * 86_400),
                    sampledAt: Date(), startsAt: start)],
                publishedAt: Date()))

        let row = try XCTUnwrap(store.watchedModels.first)
        XCTAssertEqual(row.startTime?.timeIntervalSince1970 ?? 0, start.timeIntervalSince1970, accuracy: 1)
        // Without a start there is no "how far into the window are we", so pace --
        // and with it the ring's inner channel -- cannot be computed at all.
        XCTAssertNotNil(row.currentIntervalElapsedRatio)
        XCTAssertNotNil(row.quotaChartWindow())
    }

    func testAWindowStartAfterTheResetIsDroppedRatherThanRenderedOutOfCycle() throws {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        let reset = Date().addingTimeInterval(3 * 86_400)
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 42,
                    resetsAt: reset, sampledAt: Date(),
                    startsAt: reset.addingTimeInterval(600))],
                publishedAt: Date()))

        // The row survives, and the bogus start is not adopted -- the weekly
        // window is recovered from the reset time instead.
        let row = try XCTUnwrap(store.watchedModels.first)
        XCTAssertEqual(row.currentIntervalRemainingPercent, 42)
        XCTAssertEqual(row.startTime?.timeIntervalSince1970 ?? 0,
                       reset.addingTimeInterval(-7 * 86_400).timeIntervalSince1970, accuracy: 1)
    }

    func testServerTimestampsSurviveDecoding() {
        // The server re-serializes with Date#toISOString(), which always carries
        // milliseconds. A plain ISO8601DateFormatter returns nil for these -- and
        // a nil reset time means no window, which means no pace and no curve.
        for raw in [
            "2026-10-11T15:59:38.000Z",   // what the server actually sends
            "2026-10-11T15:59:38Z",       // and the bare form, for older rows
        ] {
            let parsed = CodexWatchCloudClient.parseDate(raw)
            XCTAssertNotNil(parsed, "failed to decode \(raw)")
        }
        let round = CodexWatchCloudClient.parseDate(
            CodexWatchCloudClient.formatDate(Date(timeIntervalSince1970: 1_767_365_978)))
        XCTAssertEqual(round?.timeIntervalSince1970 ?? 0, 1_767_365_978, accuracy: 1)
        XCTAssertNil(CodexWatchCloudClient.parseDate(nil))
        XCTAssertNil(CodexWatchCloudClient.parseDate(""))
    }

    func testAFutureWindowStartIsDropped() throws {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        // A window that has not opened yet, and whose derived start is still in
        // the future: nothing here describes a window we can plot.
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 42,
                    resetsAt: Date().addingTimeInterval(9 * 86_400), sampledAt: Date(),
                    startsAt: Date().addingTimeInterval(86_400))],
                publishedAt: Date()))
        let row = try XCTUnwrap(store.watchedModels.first)
        XCTAssertNil(row.startTime)
    }

    // MARK: - 菜单栏环：环与环内都走 Weekly

    func testWeeklyOnlyCodexAccountRingsFromWeeklyEvenWhenTheRingIsSetTo5h() {
        withWeeklyRingViewModel { viewModel in
            let now = Date()
            // The user asked for a 5h ring; this account has no 5h at all.
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)

            let codex = viewModel.menuBarSnapshots.first { $0.provider == .codex }
            XCTAssertEqual(codex?.ringPercent, 73, "the only quota this account has is the weekly one")
            XCTAssertEqual(codex?.modelName, "Weekly")
        }
    }

    func testWeeklyOnlyCodexAccountFillsTheInnerChannelFromWeeklyPace() throws {
        try withWeeklyRingViewModel { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)

            // 3 of 7 days elapsed -> ~43% should be used, 27% actually is:
            // spending slower than even, so the fan reads as a reserve.
            let delta = viewModel.menuBarSnapshots
                .first { $0.provider == .codex }?.paceDeltaPercent
            XCTAssertGreaterThan(try XCTUnwrap(delta), 0)
        }
    }

    func testAnAccountThatStillHasA5hWindowKeepsTheExistingFanAndRing() {
        withWeeklyRingViewModel { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 2, total: 2, timestamp: now,
                models: [
                    makeCodexWindow(
                        account: "a@example.com", name: "5h", remainingPercent: 30,
                        start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(3_600)),
                    makeCodexWindow(
                        account: "a@example.com", name: "Weekly", remainingPercent: 73,
                        start: now.addingTimeInterval(-3 * 86_400),
                        end: now.addingTimeInterval(4 * 86_400)),
                ],
                subscribeTitle: nil, subscribeEndTime: nil)
            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 8, now: now),
            ])

            let codex = viewModel.menuBarSnapshots.first { $0.provider == .codex }
            XCTAssertEqual(codex?.ringPercent, 30, "with a 5h window present the ring still follows the setting")
            XCTAssertNil(codex?.ringTrend, "a 5h account keeps the fan; the curve is the weekly-only case")
        }
    }

    func testAPrefixedFiveHourWindowNameStillCountsAsHavingA5h() {
        // "GLM Credits (5h)" is not the string "5h". An equality test silently
        // reads such an account as weekly-only and reroutes a healthy ring to
        // the weekly window -- the exact regression this rule can cause.
        XCTAssertTrue(UsageViewModel.looksLikeFiveHourWindowName("GLM Credits (5h)"))
        XCTAssertTrue(UsageViewModel.looksLikeFiveHourWindowName("Codex Spark 5-hour"))
        XCTAssertTrue(UsageViewModel.looksLikeFiveHourWindowName("5h"))
        XCTAssertFalse(UsageViewModel.looksLikeFiveHourWindowName("Weekly"))
        XCTAssertFalse(UsageViewModel.looksLikeFiveHourWindowName("GLM Credits (weekly)"))
    }

    func testProvidersWithoutAWeeklyWindowAreLeftAlone() {
        withWeeklyRingViewModel { viewModel in
            viewModel.menuBarRingSelectedProviders = [.miniMax]
            let now = Date()
            let miniMax = ModelUsageData(
                provider: .miniMax, accountName: nil, modelName: "MiniMax",
                currentIntervalTotal: 100, currentIntervalUsed: 23,
                weeklyTotal: 0, weeklyUsed: 0, remainsTime: 3_600_000,
                startTime: now.addingTimeInterval(-3_600), endTime: now.addingTimeInterval(3_600),
                weeklyStartTime: nil, weeklyEndTime: nil, valueSuffix: nil, detailText: nil,
                currentIntervalRemainingPercent: 23, weeklyRemainingPercent: nil,
                progressBarPercentOverride: nil, progressBarRightText: nil, sampledAt: nil)
            viewModel.usageData = UsageData(
                provider: .miniMax, remains: 1, total: 1, timestamp: now,
                models: [miniMax], subscribeTitle: nil, subscribeEndTime: nil)

            let ring = viewModel.menuBarSnapshots.first { $0.provider == .miniMax }
            XCTAssertEqual(ring?.ringPercent, 23)
            XCTAssertNil(ring?.ringTrend)
        }
    }

    func testAFailedFetchIsNotRecordedAsAReading() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        let start = Date().addingTimeInterval(-3 * 86_400)
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro 5x",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 95,
                    resetsAt: Date().addingTimeInterval(4 * 86_400),
                    sampledAt: Date(), startsAt: start)],
                publishedAt: Date()))
        // The cached snapshot keeps the row alive...
        XCTAssertEqual(store.watchedModels.count, 1)
        // ...but it is not this cycle's reading, so nothing may be sampled from it.
        XCTAssertTrue(store.freshlyFetchedAccountNames.isEmpty)
        XCTAssertTrue(store.freshlyFetchedModels.isEmpty)
    }

    func testAStaleMarkerAlsoStopsSamplingWithoutHidingTheRow() {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro 5x",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 95,
                    resetsAt: Date().addingTimeInterval(4 * 86_400),
                    sampledAt: Date(), startsAt: Date().addingTimeInterval(-3 * 86_400))],
                publishedAt: Date()))
        store.markStaleForTesting("a@example.com")
        XCTAssertEqual(store.watchedModels.count, 1, "the row stays")
        XCTAssertTrue(store.freshlyFetchedModels.isEmpty, "but stale numbers are not a reading")
    }

    func testAWeeklyOnlyAccountPacesTheSameWhicheverCenterWindowIsPicked() {
        // The account has no 5h at all, so "current cycle" and "weekly cycle" are
        // the same window by definition. If they disagree, one of them is asking
        // for a window that does not exist and silently falls back to no pace.
        for center in [MenuBarReserveQuotaWindow.current, .weekly, .synchronized] {
            withWeeklyRingViewModel(center: center) { viewModel in
                let now = Date()
                viewModel.usageData = UsageData(
                    provider: .codex, remains: 1, total: 1, timestamp: now,
                    models: [makeCodexWindow(
                        account: "a@example.com", name: "Weekly", remainingPercent: 55,
                        start: now.addingTimeInterval(-3 * 86_400),
                        end: now.addingTimeInterval(4 * 86_400))],
                    subscribeTitle: nil, subscribeEndTime: nil)

                let codex = viewModel.menuBarSnapshots.first { $0.provider == .codex }
                XCTAssertNotNil(codex?.paceDeltaPercent,
                                "center = \(center.rawValue) produced no pace at all")
                XCTAssertEqual(codex?.ringPercent, 55,
                               "center = \(center.rawValue) must not move the outer arc")
            }
        }
    }

    func testEveryCenterWindowAgreesForAWeeklyOnlyAccount() {
        var deltas: [MenuBarReserveQuotaWindow: Double] = [:]
        for center in [MenuBarReserveQuotaWindow.current, .weekly, .synchronized] {
            withWeeklyRingViewModel(center: center) { viewModel in
                let now = Date()
                viewModel.usageData = UsageData(
                    provider: .codex, remains: 1, total: 1, timestamp: now,
                    models: [makeCodexWindow(
                        account: "a@example.com", name: "Weekly", remainingPercent: 55,
                        start: now.addingTimeInterval(-3 * 86_400),
                        end: now.addingTimeInterval(4 * 86_400))],
                    subscribeTitle: nil, subscribeEndTime: nil)
                deltas[center] = viewModel.menuBarSnapshots
                    .first { $0.provider == .codex }?.paceDeltaPercent
            }
        }
        let values = Set(deltas.values.map { ($0 * 100).rounded() / 100 })
        XCTAssertEqual(values.count, 1, "same window, same answer: got \(deltas)")
    }

    func testAWeeklyWindowWithoutTimingDataDoesNotBlankTheInnerDisc() {
        // The reported asymmetry: "current cycle" showed pace, "weekly cycle"
        // showed nothing -- for the same window. The weekly lookup *succeeds*
        // here (a row by that name exists) but the row carries only a percentage
        // and no start/end, so it cannot answer "how far into the window are we".
        // Falling back only when a window is *missing* left that hole open.
        withWeeklyRingViewModel(center: .weekly) { viewModel in
            let now = Date()
            let timedShort = makeCodexWindow(
                account: "a@example.com", name: "5h", remainingPercent: 30,
                start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(3_600))
            let percentageOnlyWeekly = makeCodexWindow(
                account: "a@example.com", name: "Weekly", remainingPercent: 55,
                start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
                .withTimingsCleared()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 2, total: 2, timestamp: now,
                models: [timedShort, percentageOnlyWeekly],
                subscribeTitle: nil, subscribeEndTime: nil)

            let codex = viewModel.menuBarSnapshots.first { $0.provider == .codex }
            XCTAssertNotNil(codex?.paceDeltaPercent,
                            "an unusable weekly window must not empty the inner disc")
        }
    }

    func testTheSameAccountAnswersIdenticallyForCurrentAndWeeklyCenter() {
        var deltas: [MenuBarReserveQuotaWindow: Double] = [:]
        for center in [MenuBarReserveQuotaWindow.current, .weekly] {
            withWeeklyRingViewModel(center: center) { viewModel in
                let now = Date()
                let timedShort = makeCodexWindow(
                    account: "a@example.com", name: "5h", remainingPercent: 30,
                    start: now.addingTimeInterval(-3_600), end: now.addingTimeInterval(3_600))
                let percentageOnlyWeekly = makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 55,
                    start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
                    .withTimingsCleared()
                viewModel.usageData = UsageData(
                    provider: .codex, remains: 2, total: 2, timestamp: now,
                    models: [timedShort, percentageOnlyWeekly],
                    subscribeTitle: nil, subscribeEndTime: nil)
                deltas[center] = viewModel.menuBarSnapshots
                    .first { $0.provider == .codex }?.paceDeltaPercent
            }
        }
        XCTAssertNotNil(deltas[.current], "current center lost its pace")
        XCTAssertNotNil(deltas[.weekly], "weekly center lost its pace")
    }

    // MARK: - 环内曲线数据

    func testWeeklyOnlyAccountWithHistoryCarriesATrendIntoTheRing() {
        withWeeklyRingViewModel { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)
            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 6, now: now),
            ])

            // The harness points the inner channel at the current window, so the
            // trend must stay out of the disc and the fan keeps it. See
            // testWeeklyCenterDrawsTheTrendWhenItResolvesToWeekly for the pair.
            let trend = viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend
            XCTAssertNil(trend, "an inner channel set to the current window keeps the fan")
            XCTAssertNotNil(viewModel.menuBarSnapshots.first { $0.provider == .codex }?.paceDeltaPercent)
        }
    }

    /// 内环是独立设置项：只有它解析到周窗口时，趋势才有资格占内圈。
    /// 否则「只有周窗口」的账号会永远丢掉 deficit 视觉通道。
    func testWeeklyCenterDrawsTheTrendWhenItResolvesToWeekly() {
        withWeeklyRingViewModel(center: .weekly) { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)
            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 6, now: now),
            ])

            let trend = viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend
            XCTAssertEqual(trend?.count, 6)
            XCTAssertTrue(trend?.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) } ?? false)
            // The curve ends where the ring is now, so its last point is the
            // remaining percentage the arc is drawn from.
            XCTAssertEqual(trend?.last?.y ?? 0, 0.95, accuracy: 0.001)
        }
    }

    /// 显式把内环从周窗口改到别处，趋势立刻让位给扇形 —— 同一份数据、
    /// 同一批采样，只换内环设置，内圈归属就跟着变。
    func testMovingTheCenterOffWeeklyHandsTheDiscBackToTheFan() {
        withWeeklyRingViewModel(center: .weekly) { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)
            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 6, now: now),
            ])
            XCTAssertNotNil(
                viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend,
                "a weekly center draws the trend")

            viewModel.menuBarReserveQuotaWindow = .current
            viewModel.setRingCenterWindow(.current, for: .codex)
            XCTAssertNil(
                viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend,
                "moving the center off weekly must hand the disc back to the fan")
        }
    }

    /// synchronized 是默认值：内环跟随外环。外环指向 weekly 时内环也解析成
    /// weekly，趋势照常画 —— 默认同步不该顺手把周账号的内圈让给别人。
    func testSynchronizedCenterFollowsTheOuterRingOntoWeekly() {
        withWeeklyRingViewModel(center: .synchronized, outer: .weekly) { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)
            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 6, now: now),
            ])

            XCTAssertEqual(viewModel.ringQuotaWindow(for: .codex), .weekly)
            XCTAssertEqual(
                viewModel.reserveQuotaWindow(for: .codex)
                    .resolved(outerRing: viewModel.ringQuotaWindow(for: .codex)),
                .weekly,
                "synchronized must resolve to whatever the outer ring is using")
            XCTAssertNotNil(
                viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend,
                "synchronized must not silently silence the weekly center")
        }
    }

    func testTheMenuRowIsACurveEvenWithASingleSample() {
        // The left-click row is "progress bar or area chart" -- a structural
        // choice. Flipping between the two made the same quota unreadable, so a
        // single sample is a (very short) curve, not a bar.
        let now = Date()
        let row = makeCodexWindow(
            account: "a@example.com", name: "Weekly", remainingPercent: 73,
            start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
        let curveIDs = QuotaCurveModelSelector.curveModelIDs(
            in: [row], renderableModelIDs: [row.id])
        XCTAssertEqual(curveIDs, [row.id])
    }

    func testTheRingKeepsItsFanUntilThereIsAnActualLine() {
        // This one is about point count, not about the center setting, so point
        // the inner channel at weekly and let the trend own the disc.
        withWeeklyRingViewModel(center: .weekly) { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)
            // One point is a dot, not a line. Replacing the pace fan with a lone
            // dot in a 22pt ring reads as a rendering failure, not as a trend.
            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 1, now: now),
            ])
            XCTAssertNil(viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend,
                         "with one sample the inner disc keeps the fan")
            // The fan itself is still real data for a weekly-only account.
            XCTAssertNotNil(viewModel.menuBarSnapshots.first { $0.provider == .codex }?.paceDeltaPercent)

            viewModel.seedQuotaSamplesForTesting([
                "codex:a@example.com:Weekly": weeklySamples(count: 2, now: now),
            ])
            let trend = viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend
            XCTAssertEqual(trend?.count, 2)
            XCTAssertEqual(trend?.last?.y ?? 0, 0.95, accuracy: 0.001)
        }
    }

    func testNoHistoryAtAllKeepsTheFanToo() {
        withWeeklyRingViewModel { viewModel in
            let now = Date()
            viewModel.usageData = UsageData(
                provider: .codex, remains: 1, total: 1, timestamp: now,
                models: [makeCodexWindow(
                    account: "a@example.com", name: "Weekly", remainingPercent: 73,
                    start: now.addingTimeInterval(-3 * 86_400),
                    end: now.addingTimeInterval(4 * 86_400))],
                subscribeTitle: nil, subscribeEndTime: nil)
            XCTAssertNil(viewModel.menuBarSnapshots.first { $0.provider == .codex }?.ringTrend)
        }
    }

    func testTheHorizontalAxisFollowsSampleTimeNotSampleOrder() {
        let now = Date()
        let model = makeCodexWindow(
            account: "a@example.com", name: "Weekly", remainingPercent: 73,
            start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
        // A point from three days ago sits a third of the way along a seven-day
        // window. Indexing by position in the array would put it on the right.
        let early = ModelQuotaSample(
            timestamp: now.addingTimeInterval(-3 * 86_400), remaining: 100, percent: 100)
        let late = ModelQuotaSample(
            timestamp: now.addingTimeInterval(-2 * 86_400), remaining: 92, percent: 92)
        let points = try? XCTUnwrap(UsageViewModel.ringTrendPoints(for: model, samples: [late, early]))
        XCTAssertEqual(points?.count, 2)
        XCTAssertEqual(points?[0].x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(points?[1].x ?? -1, 1.0 / 7.0, accuracy: 0.001)
    }

    func testTrendIgnoresSamplesLeftOverFromThePreviousWindow() {
        let now = Date()
        let model = makeCodexWindow(
            account: "a@example.com", name: "Weekly", remainingPercent: 73,
            start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
        // Last cycle's leftovers: 40 points of 100% that sit entirely before this
        // window opened. Plotted as-is they read as a cliff from 100 to 73.
        let stale = (0..<40).map { index in
            ModelQuotaSample(
                timestamp: now.addingTimeInterval(-(10 - Double(index) * 0.1) * 86_400),
                remaining: 100, percent: 100)
        }
        XCTAssertNil(UsageViewModel.ringTrendPoints(for: model, samples: stale))
        XCTAssertEqual(
            UsageViewModel.ringTrendPoints(
                for: model, samples: stale + weeklySamples(count: 4, now: now))?.count,
            4)
    }

    func testTrendIsCappedAtTheMenuBarPointLimit() {
        let now = Date()
        let model = makeCodexWindow(
            account: "a@example.com", name: "Weekly", remainingPercent: 73,
            start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
        let trend = UsageViewModel.ringTrendPoints(
            for: model, samples: weeklySamples(count: 200, now: now))
        XCTAssertEqual(trend?.count, MenuBarRingTrend.maximumPoints)
        // The cap keeps the *newest* stretch of history, not the oldest.
        XCTAssertEqual(trend?.last?.y ?? 0, 0.95, accuracy: 0.001)
    }

    func testSamplesWithoutAPercentAreSkipped() {
        let now = Date()
        let model = makeCodexWindow(
            account: "a@example.com", name: "Weekly", remainingPercent: 73,
            start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(4 * 86_400))
        let samples = [
            ModelQuotaSample(timestamp: now.addingTimeInterval(-7_200), remaining: 80, percent: nil),
            ModelQuotaSample(timestamp: now.addingTimeInterval(-3_600), remaining: 80, percent: nil),
            ModelQuotaSample(timestamp: now.addingTimeInterval(-1_800), remaining: 90, percent: 90),
            ModelQuotaSample(timestamp: now.addingTimeInterval(-900), remaining: 92, percent: 92),
        ]
        XCTAssertEqual(UsageViewModel.ringTrendPoints(for: model, samples: samples)?.count, 2)
        XCTAssertTrue(UsageViewModel.ringTrendPoints(for: model, samples: samples)?
            .allSatisfy { $0.y > 0.5 } ?? false)
    }

    // MARK: - 左键菜单

    func testAWatchedWeeklyOnlyRowBecomesTheAccountCurve() {
        let rows = watchedRows(startsAt: Date().addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(rows.count, 1)
        let curveIDs = QuotaCurveModelSelector.curveModelIDs(
            in: rows, renderableModelIDs: Set(rows.map(\.id)))
        XCTAssertEqual(curveIDs, Set(rows.map(\.id)),
                       "a Codex account with no 5h promotes its weekly window to the curve")
    }

    func testAWatchedRowFromAnOlderPublisherDerivesTheWeeklyWindowItself() throws {
        // Publishers that predate the window start send name/percent/reset only.
        // A weekly window is 7 days by definition, so the reader can recover the
        // window without waiting for the publisher to ship the new field --
        // otherwise every existing watch silently stays a bare percentage.
        let rows = watchedRows(startsAt: nil)
        let row = try XCTUnwrap(rows.first)
        XCTAssertNotNil(row.startTime)
        XCTAssertNotNil(row.quotaChartWindow())
        let curveIDs = QuotaCurveModelSelector.curveModelIDs(
            in: rows, renderableModelIDs: Set(rows.map(\.id)))
        XCTAssertEqual(curveIDs, Set(rows.map(\.id)))
    }

    func testTheDerivationOnlyAppliesToWeeklyWindows() {
        let reset = Date().addingTimeInterval(3 * 86_400)
        XCTAssertNotNil(CodexWatchStore.derivedWeeklyWindowStart(name: "Weekly", resetsAt: reset))
        XCTAssertNotNil(CodexWatchStore.derivedWeeklyWindowStart(name: "7d", resetsAt: reset))
        // A 5h window's length depends on when the publishing Mac opened it, so
        // backing one out from its reset time would report a wrong pace.
        XCTAssertNil(CodexWatchStore.derivedWeeklyWindowStart(name: "5h", resetsAt: reset))
        XCTAssertNil(CodexWatchStore.derivedWeeklyWindowStart(name: "Codex Spark 5-hour", resetsAt: reset))
        XCTAssertNil(CodexWatchStore.derivedWeeklyWindowStart(name: "Weekly", resetsAt: nil))
    }

    // MARK: - 渲染

    func testTheCurveFitsBetweenTheProviderLetterAndTheRingsInnerEdge() {
        // Source space is 367 x 410 with the centre at (183.5, 183.5).
        let top = 183.5 + QuotaSymbolRenderer.trendPlotHalfHeight
        let letterBaseline = 286.0
        let ringInnerEdge = 155.975 - 55.05 / 2
        XCTAssertLessThanOrEqual(top, letterBaseline, "a full-scale curve would run into the letter")
        XCTAssertLessThanOrEqual(QuotaSymbolRenderer.trendClipRadius, ringInnerEdge,
                                 "the curve would smear across the arc")
        XCTAssertGreaterThanOrEqual(183.5 - QuotaSymbolRenderer.trendPlotHalfWidth, 0)
        XCTAssertLessThanOrEqual(183.5 + QuotaSymbolRenderer.trendPlotHalfWidth, 367)
    }

    func testATrendDrawnIntoTheRingReachesTheCentre() throws {
        let rendered = try renderRing(trend: trend(0.95, 0.9, 0.86, 0.8, 0.74, 0.7, 0.66, 0.6))
        XCTAssertTrue(rendered.inkInInnerDisc, "the curve never reached the centre of the ring")
    }

    func testTheCurveIsMonotonicInTheRemainingPercentage() throws {
        // A full-height curve and an empty one must not render the same frame,
        // otherwise the vertical mapping is doing nothing at all.
        let high = try renderRing(trend: trend(Array(repeating: 1, count: 6)))
        let low = try renderRing(trend: trend(Array(repeating: 0, count: 6)))
        XCTAssertGreaterThan(high.differingPixels(from: low), 4)
    }

    func testARingWithoutATrendKeepsTheFan() throws {
        let fan = try renderRing(trend: nil)
        let curve = try renderRing(trend: trend(0.2, 0.6, 0.4, 0.8))
        XCTAssertGreaterThan(fan.differingPixels(from: curve), 4)
    }

    // MARK: - 光栅缓存

    func testANewSampleInvalidatesTheCachedRasterEvenWhenRingAndPaceDoNotMove() {
        let base = makeSnapshot(trend: trend(0.9, 0.8, 0.7))
        let next = makeSnapshot(trend: trend(0.9, 0.8, 0.7, 0.6))
        XCTAssertNotEqual(
            Self.renderState(snapshots: [base]), Self.renderState(snapshots: [next]),
            "the curve lives in the inner disc, so the raster key has to notice it")
    }

    func testIdenticalTrendKeepsTheCachedRaster() {
        let base = makeSnapshot(trend: trend(0.9, 0.8, 0.7))
        let same = makeSnapshot(trend: trend(0.9, 0.8, 0.7))
        XCTAssertEqual(Self.renderState(snapshots: [base]), Self.renderState(snapshots: [same]))
    }

    // MARK: - 支撑

    private func makeStore() -> (CodexWatchStore, UserDefaults) {
        let suite = "menubar.weekly.trend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (CodexWatchStore(defaults: defaults), defaults)
    }

    /// 一条被关注的「只有 Weekly」账号在菜单里投影出来的行。
    private func watchedRows(startsAt: Date?) -> [ModelUsageData] {
        let (store, _) = makeStore()
        store.watch("a@example.com")
        store.seedSnapshotForTesting(
            account: "a@example.com",
            snapshot: CodexWatchSnapshot(
                account: "a@example.com", plan: "Pro 5x",
                windows: [CodexWatchWindow(
                    name: "Weekly", remainingPercent: 95,
                    resetsAt: Date().addingTimeInterval(4 * 86_400),
                    sampledAt: Date(), startsAt: startsAt)],
                publishedAt: Date()))
        return store.watchedModels
    }

    private func makeCodexWindow(
        account: String, name: String, remainingPercent: Int, start: Date, end: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: .codex, accountName: account, modelName: name,
            currentIntervalTotal: 100, currentIntervalUsed: remainingPercent,
            weeklyTotal: 0, weeklyUsed: 0, remainsTime: Int(end.timeIntervalSinceNow * 1000),
            startTime: start, endTime: end,
            weeklyStartTime: nil, weeklyEndTime: nil,
            valueSuffix: "%", detailText: "Pro 5x · Watch",
            currentIntervalRemainingPercent: remainingPercent, weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil, progressBarRightText: nil, sampledAt: nil)
    }

    /// 逐点下降的周窗口历史：第一个点 100%，最后一个点固定落在 95%。
    private func weeklySamples(count: Int, now: Date) -> [ModelQuotaSample] {
        (0..<count).map { index in
            let offset = count - 1 - index
            return ModelQuotaSample(
                timestamp: now.addingTimeInterval(-Double(offset) * 3_600),
                remaining: 95 + offset, percent: 95 + offset)
        }
    }

    /// 一个把环外层设成「5h」的菜单栏环境：只有 Weekly 的账号必须
    /// 自己认出没有 5h，而不是被这个设置清空。
    /// `center` / `outer` 决定内外圈各自解析到哪个窗口，趋势只在内圈落回
    /// weekly 时才占内圈。
    private func withWeeklyRingViewModel(
        center: MenuBarReserveQuotaWindow = .current,
        outer: MenuBarRingQuotaWindow = .current,
        _ body: (UsageViewModel) throws -> Void
    ) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarRingQuotaWindow.storageKey, MenuBarReserveQuotaWindow.storageKey,
            MenuBarAppearance.storageKey, MenuBarRingDisplayMode.storageKey,
            MenuBarRingPreferences.providersKey,
            // Per-provider overrides win over the global defaults, and they are
            // written straight to UserDefaults. Leaving them behind lets one
            // test's setRingCenterWindow silently decide the next test's center.
            MenuBarProviderRingWindows.storageKey,
        ]
        let saved = keys.map { (key: $0, value: defaults.object(forKey: $0)) }
        defer {
            for previous in saved {
                if let value = previous.value { defaults.set(value, forKey: previous.key) }
                else { defaults.removeObject(forKey: previous.key) }
            }
        }
        defaults.set(outer.rawValue, forKey: MenuBarRingQuotaWindow.storageKey)
        defaults.set(center.rawValue, forKey: MenuBarReserveQuotaWindow.storageKey)
        // Start from no per-provider override so the global `center` above is
        // what actually resolves, whatever the previous test left behind.
        defaults.removeObject(forKey: MenuBarProviderRingWindows.storageKey)
        defaults.set(MenuBarAppearance.compactRing.rawValue, forKey: MenuBarAppearance.storageKey)
        defaults.set(MenuBarRingDisplayMode.all.rawValue, forKey: MenuBarRingDisplayMode.storageKey)
        defaults.set(["codex"], forKey: MenuBarRingPreferences.providersKey)

        let viewModel = UsageViewModel()
        viewModel.menuBarRingSelectedProviders = [.codex]
        try body(viewModel)
    }

    /// 铺满绘图区的测试曲线：横轴从左到右均匀分布。
    private func trend(_ values: Double...) -> [MenuBarRingTrendPoint] {
        trend(values)
    }

    private func trend(_ values: [Double]) -> [MenuBarRingTrendPoint] {
        let last = max(1, values.count - 1)
        return values.enumerated().map { index, value in
            MenuBarRingTrendPoint(
                x: Double(index) / Double(last),
                y: min(1, max(0, value)))
        }
    }

    private func makeSnapshot(trend: [MenuBarRingTrendPoint]?) -> MenuBarSnapshot {
        MenuBarSnapshot(
            provider: .codex, modelName: "Weekly", remainingPercent: 73,
            ringPercent: 73, paceDeltaPercent: 0, ringTrend: trend,
            resetsAt: nil, state: .ready, isLowQuota: false, tooltip: "Test")
    }

    private static func renderState(snapshots: [MenuBarSnapshot]) -> CompactStatusRenderState {
        CompactStatusRenderState(
            snapshots: snapshots, connectivity: .reachable, pace: .staged,
            taskWaveLayout: .evenlySpaced, selfTesting: false, tasks: [:],
            padding: 0, spacing: 1, appearance: "aqua", scale: 2, height: 22,
            reduceMotion: false, placeholderStyle: .openAIConnectivity)
    }

    @MainActor
    private func renderRing(trend: [MenuBarRingTrendPoint]?, scale: Int = 2) throws -> RingPixels {
        let side = 22 * scale
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 22, height: 22)
        let view = StatusBarCompactRingView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        view.setSnapshot(makeSnapshot(trend: trend), connectivity: .reachable, accessibilityLabel: "Test")
        view.setOfflinePulseOpacityForTesting(1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { view.draw(view.bounds) }

        var ink = [Bool](repeating: false, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                ink[y * side + x] = (color?.alphaComponent ?? 0) > 0.3
            }
        }
        return RingPixels(ink: ink, side: side)
    }

    private struct RingPixels {
        let ink: [Bool]
        let side: Int

        /// 中间那块空腔（源空间半径 < 70）—— 曲线必须落在这里。
        var inkInInnerDisc: Bool {
            let center = Double(side) / 2
            for y in 0..<side {
                for x in 0..<side {
                    let dx = Double(x) - center, dy = Double(y) - center
                    if dx * dx + dy * dy < 70 * 70, ink[y * side + x] { return true }
                }
            }
            return false
        }

        func differingPixels(from other: RingPixels) -> Int {
            zip(ink, other.ink).reduce(0) { count, pair in count + (pair.0 == pair.1 ? 0 : 1) }
        }
    }
}


/// 一个和原 model 百分比相同、但没有任何起止时间的副本 —— 云端补全与
/// 关注快照拿到的就是这种行。
private extension ModelUsageData {
    func withTimingsCleared() -> ModelUsageData {
        ModelUsageData(
            provider: provider, accountName: accountName, modelName: modelName,
            currentIntervalTotal: currentIntervalTotal,
            currentIntervalUsed: currentIntervalUsed,
            weeklyTotal: weeklyTotal, weeklyUsed: weeklyUsed,
            remainsTime: remainsTime, startTime: nil, endTime: endTime,
            weeklyStartTime: nil, weeklyEndTime: nil,
            valueSuffix: valueSuffix, detailText: detailText,
            currentIntervalRemainingPercent: currentIntervalRemainingPercent,
            weeklyRemainingPercent: weeklyRemainingPercent,
            progressBarPercentOverride: progressBarPercentOverride,
            progressBarRightText: progressBarRightText, sampledAt: sampledAt)
    }
}
