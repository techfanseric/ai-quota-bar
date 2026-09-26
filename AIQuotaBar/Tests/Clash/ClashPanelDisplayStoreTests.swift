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
        let collapsedHeight = ClashPopoverLayout.collapsedSectionHeight
        let protection = ClashPopoverLayout.protectionSectionHeight
        let routes = ClashPopoverLayout.routeSectionHeight
        let dividers = ClashPopoverLayout.dividerAllowance * 3
        let defaultAccountsHeight: CGFloat = 100

        // 全部展开：connections 吃掉 850 总高的剩余空间。
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false),
            ClashPopoverLayout.height)
        // connections 是弹性区：其余分区展开到上限时面板仍保持 850。
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: false,
                accountsContentHeight: 250),
            ClashPopoverLayout.height)

        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: true,
                connectionsCollapsed: false),
            ClashPopoverLayout.height)

        let expectedConnectionsCollapsed = protection
            + defaultAccountsHeight
            + routes
            + collapsedHeight
            + dividers
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: true),
            expectedConnectionsCollapsed)

        let expectedBothCollapsed = protection
            + defaultAccountsHeight
            + collapsedHeight * 2
            + dividers
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: true,
                connectionsCollapsed: true),
            expectedBothCollapsed)

        // 账号分区收起后回到与旧两分区布局等价的高度。
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: true),
            ClashPopoverLayout.height)
    }

    func testAccountsContentHeightCountsRowsAndClamps() {
        // 空状态：chrome + 当前账号行 + 登录入口。
        XCTAssertEqual(
            ClashPopoverLayout.accountsContentHeight(
                stashCount: 0, legacyCount: 0, hasPending: false, hasStatus: false),
            ClashPopoverLayout.accountsSectionChromeHeight
                + ClashPopoverLayout.accountRowHeight + 32)
        // chrome + 当前行 + 备份行×2 + 旧备份 30 + 横幅 28 + 登录 32 + 状态 20，
        // 超出上限时收敛到最大高度（内部滚动）。
        let naturalHeight: CGFloat = ClashPopoverLayout.accountsSectionChromeHeight
            + ClashPopoverLayout.accountRowHeight * 3 + 30 + 28 + 32 + 20
        XCTAssertEqual(
            ClashPopoverLayout.accountsContentHeight(
                stashCount: 2, legacyCount: 1, hasPending: true, hasStatus: true),
            min(naturalHeight, ClashPopoverLayout.accountsSectionMaximumHeight))
        // 上限抬高到 280 后，四个账号的常规现场无需滚动即可完整显示。
        XCTAssertGreaterThanOrEqual(
            ClashPopoverLayout.accountsSectionMaximumHeight,
            ClashPopoverLayout.accountsSectionChromeHeight
                + ClashPopoverLayout.accountRowHeight * 4 + 30 + 32)
        XCTAssertLessThanOrEqual(
            ClashPopoverLayout.accountsContentHeight(
                stashCount: 20, legacyCount: 0, hasPending: false, hasStatus: false),
            ClashPopoverLayout.accountsSectionMaximumHeight)
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
