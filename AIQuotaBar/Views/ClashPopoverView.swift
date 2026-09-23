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

    static var dividerAllowance: CGFloat { 2 }

    /// 两个分区都展开时的 connections 高度（保持原 850 总高）。
    static var connectionSectionHeight: CGFloat {
        height - protectionSectionHeight - dividerAllowance - routeSectionHeight
    }

    /// 面板总高随折叠状态收缩；双展开时与旧固定高度一致。
    static func panelHeight(
        routesCollapsed: Bool,
        connectionsCollapsed: Bool
    ) -> CGFloat {
        let routesHeight = routesCollapsed
            ? collapsedSectionHeight
            : routeSectionHeight
        let connectionsHeight = connectionsCollapsed
            ? collapsedSectionHeight
            : connectionSectionHeight
        return protectionSectionHeight + dividerAllowance
            + routesHeight + connectionsHeight
    }
}

struct ClashPopoverView: View {
    @Bindable var routeViewModel: ClashRouteViewModel
    @Bindable var connectionViewModel: ClashConnectionViewModel
    @Bindable var sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    @Bindable var displayStore: ClashPanelDisplayStore

    var body: some View {
        let routesCollapsed = displayStore.isRoutesCollapsed
        let connectionsCollapsed = displayStore.isConnectionsCollapsed
        VStack(spacing: 0) {
            CodexProtectionPopoverView(
                coordinator: sleepProtectionCoordinator,
                closedLidModeManager: sleepProtectionCoordinator.closedLidModeManager,
                language: routeViewModel.language
            )

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
                    : ClashPopoverLayout.connectionSectionHeight)
        }
        .frame(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.panelHeight(
                routesCollapsed: routesCollapsed,
                connectionsCollapsed: connectionsCollapsed))
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            connectionViewModel.endLiveUpdates()
        }
    }
}
