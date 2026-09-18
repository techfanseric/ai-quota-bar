import AppKit
import SwiftUI
import XCTest
import CodexLocalUsageCore
@testable import AIQuotaBar

@MainActor final class LocalUsageViewTests: XCTestCase {
    func testEmptyInstallationDoesNotCreateProviderErrors() async {
        let model = UsageViewModel(providerPresence: { _ in false })
        XCTAssertTrue(model.registeredProviders.isEmpty)
        await model.refresh(showIconSelfTest: false)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.menuBarSnapshot.state, .needsSetup)
        XCTAssertTrue(model.providerErrors.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func testMatrixHasExactlyThirtyRealDaysAndDistinguishesMissingValues() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = Date(timeIntervalSince1970: 1_789_700_000)
        let events = LocalUsageSamplePreview.events(now: now, calendar: calendar)
        let daily = UsageHistory.buckets(events: events, prices: [], days: 30, now: now, calendar: calendar)
        let slots = UsageActivityLayout.slots(dates: daily.map(\.start), calendar: calendar)
        XCTAssertEqual(slots.compactMap { $0 }, Array(0..<30))
        XCTAssertEqual(slots.count % 7, 0)
        XCTAssertNil(UsageActivityLayout.intensity(value: nil, maximum: 100))
        XCTAssertEqual(UsageActivityLayout.intensity(value: 0, maximum: 100), 0)
        XCTAssertEqual(UsageActivityLayout.intensity(value: 1, maximum: 100), 0.25)
        XCTAssertEqual(UsageActivityLayout.intensity(value: 100, maximum: 100), 1)
    }

    func testCalloutOriginHugsTheHoveredCellAndStaysInsideTheContainer() {
        let container = CGSize(width: 240, height: 88), callout = CGSize(width: 200, height: 18)
        // 默认贴着格子正上方、水平居中并钳制在容器内。
        XCTAssertEqual(
            UsageActivityLayout.calloutOrigin(cell: CGRect(x: 140, y: 40, width: 10, height: 10),
                                              container: container, callout: callout, hugsLeading: true),
            CGPoint(x: 40, y: 18))
        // 顶部一两行放不下时翻到格子下方。
        XCTAssertEqual(
            UsageActivityLayout.calloutOrigin(cell: CGRect(x: 140, y: 0, width: 10, height: 10),
                                              container: container, callout: callout, hugsLeading: true),
            CGPoint(x: 40, y: 14))
        // 月份网格比气泡窄且贴容器左缘：保持 x=0，纵向仍跟随所在行。
        XCTAssertEqual(
            UsageActivityLayout.calloutOrigin(cell: CGRect(x: 52, y: 52, width: 10, height: 10),
                                              container: CGSize(width: 78, height: 88), callout: callout, hugsLeading: true),
            CGPoint(x: 0, y: 30))
        // 24 列网格比气泡窄且贴容器右缘：向左溢出，右上不越界。
        XCTAssertEqual(
            UsageActivityLayout.calloutOrigin(cell: CGRect(x: 100, y: 80, width: 6, height: 6.333),
                                              container: CGSize(width: 170, height: 88), callout: callout, hugsLeading: false),
            CGPoint(x: -30, y: 58))
    }

