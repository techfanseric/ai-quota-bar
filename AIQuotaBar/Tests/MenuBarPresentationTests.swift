import XCTest
@testable import AIQuotaBar

final class MenuBarPresentationTests: XCTestCase {
    func testPaceGlyphUsesLeftDeficitAndRightReserveBuckets() {
        XCTAssertEqual(
            MenuBarPaceGlyph(deltaPercent: nil),
            MenuBarPaceGlyph(deltaPercent: 0))
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -2).direction, .onTrack)

        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -3).direction, .deficit)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -3).fillFraction, 1.0 / 3.0)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -8).fillFraction, 2.0 / 3.0)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -20).fillFraction, 1)

        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: 3).direction, .reserve)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: 3).fillFraction, 1.0 / 3.0)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: 8).fillFraction, 2.0 / 3.0)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: 20).fillFraction, 1)
    }

    func testContinuousPaceGlyphMapsExactPercentages() {
        let mildDeficit = MenuBarPaceGlyph(deltaPercent: -8, mode: .continuous)
        XCTAssertEqual(mildDeficit.direction, .deficit)
        XCTAssertEqual(mildDeficit.fillFraction, 0.08, accuracy: 0.0001)

        let reserve = MenuBarPaceGlyph(deltaPercent: 42, mode: .continuous)
        XCTAssertEqual(reserve.direction, .reserve)
        XCTAssertEqual(reserve.fillFraction, 0.42, accuracy: 0.0001)

        XCTAssertEqual(
            MenuBarPaceGlyph(deltaPercent: 0, mode: .continuous).direction,
            .onTrack)
        XCTAssertEqual(
            MenuBarPaceGlyph(deltaPercent: 140, mode: .continuous).fillFraction,
            1)
    }

    func testSelfTestCyclesThroughPaceStatesAndKeepsRingInBounds() {
        XCTAssertLessThan(MenuBarSelfTestFrame.frame(elapsed: 0.2).paceDeltaPercent, 0)
        XCTAssertEqual(MenuBarSelfTestFrame.frame(elapsed: 1.2).paceDeltaPercent, 0)
        XCTAssertGreaterThan(MenuBarSelfTestFrame.frame(elapsed: 2.2).paceDeltaPercent, 0)

        for sample in 0 ... 60 {
            let frame = MenuBarSelfTestFrame.frame(elapsed: Double(sample) / 10)
            XCTAssertGreaterThanOrEqual(frame.ringPercent, 8)
            XCTAssertLessThanOrEqual(frame.ringPercent, 92)
        }
        XCTAssertEqual(
            MenuBarSelfTestFrame.frame(elapsed: 0),
            MenuBarSelfTestFrame.frame(elapsed: MenuBarSelfTestFrame.cycleDuration))

        let staged = MenuBarSelfTestFrame.frame(elapsed: 0.2, paceDisplayMode: .staged)
        let continuous = MenuBarSelfTestFrame.frame(elapsed: 0.2, paceDisplayMode: .continuous)
        XCTAssertGreaterThan(
            abs(continuous.paceDeltaPercent),
            abs(staged.paceDeltaPercent))
    }

    func testWeeklyMetricRejectsRegressionBeforeHistoricalReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let activeEntry = UtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-600),
            usedPercent: 40,
            resetsAt: now.addingTimeInterval(3 * 24 * 3600))

        let resolved = MenuBarWeeklyMetricResolver.preferredHistoricalEntry(
            liveUsedPercent: 0,
            historyEntries: [activeEntry],
            now: now)

        XCTAssertEqual(resolved, activeEntry)
    }

    func testWeeklyMetricAcceptsResetOrNonRegressingLiveValue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let completedEntry = UtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-3600),
            usedPercent: 40,
            resetsAt: now.addingTimeInterval(-1))
        let activeEntry = UtilizationHistoryEntry(
            capturedAt: now.addingTimeInterval(-600),
            usedPercent: 40,
            resetsAt: now.addingTimeInterval(3 * 24 * 3600))

        XCTAssertNil(MenuBarWeeklyMetricResolver.preferredHistoricalEntry(
            liveUsedPercent: 0,
            historyEntries: [completedEntry],
            now: now))
        XCTAssertNil(MenuBarWeeklyMetricResolver.preferredHistoricalEntry(
            liveUsedPercent: 39,
            historyEntries: [activeEntry],
            now: now))
    }

    @MainActor
    func testPaceDisplayModeLoadsAndPersists() {
        let defaults = UserDefaults.standard
        let key = MenuBarPaceDisplayMode.storageKey
        let previousValue = defaults.object(forKey: key)
        let cloudKey = CloudSyncSettings.enabledKey
        let previousCloudValue = defaults.object(forKey: cloudKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            if let previousCloudValue {
                defaults.set(previousCloudValue, forKey: cloudKey)
            } else {
                defaults.removeObject(forKey: cloudKey)
            }
        }

        defaults.set(MenuBarPaceDisplayMode.continuous.rawValue, forKey: key)
        defaults.set(false, forKey: cloudKey)
        let viewModel = UsageViewModel()
        XCTAssertEqual(viewModel.menuBarPaceDisplayMode, .continuous)

        viewModel.menuBarPaceDisplayMode = .staged
        XCTAssertEqual(defaults.string(forKey: key), MenuBarPaceDisplayMode.staged.rawValue)
    }

    @MainActor
    func testCodexCompactRingUsesWeeklyConsumedPercent() {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarAppearance.storageKey,
            MenuBarPaceDisplayMode.storageKey,
            CloudSyncSettings.enabledKey,
        ]
        let previousValues = keys.map { key in
            (key: key, value: defaults.object(forKey: key))
        }
        defer {
            for previous in previousValues {
                if let value = previous.value {
                    defaults.set(value, forKey: previous.key)
                } else {
                    defaults.removeObject(forKey: previous.key)
                }
            }
        }

        defaults.set(MenuBarContentSelection.codex.rawValue, forKey: MenuBarContentSelection.storageKey)
        defaults.set(MenuBarAppearance.compactRing.rawValue, forKey: MenuBarAppearance.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)

        let now = Date()
        let fiveHour = makeModel(provider: .codex, name: "5h", remainingPercent: 80, now: now)
        let weekly = makeModel(provider: .codex, name: "Weekly", remainingPercent: 65, now: now)
        let viewModel = UsageViewModel()

        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 2,
            total: 2,
            timestamp: now,
            models: [fiveHour, weekly],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        XCTAssertEqual(viewModel.menuBarSnapshot.remainingPercent, 80)
        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 35)
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("Weekly"))
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("35%"))

        let exhaustedWeekly = makeModel(
            provider: .codex,
            name: "Weekly",
            remainingPercent: 0,
            now: now)
        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 1,
            total: 2,
            timestamp: now,
            models: [fiveHour, exhaustedWeekly],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 100)
        XCTAssertLessThan(viewModel.menuBarSnapshot.paceDeltaPercent ?? 0, 0)
    }

    @MainActor
    func testAutomaticSelectsUrgentProviderAndFixedSelectionOverridesIt() {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarAppearance.storageKey,
            MenuBarPaceDisplayMode.storageKey,
            CloudSyncSettings.enabledKey,
        ]
        let previousValues = keys.map { key in
            (key: key, value: defaults.object(forKey: key))
        }
        defer {
            for previous in previousValues {
                if let value = previous.value {
                    defaults.set(value, forKey: previous.key)
                } else {
                    defaults.removeObject(forKey: previous.key)
                }
            }
        }

        defaults.set(MenuBarContentSelection.automatic.rawValue, forKey: MenuBarContentSelection.storageKey)
        defaults.set(MenuBarAppearance.compactRing.rawValue, forKey: MenuBarAppearance.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)

        let now = Date()
        let codex = makeModel(provider: .codex, name: "5h", remainingPercent: 80, now: now)
        let miniMax = makeModel(provider: .miniMax, name: "MiniMax", remainingPercent: 10, now: now)
        let viewModel = UsageViewModel()

        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 2,
            total: 2,
            timestamp: now,
            models: [codex, miniMax],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        XCTAssertEqual(viewModel.menuBarSnapshot.provider, .miniMax)
        XCTAssertEqual(viewModel.menuBarSnapshot.state, .ready)
        XCTAssertEqual(viewModel.menuBarSnapshot.remainingPercent, 10)

        viewModel.menuBarContentSelection = .codex

        XCTAssertEqual(viewModel.menuBarSnapshot.provider, .codex)
        XCTAssertEqual(viewModel.menuBarSnapshot.remainingPercent, 80)
        XCTAssertEqual(
            defaults.string(forKey: MenuBarContentSelection.storageKey),
            MenuBarContentSelection.codex.rawValue)

        viewModel.menuBarContentSelection = .automatic
        viewModel.menuBarAppearance = .detailedText

        let detailedLines = viewModel.statusBarText.split(separator: "\n").map(String.init)
        XCTAssertEqual(detailedLines.count, 2)
        XCTAssertTrue(detailedLines[0].hasPrefix("M:"), "The urgent automatic provider should stay first")
        XCTAssertTrue(detailedLines[1].hasPrefix("C:"))

        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: now,
            models: [codex],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        XCTAssertFalse(viewModel.statusBarText.contains("M:"))
        XCTAssertTrue(viewModel.statusBarText.hasPrefix("Codex\n"))
    }

    private func makeModel(
        provider: UsageProvider,
        name: String,
        remainingPercent: Int,
        now: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: provider,
            accountName: nil,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(3_600),
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
