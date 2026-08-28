import AppKit
import SwiftUI

@MainActor
final class ClashRoutePopoverController: NSObject {
    private let routeViewModel: ClashRouteViewModel
    private let connectionViewModel: ClashConnectionViewModel
    private let sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    private let panel: MenuBarPanel
    private let hostingView:
        NSHostingView<MenuBarPanelSurface<ClashPopoverView>>

    init(
        routeViewModel: ClashRouteViewModel,
        connectionViewModel: ClashConnectionViewModel,
        sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    ) {
        self.routeViewModel = routeViewModel
        self.connectionViewModel = connectionViewModel
        self.sleepProtectionCoordinator = sleepProtectionCoordinator
        panel = MenuBarPanel()
        hostingView = NSHostingView(
            rootView: MenuBarPanelSurface {
                ClashPopoverView(
                    routeViewModel: routeViewModel,
                    connectionViewModel: connectionViewModel,
                    sleepProtectionCoordinator:
                        sleepProtectionCoordinator)
            })
        super.init()

        let contentSize = NSSize(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.height)
        hostingView.frame = NSRect(
            origin: .zero,
            size: contentSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setContentSize(contentSize)
        panel.onDismiss = { [weak self] in
            self?.connectionViewModel.endLiveUpdates()
            self?.routeViewModel.endFilterEditing()
        }
    }

    var isShown: Bool {
        panel.isVisible
    }

    func toggle(
        relativeTo button: NSStatusBarButton,
        automaticallyTest: Bool = true
    ) {
        if panel.isVisible {
            panel.dismiss()
        } else {
            show(relativeTo: button, automaticallyTest: automaticallyTest)
        }
    }

    func show(
        relativeTo button: NSStatusBarButton,
        automaticallyTest: Bool
    ) {
        guard !panel.isVisible,
              let placement = MenuBarPanelPlacement.resolve(
                relativeTo: button) else { return }

        let appearance = StatusItemMenuAppearance.resolved(
            from: NSApp.effectiveAppearance)
        routeViewModel.endFilterEditing()
        panel.appearance = appearance
        hostingView.appearance = appearance
        panel.present(
            relativeTo: button,
            placement: placement,
            contentSize: NSSize(
                width: ClashPopoverLayout.width,
                height: ClashPopoverLayout.height))
        connectionViewModel.beginLiveUpdates()
        Task {
            await routeViewModel.prepareForDisplay(
                automaticallyTest: automaticallyTest)
        }
    }

    func close() {
        connectionViewModel.endLiveUpdates()
        panel.dismiss()
    }
}
