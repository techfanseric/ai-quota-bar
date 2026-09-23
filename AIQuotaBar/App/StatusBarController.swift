import AppKit
import SwiftUI

/// Only visible inputs invalidate raster frames. Tooltip/reset text does not.
struct CompactStatusRenderState: Equatable {
    let snapshots: [MenuBarSnapshot]
    let connectivity: CodexConnectivityState
    let pace: MenuBarPaceDisplayMode
    let selfTesting: Bool
    let tasks: [UsageProvider: Int]
    let padding: Double
    let spacing: Double
    let appearance: String
    let scale: CGFloat
    let height: CGFloat
    let reduceMotion: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshots.count == rhs.snapshots.count
            && zip(lhs.snapshots, rhs.snapshots).allSatisfy { a, b in
                a.provider == b.provider && a.ringPercent == b.ringPercent
                    && a.paceDeltaPercent == b.paceDeltaPercent && a.state == b.state
                    && a.isLowQuota == b.isLowQuota
            }
            && lhs.connectivity == rhs.connectivity && lhs.pace == rhs.pace
            && lhs.selfTesting == rhs.selfTesting && lhs.tasks == rhs.tasks
            && lhs.padding == rhs.padding && lhs.spacing == rhs.spacing
            && lhs.appearance == rhs.appearance && lhs.scale == rhs.scale
            && lhs.height == rhs.height && lhs.reduceMotion == rhs.reduceMotion
    }
}

private final class StatusButtonAppearanceTrackingView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onAppearanceChanged?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 状态栏显示：两行 NSTextField 直接 addSubview 到 NSStatusBarButton。
///
/// 第一行：剩余百分比（如 "60%"）
/// 第二行：重置时间（如 "2h"）
///
/// 不用 button.image + NSImage(SVG) 那条路，brand icon 渲染对 template image / dark mode
/// / 光栅化的边角太多；用 stats 项目的 addSubview 模式更稳。
@MainActor
final class StatusBarController {
    let viewModel = UsageViewModel()
    let sleepProtectionCoordinator = CodexSleepProtectionCoordinator()
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuItem: NSMenuItem?
    private var hostingView: NSHostingView<MenuView>?
    private let menuPresentationSizing = MenuPresentationSizing(
        maximumScrollableHeight:
            MenuBarPanelLayout.maximumScrollableHeight(
                visibleHeight: MenuBarPanelLayout.fallbackVisibleHeight))
    private var maximumMenuHeight = MenuBarPanelLayout.maximumHeight(
        visibleHeight: MenuBarPanelLayout.fallbackVisibleHeight)

    private let statusView = StatusBarContentView()
    private let connectivityMonitor = CodexConnectivityMonitor()
    private let clashRouteViewModel = ClashRouteViewModel()
    private let clashConnectionViewModel = ClashConnectionViewModel()
    private(set) lazy var mobileDashboardService =
        MobileDashboardService(
            snapshotProvider: {
                [unowned self] masksAccountNames,
                    lastRouteTestedAt,
                    selectedModelKeys,
                    sharesTaskProgressText in
                MobileDashboardSnapshotBuilder.make(
                    usageViewModel: self.viewModel,
                    connectivityMonitor: self.connectivityMonitor,
                    protectionCoordinator:
                        self.sleepProtectionCoordinator,
                    routeViewModel: self.clashRouteViewModel,
                    connectionViewModel:
                        self.clashConnectionViewModel,
                    masksAccountNames:
                        masksAccountNames,
                    selectedModelKeys:
                        selectedModelKeys,
                    lastRouteTestedAt:
                        lastRouteTestedAt,
                    sharesTaskProgressText:
                        sharesTaskProgressText)
            },
            onViewerActivityChanged: { [weak self] isActive in
                guard let self else { return }
                if isActive {
                    self.clashConnectionViewModel
                        .beginLiveUpdates(
                            owner:
                                MobileDashboardService
                                    .liveUpdateOwner)
                } else {
                    self.clashConnectionViewModel
                        .endLiveUpdates(
                            owner:
                                MobileDashboardService
                                    .liveUpdateOwner)
                }
            },
            refreshRoute: { [weak self] in
                guard let self else { return }
                self.clashRouteViewModel.language =
                    self.viewModel.appLanguage
                await self.clashRouteViewModel.refresh()
            },
            testRoutes: { [weak self] in
                guard let self else { return }
                self.clashRouteViewModel.language =
                    self.viewModel.appLanguage
                await self.clashRouteViewModel.testRoutes()
            })
    private lazy var clashRoutePopoverController = ClashRoutePopoverController(
        routeViewModel: clashRouteViewModel,
        connectionViewModel: clashConnectionViewModel,
        sleepProtectionCoordinator: sleepProtectionCoordinator)
    private let initialStatusItemLength: CGFloat = 110
    private var screenObserverTokens: [NSObjectProtocol] = []
    private var accessibilityDisplayObserver: NSObjectProtocol?
    private var consecutiveUnreachableChecks = 0
    private var hasHandledCurrentOutage = false
    private var recoveryTask: Task<Void, Never>?
    private var compactImageAnimationTask: Task<Void, Never>?
    private let compactAppearanceTrackingView = StatusButtonAppearanceTrackingView()
    private var compactImageFrames: [NSImage] = []
    private var compactRenderState: CompactStatusRenderState?
    private var appearanceUpdateScheduled = false
    private let compactAnimationEpoch = ProcessInfo.processInfo.systemUptime

    init() {
        sleepProtectionCoordinator.setProtectedProviders(
            viewModel.taskProtectionProviders)
        setupStatusItem()
        setupMenu()
        sleepProtectionCoordinator.start()
        viewModel.appPresenceMonitor.start()
        viewModel.syncCollapsedProvidersWithRunningApps()
        connectivityMonitor.start()
        clashConnectionViewModel.startBackgroundMonitoring()
        viewModel.flushPendingCloudSyncQueue()
        mobileDashboardService.startIfEnabled()
        synchronizeMobileDashboardModelSelection()
        observeMobileDashboardModelSelection()
        observeCredentialVaultDidLoad()
    }

