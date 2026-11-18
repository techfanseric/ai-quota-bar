import AppKit
import SwiftUI

@MainActor
final class ClashRoutePopoverController: NSObject {
    private let routeViewModel: ClashRouteViewModel
    private let connectionViewModel: ClashConnectionViewModel
    private let sleepProtectionCoordinator: CodexSleepProtectionCoordinator
    private let displayStore: ClashPanelDisplayStore
    private let accountStore: CodexAuthAccountStore
    private let stepAwayDimController: StepAwayDimController
    private var panel: MenuBarPanel?
    private var hostingView:
        NSHostingView<MenuBarPanelSurface<ClashPopoverView>>?
    private let lightweightMode: LightweightModeController
    private weak var anchoredButton: NSStatusBarButton?

    init(
        routeViewModel: ClashRouteViewModel,
        connectionViewModel: ClashConnectionViewModel,
        sleepProtectionCoordinator: CodexSleepProtectionCoordinator,
        displayStore: ClashPanelDisplayStore,
        accountStore: CodexAuthAccountStore,
        stepAwayDimController: StepAwayDimController,
        lightweightMode: LightweightModeController? = nil
    ) {
        self.routeViewModel = routeViewModel
        self.connectionViewModel = connectionViewModel
        self.sleepProtectionCoordinator = sleepProtectionCoordinator
        self.displayStore = displayStore
        self.accountStore = accountStore
        self.stepAwayDimController = stepAwayDimController
        self.lightweightMode = lightweightMode ?? .shared
        super.init()
        observeSectionChanges()
    }

    var loadedPanel: MenuBarPanel? { panel }

    func loadPanelIfNeeded() {
        guard panel == nil else { return }
        let popoverPanel = MenuBarPanel()
        panel = popoverPanel
        let host = NSHostingView(
            rootView: MenuBarPanelSurface {
                ClashPopoverView(
                    routeViewModel: routeViewModel,
                    connectionViewModel: connectionViewModel,
                    sleepProtectionCoordinator:
                        sleepProtectionCoordinator,
                    displayStore: displayStore,
                    accountStore: accountStore,
                    stepAwayDimController: stepAwayDimController,
                    onDimDismiss: { [weak popoverPanel] in
                        popoverPanel?.dismiss()
                    })
            })
        hostingView = host

        let contentSize = NSSize(
            width: ClashPopoverLayout.width,
            height: ClashPopoverLayout.panelHeight(
                routesCollapsed: displayStore.isRoutesCollapsed,
                connectionsCollapsed: displayStore.isConnectionsCollapsed,
                accountsCollapsed: displayStore.isAccountsCollapsed))
        host.frame = NSRect(
            origin: .zero,
            size: contentSize)
        host.autoresizingMask = [.width, .height]
        popoverPanel.contentView = host
        popoverPanel.setContentSize(contentSize)
        popoverPanel.onDismiss = { [weak self] in
            self?.connectionViewModel.endLiveUpdates()
            self?.routeViewModel.endFilterEditing()
            self?.accountStore.endDisplayRefresh()
            self?.lightweightMode.didHide("control-panel")
        }
        lightweightMode.register("control-panel", isOpen: { [weak popoverPanel] in
            LightweightModeController.isOpen(popoverPanel)
        }, release: { [weak self] in self?.releasePanel() })
    }

    private func releasePanel() {
        panel?.onDismiss = nil
        panel?.contentView = nil
        hostingView = nil
        panel?.close()
        panel = nil
        anchoredButton = nil
        CodexLocalUsageModel.shared.releasePresentationCaches()
    }

    var isShown: Bool {
        panel?.isVisible == true
    }

    func toggle(
        relativeTo button: NSStatusBarButton,
        automaticallyTest: Bool = true
    ) {
        if panel?.isVisible == true {
            panel?.dismiss()
        } else {
            show(relativeTo: button, automaticallyTest: automaticallyTest)
        }
    }

    func show(
        relativeTo button: NSStatusBarButton,
        automaticallyTest: Bool
    ) {
        guard panel?.isVisible != true,
              let placement = MenuBarPanelPlacement.resolve(
                relativeTo: button) else { return }
        loadPanelIfNeeded()
        guard let panel, let hostingView else { return }

        let appearance = StatusItemMenuAppearance.resolved(
            from: NSApp.effectiveAppearance)
        routeViewModel.endFilterEditing()
        anchoredButton = button
        panel.appearance = appearance
        hostingView.appearance = appearance
        accountStore.beginDisplayRefresh()
        displayStore.panelMaximumHeight = placement.maximumHeight
        panel.present(
            relativeTo: button,
            placement: placement,
            contentSize: currentContentSize())
        lightweightMode.didShow("control-panel")
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
        panel?.dismiss()
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
                    hasStatus: accountStore.statusMessage != nil),
                maximumHeight: displayStore.panelMaximumHeight))
    }

    /// 展开收起变化时：重算面板高度；收起/展开 connections 增删 live 轮询；
    /// 展开 routes 时补一次自动测速（"用户想看"）。
    private func handleSectionsChanged() {
        guard panel?.isVisible == true else { return }
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
        guard let panel, let hostingView, let button = anchoredButton,
              let placement = MenuBarPanelPlacement.resolve(
                relativeTo: button) else { return }
        // 屏幕可能变了（外接显示器插拔），重新测定可用高度。
        displayStore.panelMaximumHeight = placement.maximumHeight
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
