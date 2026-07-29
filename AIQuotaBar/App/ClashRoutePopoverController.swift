import AppKit
import SwiftUI

@MainActor
final class ClashRoutePopoverController: NSObject, NSPopoverDelegate {
    private let routeViewModel: ClashRouteViewModel
    private let connectionViewModel: ClashConnectionViewModel
    private let sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    private let popover = NSPopover()

    init(
        routeViewModel: ClashRouteViewModel,
        connectionViewModel: ClashConnectionViewModel,
        sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    ) {
        self.routeViewModel = routeViewModel
        self.connectionViewModel = connectionViewModel
        self.sleepProtectionCoordinator = sleepProtectionCoordinator
        super.init()

        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.height)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: ClashPopoverView(
                routeViewModel: routeViewModel,
                connectionViewModel: connectionViewModel,
                sleepProtectionCoordinator: sleepProtectionCoordinator))
    }

    var isShown: Bool {
        popover.isShown
    }

    func toggle(
        relativeTo button: NSStatusBarButton,
        automaticallyTest: Bool = true
    ) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(relativeTo: button, automaticallyTest: automaticallyTest)
        }
    }

    func show(
        relativeTo button: NSStatusBarButton,
        automaticallyTest: Bool
    ) {
        guard !popover.isShown else { return }
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY)
        connectionViewModel.beginLiveUpdates()
        Task {
            await routeViewModel.prepareForDisplay(
                automaticallyTest: automaticallyTest)
        }
    }

    func close() {
        connectionViewModel.endLiveUpdates()
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        connectionViewModel.endLiveUpdates()
    }
}