    /// The vault now loads asynchronously after launch; if it answered
    /// differently from the persisted configured-providers cache (first run
    /// on a new account, credential revoked elsewhere), refresh immediately.
    private func observeCredentialVaultDidLoad() {
        NotificationCenter.default.addObserver(
            forName: .credentialVaultDidLoad,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.viewModel.refresh(showIconSelfTest: false)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: initialStatusItemLength)

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Left-click for usage. Right-click for task protection, OpenAI routes, and connections."
            statusView.translatesAutoresizingMaskIntoConstraints = true
            statusView.frame = NSRect(x: 0, y: 0, width: initialStatusItemLength, height: 22)
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
            compactAppearanceTrackingView.frame = button.bounds
            compactAppearanceTrackingView.autoresizingMask = [.width, .height]
            compactAppearanceTrackingView.onAppearanceChanged = { [weak self] in
                // AppKit temporarily changes appearances while taking menu-bar
                // replica snapshots. Inspect the settled appearance next run loop.
                self?.scheduleAppearanceUpdate()
            }
            button.addSubview(compactAppearanceTrackingView)
            updateStatusItem()
            installActiveScreenObservers(button: button)
            accessibilityDisplayObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.scheduleAppearanceUpdate() } }
        }

        observeProperties(viewModel) { viewModel in
            _ = viewModel.statusBarText
            _ = viewModel.menuBarSnapshot
            _ = viewModel.menuBarRingDisplayMode
            _ = viewModel.menuBarSnapshots
            _ = viewModel.menuBarAppearance
            _ = viewModel.menuBarPaceDisplayMode
            _ = viewModel.menuBarCompactHorizontalPadding
            _ = viewModel.menuBarCompactRingSpacing
            _ = viewModel.isMenuBarSelfTesting
        } onChange: { [weak self] in
            self?.updateStatusItem()
        }

        observeProperties(connectivityMonitor) { monitor in
            _ = monitor.state
            _ = monitor.checkSequence
        } onChange: { [weak self] in
            self?.handleConnectivityCheck()
        }

        observeProperties(sleepProtectionCoordinator) { coordinator in
            _ = coordinator.activeTurnCount
            _ = coordinator.activeTaskCounts
        } onChange: { [weak self] in
            self?.updateStatusItem()
        }

        // 应用启动 / 退出 → 跟随模式下的菜单栏与左键菜单显示集合。
        observeProperties(viewModel.appPresenceMonitor) { monitor in
            _ = monitor.runningProviders
        } onChange: { [weak self] in
            guard let self else { return }
            self.viewModel.handleAppPresenceChanged()
            self.updateMenuLayout()
        }

        observeProperties(viewModel) { viewModel in
            _ = viewModel.providerUsageSections
        } onChange: { [weak self] in
            guard let self else { return }
            self.synchronizeMobileDashboardModelSelection()
            self.sleepProtectionCoordinator.setProtectedProviders(
                self.viewModel.taskProtectionProviders)
        }
    }

    private func synchronizeMobileDashboardModelSelection() {
        mobileDashboardService.initializeModelSelectionIfNeeded(
            candidates:
                viewModel.providerUsageSections.flatMap(\.models))
        viewModel.setMobileDashboardSelectedModelKeys(
            mobileDashboardService.selectedModelKeys)
    }

    private func observeMobileDashboardModelSelection() {
        observeProperties(mobileDashboardService) { service in
            _ = service.selectedModelKeys
        } onChange: { [weak self] in
            guard let self else { return }
            self.viewModel.setMobileDashboardSelectedModelKeys(
                self.mobileDashboardService.selectedModelKeys)
        }
    }

    private func setupMenu() {
        let menuView = MenuView(
            viewModel: viewModel,
            presentationSizing: menuPresentationSizing,
            onOpenSettings: { [weak self] in
                self?.dismissMenu()
                self?.openSettings()
            },
            onLayoutChange: { [weak self] in
                self?.updateMenuLayout()
            }
        )

        let hostingView = NSHostingView(rootView: menuView)
        hostingView.autoresizingMask = [.width, .height]
        self.hostingView = hostingView

        let nativeMenu = MenuBarNativeMenu.make(
            contentView: hostingView)
        menu = nativeMenu.menu
        menuItem = nativeMenu.item
        updateMenuLayout()

        observeMenuLayoutChanges()
    }

    /// 持续追踪下拉菜单用到的所有 keyPath，任意一个变化时重算 menu 尺寸。
    private func observeMenuLayoutChanges() {
        observeProperties(viewModel) { vm in
            _ = vm.usageData
            _ = vm.error
            _ = vm.providerUsageData
            _ = vm.providerErrors
            _ = vm.cloudProviderUsageData
            _ = vm.cloudModelQuotaSamples
            _ = vm.modelQuotaSamples
            _ = vm.utilizationHistories
            _ = vm.lastRefreshTime
            _ = vm.appLanguage
            _ = vm.isLoading
            _ = vm.warningThreshold
            _ = vm.warningThresholdEnabled
        } onChange: { [weak self] in
            self?.updateMenuLayout()
        }
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        AppUsageAnalytics.shared.recordActivity()
        if NSApp.currentEvent?.type == .rightMouseUp {
            dismissMenu()
            clashRouteViewModel.language = viewModel.appLanguage
            clashConnectionViewModel.language = viewModel.appLanguage
            clashRoutePopoverController.toggle(
                relativeTo: sender,
                automaticallyTest: true)
        } else {
            clashRoutePopoverController.close()
            showMenu(relativeTo: sender)
        }
    }

    private func showMenu(relativeTo button: NSStatusBarButton) {
        guard let statusItem,
              let menu else {
            return
        }

        if let placement = MenuBarPanelPlacement.resolve(
            relativeTo: button) {
            updateMenuConstraints(
                visibleHeight: placement.visibleFrame.height)
        }
        updateMenuLayout()

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func updateMenuLayout() {
        guard let hostingView else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(
            width: ceil(fittingSize.width),
            height: ceil(min(fittingSize.height, maximumMenuHeight))
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        menuItem?.view?.frame = NSRect(origin: .zero, size: size)
        menu?.update()
    }

    private func updateMenuConstraints(visibleHeight: CGFloat) {
        maximumMenuHeight = MenuBarPanelLayout.maximumHeight(
            visibleHeight: visibleHeight)
        menuPresentationSizing.maximumScrollableHeight =
            MenuBarPanelLayout.maximumScrollableHeight(
                visibleHeight: visibleHeight)
        hostingView?.invalidateIntrinsicContentSize()
    }

    private func dismissMenu() {
        menu?.cancelTracking()
    }

    private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    func showClashRoutes(automaticallyTest: Bool = true) {
        guard let button = statusItem?.button else { return }
        dismissMenu()
        clashRouteViewModel.language = viewModel.appLanguage
        clashConnectionViewModel.language = viewModel.appLanguage
        clashRoutePopoverController.show(
            relativeTo: button,
            automaticallyTest: automaticallyTest)
    }

    private func handleConnectivityCheck() {
        updateStatusItem()

        guard viewModel.configuredProviders.contains(.codex) else {
            consecutiveUnreachableChecks = 0
            hasHandledCurrentOutage = false
            return
        }

        switch connectivityMonitor.state {
        case .unknown:
            return
        case .reachable:
            consecutiveUnreachableChecks = 0
            hasHandledCurrentOutage = false
        case .unreachable:
            consecutiveUnreachableChecks += 1
            guard consecutiveUnreachableChecks >= 2,
                  !hasHandledCurrentOutage,
                  recoveryTask == nil else {
                return
            }
            hasHandledCurrentOutage = true
            beginAutomaticRecovery()
        }
    }

    private func beginAutomaticRecovery() {
        clashRouteViewModel.language = viewModel.appLanguage
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await clashRouteViewModel.attemptAutomaticRecovery {
                await self.connectivityMonitor.recheckNow() == .reachable
            }

            switch outcome {
            case let .recovered(result):
                await ClashRecoveryNotificationService.shared.notifyRecovery(
                    result,
                    language: self.viewModel.appLanguage)
            case .suppressed:
                break
            case let .needsAttention(shouldTestWhenShown):
                self.showClashRoutes(
                    automaticallyTest: shouldTestWhenShown)
            }

            self.recoveryTask = nil
        }
    }

    // MARK: - Active screen dimming

    /// 监听"激活屏变化"和"window 跨屏",让 statusView 跟随系统半透明规范:
    /// 非激活屏 0.5 opacity(NSScreen.main 在 macOS 14+ 是用户当前激活屏)。
    private func installActiveScreenObservers(button: NSStatusBarButton) {
        let refresh = { [weak self, weak button] in
            guard let button else { return }
            // 优先用 button 所在 window 的 screen;fallback 走 NSScreen.screens 几何
            let screen = button.window?.screen ?? self?.screenContaining(button: button)
            let isActive = (screen == NSScreen.main)
#if DEBUG
            NSLog("[menubar-dim] screen=%@ main=%@ isActive=%d", String(describing: screen), String(describing: NSScreen.main), isActive ? 1 : 0)
#endif
            self?.statusView.applyDim(isOnActiveScreen: isActive)
        }
        let paramsToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in refresh() }
        screenObserverTokens.append(paramsToken)

        if let win = button.window {
            let winToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: win, queue: .main
            ) { _ in refresh() }
            screenObserverTokens.append(winToken)
        }
    }

    deinit {
        // 单例场景下不会真跑,但单测 / 未来替换会用到 —— 显式 removeObserver
        // 避免 zombie observer 留存。`NotificationCenter.removeObserver` 自身线程安全。
        if let accessibilityDisplayObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityDisplayObserver)
        }
        let tokens = screenObserverTokens
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func stop() {
        compactImageAnimationTask?.cancel()
        compactImageAnimationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        sleepProtectionCoordinator.stop()
        viewModel.appPresenceMonitor.stop()
        dismissMenu()
        clashRoutePopoverController.close()
        clashConnectionViewModel.stop()
        connectivityMonitor.stop()
        mobileDashboardService.stopForApplicationTermination()
    }

    /// NSStatusItem.button 在某些 macOS 版本上无 window — 用 button 的全局 frame 反查 screen
    private func screenContaining(button: NSStatusBarButton) -> NSScreen? {
        // button 自身坐标 = window 坐标(NSStatusItem 没挪移);取 frame.origin 在 NSScreen.screens 里查找
        let origin = button.convert(button.bounds, to: nil).origin
        let originOnScreen: NSPoint
        if let win = button.window {
            originOnScreen = win.convertPoint(toScreen: origin)
        } else {
            originOnScreen = origin
        }
        for screen in NSScreen.screens where screen.frame.contains(originOnScreen) {
            return screen
        }
        return nil
    }

    // MARK: - Status item rendering

    private func scheduleAppearanceUpdate() {
        guard !appearanceUpdateScheduled else { return }
        appearanceUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceUpdateScheduled = false
            // Snapshot callbacks commonly report no persistent appearance change.
            // Avoid even layout/accessibility writes in that case.
            if let button = self.statusItem?.button,
               self.viewModel.menuBarAppearance == .compactRing,
               self.makeCompactRenderState(button: button) == self.compactRenderState { return }
            self.updateStatusItem()
        }
    }

    private func updateStatusItem() {
        switch viewModel.menuBarAppearance {
        case .detailedText:
            compactImageAnimationTask?.cancel()
            compactImageAnimationTask = nil
            compactImageFrames.removeAll()
            compactRenderState = nil
            statusItem?.button?.image = nil
            attachStatusViewIfNeeded()
            statusView.isHidden = false
            let text = viewModel.statusBarText
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            statusView.showDetailed(
                line1: parts.first ?? text,
                line2: parts.count > 1 ? parts[1] : "")
        case .compactRing:
            statusView.showCompact(
                snapshots: displayedCompactSnapshots,
                codexConnectivity: connectivityMonitor.state,
                paceDisplayMode: viewModel.menuBarPaceDisplayMode,
                isSelfTesting: viewModel.isMenuBarSelfTesting,
                activeTaskCounts: sleepProtectionCoordinator.activeTaskCounts,
                horizontalPadding: viewModel.menuBarCompactHorizontalPadding,
                ringSpacing: viewModel.menuBarCompactRingSpacing,
                accessibilityLabel: statusItemTooltip)
        }
        statusItem?.button?.toolTip = statusItemTooltip
        updateStatusItemLength()
        if viewModel.menuBarAppearance == .compactRing {
            presentCompactButtonImages()
        }
    }

    private func attachStatusViewIfNeeded() {
        guard let button = statusItem?.button,
              statusView.superview !== button else { return }
        statusView.removeFromSuperview()
        statusView.frame = button.bounds
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)
    }

    private func makeCompactRenderState(button: NSStatusBarButton) -> CompactStatusRenderState {
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CompactStatusRenderState(
            snapshots: displayedCompactSnapshots, connectivity: connectivityMonitor.state,
            pace: viewModel.menuBarPaceDisplayMode, selfTesting: viewModel.isMenuBarSelfTesting,
            tasks: sleepProtectionCoordinator.activeTaskCounts,
            padding: viewModel.menuBarCompactHorizontalPadding, spacing: viewModel.menuBarCompactRingSpacing,
            appearance: button.effectiveAppearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])?.rawValue ?? "",
            scale: scale, height: statusView.frame.height,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func presentCompactButtonImages() {
        guard let button = statusItem?.button else { return }
        let renderState = makeCompactRenderState(button: button)
        let scale = renderState.scale
        button.setAccessibilityLabel(statusItemTooltip)
        guard renderState != compactRenderState else {
            statusView.suspendCompactAnimations()
            return
        }
        // Publish the key before AppKit callbacks can reenter this method.
        compactRenderState = renderState
        compactImageAnimationTask?.cancel()
        compactImageAnimationTask = nil

        // A custom status-item subview forces AppKit to bitmap-snapshot the
        // complete view hierarchy for every menu-bar replica. Compact mode is
        // already fully rasterizable, so detach that hierarchy and use the
        // status button's optimized image path instead.
        statusView.removeFromSuperview()
        statusView.appearance = button.effectiveAppearance
        let frames = statusView.renderedCompactFrames(scale: scale)
        guard !frames.isEmpty else {
            button.image = nil
            return
        }

        compactImageFrames = frames
        let elapsed = ProcessInfo.processInfo.systemUptime - compactAnimationEpoch
        let initialIndex = Int(elapsed * Double(StatusBarAnimationCadence.taskWaveFramesPerSecond)) % frames.count
        presentCompactImage(frames[initialIndex], on: button)
        button.setAccessibilityLabel(statusItemTooltip)
        guard frames.count > 1 else { return }

        compactImageAnimationTask = Task { @MainActor [weak self, weak button] in
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - (self?.compactAnimationEpoch ?? 0)
                let index = Int(elapsed * Double(StatusBarAnimationCadence.taskWaveFramesPerSecond)) % frames.count
                if let button {
                    self?.presentCompactImage(frames[index], on: button)
                }
                do {
                    try await Task.sleep(
                        nanoseconds: StatusBarAnimationCadence.continuousNanoseconds)
                } catch {
                    return
                }
                guard self != nil, button != nil else { return }
            }
        }
    }

    private func presentCompactImage(_ image: NSImage, on button: NSStatusBarButton) {
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        if button.image !== image { button.image = image }
    }

    private var statusItemTooltip: String {
        let displayedSnapshots = viewModel.menuBarAppearance == .compactRing
            ? displayedCompactSnapshots
            : [viewModel.menuBarSnapshot]
        let base = displayedSnapshots.map(\.tooltip).joined(separator: "\n")
        if viewModel.menuBarAppearance == .compactRing,
           viewModel.isMenuBarSelfTesting,
           displayedSnapshots.contains(where: { $0.provider == .codex }) {
            return viewModel.appLanguage.menuBarSelfTestTooltip()
        }
        guard displayedSnapshots.contains(where: { $0.provider == .codex }),
              connectivityMonitor.state == .unreachable else { return base }
        return viewModel.appLanguage.codexConnectivityUnavailableTooltip(base: base)
    }

    private var displayedCompactSnapshots: [MenuBarSnapshot] {
        MenuBarCompactSnapshotSelector.select(
            mode: viewModel.menuBarRingDisplayMode,
            snapshots: viewModel.menuBarSnapshots,
            activeProviders: sleepProtectionCoordinator.activeProviders)
    }

    private func updateStatusItemLength() {
        guard let statusItem else { return }
        let targetLength = statusView.preferredWidth
        if abs(statusItem.length - targetLength) > 0.5 {
            statusItem.length = targetLength
        }
        if let button = statusItem.button {
            let targetHeight = max(button.bounds.height, statusView.frame.height)
            statusView.frame = NSRect(x: 0, y: 0, width: targetLength, height: targetHeight)
            statusView.needsLayout = true
        }
    }
}

