import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar

final class MenuBarPresentationTests: XCTestCase {
    @MainActor
    func testMenuSizingUpdatesHostingViewWithoutRebuildingRoot() {
        let sizing = MenuPresentationSizing(
            maximumScrollableHeight: 700)
        let hostingView = NSHostingView(
            rootView: MenuSizingProbeView(sizing: sizing))

        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(hostingView.fittingSize.height, 700)

        sizing.maximumScrollableHeight = 394
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(hostingView.fittingSize.height, 394)
    }

    func testNativeMenuAppearanceFollowsApplicationAppearance() throws {
        let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(
            StatusItemMenuAppearance.resolvedName(from: lightAppearance),
            .aqua)

        let darkAppearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(
            StatusItemMenuAppearance.resolvedName(from: darkAppearance),
            .darkAqua)
    }

    func testRightPanelCentersUnderStatusItem() {
        let visibleFrame = NSRect(
            x: -1_000,
            y: 0,
            width: 3_000,
            height: 878)

        let compactFrame = MenuBarPanelPlacement(
            buttonFrame: NSRect(
                x: 0,
                y: 878,
                width: 22,
                height: 22),
            visibleFrame: visibleFrame)
            .panelFrame(contentSize: NSSize(
                width: MenuBarPanelLayout.width,
                height: 700))
        XCTAssertEqual(compactFrame.minX, -137)

        let detailedFrame = MenuBarPanelPlacement(
            buttonFrame: NSRect(
                x: 0,
                y: 878,
                width: 110,
                height: 22),
            visibleFrame: visibleFrame)
            .panelFrame(contentSize: NSSize(
                width: MenuBarPanelLayout.width,
                height: 700))
        XCTAssertEqual(detailedFrame.minX, -93)
    }

    func testRightPanelStartsBelowMenuBarSafeArea() {
        let frame = MenuBarPanelPlacement(
            buttonFrame: NSRect(x: 900, y: 878, width: 22, height: 22),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 878))
            .panelFrame(contentSize: NSSize(
                width: MenuBarPanelLayout.width,
                height: 720))

