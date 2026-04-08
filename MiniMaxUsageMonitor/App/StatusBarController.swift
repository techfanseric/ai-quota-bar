import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusBarController {
    let viewModel = UsageViewModel()
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuItem: NSMenuItem?
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
        updateMenuLayout()

        let menuItem = NSMenuItem()
        menuItem.view = hostingView!
        self.menuItem = menuItem
        menu?.addItem(menuItem)

        statusItem?.menu = menu

        Publishers.CombineLatest4(
            viewModel.$usageData.map { _ in () },
            viewModel.$error.map { _ in () },
            viewModel.$lastRefreshTime.map { _ in () },
            viewModel.$appLanguage.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateMenuLayout()
        }
        .store(in: &cancellables)
    }

    private func updateMenuLayout() {
        guard let hostingView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        menuItem?.view?.frame = NSRect(origin: .zero, size: size)
    }

    private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }
}