enum StatusItemMenuAppearance {
    private static let supportedNames: [NSAppearance.Name] = [
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .aqua,
        .darkAqua,
    ]

    static func resolvedName(
        from applicationAppearance: NSAppearance
    ) -> NSAppearance.Name {
        applicationAppearance.bestMatch(from: supportedNames) ?? .aqua
    }

    static func resolved(
        from applicationAppearance: NSAppearance
    ) -> NSAppearance {
        NSAppearance(
            named: resolvedName(from: applicationAppearance)
        ) ?? applicationAppearance
    }
}

// MARK: - @Observable 持续追踪桥接
//
// `withObservationTracking` 只触发一次回调；要"持续追踪"需在 onChange 里
// 重新订阅。下面的工具方法把这段样板收拢,避免在调用处散落。

@MainActor
private func observeProperties<Object: Observable>(
    _ object: Object,
    access: @escaping @MainActor (Object) -> Void,
    onChange: @escaping @MainActor () -> Void
) {
    withObservationTracking {
        access(object)
    } onChange: {
        Task { @MainActor in
            onChange()
            observeProperties(object, access: access, onChange: onChange)
        }
    }
}

/// 在详细文字和紧凑环形之间切换的单一状态栏容器。
@MainActor
private final class StatusBarContentView: NSView {
    private let detailedView = StatusBarTwoLineView()
    private let compactView = StatusBarCompactRingsView()
    private var isCompact = false

