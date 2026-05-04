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
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Left click: details. Right click: switch used model."
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

        let menuView = MenuView(
            viewModel: viewModel,
            onOpenSettings: { [weak self] in
                self?.openSettings()
            },
            onLayoutChange: { [weak self] in
                self?.updateMenuLayout()
            }
        )

        hostingView = NSHostingView(rootView: menuView)
        updateMenuLayout()

        let menuItem = NSMenuItem()
        menuItem.view = hostingView!
        self.menuItem = menuItem
        menu?.addItem(menuItem)

        Publishers.MergeMany(
            viewModel.$usageData.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$error.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$providerUsageData.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$providerErrors.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$lastRefreshTime.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$appLanguage.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$selectedModelName.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isLoading.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$displayFormat.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$warningThreshold.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateMenuLayout()
        }
        .store(in: &cancellables)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            viewModel.switchToNextUsedModel()
        default:
            showMenu()
        }
    }

    private func showMenu() {
        guard let statusItem, let menu else { return }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func updateMenuLayout() {
        guard let hostingView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let maxMenuHeight = (NSScreen.main?.visibleFrame.height ?? 600) * 0.9
        let size = NSSize(
            width: ceil(fittingSize.width),
            height: ceil(min(fittingSize.height, maxMenuHeight))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        menuItem?.view?.frame = NSRect(origin: .zero, size: size)
        menu?.update()
    }

    private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }
}
