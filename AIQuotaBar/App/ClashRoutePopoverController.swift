import AppKit
import SwiftUI

@MainActor
final class ClashRoutePopoverController {
    private let viewModel: ClashRouteViewModel
    private let popover = NSPopover()

    init(viewModel: ClashRouteViewModel) {
        self.viewModel = viewModel
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 376, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: ClashRoutePopoverView(viewModel: viewModel))
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
        Task {
            await viewModel.prepareForDisplay(
                automaticallyTest: automaticallyTest)
        }
    }

    func close() {
        popover.performClose(nil)
    }
}