    var preferredWidth: CGFloat {
        isCompact ? compactView.preferredWidth : detailedView.preferredWidth
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(detailedView)
        addSubview(compactView)
        compactView.isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(detailedView)
        addSubview(compactView)
        compactView.isHidden = true
    }

    override func layout() {
        super.layout()
        detailedView.frame = bounds
        compactView.frame = bounds
    }

    func showDetailed(line1: String, line2: String) {
        isCompact = false
        compactView.suspendAnimationLoops()
        detailedView.setLine1(line1)
        detailedView.setLine2(line2)
        detailedView.isHidden = false
        compactView.isHidden = true
        needsLayout = true
    }

    func showCompact(
        snapshots: [MenuBarSnapshot],
        codexConnectivity: CodexConnectivityState,
        paceDisplayMode: MenuBarPaceDisplayMode,
        isSelfTesting: Bool,
        activeTaskCounts: [UsageProvider: Int],
        horizontalPadding: Double,
        ringSpacing: Double,
        accessibilityLabel: String
    ) {
        isCompact = true
        compactView.setSnapshots(
            snapshots,
            codexConnectivity: codexConnectivity,
            paceDisplayMode: paceDisplayMode,
            isSelfTesting: isSelfTesting,
            activeTaskCounts: activeTaskCounts,
            horizontalPadding: horizontalPadding,
            ringSpacing: ringSpacing,
            accessibilityLabel: accessibilityLabel)
        detailedView.isHidden = true
        compactView.isHidden = false
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screen = window?.screen {
            applyDim(isOnActiveScreen: screen == NSScreen.main)
        }
    }

    func applyDim(isOnActiveScreen: Bool) {
        wantsLayer = true
        layer?.opacity = isOnActiveScreen ? 1.0 : 0.5
    }

    func suspendCompactAnimations() { compactView.suspendAnimationLoops() }

