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

    func testPanelHeightGrowsWithAccountsAndKeepsConnectionsWhole() {
        let connectionsMinimum = ClashPopoverLayout.connectionsSectionMinimumHeight
        let fixed = ClashPopoverLayout.protectionSectionHeight
            + ClashPopoverLayout.routeSectionHeight
            + ClashPopoverLayout.dividerAllowance * 3

        // 全展开、无屏幕约束：面板随账号内容增长，
        // connections 不再被压到「chrome + 列表最小高」以下。
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: false,
                accountsContentHeight: 115),
            fixed + 115 + connectionsMinimum)
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: false,
                accountsContentHeight: 467),
            fixed + 467 + connectionsMinimum)
        // 基准高 850 只是下限参考：内容超出基准时面板变高。
        XCTAssertGreaterThan(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: false,
                accountsContentHeight: 115),
            ClashPopoverLayout.height)
    }

    func testPanelHeightKeepsBaselineWhenRoutesCollapsed() {
        // 路由收起时 850 基线内放得下：connections 拿残余（旧弹性区行为保留）。
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: true,
                connectionsCollapsed: false,
                accountsCollapsed: true),
            ClashPopoverLayout.height)
    }

    func testPanelHeightCollapsesAndRestores() {
        let collapsedHeight = ClashPopoverLayout.collapsedSectionHeight
        let protection = ClashPopoverLayout.protectionSectionHeight
        let routes = ClashPopoverLayout.routeSectionHeight
        let dividers = ClashPopoverLayout.dividerAllowance * 3
        let defaultAccountsHeight: CGFloat = 100

        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: true),
            protection + defaultAccountsHeight + routes
                + collapsedHeight + dividers)

        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: true,
                connectionsCollapsed: true),
            protection + defaultAccountsHeight
                + collapsedHeight * 2 + dividers)
    }

    func testScreenCapCompressesAccountsBeforeConnections() {
        // 屏幕 1000：账号区先让位（下限 80），connections 保住 chrome + 列表。
        let sections = ClashPopoverLayout.resolveSectionHeights(
            routesCollapsed: false,
            connectionsCollapsed: false,
            accountsCollapsed: false,
            accountsContentHeight: 467,
            maximumHeight: 1000)
        XCTAssertEqual(sections.accounts, 111)
        XCTAssertEqual(
            sections.connections,
            ClashPopoverLayout.connectionsSectionMinimumHeight)
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: false,
                accountsContentHeight: 467,
                maximumHeight: 1000),
            1000)
    }

    func testScreenCapCompressionKeepsConnectionsChromeWhole() {
        // 中等屏幕（850）：账号压到 80 仍放不下 → 连接列表让位（下限 0）
        // → 账号再压到只剩标题行。chrome 完整，总高恰好贴合屏幕上限。
        let sections = ClashPopoverLayout.resolveSectionHeights(
            routesCollapsed: false,
            connectionsCollapsed: false,
            accountsCollapsed: false,
            accountsContentHeight: 467,
            maximumHeight: 850)
        XCTAssertEqual(sections.accounts, 51)
        XCTAssertEqual(
            sections.connections,
            ClashPopoverLayout.connectionsChromeHeight)
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: false,
                accountsCollapsed: false,
                accountsContentHeight: 467,
                maximumHeight: 850),
            850)
    }

    func testScreenCapAlsoAppliesWhenConnectionsCollapsed() {
        // connections 收起时账号分区同样受屏幕约束（不再封顶后尤其重要）。
        XCTAssertEqual(
            ClashPopoverLayout.panelHeight(
                routesCollapsed: false,
                connectionsCollapsed: true,
                accountsCollapsed: false,
                accountsContentHeight: 995,
                maximumHeight: 700),
            700)
    }

    func testAccountsContentHeightCountsRowsWithoutUpperCap() {
        // 空状态：chrome + 当前账号行 + 登录入口。
        XCTAssertEqual(
            ClashPopoverLayout.accountsContentHeight(
                stashCount: 0, legacyCount: 0, hasPending: false, hasStatus: false),
            ClashPopoverLayout.accountsSectionChromeHeight
                + ClashPopoverLayout.accountRowHeight + 32)
        // 不再封顶：20 个备份按行数自然增长，挤压由屏幕钳制统一处理。
        XCTAssertEqual(
            ClashPopoverLayout.accountsContentHeight(
                stashCount: 20, legacyCount: 0, hasPending: false, hasStatus: false),
            ClashPopoverLayout.accountsSectionChromeHeight
                + ClashPopoverLayout.accountRowHeight * 21 + 32)
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