        XCTAssertEqual(frame.minX, 763)
        XCTAssertEqual(
            frame.maxY,
            878 - MenuBarPanelLayout.topGap)
    }

    func testRightPanelPreservesVerticallyArrangedDisplayOrigin() {
        let visibleFrame = NSRect(
            x: 0,
            y: 1169,
            width: 2560,
            height: 1410)
        let frame = MenuBarPanelPlacement(
            buttonFrame: NSRect(
                x: 1200,
                y: visibleFrame.maxY,
                width: 22,
                height: 30),
            visibleFrame: visibleFrame)
            .panelFrame(contentSize: NSSize(
                width: MenuBarPanelLayout.width,
                height: 1269))

        XCTAssertEqual(frame.minX, 1063)
        XCTAssertEqual(
            frame.maxY,
            2579 - MenuBarPanelLayout.topGap)
    }

    func testRightPanelClampsToTargetDisplayWithNegativeOrigin() {
        let visibleFrame = NSRect(x: -1440, y: -900, width: 1440, height: 876)

        let leftFrame = MenuBarPanelPlacement(
            buttonFrame: NSRect(x: -1435, y: -24, width: 22, height: 24),
            visibleFrame: visibleFrame)
            .panelFrame(contentSize: NSSize(
                width: MenuBarPanelLayout.width,
                height: 700))
        XCTAssertEqual(leftFrame.minX, visibleFrame.minX)
        XCTAssertEqual(
            leftFrame.maxY,
            visibleFrame.maxY - MenuBarPanelLayout.topGap)

        let rightFrame = MenuBarPanelPlacement(
            buttonFrame: NSRect(x: -30, y: -24, width: 22, height: 24),
            visibleFrame: visibleFrame)
            .panelFrame(contentSize: NSSize(
                width: MenuBarPanelLayout.width,
                height: 700))
        XCTAssertEqual(
            rightFrame.minX,
            visibleFrame.maxX - MenuBarPanelLayout.width)
        XCTAssertEqual(
            rightFrame.maxY,
            visibleFrame.maxY - MenuBarPanelLayout.topGap)
    }

    func testMenuHeightShrinksForShortTargetDisplay() {
        XCTAssertEqual(
            MenuBarPanelLayout.maximumHeight(
                visibleHeight: 900),
            810)
        XCTAssertEqual(
            MenuBarPanelLayout.maximumScrollableHeight(
                visibleHeight: 900),
            754)

        let shortMenuHeight = MenuBarPanelLayout.maximumHeight(
            visibleHeight: 500)
        let shortScrollableHeight =
            MenuBarPanelLayout.maximumScrollableHeight(
                visibleHeight: 500)
        XCTAssertEqual(shortMenuHeight, 450)
        XCTAssertEqual(shortScrollableHeight, 394)
        XCTAssertLessThan(shortScrollableHeight, 540)
        XCTAssertLessThanOrEqual(shortMenuHeight, 500)
    }

    @MainActor
    func testRightPanelKeepsCompactArrowlessChrome() {
        XCTAssertEqual(
            ClashPopoverLayout.width,
            MenuBarPanelLayout.width)
        XCTAssertEqual(MenuBarPanelLayout.cornerRadius, 12)

        let panel = MenuBarPanel()
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.styleMask.contains(.titled))
    }

    @MainActor
    func testQuotaViewIsHostedByNativeMenu() {
        let contentView = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: MenuBarPanelLayout.width,
            height: 500))
        let nativeMenu = MenuBarNativeMenu.make(
            contentView: contentView)

        XCTAssertEqual(
            String(describing: type(of: nativeMenu.menu)),
            "NSMenu")
        XCTAssertEqual(nativeMenu.menu.items.count, 1)
        XCTAssertFalse(nativeMenu.menu.autoenablesItems)
        XCTAssertTrue(nativeMenu.item.isEnabled)
        XCTAssertTrue(nativeMenu.item.view === contentView)
    }

    func testPaceGlyphUsesLeftDeficitAndRightReserveBuckets() {
        XCTAssertEqual(
            MenuBarPaceGlyph(deltaPercent: nil),
            MenuBarPaceGlyph(deltaPercent: 0))
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -2).direction, .onTrack)

        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -3).direction, .deficit)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -3).fillFraction, 0.25)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -8).fillFraction, 0.5)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: -20).fillFraction, 0.75)
        XCTAssertEqual(
            MenuBarPaceGlyph(
                deltaPercent: -MenuBarPaceGlyph.fullScaleDeltaPercent
            ).fillFraction,
            1)

        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: 3).direction, .reserve)
        XCTAssertEqual(MenuBarPaceGlyph(deltaPercent: 3).fillFraction, 0.25)
        XCTAssertEqual(
            MenuBarPaceGlyph(
                deltaPercent: MenuBarPaceGlyph.percentPointsPerDay
            ).fillFraction,
            0.5)
        XCTAssertEqual(
            MenuBarPaceGlyph(
                deltaPercent: MenuBarPaceGlyph.fullScaleDeltaPercent
            ).fillFraction,
            1)
    }

    func testContinuousPaceGlyphMapsOneDayToHalfAndTwoDaysToFull() {
        let onePercentDeficit = MenuBarPaceGlyph(deltaPercent: -1, mode: .continuous)
        XCTAssertEqual(onePercentDeficit.direction, .deficit)
        XCTAssertEqual(
            onePercentDeficit.fillFraction,
            1 / MenuBarPaceGlyph.fullScaleDeltaPercent,
            accuracy: 0.0001)

        let mildDeficit = MenuBarPaceGlyph(deltaPercent: -8, mode: .continuous)
        XCTAssertEqual(mildDeficit.direction, .deficit)
        XCTAssertEqual(
            mildDeficit.fillFraction,
            8 / MenuBarPaceGlyph.fullScaleDeltaPercent,
            accuracy: 0.0001)

        let oneDayReserve = MenuBarPaceGlyph(
            deltaPercent: MenuBarPaceGlyph.percentPointsPerDay,
            mode: .continuous)
        XCTAssertEqual(oneDayReserve.direction, .reserve)
        XCTAssertEqual(oneDayReserve.fillFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            MenuBarPaceGlyph(
                deltaPercent: -MenuBarPaceGlyph.percentPointsPerDay,
                mode: .continuous
            ).fillFraction,
            0.5,
            accuracy: 0.0001)

        let twoDayDeficit = MenuBarPaceGlyph(
            deltaPercent: -MenuBarPaceGlyph.fullScaleDeltaPercent,
            mode: .continuous)
        XCTAssertEqual(twoDayDeficit.direction, .deficit)
        XCTAssertEqual(twoDayDeficit.fillFraction, 1, accuracy: 0.0001)
        XCTAssertEqual(
            MenuBarPaceGlyph(
                deltaPercent: MenuBarPaceGlyph.fullScaleDeltaPercent,
                mode: .continuous
            ).fillFraction,
            1,
            accuracy: 0.0001)

        XCTAssertEqual(
            MenuBarPaceGlyph(deltaPercent: 0, mode: .continuous).direction,
            .onTrack)
        XCTAssertEqual(
            MenuBarPaceGlyph(deltaPercent: 140, mode: .continuous).fillFraction,
            1)
    }

    func testActiveBorderOnlyMarksDeviationBeyondTwoDays() {
        let stagedFullBeforeTwoDays = MenuBarPaceGlyph(
            deltaPercent: MenuBarPaceGlyph.fullScaleDeltaPercent - 1,
            mode: .staged)
        XCTAssertEqual(stagedFullBeforeTwoDays.fillFraction, 1)
        XCTAssertFalse(stagedFullBeforeTwoDays.showsActiveBorder)

        for direction in [-1.0, 1.0] {
            let exactlyTwoDays = MenuBarPaceGlyph(
                deltaPercent: direction * MenuBarPaceGlyph.fullScaleDeltaPercent,
                mode: .continuous)
            XCTAssertEqual(exactlyTwoDays.fillFraction, 1)
            XCTAssertFalse(exactlyTwoDays.showsActiveBorder)

            let beyondTwoDays = MenuBarPaceGlyph(
                deltaPercent: direction * (MenuBarPaceGlyph.fullScaleDeltaPercent + 0.01),
                mode: .continuous)
            XCTAssertEqual(beyondTwoDays.fillFraction, 1)
            XCTAssertTrue(beyondTwoDays.showsActiveBorder)
        }
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

        for mode in MenuBarPaceDisplayMode.allCases {
            let startingFrame = MenuBarSelfTestFrame.frame(
                elapsed: 0.01,
                paceDisplayMode: mode)
            let endingFrame = MenuBarSelfTestFrame.frame(
                elapsed: 0.99,
                paceDisplayMode: mode)
            let startingFill = MenuBarPaceGlyph(
                deltaPercent: startingFrame.paceDeltaPercent,
                mode: mode).fillFraction
            let endingFill = MenuBarPaceGlyph(
                deltaPercent: endingFrame.paceDeltaPercent,
                mode: mode).fillFraction
            XCTAssertLessThan(startingFill, endingFill)
            XCTAssertGreaterThan(endingFill, 0.99)
        }
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

        defaults.removeObject(forKey: key)
        defaults.set(false, forKey: cloudKey)
        let viewModel = UsageViewModel()
        XCTAssertEqual(viewModel.menuBarPaceDisplayMode, .continuous)

        viewModel.menuBarPaceDisplayMode = .staged
        XCTAssertEqual(defaults.string(forKey: key), MenuBarPaceDisplayMode.staged.rawValue)
    }

    @MainActor
    func testCodexCompactRingUsesWeeklyRemainingPercent() {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarAppearance.storageKey,
            MenuBarPaceDisplayMode.storageKey,
            MenuBarRingQuotaWindow.storageKey,
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
        defaults.set(MenuBarRingQuotaWindow.weekly.rawValue, forKey: MenuBarRingQuotaWindow.storageKey)
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
        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 65)
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("Weekly"))
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("65%"))

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

        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 0)
        XCTAssertLessThan(viewModel.menuBarSnapshot.paceDeltaPercent ?? 0, 0)
    }

    @MainActor
    func testKimiCompactRingUsesConfigurableWeeklyQuota() {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarAppearance.storageKey,
            MenuBarRingQuotaWindow.storageKey,
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

        defaults.set(
            MenuBarContentSelection.kimi.rawValue,
            forKey: MenuBarContentSelection.storageKey)
        defaults.set(
            MenuBarAppearance.compactRing.rawValue,
            forKey: MenuBarAppearance.storageKey)
        defaults.set(
            MenuBarRingQuotaWindow.weekly.rawValue,
            forKey: MenuBarRingQuotaWindow.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)

        let now = Date()
        let fiveHour = makeModel(
            provider: .kimi,
            name: "5h",
            remainingPercent: 82,
            now: now)
        let weekly = makeModel(
            provider: .kimi,
            name: "7d",
            remainingPercent: 37,
            now: now)
        let viewModel = UsageViewModel()
        viewModel.usageData = UsageData(
            provider: .kimi,
            remains: 2,
            total: 2,
            timestamp: now,
            models: [fiveHour, weekly],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        XCTAssertEqual(viewModel.menuBarSnapshot.remainingPercent, 82)
        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 37)
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("37%"))

        viewModel.menuBarRingQuotaWindow = .current
        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 82)
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

    @MainActor
    func testAutomaticCompactModeBuildsIndependentCodexAndKimiRings() {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarAppearance.storageKey,
            MenuBarRingQuotaWindow.storageKey,
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

        defaults.set(
            MenuBarContentSelection.all.rawValue,
            forKey: MenuBarContentSelection.storageKey)
        defaults.set(
            MenuBarAppearance.compactRing.rawValue,
            forKey: MenuBarAppearance.storageKey)
        defaults.set(
            MenuBarRingQuotaWindow.weekly.rawValue,
            forKey: MenuBarRingQuotaWindow.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)

        let now = Date()
        let codexFiveHour = makeModel(
            provider: .codex,
            name: "5h",
            remainingPercent: 80,
            now: now)
        let codexWeekly = makeModel(
            provider: .codex,
            name: "Weekly",
            remainingPercent: 65,
            now: now)
        let kimiFiveHour = makeModel(
            provider: .kimi,
            name: "5h",
            remainingPercent: 76,
            now: now)
        let kimiWeekly = makeModel(
            provider: .kimi,
            name: "7d",
            remainingPercent: 42,
            now: now)
        let miniMax = makeModel(
            provider: .miniMax,
            name: "MiniMax",
            remainingPercent: 23,
            now: now)
        let viewModel = UsageViewModel()

        viewModel.usageData = UsageData(
            provider: .codex,
            remains: 3,
            total: 3,
            timestamp: now,
            models: [miniMax, kimiFiveHour, kimiWeekly, codexFiveHour, codexWeekly],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        XCTAssertEqual(viewModel.menuBarSnapshots.map(\.provider), [.codex, .kimi])
        XCTAssertEqual(viewModel.menuBarSnapshots.map(\.ringPercent), [65, 42])

        viewModel.menuBarContentSelection = .kimi
        XCTAssertEqual(viewModel.menuBarSnapshots.map(\.provider), [.kimi])
        XCTAssertEqual(viewModel.menuBarSnapshots.first?.ringPercent, 42)
    }

    func testCompactSelectionSupportsAlwaysWorkAwareAndFixedModes() {
        let codex = makeSnapshot(provider: .codex, ringPercent: 65)
        let kimi = makeSnapshot(provider: .kimi, ringPercent: 42)
        let miniMax = makeSnapshot(provider: .miniMax, ringPercent: 10)
        let snapshots = [codex, kimi, miniMax]

        XCTAssertEqual(
            MenuBarCompactSnapshotSelector.select(
                selection: .all,
                snapshots: snapshots,
                activeProviders: []),
            [codex, kimi])
        XCTAssertEqual(
            MenuBarCompactSnapshotSelector.select(
                selection: .automatic,
                snapshots: snapshots,
                activeProviders: [.codex, .kimi]),
            [codex, kimi])
        XCTAssertEqual(
            MenuBarCompactSnapshotSelector.select(
                selection: .automatic,
                snapshots: snapshots,
                activeProviders: [.kimi]),
            [kimi])
        XCTAssertEqual(
            MenuBarCompactSnapshotSelector.select(
                selection: .automatic,
                snapshots: snapshots,
                activeProviders: []),
            [kimi],
            "Idle work-aware mode should ignore MiniMax and show the lowest remaining supported provider.")
        XCTAssertEqual(
            MenuBarCompactSnapshotSelector.select(
                selection: .miniMax,
                snapshots: [miniMax],
                activeProviders: []),
            [miniMax])
    }

    @MainActor
    func testCompactRingStripExpandsByOneRingWidthPerProvider() {
        let view = StatusBarCompactRingsView()
        let snapshots = [
            makeSnapshot(provider: .codex, ringPercent: 65),
            makeSnapshot(provider: .kimi, ringPercent: 42),
        ]

        view.setSnapshots(
            snapshots,
            codexConnectivity: .reachable,
            paceDisplayMode: .staged,
            isSelfTesting: false,
            activeTaskCounts: [:],
            accessibilityLabel: "Codex and Kimi")

        XCTAssertEqual(view.preferredWidth, 40)
        view.frame = NSRect(x: 0, y: 0, width: 40, height: 22)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.subviews.map(\.frame), [
            NSRect(x: 0.5, y: 0, width: 19, height: 22),
            NSRect(x: 20.5, y: 0, width: 19, height: 22),
        ])

        view.setSnapshots(
            snapshots,
            codexConnectivity: .reachable,
            paceDisplayMode: .staged,
            isSelfTesting: false,
            activeTaskCounts: [:],
            horizontalPadding: 2,
            ringSpacing: 4,
            accessibilityLabel: "Codex and Kimi")
        XCTAssertEqual(view.preferredWidth, 46)
    }

    @MainActor
    func testWorkAwareLoadingStateAlwaysKeepsAVisibleRing() {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarAppearance.storageKey,
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

        defaults.set(
            MenuBarContentSelection.automatic.rawValue,
            forKey: MenuBarContentSelection.storageKey)
        defaults.set(
            MenuBarAppearance.compactRing.rawValue,
            forKey: MenuBarAppearance.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)

        let viewModel = UsageViewModel()
        viewModel.isLoading = true
        viewModel.usageData = nil
        let displayed = MenuBarCompactSnapshotSelector.select(
            selection: .automatic,
            snapshots: viewModel.menuBarSnapshots,
            activeProviders: [])

        XCTAssertFalse(displayed.isEmpty)
        XCTAssertEqual(displayed.first?.state, .loading)
        XCTAssertNotEqual(displayed.first?.provider, .miniMax)
    }

    private func makeSnapshot(
        provider: UsageProvider,
        ringPercent: Double
    ) -> MenuBarSnapshot {
        MenuBarSnapshot(
            provider: provider,
            modelName: provider.displayName,
            remainingPercent: ringPercent,
            ringPercent: ringPercent,
            paceDeltaPercent: 0,
            resetsAt: nil,
            state: .ready,
            isLowQuota: false,
            tooltip: provider.displayName)
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

private struct MenuSizingProbeView: View {
    @Bindable var sizing: MenuPresentationSizing

    var body: some View {
        Color.clear
            .frame(
                width: 10,
                height: sizing.maximumScrollableHeight)
    }
}