    func testMonthAnd24HourViewsKeepAccountScopeAndAdvanceWithoutNewEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CodexLocalUsageModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        let now = Date()
        model.currentAccountID = "a"; model.selectedAccount = "b"
        model.events = ["a", "b"].enumerated().map { i, account in
            LocalUsageEvent(id: account, occurredAt: UsageTime.string(now.addingTimeInterval(-300)), model: "m", tokens: UsageTokens(input: Int64(i + 1)), accountID: account)
        }
        XCTAssertEqual(model.activityHistory(month: false, currentAccount: true, now: now).reduce(0) { $0 + $1.summary.tokens.input }, 1)
        XCTAssertEqual(model.activityHistory(month: false, now: now).reduce(0) { $0 + $1.summary.tokens.input }, 2)
        let later = now.addingTimeInterval(86500)
        XCTAssertEqual(model.activityHistory(month: false, currentAccount: true, now: later).reduce(0) { $0 + $1.summary.records }, 0)
        XCTAssertEqual(model.activityHistory(month: false, currentAccount: true, now: later).last?.end, later)
    }

    func testHourlySummaryUsesTotalsForWeightedCacheRate() {
        let now = Date()
        let events = [
            LocalUsageEvent(id: "a", occurredAt: UsageTime.string(now.addingTimeInterval(-60)), model: "m", tokens: UsageTokens(input: 100, cached: 100)),
            LocalUsageEvent(id: "b", occurredAt: UsageTime.string(now.addingTimeInterval(-600)), model: "m", tokens: UsageTokens(input: 900, cached: 0))
        ]
        let total = UsageActivityLayout.summary(UsageHistory.last24Hours(events: events, prices: [], now: now))
        XCTAssertEqual(total.records, 2)
        XCTAssertEqual(total.tokens.total, 1000)
        XCTAssertEqual(total.cacheHitRate!, 0.1, accuracy: 0.0001)
        XCTAssertEqual(total.pricedRecords, 0)
    }

    func testCostTabNeedsAnActuallyPricedNonEmptyBucket() {
        let now = Date()
        let event = LocalUsageEvent(id: "priced", occurredAt: UsageTime.string(now.addingTimeInterval(-60)), model: "m", tokens: UsageTokens(input: 100))
        XCTAssertFalse(UsageActivityLayout.hasUsableCost(UsageHistory.last24Hours(events: [], prices: [], now: now)))
        XCTAssertFalse(UsageActivityLayout.hasUsableCost(UsageHistory.last24Hours(events: [event], prices: [], now: now)))
        // A valid zero price still carries real information and must remain visible.
        let zeroPrice = UsagePrice(model: "m", version: "v1", source: "test", effectiveFrom: "2020-01-01T00:00:00Z", input: 0, cached: 0, output: 0)
        let buckets = UsageHistory.last24Hours(events: [event], prices: [zeroPrice], now: now)
        XCTAssertTrue(UsageActivityLayout.hasUsableCost(buckets))
        XCTAssertEqual(buckets.count / 12, 24)
        XCTAssertEqual(buckets.first!.start, now.addingTimeInterval(-24 * 3600))
    }

    func testMenuAccountScopeIsIndependentOfSettingsAndTracksSwitches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = CodexLocalUsageModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
        model.events = ["a", "b", nil].enumerated().map { index, account in
            LocalUsageEvent(id: "event-\(index)", occurredAt: UsageTime.string(Date()), model: "test",
                tokens: UsageTokens(input: Int64(index + 1), cached: 0, output: 0), accountID: account)
        }
        model.currentAccountID = "a"
        model.selectedAccount = "b"
        XCTAssertEqual(model.rangeSummary(days: 7, currentAccount: true).tokens.input, 1)
        XCTAssertEqual(model.rangeSummary(days: 7).tokens.input, 2)
        XCTAssertEqual(model.history(days: 7, currentAccount: true).reduce(0) { $0 + $1.summary.records }, 1)
        model.currentAccountID = "b"
        XCTAssertEqual(model.rangeSummary(days: 7, currentAccount: true).tokens.input, 2)
        model.currentAccountID = nil
        XCTAssertEqual(model.rangeSummary(days: 7, currentAccount: true).records, 0)
        XCTAssertEqual(model.history(days: 7, currentAccount: true).reduce(0) { $0 + $1.summary.records }, 0)
        model.selectedAccount = "all"
        XCTAssertEqual(model.rangeSummary(days: 7).records, 3)
    }

    func testLocalUsagePaneAndMenuRenderInBothLanguages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "LocalUsageViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CodexLocalUsageModel(defaults: defaults, databaseURL: directory.appendingPathComponent("test.sqlite"))
        model.events = (0..<7).map { day in
            LocalUsageEvent(id: String(repeating: String(day), count: 64),
                occurredAt: UsageTime.string(Calendar.current.date(byAdding: .day, value: -day, to: Date())!), model: "test-model",
                tokens: UsageTokens(input: Int64([125000, 85000, 210000, 95000, 175000, 50000, 120000][day]), cached: 40000, output: 12000))
        }
        model.files = 12; model.lastScan = Date(); model.issues = 1; model.deferred = 1
        for language in AppLanguage.allCases {
            let root = ScrollView { CodexLocalUsageSection(model: model, language: language).padding(20) }.frame(width: 720, height: 650).background(Color.white).environment(\.colorScheme, .light)
            let view = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = view; window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(view.fittingSize.height, 0)
            if let output = ProcessInfo.processInfo.environment["USAGE_SCREENSHOT_DIR"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("local-usage-\(language.rawValue).png"))
            }
            window.close()
            let menu = NSHostingView(rootView: LocalUsageSamplePreview(language: language).padding(8).frame(width: 276).background(Color.white).environment(\.colorScheme, .light))
            XCTAssertGreaterThan(menu.fittingSize.height, 50)
            let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 276, height: 235), styleMask: [.titled], backing: .buffered, defer: false)
            menuWindow.isReleasedWhenClosed = false
            menuWindow.animationBehavior = .none
            menuWindow.contentView = menu; menuWindow.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            menu.layoutSubtreeIfNeeded()
            if let output = ProcessInfo.processInfo.environment["USAGE_SCREENSHOT_DIR"], let bitmap = menu.bitmapImageRepForCachingDisplay(in: menu.bounds) {
                menu.cacheDisplay(in: menu.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("local-menu-\(language.rawValue).png"))
            }
            menuWindow.close()
        }
        XCTAssertFalse(model.reportingEnabled)
    }
}