    func renderedCompactFrames(
        scale: CGFloat,
        showsProviderInitials: Bool = false
    ) -> [NSImage] {
        compactView.renderedFrames(
            scale: scale,
            height: max(22, frame.height),
            showsProviderInitials: showsProviderInitials)
    }
}

/// A compact strip containing one quota ring per provider. Automatic selection
/// can therefore show Codex and Kimi together, while a fixed provider still
/// occupies the original 22pt width. Hover applies to the complete strip.
@MainActor
final class StatusBarCompactRingsView: NSView {
    private static let ringWidth: CGFloat = 19
    private var ringViews: [StatusBarCompactRingView] = []
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var horizontalPadding = CGFloat(
        MenuBarCompactLayoutPreferences.defaultHorizontalPadding)
    private var ringSpacing = CGFloat(
        MenuBarCompactLayoutPreferences.defaultRingSpacing)

    var preferredWidth: CGFloat {
        let count = max(1, ringViews.count)
        return horizontalPadding * 2
            + CGFloat(count) * Self.ringWidth
            + CGFloat(max(0, count - 1)) * ringSpacing
    }

    func setSnapshots(
        _ snapshots: [MenuBarSnapshot],
        codexConnectivity: CodexConnectivityState,
        paceDisplayMode: MenuBarPaceDisplayMode,
        isSelfTesting: Bool,
        activeTaskCounts: [UsageProvider: Int],
        horizontalPadding: Double =
            MenuBarCompactLayoutPreferences.defaultHorizontalPadding,
        ringSpacing: Double =
            MenuBarCompactLayoutPreferences.defaultRingSpacing,
        accessibilityLabel: String
    ) {
        self.horizontalPadding = CGFloat(
            MenuBarCompactLayoutPreferences.horizontalPadding(
                horizontalPadding))
        self.ringSpacing = CGFloat(
            MenuBarCompactLayoutPreferences.ringSpacing(ringSpacing))
        let displayedSnapshots = snapshots.isEmpty ? [] : snapshots
        while ringViews.count < displayedSnapshots.count {
            let ringView = StatusBarCompactRingView()
            ringViews.append(ringView)
            addSubview(ringView)
        }
        while ringViews.count > displayedSnapshots.count {
            let ringView = ringViews.removeLast()
            ringView.suspendAnimationLoops()
            ringView.removeFromSuperview()
        }

        for (ringView, snapshot) in zip(ringViews, displayedSnapshots) {
            ringView.setSnapshot(
                snapshot,
                connectivity:
                    snapshot.provider == .codex
                        ? codexConnectivity
                        : .unknown,
                paceDisplayMode: paceDisplayMode,
                isSelfTesting: isSelfTesting,
                activeTaskCount: activeTaskCounts[snapshot.provider] ?? 0,
                accessibilityLabel: snapshot.tooltip)
            ringView.setHovered(isHovered)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(accessibilityLabel)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, ringView) in ringViews.enumerated() {
            ringView.frame = NSRect(
                x: horizontalPadding
                    + CGFloat(index) * (Self.ringWidth + ringSpacing),
                y: 0,
                width: Self.ringWidth,
                height: bounds.height)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        ringViews.forEach { $0.setHovered(true) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        ringViews.forEach { $0.setHovered(false) }
    }

    func suspendAnimationLoops() {
        ringViews.forEach { $0.suspendAnimationLoops() }
    }

    func renderedFrames(
        scale: CGFloat,
        height: CGFloat,
        showsProviderInitials: Bool = false
    ) -> [NSImage] {
        ringViews.forEach { $0.setHovered(showsProviderInitials) }
        defer { ringViews.forEach { $0.setHovered(false) } }
        let pointSize = NSSize(width: ceil(preferredWidth), height: ceil(height))
        let hasTasks = ringViews.contains { $0.hasActiveTaskForRendering }
        let hasSelfTest = ringViews.contains { $0.isSelfTestingForRendering }
        let hasOffline = ringViews.contains { $0.isOfflineForRendering }
        let duration: Double = hasTasks && (hasSelfTest || hasOffline) ? 9
            : hasSelfTest ? 3 : hasTasks ? StatusBarAnimationCadence.taskWaveDuration : 1
        let animates = hasTasks || hasSelfTest || hasOffline
        let frameCount = !showsProviderInitials && animates
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Int(duration * Double(StatusBarAnimationCadence.taskWaveFramesPerSecond)) : 1
        // Every frame carries native 1x and Retina pixels, including when the
        // primary menu bar lives on a 1x screen. Never upscale a cached 1x frame.
        let scales = Array(Set([CGFloat(1), CGFloat(2), max(1, scale)])).sorted(by: >)
        let frames = (0 ..< frameCount).compactMap { frameIndex -> NSImage? in
            let image = NSImage(size: pointSize)
            for scale in scales {
                let pixelsWide = max(1, Int(ceil(pointSize.width * scale)))
                let pixelsHigh = max(1, Int(ceil(pointSize.height * scale)))
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: pixelsWide,
                    pixelsHigh: pixelsHigh,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap)
                else { return nil }

                bitmap.size = pointSize
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                // NSGraphicsContext(bitmapImageRep:) keeps an identity CTM even
                // when the bitmap representation has a 2x logical size. Draw in
                // points explicitly so Retina frames preserve the on-screen size
                // of the original custom status view.
                context.cgContext.scaleBy(x: scale, y: scale)
                context.cgContext.clear(NSRect(origin: .zero, size: pointSize))

                for (index, ringView) in ringViews.enumerated() {
                    let ringFrame = NSRect(
                        x: horizontalPadding
                            + CGFloat(index) * (Self.ringWidth + ringSpacing),
                        y: 0,
                        width: Self.ringWidth,
                        height: height)
                    ringView.frame = NSRect(
                        origin: .zero,
                        size: ringFrame.size)
                    ringView.setAnimationTimeForRendering(
                        Double(frameIndex) / Double(StatusBarAnimationCadence.taskWaveFramesPerSecond))
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: (ringFrame.minX * scale).rounded() / scale, y: 0)
                    effectiveAppearance.performAsCurrentDrawingAppearance {
                        ringView.draw(ringView.bounds)
                    }
                    context.cgContext.restoreGState()
                }
                NSGraphicsContext.restoreGraphicsState()

                image.addRepresentation(bitmap)
            }
            image.isTemplate = false
            return image
        }
        ringViews.forEach { $0.suspendAnimationLoops() }
        return frames
    }

#if DEBUG
    func setHoveredForTesting(_ value: Bool) {
        isHovered = value
        ringViews.forEach { $0.setHovered(value) }
    }

    var providerInitialCountForTesting: Int {
        ringViews.filter(\.isShowingProviderInitialForTesting).count
    }

