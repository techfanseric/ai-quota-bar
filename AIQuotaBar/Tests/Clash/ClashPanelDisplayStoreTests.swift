import XCTest
@testable import AIQuotaBar

@MainActor
final class ClashPanelDisplayStoreTests: XCTestCase {
    func testTogglePersistsAndRoundTripsThroughDefaults() throws {
        let fixture = try makeFixture()
        XCTAssertFalse(fixture.store.isRoutesCollapsed)
        XCTAssertFalse(fixture.store.isConnectionsCollapsed)

        fixture.store.toggle(.routes)

        XCTAssertTrue(fixture.store.isRoutesCollapsed)
        XCTAssertFalse(fixture.store.isConnectionsCollapsed)

        let reloaded = ClashPanelDisplayStore(defaults: fixture.defaults)
        XCTAssertTrue(reloaded.isRoutesCollapsed)
        XCTAssertFalse(reloaded.isConnectionsCollapsed)
    }

    func testFollowEnabledAlignsBothSectionsToCodexPresence() throws {
        let fixture = try makeFixture()

        fixture.store.alignWithCodexPresence(
            isRunning: true,
            followRunningAppsEnabled: true)
        XCTAssertFalse(fixture.store.isRoutesCollapsed)
        XCTAssertFalse(fixture.store.isConnectionsCollapsed)

        fixture.store.alignWithCodexPresence(
            isRunning: false,
            followRunningAppsEnabled: true)
        XCTAssertTrue(fixture.store.isRoutesCollapsed)
        XCTAssertTrue(fixture.store.isConnectionsCollapsed)
    }

    func testAlignIgnoredWhenFollowDisabled() throws {
        let fixture = try makeFixture()
        fixture.store.setCollapsed(true, section: .routes)

        fixture.store.alignWithCodexPresence(
            isRunning: true,
            followRunningAppsEnabled: false)

        XCTAssertTrue(fixture.store.isRoutesCollapsed)
        XCTAssertFalse(fixture.store.isConnectionsCollapsed)
    }

    func testManualExpandHoldsUntilNextPresenceAlignment() throws {
        let fixture = try makeFixture()
        fixture.store.alignWithCodexPresence(
            isRunning: false,
            followRunningAppsEnabled: true)

        fixture.store.setCollapsed(false, section: .routes)
        XCTAssertFalse(fixture.store.isRoutesCollapsed)

        // 下一次 presence 对齐（最后操作生效），手动展开被重新收起——
        // 与左键菜单供应商区语义一致。
        fixture.store.alignWithCodexPresence(
            isRunning: false,
            followRunningAppsEnabled: true)
        XCTAssertTrue(fixture.store.isRoutesCollapsed)
        XCTAssertTrue(fixture.store.isConnectionsCollapsed)
    }

    func testPanelHeightCollapsesAndRestores() {
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false),
            ClashPopoverLayout.height)

        let collapsedHeight = ClashPopoverLayout.collapsedSectionHeight
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: true,
                connectionsCollapsed: false),
            ClashPopoverLayout.protectionSectionHeight
                + ClashPopoverLayout.dividerAllowance
                + collapsedHeight
                + ClashPopoverLayout.connectionSectionHeight)
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: true),
            ClashPopoverLayout.protectionSectionHeight
                + ClashPopoverLayout.dividerAllowance
                + ClashPopoverLayout.routeSectionHeight
                + collapsedHeight)
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: true,
                connectionsCollapsed: true),
            ClashPopoverLayout.protectionSectionHeight
                + ClashPopoverLayout.dividerAllowance
                + collapsedHeight * 2)
    }

    // MARK: - Fixtures

    private func makeFixture() throws -> (
        store: ClashPanelDisplayStore,
        defaults: UserDefaults
    ) {
        let suiteName = "ClashPanelDisplayStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (
            ClashPanelDisplayStore(defaults: defaults),
            defaults
        )
    }
}
