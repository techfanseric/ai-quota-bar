import SwiftUI

enum ClashPopoverLayout {
    static let width: CGFloat = MenuBarPanelLayout.width
    /// 面板基准高:内容放得下时 connections 吃掉剩余空间,面板保持这个高度;
    /// 账号等内容超出基准时面板随之长高,屏幕放不下再按 resolveSectionHeights 压缩。
    static let height: CGFloat = 850
    /// 保护分区：头部 50 + 保持唤醒/防屏保行 36 + 合盖行 52 + 暂时离开行 52
    /// + 3 条 divider。
    static let protectionSectionHeight: CGFloat = 193
    static let routeSectionHeight: CGFloat = 334
    static let routeListMinimumHeight: CGFloat = 96
    static let connectionListMinimumHeight: CGFloat = 90
    /// 分区收起后只剩标题行的高度。
    static let collapsedSectionHeight: CGFloat = 30
    static let accountsSectionMinimumHeight: CGFloat = 80
    /// 标题行 30 + 分隔线与行间 divider 的余量。
    static let accountsSectionChromeHeight: CGFloat = 39
    /// 单个账号行高度：名称 + 邮箱 + 配额行（三行）。
    static let accountRowHeight: CGFloat = 44

    // connections 分区固定内容（chrome）预算，与 ClashConnectionPopoverView 里的
    // 写死值一一对应；改视图任一项都要同步这里，否则分区会被压矮、尾部被裁。
    /// 标题行（13pt）+ 过滤提示（9pt）+ 上下 padding 8。
    static let connectionsHeaderHeight: CGFloat = 48
    /// 指标卡 minHeight 44 + 上下 padding 7。
    static let connectionsMetricsHeight: CGFloat = 58
    /// 活动图 78 + 图表标题行、间距与底部 padding 7。
    static let connectionsChartHeight: CGFloat = 104
    /// 「Active connections」表头行（上下 padding 6）。
    static let connectionsListHeaderHeight: CGFloat = 24
    /// 底部状态行。
    static let connectionsFooterHeight: CGFloat = 29
    /// 分区内 3 条 divider。
    static let connectionsDividerAllowance: CGFloat = 3

    /// connections 分区 chrome 合计：列表以外的固定内容。
    static var connectionsChromeHeight: CGFloat {
        connectionsHeaderHeight + connectionsMetricsHeight
            + connectionsChartHeight + connectionsListHeaderHeight
            + connectionsFooterHeight + connectionsDividerAllowance
    }
    /// connections 分区最小高：chrome + 列表最小高。低于此值列表被裁、尾部缺失。
    static var connectionsSectionMinimumHeight: CGFloat {
        connectionsChromeHeight + connectionListMinimumHeight
    }

    static var dividerAllowance: CGFloat { 2 }