    var activeTaskCountsForTesting: [Int] {
        ringViews.map(\.activeTaskCountForTesting)
    }
#endif
}

/// 单一 22pt glance target。
/// 缺口中的字母标识 provider；外环显示剩余；中心上方扇形为 reserve，下方扇形为 deficit。
/// 不可用时显示红色横杠，保留最后已知额度。服务商字母始终可见。
enum MenuBarTaskEnergyMotion {
    static let waveSpanFraction: CGFloat = 0.16
    static let maximumWaveCount = 5
    static let thickWaveLineWidth: CGFloat = 1.15
    static let thinWaveLineWidth: CGFloat = 1.15
    static let thinWaveOpacityScale: CGFloat = 0.45

    static func waveCount(activeTaskCount: Int) -> Int {
        min(maximumWaveCount, max(0, activeTaskCount))
    }

    static func phase(
        basePhase: CGFloat,
        waveIndex: Int,
        waveCount: Int
    ) -> CGFloat {
        guard waveCount > 0 else { return 0 }
        let offset = CGFloat(waveIndex) / CGFloat(waveCount)
        let combined = (basePhase + offset)
            .truncatingRemainder(dividingBy: 1)
        return combined < 0 ? combined + 1 : combined
    }

    /// Counterclockwise orbit position across the complete ring. Both ends of
    /// the phase map to the same top point, so a cycle restarts without a jump.
    static func orbitPosition(phase: CGFloat) -> CGFloat {
        let normalizedPhase = phase
            .truncatingRemainder(dividingBy: 1)
        let forwardPhase = normalizedPhase < 0
            ? normalizedPhase + 1
            : normalizedPhase
        return (1 - forwardPhase).truncatingRemainder(dividingBy: 1)
    }

    /// Map a physical clockwise orbit interval to the visible quota arc.
    /// The 104-degree opening is empty space, not an instantaneous wrap point.
    static func visibleArcInterval(start: CGFloat, end: CGFloat) -> ClosedRange<CGFloat>? {
        let openingEnd = (90 - QuotaSymbolRenderer.ringStartAngle) / 360
        let visibleSpan = QuotaSymbolRenderer.ringSweepAngle / 360
        let lower = max(start, openingEnd)
        let upper = min(end, openingEnd + visibleSpan)
        guard upper > lower else { return nil }
        return max(0, (lower - openingEnd) / visibleSpan)...min(1, (upper - openingEnd) / visibleSpan)
    }

    static func waveLineWidth(
        at position: CGFloat,
        remainingFraction: CGFloat
    ) -> CGFloat {
        let normalizedPosition = position
            .truncatingRemainder(dividingBy: 1)
        let position = normalizedPosition < 0
            ? normalizedPosition + 1
            : normalizedPosition
        let remaining = min(1, max(0, remainingFraction))
        return position < remaining
            ? thickWaveLineWidth
            : thinWaveLineWidth
    }

    static func waveOpacityScale(
        at position: CGFloat,
        remainingFraction: CGFloat
    ) -> CGFloat {
        let normalized = (position.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        return normalized < min(1, max(0, remainingFraction)) ? 1 : thinWaveOpacityScale
    }

    static func waveOpacity(
        clockwiseDistanceFromHead: CGFloat
    ) -> CGFloat {
        let distance = min(
            1,
            max(0, clockwiseDistanceFromHead))
        // A sublinear falloff keeps most of the tail readable at 22pt.
        // It only dissolves quickly near the very end, so the wave reads
        // as flowing energy rather than a travelling dot.
        return pow(1 - distance, 0.65)
    }
}

enum StatusBarAnimationCadence {
    // Cache full-resolution frames once per state change; playback only swaps
    // images. Smooth motion must not trade away spatial resolution or contrast.
    static let selfTestNanoseconds: UInt64 = 66_000_000
    static let taskWaveFramesPerSecond = 30
    static let taskWaveDuration: TimeInterval = 1.8
    static let continuousNanoseconds: UInt64 = 33_333_333
    static let taskWaveSegmentCount = 16
}

@MainActor
final class StatusBarCompactRingView: NSView {
    let preferredWidth: CGFloat = 22
    private static let consumedStrokeAlpha: CGFloat = 0.12
    private static let activeLiveRingOpacity: CGFloat = 1
    private static let offlinePulseMinimumOpacity: CGFloat = 0.32
    private static let offlinePulseDuration: TimeInterval = 1
    private var snapshot = MenuBarSnapshot(
        provider: .codex,
        modelName: nil,
        remainingPercent: nil,
        ringPercent: nil,
        paceDeltaPercent: nil,
        resetsAt: nil,
        state: .loading,
        isLowQuota: false,
        tooltip: "")
    private var connectivity: CodexConnectivityState = .unknown
    private var paceDisplayMode: MenuBarPaceDisplayMode = .staged
    private var isSelfTesting = false
    private var activeTaskCount = 0
    private var selfTestFrame: MenuBarSelfTestFrame?
    private var taskOrbitPhase: CGFloat = 0
    private var offlinePulseOpacity: CGFloat = 1
    private var offlinePulseTask: Task<Void, Never>?
    private var selfTestTask: Task<Void, Never>?
    private var taskEnergyTask: Task<Void, Never>?
    private var isHovered = false

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value
        needsDisplay = true
    }

