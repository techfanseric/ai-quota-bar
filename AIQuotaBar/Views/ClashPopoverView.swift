import SwiftUI

enum ClashPopoverLayout {
    static let width: CGFloat = MenuBarPanelLayout.width
    static let height: CGFloat = 850
    static let routeSectionHeight: CGFloat = 334
    static let routeListMinimumHeight: CGFloat = 96
    static let connectionListMinimumHeight: CGFloat = 90
}

struct ClashPopoverView: View {
    @Bindable var routeViewModel: ClashRouteViewModel
    @Bindable var connectionViewModel: ClashConnectionViewModel
    @Bindable var sleepProtectionCoordinator: CodexSleepProtectionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            CodexProtectionPopoverView(
                coordinator: sleepProtectionCoordinator,
                closedLidModeManager: sleepProtectionCoordinator.closedLidModeManager,
                language: routeViewModel.language
            )

            Divider()

            ClashRoutePopoverView(viewModel: routeViewModel)
                .frame(
                    height: ClashPopoverLayout.routeSectionHeight)

            Divider()

            ClashConnectionPopoverView(
                viewModel: connectionViewModel)
        }
        .frame(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            connectionViewModel.endLiveUpdates()
        }
    }
}
