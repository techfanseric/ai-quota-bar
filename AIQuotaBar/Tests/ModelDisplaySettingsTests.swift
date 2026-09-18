import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar

@MainActor
final class ModelDisplaySettingsTests: XCTestCase {
    func testCatalogDeduplicatesByIdentityWithoutMergingAccountsOrProviders() {
        let a = model(.codex, "One@example.com", "5h")
        let duplicate = model(.codex, " one@EXAMPLE.com ", "5h")
        let b = model(.codex, "two@example.com", "5h")
        let c = model(.kimi, "One@example.com", "5h")
        let catalog = ModelDisplayCatalog(models: [a, duplicate, b, c])
        XCTAssertEqual(catalog.models.map(\.mobileDashboardSelectionKey), [a, b, c].map(\.mobileDashboardSelectionKey))
        XCTAssertEqual(catalog.accounts.count, 3)
        XCTAssertEqual(catalog.accounts.map(\.models.count), [1, 1, 1])
        XCTAssertEqual(ModelDisplayCatalog(models: []).accounts.count, 0)
    }

    func testUnavailableSelectionReturnsToItsRowWhenAccountRecovers() {
        let live = model(.codex, "current@example.com", "5h")
        let old = model(.codex, "old@example.com", "Weekly")
        let selection = [live, old].map(\.mobileDashboardSelectionKey)
        XCTAssertEqual(ModelDisplayCatalog(models: [live]).unavailableSelections(selection), [old.mobileDashboardSelectionKey])
        XCTAssertTrue(ModelDisplayCatalog(models: [live, old]).unavailableSelections(selection).isEmpty)
    }

    func testMatrixRendersBothLanguagesAndAppearancesWithoutChangingSavedChoices() throws {
        let suite = "ModelDisplaySettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = [
            model(.codex, "developer@example.com", "5h"),
            model(.codex, "developer@example.com", "Weekly"),
            model(.codex, "previous.long.account.name@example.com", "5h"),
            model(.miniMax, "", "MiniMax Coding Plan"),
            model(.kimi, "", "Kimi Code"),
            model(.glm, "", "GLM Coding Plan")
        ]
        var menu = LeftClickMenuDisplayPreferences()
        menu.setModelVisible(false, key: models[1].mobileDashboardSelectionKey)
        menu.setAccountVisible(false, key: LeftClickMenuAccountKey(model: models[2]))
        var charts = QuotaChartDisplayPreferences()
        charts.setMode(.areaChart, for: models[0])
        charts.setMode(.progressBar, for: models[3])
        let originalMenu = menu
        let originalCharts = charts
        let service = MobileDashboardService(defaults: defaults,
            snapshotProvider: { _, _, _, _ in fatalError("Display settings must not start the server") },
            onViewerActivityChanged: { _ in }, refreshRoute: {}, testRoutes: {})
        let orphan = model(.codex, "unavailable@example.com", "Weekly").mobileDashboardSelectionKey
        XCTAssertTrue(service.setSelectedModelKeys([models[0].mobileDashboardSelectionKey, orphan]))
        let originalSelection = service.selectedModelKeys
        for language in AppLanguage.allCases {
            for dark in [false, true] {
                let root = ModelDisplaySettings(models: models, language: language,
                    menuPreferences: Binding(get: { menu }, set: { menu = $0 }),
                    chartPreferences: Binding(get: { charts }, set: { charts = $0 }), service: service)
                    .padding(20).frame(width: 704)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let height = host.fittingSize.height
                XCTAssertLessThan(height, 780, "Six models plus a saved unavailable selection should remain compact")
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 704, height: height),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                host.layoutSubtreeIfNeeded()
                XCTAssertGreaterThan(host.fittingSize.height, 0)
                XCTAssertEqual(menu, originalMenu)
                XCTAssertEqual(charts, originalCharts)
                XCTAssertEqual(service.selectedModelKeys, originalSelection)
                if let directory = ProcessInfo.processInfo.environment["SETTINGS_SCREENSHOT_DIR"],
                   let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: directory).appendingPathComponent("display-settings-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                }
                window.close()
            }
        }
    }

    private func model(_ provider: UsageProvider, _ account: String, _ name: String) -> ModelUsageData {
        ModelUsageData(provider: provider, accountName: account, modelName: name,
            currentIntervalTotal: 100, currentIntervalUsed: 50, weeklyTotal: 0, weeklyUsed: 0,
            remainsTime: 3_600_000, startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(3600), weeklyStartTime: nil, weeklyEndTime: nil,
            valueSuffix: "%", detailText: nil, currentIntervalRemainingPercent: 50,
            weeklyRemainingPercent: nil, progressBarPercentOverride: nil, progressBarRightText: nil, sampledAt: nil)
    }
}