    func setSnapshot(
        _ snapshot: MenuBarSnapshot,
        connectivity: CodexConnectivityState,
        paceDisplayMode: MenuBarPaceDisplayMode = .staged,
        isSelfTesting: Bool = false,
        activeTaskCount: Int = 0,
        accessibilityLabel: String
    ) {
        let normalizedTaskCount = max(0, activeTaskCount)
        let normalizedSelfTesting = isSelfTesting && snapshot.provider == .codex
        let stateChanged = self.snapshot != snapshot
            || self.connectivity != connectivity
            || self.paceDisplayMode != paceDisplayMode
            || self.isSelfTesting != normalizedSelfTesting
            || self.activeTaskCount != normalizedTaskCount

        setAccessibilityLabel(accessibilityLabel)
        guard stateChanged else { return }

        self.snapshot = snapshot
        self.connectivity = connectivity
        self.paceDisplayMode = paceDisplayMode
        self.isSelfTesting = normalizedSelfTesting
        self.activeTaskCount = normalizedTaskCount
        updateOfflinePulseAnimation()
        updateSelfTestAnimation()
        updateTaskEnergyAnimation()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let state = selfTestFrame == nil ? snapshot.state : .ready
        let percent = selfTestFrame?.ringPercent ?? snapshot.ringPercent
        let delta = selfTestFrame?.paceDeltaPercent ?? snapshot.paceDeltaPercent
        let glyph = MenuBarPaceGlyph(deltaPercent: delta, mode: paceDisplayMode)
        let status: QuotaSymbolRenderer.Status
        if isOffline { status = .offline }
        else {
            switch state {
            case .ready: status = .ready
            case .loading: status = .loading
            case .needsSetup: status = .setup
            case .unavailable: status = .unavailable
            case .failed: status = .failed
            }
        }
        let symbolRect = bounds.insetBy(dx: 1, dy: 1)
        QuotaSymbolRenderer.draw(
            in: symbolRect, initial: snapshot.providerInitial,
            remaining: percent.map { $0 / 100 },
            signedFill: delta.map { _ in glyph.fillFraction * (glyph.direction == .deficit ? -1 : 1) },
            status: status,
            lowQuota: selfTestFrame == nil ? snapshot.isLowQuota : (percent ?? 100) <= 20,
            offlineOpacity: offlinePulseOpacity,
            liveOpacity: showsTaskEnergy ? Self.activeLiveRingOpacity : 1)
        if showsTaskEnergy {
            let scale = min(symbolRect.width / 367, symbolRect.height / 410)
            drawTaskEnergyWave(
                center: NSPoint(x: bounds.midX, y: bounds.midY - 21.5 * scale),
                radius: 155.975 * scale,
                originFraction: (percent ?? 0) / 100,
                alpha: 1)
        }
    }

    private var isOffline: Bool {
        snapshot.provider == .codex && snapshot.state != .needsSetup && connectivity == .unreachable && !isSelfTesting
    }

    private var showsTaskEnergy: Bool {
        activeTaskCount > 0 && snapshot.state == .ready && !isOffline && !isSelfTesting
    }

    var isSelfTestingForRendering: Bool { isSelfTesting }
    var isOfflineForRendering: Bool { isOffline }

    func setAnimationTimeForRendering(_ elapsed: Double) {
        setTaskOrbitPhaseForRendering(CGFloat(elapsed / StatusBarAnimationCadence.taskWaveDuration))
        if isSelfTesting {
            selfTestFrame = .frame(elapsed: elapsed, paceDisplayMode: paceDisplayMode)
        }
        if isOffline {
            let wave = (1 + cos(elapsed * 2 * .pi / Self.offlinePulseDuration)) / 2
            offlinePulseOpacity = Self.offlinePulseMinimumOpacity
                + (1 - Self.offlinePulseMinimumOpacity) * CGFloat(wave)
        }
    }

    var hasActiveTaskForRendering: Bool { showsTaskEnergy }

    func setTaskOrbitPhaseForRendering(_ value: CGFloat) {
        taskEnergyTask?.cancel()
        taskEnergyTask = nil
        taskOrbitPhase = value
            .truncatingRemainder(dividingBy: 1)
        if taskOrbitPhase < 0 {
            taskOrbitPhase += 1
        }
    }

