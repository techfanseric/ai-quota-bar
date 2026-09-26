import AppKit
import SwiftUI

@MainActor
final class ClashRoutePopoverController: NSObject {
    private let routeViewModel: ClashRouteViewModel
    private let connectionViewModel: ClashConnectionViewModel
    private let sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    private let displayStore: ClashPanelDisplayStore
    private let accountStore: CodexAuthAccountStore
    private let panel: MenuBarPanel
    private let hostingView:
        NSHostingView<MenuBarPanelSurface<ClashPopoverView>>
    private weak var anchoredButton: NSStatusBarButton?

    init(
        routeViewModel: ClashRouteViewModel,
        connectionViewModel: ClashConnectionViewModel,
        sleepProtectionCoordinator: CodexSleepProtectionCoordinator,
        displayStore: ClashPanelDisplayStore,
        accountStore: CodexAuthAccountStore
    ) {
        self.routeViewModel = routeViewModel
        self.connectionViewModel = connectionViewModel
        self.sleepProtectionCoordinator = sleepProtectionCoordinator
        self.displayStore = displayStore
        self.accountStore = accountStore
        panel = MenuBarPanel()
        hostingView = NSHostingView(
            rootView: MenuBarPanelSurface {
                ClashPopoverView(
                    routeViewModel: routeViewModel,
                    connectionViewModel: connectionViewModel,
                    sleepProtectionCoordinator:
                        sleepProtectionCoordinator,
                    displayStore: displayStore,
                    accountStore: accountStore)
            })
        super.init()

        let contentSize = NSSize(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.panelHeight(
                routesCollapsed: displayStore.isRoutesCollapsed,
                connectionsCollapsed: displayStore.isConnectionsCollapsed,
                accountsCollapsed: displayStore.isAccountsCollapsed))
        hostingView.frame = NSRect(
            origin: .zero,
            size: contentSize)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.setContentSize(contentSize)
        panel.onDismiss = { [weak self] in
            self?.connectionViewModel.endLiveUpdates()
            self?.routeViewModel.endFilterEditing()
            self?.accountStore.endDisplayRefresh()
        }
        observeSectionChanges()
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
        anchoredButton = button
        panel.appearance = appearance
        hostingView.appearance = appearance
        accountStore.beginDisplayRefresh()
        panel.present(
            relativeTo: button,
            placement: placement,
            contentSize: currentContentSize())
        if !displayStore.isConnectionsCollapsed {
            connectionViewModel.beginLiveUpdates()
        }
        Task {
            await routeViewModel.prepareForDisplay(
                automaticallyTest: automaticallyTest
                    && !displayStore.isRoutesCollapsed)
        }
    }

    func close() {
        connectionViewModel.endLiveUpdates()
        panel.dismiss()
    }

    private func currentContentSize() -> NSSize {
        NSSize(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.panelHeight(
                routesCollapsed: displayStore.isRoutesCollapsed,
                connectionsCollapsed: displayStore.isConnectionsCollapsed,
                accountsCollapsed: displayStore.isAccountsCollapsed,
                accountsContentHeight: ClashPopoverLayout.accountsContentHeight(
                    stashCount: accountStore.stashedAccounts.count,
                    legacyCount: accountStore.legacyBackupFileNames.count,
                    hasPending: accountStore.pendingRequest != nil,
                    hasStatus: accountStore.statusMessage != nil)))
    }

    /// 展开收起变化时：重算面板高度；收起/展开 connections 增删 live 轮询；
    /// 展开 routes 时补一次自动测速（"用户想看"）。
    private func handleSectionsChanged() {
        guard panel.isVisible else { return }
        resizePanel()
        if displayStore.isConnectionsCollapsed {
            connectionViewModel.endLiveUpdates()
        } else {
            connectionViewModel.beginLiveUpdates()
        }
        if !displayStore.isRoutesCollapsed {
            Task {
                await routeViewModel.prepareForDisplay(automaticallyTest: true)
            }
        }
    }

    private func resizePanel() {
        guard let button = anchoredButton,
              let placement = MenuBarPanelPlacement.resolve(
                relativeTo: button) else { return }
        let size = currentContentSize()
        panel.setFrame(
            placement.panelFrame(contentSize: size),
            display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    private func observeSectionChanges() {
        withObservationTracking { [displayStore] in
            _ = displayStore.collapsedSections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSectionsChanged()
                self?.observeSectionChanges()
            }
        }
    }
}
