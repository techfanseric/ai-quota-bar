import AppKit
import SwiftUI

private final class StatusButtonHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
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
    private var consecutiveUnreachableChecks = 0
    private var hasHandledCurrentOutage = false
    private var recoveryTask: Task<Void, Never>?
    private var compactImageAnimationTask: Task<Void, Never>?
    private let compactHoverTrackingView = StatusButtonHoverTrackingView()
    private var compactImageFrames: [NSImage] = []
    private var compactHoverImage: NSImage?
    private var compactImageFrameIndex = 0
    private var isCompactButtonHovered = false

    init() {
        sleepProtectionCoordinator.setProtectedProviders(
            viewModel.taskProtectionProviders)
        setupStatusItem()
        setupMenu()
        sleepProtectionCoordinator.start()
        connectivityMonitor.start()
        clashConnectionViewModel.startBackgroundMonitoring()
        viewModel.flushPendingCloudSyncQueue()
        mobileDashboardService.startIfEnabled()
        synchronizeMobileDashboardModelSelection()
        observeMobileDashboardModelSelection()
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
            compactHoverTrackingView.frame = button.bounds
            compactHoverTrackingView.autoresizingMask = [.width, .height]
            compactHoverTrackingView.onHoverChanged = { [weak self] isHovered in
                self?.setCompactButtonHovered(isHovered)
            }
            button.addSubview(compactHoverTrackingView)
            updateStatusItem()
            installActiveScreenObservers(button: button)
        }

        observeProperties(viewModel) { viewModel in
            _ = viewModel.statusBarText
            _ = viewModel.menuBarSnapshot
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

    private func updateStatusItem() {
        switch viewModel.menuBarAppearance {
        case .detailedText:
            compactImageAnimationTask?.cancel()
            compactImageAnimationTask = nil
            compactImageFrames.removeAll()
            compactHoverImage = nil
            isCompactButtonHovered = false
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

    private func presentCompactButtonImages() {
        guard let button = statusItem?.button else { return }
        compactImageAnimationTask?.cancel()
        compactImageAnimationTask = nil

        // A custom status-item subview forces AppKit to bitmap-snapshot the
        // complete view hierarchy for every menu-bar replica. Compact mode is
        // already fully rasterizable, so detach that hierarchy and use the
        // status button's optimized image path instead.
        statusView.removeFromSuperview()
        let scale = button.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let frames = statusView.renderedCompactFrames(scale: scale)
        guard let firstFrame = frames.first else {
            button.image = nil
            return
        }

        compactImageFrames = frames
        compactHoverImage = statusView.renderedCompactFrames(
            scale: scale,
            showsProviderInitials: true).first
        compactImageFrameIndex = 0
        presentCompactImage(firstFrame, on: button)
        button.setAccessibilityLabel(statusItemTooltip)
        guard frames.count > 1 else { return }

        compactImageAnimationTask = Task { @MainActor [weak self, weak button] in
            var index = 0
            while !Task.isCancelled {
                index = (index + 1) % frames.count
                self?.compactImageFrameIndex = index
                if self?.isCompactButtonHovered == false {
                    if let button {
                        self?.presentCompactImage(frames[index], on: button)
                    }
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

    private func setCompactButtonHovered(_ isHovered: Bool) {
        guard viewModel.menuBarAppearance == .compactRing,
              isHovered != isCompactButtonHovered,
              let button = statusItem?.button else { return }
        isCompactButtonHovered = isHovered
        if isHovered, let compactHoverImage {
            presentCompactImage(compactHoverImage, on: button)
        } else if compactImageFrames.indices.contains(compactImageFrameIndex) {
            presentCompactImage(
                compactImageFrames[compactImageFrameIndex],
                on: button)
        }
    }

    private func presentCompactImage(_ image: NSImage, on button: NSStatusBarButton) {
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = image
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
            selection: viewModel.menuBarContentSelection,
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
        let pointSize = NSSize(width: preferredWidth, height: height)
        let frameCount = !showsProviderInitials
            && ringViews.contains(where: { $0.hasActiveTaskForRendering })
            ? Int(
                StatusBarAnimationCadence.taskWaveDuration
                    * Double(StatusBarAnimationCadence.taskWaveFramesPerSecond))
            : 1
        let pixelsWide = max(1, Int(ceil(pointSize.width * scale)))
        let pixelsHigh = max(1, Int(ceil(pointSize.height * scale)))

        let frames = (0 ..< frameCount).compactMap { frameIndex -> NSImage? in
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
                ringView.setTaskOrbitPhaseForRendering(
                    CGFloat(frameIndex) / CGFloat(frameCount))
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: ringFrame.minX, y: 0)
                ringView.draw(ringView.bounds)
                context.cgContext.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()

            let image = NSImage(size: pointSize)
            image.addRepresentation(bitmap)
            image.isTemplate = true
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
/// 外环 = provider 剩余比例；分半内圆 = 左 deficit / 右 reserve；
/// OpenAI 双域名均不可达时，外环显示全消耗轨道，内圆变为持续明暗的禁止图标。
/// 悬停时，内圆临时替换为 provider 首字母。
enum MenuBarTaskEnergyMotion {
    static let waveSpanFraction: CGFloat = 0.16
    static let maximumWaveCount = 5
    static let thickWaveLineWidth: CGFloat = 2.6
    static let thinWaveLineWidth: CGFloat = 1.6
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
        waveLineWidth(
            at: position,
            remainingFraction: remainingFraction) == thinWaveLineWidth
            ? thinWaveOpacityScale
            : 1
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
    // NSStatusItem mirrors its custom view into every menu-bar replica by
    // snapshotting the complete layer tree after each invalidation. Driving a
    // 22-point icon at 30 fps therefore costs substantially more than drawing
    // an ordinary in-window view. These cadences keep continuous motion clear
    // without continuously waking and rasterizing every replica.
    static let selfTestNanoseconds: UInt64 = 66_000_000
    static let taskWaveFramesPerSecond = 15
    static let taskWaveDuration: TimeInterval = 1.8
    static let continuousNanoseconds: UInt64 = 66_000_000
    static let taskWaveSegmentCount = 6
}

@MainActor
final class StatusBarCompactRingView: NSView {
    let preferredWidth: CGFloat = 22
    private static let consumedStrokeAlpha: CGFloat = 0.12
    private static let activeLiveRingOpacity: CGFloat = 0.60
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
    private var offlineMorph: CGFloat = 0
    private var offlinePulseOpacity: CGFloat = 1
    private var morphTask: Task<Void, Never>?
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

        let wasOffline = isOffline
        self.snapshot = snapshot
        self.connectivity = connectivity
        self.paceDisplayMode = paceDisplayMode
        self.isSelfTesting = normalizedSelfTesting
        self.activeTaskCount = normalizedTaskCount
        let shouldBeOffline = isOffline
        if wasOffline != shouldBeOffline {
            animateOfflineMorph(to: shouldBeOffline ? 1 : 0)
        }
        updateOfflinePulseAnimation()
        updateSelfTestAnimation()
        updateTaskEnergyAnimation()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(
            8.0,
            max(0, min(bounds.width, bounds.height) / 2 - 0.5))
        guard radius > 0 else { return }

        drawArc(
            center: center,
            radius: radius,
            fraction: 1,
            color: NSColor.labelColor.withAlphaComponent(Self.consumedStrokeAlpha),
            lineWidth: 1.4)

        let effectiveState: MenuBarSnapshotState = selfTestFrame == nil ? snapshot.state : .ready
        let effectiveRingPercent = selfTestFrame?.ringPercent ?? snapshot.ringPercent
        let liveRingAmount: CGFloat = snapshot.provider == .codex ? 1 - offlineMorph : 1
        let liveRingOpacity: CGFloat = showsTaskEnergy
            ? Self.activeLiveRingOpacity
            : 1

        if liveRingAmount > 0.001 {
            switch effectiveState {
            case .ready:
                let progress = min(100, max(0, effectiveRingPercent ?? 0)) / 100
                drawArc(
                    center: center,
                    radius: radius,
                    fraction: progress,
                    color: NSColor.labelColor.withAlphaComponent(
                        liveRingAmount * liveRingOpacity),
                    lineWidth: 2.4)
                if showsTaskEnergy {
                    drawTaskEnergyWave(
                        center: center,
                        radius: radius,
                        originFraction: progress,
                        alpha: liveRingAmount)
                } else {
                    drawProgressEndpoint(
                        center: center,
                        radius: radius,
                        fraction: progress,
                        alpha: liveRingAmount
                            * liveRingOpacity)
                }
            case .loading:
                drawArc(
                    center: center,
                    radius: radius,
                    fraction: 0.28,
                    color: NSColor.labelColor.withAlphaComponent(
                        0.58 * liveRingAmount * liveRingOpacity),
                    lineWidth: 2.4)
                if showsTaskEnergy {
                    drawTaskEnergyWave(
                        center: center,
                        radius: radius,
                        originFraction: 0.28,
                        alpha: liveRingAmount)
                }
            case .unavailable, .failed:
                drawUnavailableSlash(
                    center: center,
                    radius: radius,
                    alpha: liveRingAmount * liveRingOpacity)
            }
        }

        if isHovered {
            drawProviderInitial(center: center)
        } else {
            drawCodexCore(
                center: center,
                radius: 4.25,
                state: effectiveState,
                paceDeltaPercent: selfTestFrame?.paceDeltaPercent ?? snapshot.paceDeltaPercent)
        }
    }

    private var isOffline: Bool {
        snapshot.provider == .codex && connectivity == .unreachable && !isSelfTesting
    }

    private var showsTaskEnergy: Bool {
        activeTaskCount > 0 && !isOffline && !isSelfTesting
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

    private func animateOfflineMorph(to target: CGFloat) {
        morphTask?.cancel()

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            offlineMorph = target
            needsDisplay = true
            return
        }

        let startValue = offlineMorph
        let startTime = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = 0.2
        morphTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let rawProgress = min(1, max(0, elapsed / duration))
                let easedProgress = rawProgress * rawProgress * (3 - 2 * rawProgress)
                self?.offlineMorph = startValue + (target - startValue) * CGFloat(easedProgress)
                self?.needsDisplay = true

                guard rawProgress < 1 else { return }
                do {
                    try await Task.sleep(nanoseconds: 16_000_000)
                } catch {
                    return
                }
            }
        }
    }

#if DEBUG
    var isShowingProviderInitialForTesting: Bool { isHovered }
    var activeTaskCountForTesting: Int { activeTaskCount }

    func setHoveredForTesting(_ value: Bool) {
        setHovered(value)
    }

    func setOfflineMorphForTesting(_ value: CGFloat) {
        morphTask?.cancel()
        offlineMorph = min(1, max(0, value))
        needsDisplay = true
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

    private func drawCodexCore(
        center: NSPoint,
        radius: CGFloat,
        state: MenuBarSnapshotState,
        paceDeltaPercent: Double?
    ) {
        let glyph = MenuBarPaceGlyph(
            deltaPercent: paceDeltaPercent,
            mode: paceDisplayMode)
        let activeAlpha: CGFloat
        switch state {
        case .ready: activeAlpha = 0.86
        case .loading: activeAlpha = 0.52
        case .unavailable: activeAlpha = 0.44
        case .failed: activeAlpha = 0.68
        }

        let circleRect = NSRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2)
        let circle = NSBezierPath(ovalIn: circleRect)
        let normalAmount = 1 - offlineMorph

        let angle = (.pi / 2) * normalAmount
        let dividerHalfLength = radius - 0.55
        let dividerLineWidth: CGFloat = 1

        if offlineMorph > 0.001 {
            let offlineShape = NSBezierPath()
            offlineShape.append(circle)
            offlineShape.append(cutoutBandPath(
                center: center,
                angle: angle,
                halfLength: radius + 0.35,
                halfWidth: (1.55 * offlineMorph) / 2))
            offlineShape.windingRule = .evenOdd
            NSGraphicsContext.current?.saveGraphicsState()
            circle.addClip()
            NSColor.labelColor
                .withAlphaComponent(offlineMorph * offlinePulseOpacity)
                .setFill()
            offlineShape.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        if glyph.fillFraction > 0, normalAmount > 0.001 {
            NSGraphicsContext.current?.saveGraphicsState()
            circle.addClip()
            // Preserve the day-normalized pace mapping while keeping any non-zero
            // direction visible by flooring its rendered width to one pixel.
            let backingScale = window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            let minimumVisibleWidth = dividerLineWidth / 2 + 1 / max(1, backingScale)
            let fillWidth = max(
                radius * CGFloat(glyph.fillFraction),
                minimumVisibleWidth)
            let fillRect: NSRect
            switch glyph.direction {
            case .deficit:
                fillRect = NSRect(
                    x: center.x - fillWidth,
                    y: center.y - radius,
                    width: fillWidth,
                    height: radius * 2)
            case .reserve:
                fillRect = NSRect(
                    x: center.x,
                    y: center.y - radius,
                    width: fillWidth,
                    height: radius * 2)
            case .onTrack:
                fillRect = .zero
            }
            NSColor.labelColor.withAlphaComponent(activeAlpha * normalAmount).setFill()
            NSBezierPath(rect: fillRect).fill()
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        let leftBorderAlpha: CGFloat
        let rightBorderAlpha: CGFloat
        switch glyph.direction {
        case .deficit:
            leftBorderAlpha = glyph.showsActiveBorder ? activeAlpha : 0
            rightBorderAlpha = Self.consumedStrokeAlpha
        case .onTrack:
            leftBorderAlpha = Self.consumedStrokeAlpha
            rightBorderAlpha = Self.consumedStrokeAlpha
        case .reserve:
            leftBorderAlpha = Self.consumedStrokeAlpha
            rightBorderAlpha = glyph.showsActiveBorder ? activeAlpha : 0
        }
        drawCoreBorderHalf(
            center: center,
            radius: radius,
            isLeft: true,
            alpha: leftBorderAlpha * normalAmount)
        drawCoreBorderHalf(
            center: center,
            radius: radius,
            isLeft: false,
            alpha: rightBorderAlpha * normalAmount)

        let direction = NSPoint(x: cos(angle), y: sin(angle))
        let dividerStart = NSPoint(
            x: center.x - direction.x * dividerHalfLength,
            y: center.y - direction.y * dividerHalfLength)
        let dividerEnd = NSPoint(
            x: center.x + direction.x * dividerHalfLength,
            y: center.y + direction.y * dividerHalfLength)

        if normalAmount > 0.001 {
            let divider = NSBezierPath()
            divider.move(to: dividerStart)
            divider.line(to: dividerEnd)
            divider.lineWidth = dividerLineWidth
            divider.lineCapStyle = .butt
            let dividerAlpha: CGFloat = state == .ready ? 1 : activeAlpha
            NSColor.labelColor
                .withAlphaComponent(dividerAlpha)
                .setStroke()
            divider.stroke()
        }

    }

    private func drawCoreBorderHalf(
        center: NSPoint,
        radius: CGFloat,
        isLeft: Bool,
        alpha: CGFloat
    ) {
        guard alpha > 0.001 else { return }
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: isLeft ? 270 : -90,
            clockwise: !isLeft)
        path.lineWidth = 1.05
        path.lineCapStyle = .butt
        NSColor.labelColor.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func cutoutBandPath(
        center: NSPoint,
        angle: CGFloat,
        halfLength: CGFloat,
        halfWidth: CGFloat
    ) -> NSBezierPath {
        let along = NSPoint(x: cos(angle), y: sin(angle))
        let across = NSPoint(x: -sin(angle), y: cos(angle))
        let corners = [
            NSPoint(
                x: center.x - along.x * halfLength - across.x * halfWidth,
                y: center.y - along.y * halfLength - across.y * halfWidth),
            NSPoint(
                x: center.x + along.x * halfLength - across.x * halfWidth,
                y: center.y + along.y * halfLength - across.y * halfWidth),
            NSPoint(
                x: center.x + along.x * halfLength + across.x * halfWidth,
                y: center.y + along.y * halfLength + across.y * halfWidth),
            NSPoint(
                x: center.x - along.x * halfLength + across.x * halfWidth,
                y: center.y - along.y * halfLength + across.y * halfWidth),
        ]
        let path = NSBezierPath()
        path.move(to: corners[0])
        for corner in corners.dropFirst() {
            path.line(to: corner)
        }
        path.close()
        return path
    }

    private func drawArc(
        center: NSPoint,
        radius: CGFloat,
        fraction: Double,
        color: NSColor,
        lineWidth: CGFloat
    ) {
        guard fraction > 0 else { return }
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(360 * min(1, fraction)),
            clockwise: true)
        path.lineWidth = lineWidth
        // At 99% a round cap visually closes the remaining gap. A butt cap
        // preserves the tiny but meaningful "nearly full" opening.
        path.lineCapStyle = fraction > 0.98 && fraction < 1 ? .butt : .round
        color.setStroke()
        path.stroke()
    }

    /// 同色端点让剩余弧边界在 22pt 下保持清楚。
    private func drawProgressEndpoint(
        center: NSPoint,
        radius: CGFloat,
        fraction: Double,
        alpha: CGFloat,
        dotRadius: CGFloat = 1.35,
        forceVisible: Bool = false
    ) {
        guard fraction > 0.01,
              forceVisible || fraction < 0.99 else {
            return
        }
        let angle = CGFloat.pi / 2 - CGFloat.pi * 2 * CGFloat(fraction)
        let endpoint = NSPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius)
        let dot = NSBezierPath(ovalIn: NSRect(
            x: endpoint.x - dotRadius,
            y: endpoint.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2))
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        dot.fill()
    }

    /// 每个活跃任务映射为一道沿完整环逆时针前进的能量波，最多五道。
    /// 波头最实，尾部沿顺时针方向逐渐透明；经过剩余段时使用粗线，
    /// 经过已消耗段时无缝切换为细线，二者始终共用同一圆心轨道。
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
                let end = start + segmentWidth * 1.08
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
            let normalizedStart = cursor - revolution
            let normalizedEnd = pieceEnd >= revolutionEnd - 0.000_001
                ? CGFloat(1)
                : pieceEnd - revolution

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
                    color: color.withAlphaComponent(
                        color.alphaComponent * opacityScale),
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
            startAngle: 90 - 360 * startFraction,
            endAngle: 90 - 360 * endFraction,
            clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .butt
        color.setStroke()
        path.stroke()
    }

    private func drawUnavailableSlash(center: NSPoint, radius: CGFloat, alpha: CGFloat) {
        let path = NSBezierPath()
        let inset = radius * 0.58
        path.move(to: NSPoint(x: center.x - inset, y: center.y - inset))
        path.line(to: NSPoint(x: center.x + inset, y: center.y + inset))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        let stateAlpha: CGFloat = snapshot.state == .failed ? 0.78 : 0.42
        NSColor.labelColor.withAlphaComponent(stateAlpha * alpha).setStroke()
        path.stroke()
    }

    private func drawProviderInitial(center: NSPoint) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.72),
            .paragraphStyle: paragraph,
        ]
        let text = snapshot.providerInitial as NSString
        let size = text.size(withAttributes: attributes)
        let rect = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2 - 0.25,
            width: size.width,
            height: size.height)
        text.draw(in: rect, withAttributes: attributes)
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