    private func updateSelfTestAnimation() {
        guard isSelfTesting else {
            selfTestTask?.cancel()
            selfTestTask = nil
            selfTestFrame = nil
            return
        }
        guard selfTestTask == nil else { return }

        let startTime = ProcessInfo.processInfo.systemUptime
        selfTestFrame = .frame(elapsed: 0, paceDisplayMode: paceDisplayMode)
        selfTestTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let displayMode = self?.paceDisplayMode ?? .staged
                self?.selfTestFrame = .frame(
                    elapsed: elapsed,
                    paceDisplayMode: displayMode)
                self?.needsDisplay = true

                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                do {
                    try await Task.sleep(
                        nanoseconds: reduceMotion
                            ? 1_000_000_000
                            : StatusBarAnimationCadence.selfTestNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    /// Detailed-text mode hides the compact view; pause its display loops until
    /// compact mode becomes visible again without changing refresh state.
    func suspendAnimationLoops() {
        selfTestTask?.cancel()
        selfTestTask = nil
        selfTestFrame = nil
        offlinePulseTask?.cancel()
        offlinePulseTask = nil
        offlinePulseOpacity = 1
        taskEnergyTask?.cancel()
        taskEnergyTask = nil
        taskOrbitPhase = 0
    }

    private func updateTaskEnergyAnimation() {
        guard showsTaskEnergy else {
            taskEnergyTask?.cancel()
            taskEnergyTask = nil
            taskOrbitPhase = 0
            return
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            taskEnergyTask?.cancel()
            taskEnergyTask = nil
            taskOrbitPhase = 0.12
            return
        }
        guard taskEnergyTask == nil else { return }

        let startTime = ProcessInfo.processInfo.systemUptime
        taskOrbitPhase = 0
        taskEnergyTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    taskOrbitPhase = 0.12
                    taskEnergyTask = nil
                    needsDisplay = true
                    return
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                taskOrbitPhase = CGFloat(
                    elapsed.truncatingRemainder(
                        dividingBy: StatusBarAnimationCadence.taskWaveDuration)
                        / StatusBarAnimationCadence.taskWaveDuration)
                needsDisplay = true

                do {
                    try await Task.sleep(
                        nanoseconds: StatusBarAnimationCadence.continuousNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    private func updateOfflinePulseAnimation() {
        guard isOffline else {
            offlinePulseTask?.cancel()
            offlinePulseTask = nil
            offlinePulseOpacity = 1
            return
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            offlinePulseTask?.cancel()
            offlinePulseTask = nil
            offlinePulseOpacity = 1
            return
        }
        guard offlinePulseTask == nil else { return }

        let startTime = ProcessInfo.processInfo.systemUptime
        offlinePulseOpacity = 1
        offlinePulseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if self == nil { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    self?.offlinePulseOpacity = 1
                    self?.offlinePulseTask = nil
                    self?.needsDisplay = true
                    return
                }

                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let phase = elapsed
                    .truncatingRemainder(dividingBy: Self.offlinePulseDuration)
                    / Self.offlinePulseDuration
                let wave = (1 + cos(phase * 2 * .pi)) / 2
                self?.offlinePulseOpacity = Self.offlinePulseMinimumOpacity
                    + (1 - Self.offlinePulseMinimumOpacity) * CGFloat(wave)
                self?.needsDisplay = true
                do {
                    try await Task.sleep(
                        nanoseconds: StatusBarAnimationCadence.continuousNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

#if DEBUG
    var isShowingProviderInitialForTesting: Bool { true }
    var activeTaskCountForTesting: Int { activeTaskCount }

    func setHoveredForTesting(_ value: Bool) {
        setHovered(value)
    }

    func setOfflinePulseOpacityForTesting(_ value: CGFloat) {
        offlinePulseTask?.cancel()
        offlinePulseTask = nil
        offlinePulseOpacity = min(1, max(0, value))
        needsDisplay = true
    }

    func setTaskOrbitPhaseForTesting(_ value: CGFloat) {
        setTaskOrbitPhaseForRendering(value)
        needsDisplay = true
    }
#endif

    /// 每个活跃任务映射为一道沿完整环逆时针前进的能量波，最多五道。
    /// 光带保持在外环内部，按物理圆周运动并遮去顶部缺口。
    /// 剩余段用反差亮线、消耗段用深线；外环自身不降透明度。
    private func drawTaskEnergyWave(
        center: NSPoint,
        radius: CGFloat,
        originFraction: Double,
        alpha: CGFloat
    ) {
        let remainingFraction = min(
            1,
            max(0, CGFloat(originFraction)))
        let waveCount = MenuBarTaskEnergyMotion.waveCount(
            activeTaskCount: activeTaskCount)
        guard waveCount > 0 else { return }

        let maximumSeparatedSpan = 1
            / (CGFloat(waveCount) * 1.45)
        let waveSpan = min(
            MenuBarTaskEnergyMotion.waveSpanFraction,
            maximumSeparatedSpan)
        let segmentCount = StatusBarAnimationCadence.taskWaveSegmentCount

        for waveIndex in 0 ..< waveCount {
            let phase = MenuBarTaskEnergyMotion.phase(
                basePhase: taskOrbitPhase,
                waveIndex: waveIndex,
                waveCount: waveCount)
            let waveHead = MenuBarTaskEnergyMotion.orbitPosition(
                phase: phase)
            let waveTail = waveHead + waveSpan

            let segmentWidth = (waveTail - waveHead)
                / CGFloat(segmentCount)
            for segmentIndex in 0 ..< segmentCount {
                let start = waveHead
                    + CGFloat(segmentIndex) * segmentWidth
                let end = start + segmentWidth
                let midpoint = (start + end) / 2
                let clockwiseDistance = (midpoint - waveHead)
                    / (waveTail - waveHead)
                let waveOpacity =
                    MenuBarTaskEnergyMotion.waveOpacity(
                        clockwiseDistanceFromHead:
                            clockwiseDistance)
                drawTaskEnergyArcSegment(
                    center: center,
                    radius: radius,
                    startFraction: start,
                    endFraction: end,
                    remainingFraction: remainingFraction,
                    color: NSColor.labelColor.withAlphaComponent(
                        min(
                            1,
                            alpha
                                * waveOpacity
                                * 0.78)))
            }
        }
    }

    private func drawTaskEnergyArcSegment(
        center: NSPoint,
        radius: CGFloat,
        startFraction: CGFloat,
        endFraction: CGFloat,
        remainingFraction: CGFloat,
        color: NSColor
    ) {
        var cursor = startFraction
        while cursor < endFraction - 0.000_001 {
            let revolution = floor(cursor)
            let revolutionEnd = revolution + 1
            let pieceEnd = min(endFraction, revolutionEnd)
            guard let visible = MenuBarTaskEnergyMotion.visibleArcInterval(
                start: cursor - revolution, end: pieceEnd - revolution) else {
                cursor = pieceEnd
                continue
            }
            let normalizedStart = visible.lowerBound
            let normalizedEnd = visible.upperBound

            var boundaries = [normalizedStart, normalizedEnd]
            if remainingFraction > normalizedStart + 0.000_001,
               remainingFraction < normalizedEnd - 0.000_001 {
                boundaries.insert(remainingFraction, at: 1)
            }
            for (start, end) in zip(boundaries, boundaries.dropFirst()) {
                let midpoint = (start + end) / 2
                let opacityScale =
                    MenuBarTaskEnergyMotion.waveOpacityScale(
                        at: midpoint,
                        remainingFraction: remainingFraction)
                drawArcSegment(
                    center: center,
                    radius: radius,
                    startFraction: start,
                    endFraction: end,
                    color: (midpoint < remainingFraction ? NSColor.windowBackgroundColor : NSColor.labelColor)
                        .withAlphaComponent(color.alphaComponent * opacityScale),
                    lineWidth: MenuBarTaskEnergyMotion.waveLineWidth(
                        at: midpoint,
                        remainingFraction: remainingFraction))
            }
            cursor = pieceEnd
        }
    }

    private func drawArcSegment(
        center: NSPoint,
        radius: CGFloat,
        startFraction: CGFloat,
        endFraction: CGFloat,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        guard endFraction > startFraction else { return }
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: QuotaSymbolRenderer.ringStartAngle - QuotaSymbolRenderer.ringSweepAngle * startFraction,
            endAngle: QuotaSymbolRenderer.ringStartAngle - QuotaSymbolRenderer.ringSweepAngle * endFraction,
            clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .butt
        color.setStroke()
        path.stroke()
    }


}

/// 两行 NSTextField 容器。直接 addSubview 到 NSStatusBarButton。
@MainActor
private final class StatusBarTwoLineView: NSView {
    private let line1Field = NSTextField(labelWithString: "...")
    private let line2Field = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 4
    private let minimumWidth: CGFloat = 24

    private let font: NSFont = {
        // 9pt 偏小被截；用 10pt 跟 codexbar 看起来更接近
        NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    }()

    var preferredWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let line1Width = (line1Field.stringValue as NSString).size(withAttributes: attributes).width
        let line2Width = (line2Field.stringValue as NSString).size(withAttributes: attributes).width
        return max(minimumWidth, ceil(max(line1Width, line2Width) + horizontalPadding * 2))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUpLabels()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpLabels()
    }

    private func setUpLabels() {
        wantsLayer = false
        addSubview(line1Field)
        addSubview(line2Field)
        for label in [line1Field, line2Field] {
            label.font = font
            label.textColor = .labelColor
            label.backgroundColor = .clear
            label.drawsBackground = false
            label.isBordered = false
            label.isEditable = false
            label.isSelectable = false
            label.cell?.lineBreakMode = .byClipping
            label.alignment = .left
        }
    }

    override func layout() {
        super.layout()
        // 两行：上半行 / 下半行；按 frame 高度均分
        let lineHeight = bounds.height / 2
        let textWidth = max(0, bounds.width - horizontalPadding * 2)
        line1Field.frame = NSRect(x: horizontalPadding, y: lineHeight, width: textWidth, height: lineHeight)
        line2Field.frame = NSRect(x: horizontalPadding, y: 0, width: textWidth, height: lineHeight)
    }

    func setLine1(_ text: String) {
        line1Field.stringValue = text
    }

    func setLine2(_ text: String) {
        line2Field.stringValue = text
    }

}
