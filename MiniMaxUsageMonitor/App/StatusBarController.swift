import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController {
    let viewModel = UsageViewModel()
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var hostingView: NSHostingView<MenuView>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupStatusItem()
        setupMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.title = viewModel.statusBarText
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }

        // Observe status bar text changes
        viewModel.$statusBarText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.statusItem?.button?.title = text
            }
            .store(in: &cancellables)
    }

    private func setupMenu() {
        menu = NSMenu()

        let menuView = MenuView(viewModel: viewModel, onOpenSettings: { [weak self] in
            self?.openSettings()
        })

        hostingView = NSHostingView(rootView: menuView)
        hostingView?.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        let menuItem = NSMenuItem()
        menuItem.view = hostingView!
        menu?.addItem(menuItem)

        statusItem?.menu = menu
    }

    private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }
}