    /// 账号分区自然高：chrome（标题行等）+ 当前账号行 + 备份行 + 横幅
    /// + 登录入口 + 状态行。不设上限——超出屏幕的部分由
    /// resolveSectionHeights 压缩，分区内部滚动兜底。
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
        return max(height, accountsSectionMinimumHeight)
    }

    /// 求解两个弹性分区（账号 / connections）的高度。
    ///
    /// - 屏幕无约束或放得下：账号按自然高，connections 拿基准高 850 的残余，
    ///   但不低于「chrome + 列表最小高」（修复 connections 被挤死的问题）；
    /// - 超出 maximumHeight：先压账号区（内部滚动，下限 80）；
    /// - 仍超：连接列表让位（下限 0），保 chrome 完整；
    /// - 仍超：账号压到只剩标题行（30）。chrome 是最后让步项——
    ///   极端小屏连 chrome 都放不下时才交由窗口钳制裁尾（旧行为）。
    static func resolveSectionHeights(
        routesCollapsed: Bool,
        connectionsCollapsed: Bool,
        accountsCollapsed: Bool,
        accountsContentHeight: CGFloat,
        maximumHeight: CGFloat?
    ) -> (accounts: CGFloat, connections: CGFloat) {
        let routes = routesCollapsed ? collapsedSectionHeight : routeSectionHeight
        let fixed = protectionSectionHeight + routes + dividerAllowance * 3
        let naturalAccounts = accountsCollapsed
            ? collapsedSectionHeight
            : max(accountsSectionMinimumHeight, accountsContentHeight)

        // 账号分区在屏幕约束下的让位：上限 = 屏幕余量 − 为 connections 预留的高度。
        // 收起态 naturalAccounts 已是标题行高度，min 之后自然不会被压缩。
        func cappedAccounts(reserving: CGFloat) -> CGFloat {
            guard let maximumHeight else { return naturalAccounts }
            let cap = max(
                accountsSectionMinimumHeight,
                maximumHeight - fixed - reserving)
            return min(naturalAccounts, cap)
        }

        // connections 收起：面板 = 保护 + 账号 + 路由 + 收起行。
        guard !connectionsCollapsed else {
            return (
                cappedAccounts(reserving: collapsedSectionHeight),
                collapsedSectionHeight)
        }

        let baselineConnections = max(
            connectionsSectionMinimumHeight,
            height - fixed - naturalAccounts)
        let desired = fixed + naturalAccounts + baselineConnections
        if maximumHeight == nil || desired <= maximumHeight! {
            return (naturalAccounts, baselineConnections)
        }

        // 第一档：压账号区，保 connections 完整（chrome + 列表最小高）。
        let accounts = cappedAccounts(reserving: connectionsSectionMinimumHeight)
        if fixed + accounts + connectionsSectionMinimumHeight <= maximumHeight! {
            return (accounts, connectionsSectionMinimumHeight)
        }
        // 第二档：连接列表让位（可滚动，下限 0），chrome 不动。
        let listlessConnections = max(
            connectionsChromeHeight,
            maximumHeight! - fixed - accounts)
        if fixed + accounts + listlessConnections <= maximumHeight! {
            return (accounts, listlessConnections)
        }
        // 第三档：账号压到只剩标题行，chrome 是底线。
        let headerAccounts = min(
            naturalAccounts,
            max(collapsedSectionHeight,
                maximumHeight! - fixed - connectionsChromeHeight))
        let headerConnections = max(
            connectionsChromeHeight,
            maximumHeight! - fixed - headerAccounts)
        return (headerAccounts, headerConnections)
    }

    static func panelHeight(
        routesCollapsed: Bool,
        connectionsCollapsed: Bool,
        accountsCollapsed: Bool = false,
        accountsContentHeight: CGFloat = 100,
        maximumHeight: CGFloat? = nil
    ) -> CGFloat {
        let sections = resolveSectionHeights(
            routesCollapsed: routesCollapsed,
            connectionsCollapsed: connectionsCollapsed,
            accountsCollapsed: accountsCollapsed,
            accountsContentHeight: accountsContentHeight,
            maximumHeight: maximumHeight)
        return protectionSectionHeight
            + (routesCollapsed ? collapsedSectionHeight : routeSectionHeight)
            + sections.accounts + sections.connections
            + dividerAllowance * 3
    }
}

struct ClashPopoverView: View {
    @Bindable var routeViewModel: ClashRouteViewModel
    @Bindable var connectionViewModel: ClashConnectionViewModel
    @Bindable var sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    @Bindable var displayStore: ClashPanelDisplayStore
    @Bindable var accountStore: CodexAuthAccountStore
    var stepAwayDimController = StepAwayDimController()
    var onDimDismiss: (() -> Void)?

    var body: some View {
        let routesCollapsed = displayStore.isRoutesCollapsed
        let connectionsCollapsed = displayStore.isConnectionsCollapsed
        let accountsCollapsed = displayStore.isAccountsCollapsed
        let naturalAccountsHeight = ClashPopoverLayout.accountsContentHeight(
            stashCount: accountStore.stashedAccounts.count,
            legacyCount: accountStore.legacyBackupFileNames.count,
            hasPending: accountStore.pendingRequest != nil,
            hasStatus: accountStore.statusMessage != nil)
        let sections = ClashPopoverLayout.resolveSectionHeights(
            routesCollapsed: routesCollapsed,
            connectionsCollapsed: connectionsCollapsed,
            accountsCollapsed: accountsCollapsed,
            accountsContentHeight: naturalAccountsHeight,
            maximumHeight: displayStore.panelMaximumHeight)
        VStack(spacing: 0) {
            CodexProtectionPopoverView(
                coordinator: sleepProtectionCoordinator,
                closedLidModeManager: sleepProtectionCoordinator.closedLidModeManager,
                stepAwayDimController: stepAwayDimController,
                language: routeViewModel.language,
                onDimDismiss: onDimDismiss
            )

            Divider()

            CodexAccountSwitchPopoverView(
                store: accountStore,
                isCollapsed: accountsCollapsed,
                onToggleCollapse: {
                    displayStore.toggle(.accounts)
                }
            )
            .frame(height: sections.accounts)

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
            .frame(height: sections.connections)
        }
        .frame(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.panelHeight(
                routesCollapsed: routesCollapsed,
                connectionsCollapsed: connectionsCollapsed,
                accountsCollapsed: accountsCollapsed,
                accountsContentHeight: naturalAccountsHeight,
                maximumHeight: displayStore.panelMaximumHeight))
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            connectionViewModel.endLiveUpdates()
        }
    }
}
