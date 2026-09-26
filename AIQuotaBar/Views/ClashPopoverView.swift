import SwiftUI

enum ClashPopoverLayout {
    static let width: CGFloat = MenuBarPanelLayout.width
    static let height: CGFloat = 850
    static let protectionSectionHeight: CGFloat = 140
    static let routeSectionHeight: CGFloat = 334
    static let routeListMinimumHeight: CGFloat = 96
    static let connectionListMinimumHeight: CGFloat = 90
    /// 分区收起后只剩标题行的高度。
    static let collapsedSectionHeight: CGFloat = 30
    /// 账号分区内容区的最大高度，超出后内部滚动。280 时面板总高
    /// （140 保护 + 6 divider + 280 + 334 路由 + 90 连接）恰好不超过 850。
    static let accountsSectionMaximumHeight: CGFloat = 280
    static let accountsSectionMinimumHeight: CGFloat = 80
    /// 标题行 30 + 分隔线与行间 divider 的余量。
    static let accountsSectionChromeHeight: CGFloat = 39
    /// 单个账号行高度：名称 + 邮箱 + 配额行（三行）。
    static let accountRowHeight: CGFloat = 44

    static var dividerAllowance: CGFloat { 2 }

    /// 账号分区高度：chrome（标题行等）+ 当前账号行 + 备份行 + 横幅
    /// + 登录入口 + 状态行。
    static func accountsContentHeight(
        stashCount: Int,
        legacyCount: Int,
        hasPending: Bool,
        hasStatus: Bool
    ) -> CGFloat {
        var height: CGFloat = accountsSectionChromeHeight + accountRowHeight
        height += CGFloat(stashCount) * accountRowHeight
        height += CGFloat(legacyCount) * 30
        if hasPending { height += 28 }
        height += 32
        if hasStatus { height += 20 }
        return min(
            max(height, accountsSectionMinimumHeight),
            accountsSectionMaximumHeight)
    }

    /// 面板总高随折叠状态收缩；connections 是弹性区——总高以 850 为基准，
    /// 只有当其余分区把它挤压到最小高度以下时面板才变高。
    static func panelHeight(
        routesCollapsed: Bool,
        connectionsCollapsed: Bool,
        accountsCollapsed: Bool = false,
        accountsContentHeight: CGFloat = 100
    ) -> CGFloat {
        let accountsHeight = accountsCollapsed
            ? collapsedSectionHeight
            : accountsContentHeight
        let routesHeight = routesCollapsed
            ? collapsedSectionHeight
            : routeSectionHeight
        let connectionsHeight = connectionsCollapsed
            ? collapsedSectionHeight
            : max(
                connectionListMinimumHeight,
                height - protectionSectionHeight
                    - accountsHeight - routesHeight
                    - dividerAllowance * 3)
        return protectionSectionHeight + accountsHeight + routesHeight
            + connectionsHeight + dividerAllowance * 3
    }
}

struct ClashPopoverView: View {
    @Bindable var routeViewModel: ClashRouteViewModel
    @Bindable var connectionViewModel: ClashConnectionViewModel
    @Bindable var sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    @Bindable var displayStore: ClashPanelDisplayStore
    @Bindable var accountStore: CodexAuthAccountStore

    var body: some View {
        let routesCollapsed = displayStore.isRoutesCollapsed
        let connectionsCollapsed = displayStore.isConnectionsCollapsed
        let accountsCollapsed = displayStore.isAccountsCollapsed
        let accountsHeight = ClashPopoverLayout.accountsContentHeight(
            stashCount: accountStore.stashedAccounts.count,
            legacyCount: accountStore.legacyBackupFileNames.count,
            hasPending: accountStore.pendingRequest != nil,
            hasStatus: accountStore.statusMessage != nil)
        VStack(spacing: 0) {
            CodexProtectionPopoverView(
                coordinator: sleepProtectionCoordinator,
                closedLidModeManager: sleepProtectionCoordinator.closedLidModeManager,
                language: routeViewModel.language
            )

            Divider()

            CodexAccountSwitchPopoverView(
                store: accountStore,
                isCollapsed: accountsCollapsed,
                onToggleCollapse: {
                    displayStore.toggle(.accounts)
                }
            )
            .frame(
                height: accountsCollapsed
                    ? ClashPopoverLayout.collapsedSectionHeight
                    : accountsHeight)

            Divider()

            ClashRoutePopoverView(
                viewModel: routeViewModel,
                isCollapsed: routesCollapsed,
                onToggleCollapse: {
                    displayStore.toggle(.routes)
                }
            )
            .frame(
                height: routesCollapsed
                    ? ClashPopoverLayout.collapsedSectionHeight
                    : ClashPopoverLayout.routeSectionHeight)

            Divider()

            ClashConnectionPopoverView(
                viewModel: connectionViewModel,
                isCollapsed: connectionsCollapsed,
                onToggleCollapse: {
                    displayStore.toggle(.connections)
                }
            )
            .frame(
                height: connectionsCollapsed
                    ? ClashPopoverLayout.collapsedSectionHeight
                    : ClashPopoverLayout.connectionSectionHeight(
                        routesCollapsed: routesCollapsed,
                        connectionsCollapsed: connectionsCollapsed,
                        accountsCollapsed: accountsCollapsed,
                        accountsContentHeight: accountsHeight))
        }
        .frame(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.panelHeight(
                routesCollapsed: routesCollapsed,
                connectionsCollapsed: connectionsCollapsed,
                accountsCollapsed: accountsCollapsed,
                accountsContentHeight: accountsHeight))
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            connectionViewModel.endLiveUpdates()
        }
    }
}

extension ClashPopoverLayout {
    /// connections 分区的高度：总高 850 的剩余空间，最低不小于列表最小高度。
    static func connectionSectionHeight(
        routesCollapsed: Bool,
        connectionsCollapsed: Bool,
        accountsCollapsed: Bool = false,
        accountsContentHeight: CGFloat = 100
    ) -> CGFloat {
        let accountsHeight = accountsCollapsed
            ? collapsedSectionHeight
            : accountsContentHeight
        let routesHeight = routesCollapsed
            ? collapsedSectionHeight
            : routeSectionHeight
        return max(
            connectionListMinimumHeight,
            height - protectionSectionHeight - accountsHeight - routesHeight
                - dividerAllowance * 3)
    }
}
