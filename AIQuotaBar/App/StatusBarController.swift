import AppKit
import SwiftUI

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

    private let statusView = StatusBarContentView()
    private let connectivityMonitor = CodexConnectivityMonitor()
    private let clashRouteViewModel = ClashRouteViewModel()
    private let clashConnectionViewModel = ClashConnectionViewModel()
    private lazy var clashRoutePopoverController = ClashRoutePopoverController(
        routeViewModel: clashRouteViewModel,
        connectionViewModel: clashConnectionViewModel,
        sleepProtectionCoordinator: sleepProtectionCoordinator)
    private let initialStatusItemLength: CGFloat = 110
    private var screenObserverTokens: [NSObjectProtocol] = []
    private var consecutiveUnreachableChecks = 0
    private var hasHandledCurrentOutage = false
    private var recoveryTask: Task<Void, Never>?

    init() {
        setupStatusItem()
        setupMenu()
        sleepProtectionCoordinator.start()
        connectivityMonitor.start()
        clashConnectionViewModel.startBackgroundMonitoring()
        viewModel.flushPendingCloudSyncQueue()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: initialStatusItemLength)

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Left-click for usage. Right-click for Codex protection, OpenAI routes, and connections."
            statusView.translatesAutoresizingMaskIntoConstraints = true
            statusView.frame = NSRect(x: 0, y: 0, width: initialStatusItemLength, height: 22)
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
            updateStatusItem()
            installActiveScreenObservers(button: button)
        }

        observeProperties(viewModel) { viewModel in
            _ = viewModel.statusBarText
            _ = viewModel.menuBarSnapshot
            _ = viewModel.menuBarAppearance
            _ = viewModel.menuBarPaceDisplayMode
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

        observeMenuLayoutChanges()
    }

    /// 持续追踪下拉菜单用到的所有 keyPath，任意一个变化时重算 menu 尺寸。
    private func observeMenuLayoutChanges() {
        observeProperties(viewModel) { vm in
            _ = vm.usageData
            _ = vm.error
            _ = vm.providerUsageData
            _ = vm.providerErrors
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
            clashRouteViewModel.language = viewModel.appLanguage
            clashConnectionViewModel.language = viewModel.appLanguage
            clashRoutePopoverController.toggle(
                relativeTo: sender,
                automaticallyTest: true)
        } else {
            clashRoutePopoverController.close()
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

    func showClashRoutes(automaticallyTest: Bool = true) {
        guard let button = statusItem?.button else { return }
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
        recoveryTask?.cancel()
        recoveryTask = nil
        sleepProtectionCoordinator.stop()
        clashRoutePopoverController.close()
        clashConnectionViewModel.stop()
        connectivityMonitor.stop()
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
            let text = viewModel.statusBarText
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            statusView.showDetailed(
                line1: parts.first ?? text,
                line2: parts.count > 1 ? parts[1] : "")
        case .compactRing:
            statusView.showCompact(
                snapshot: viewModel.menuBarSnapshot,
                connectivity: connectivityStateForDisplayedProvider,
                paceDisplayMode: viewModel.menuBarPaceDisplayMode,
                isSelfTesting: viewModel.isMenuBarSelfTesting,
                accessibilityLabel: statusItemTooltip)
        }
        statusItem?.button?.toolTip = statusItemTooltip
        updateStatusItemLength()
    }

    private var connectivityStateForDisplayedProvider: CodexConnectivityState {
        viewModel.menuBarSnapshot.provider == .codex ? connectivityMonitor.state : .unknown
    }

    private var statusItemTooltip: String {
        let base = viewModel.menuBarSnapshot.tooltip
        if viewModel.menuBarAppearance == .compactRing,
           viewModel.isMenuBarSelfTesting,
           viewModel.menuBarSnapshot.provider == .codex {
            return viewModel.appLanguage.menuBarSelfTestTooltip()
        }
        guard connectivityStateForDisplayedProvider == .unreachable else { return base }
        return viewModel.appLanguage.codexConnectivityUnavailableTooltip(base: base)
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
    private let compactView = StatusBarCompactRingView()
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
        snapshot: MenuBarSnapshot,
        connectivity: CodexConnectivityState,
        paceDisplayMode: MenuBarPaceDisplayMode,
        isSelfTesting: Bool,
        accessibilityLabel: String
    ) {
        isCompact = true
        compactView.setSnapshot(
            snapshot,
            connectivity: connectivity,
            paceDisplayMode: paceDisplayMode,
            isSelfTesting: isSelfTesting,
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
}

/// 单一 22pt glance target。
/// Codex: 外环 = Weekly 剩余比例；分半内圆 = 左 deficit / 右 reserve；
/// OpenAI 双域名均不可达时，外环显示全消耗轨道，内圆变为持续明暗的禁止图标。
/// 其他 provider 保留原有的中心字母和剩余额度环。
@MainActor
final class StatusBarCompactRingView: NSView {
    let preferredWidth: CGFloat = 22
    private static let consumedStrokeAlpha: CGFloat = 0.12
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
    private var selfTestFrame: MenuBarSelfTestFrame?
    private var offlineMorph: CGFloat = 0
    private var offlinePulseOpacity: CGFloat = 1
    private var morphTask: Task<Void, Never>?
    private var offlinePulseTask: Task<Void, Never>?
    private var selfTestTask: Task<Void, Never>?

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

    func setSnapshot(
        _ snapshot: MenuBarSnapshot,
        connectivity: CodexConnectivityState,
        paceDisplayMode: MenuBarPaceDisplayMode = .staged,
        isSelfTesting: Bool = false,
        accessibilityLabel: String
    ) {
        let wasOffline = isOffline
        self.snapshot = snapshot
        self.connectivity = connectivity
        self.paceDisplayMode = paceDisplayMode
        self.isSelfTesting = isSelfTesting && snapshot.provider == .codex
        let shouldBeOffline = isOffline
        setAccessibilityLabel(accessibilityLabel)
        if wasOffline != shouldBeOffline {
            animateOfflineMorph(to: shouldBeOffline ? 1 : 0)
        }
        updateOfflinePulseAnimation()
        updateSelfTestAnimation()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(8.0, max(0, min(bounds.width, bounds.height) / 2 - 2.5))
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

        if liveRingAmount > 0.001 {
            switch effectiveState {
            case .ready:
                let progress = min(100, max(0, effectiveRingPercent ?? 0)) / 100
                drawArc(
                    center: center,
                    radius: radius,
                    fraction: progress,
                    color: NSColor.labelColor.withAlphaComponent(liveRingAmount),
                    lineWidth: 2.4)
                drawProgressEndpoint(
                    center: center,
                    radius: radius,
                    fraction: progress,
                    alpha: liveRingAmount)
            case .loading:
                drawArc(
                    center: center,
                    radius: radius,
                    fraction: 0.28,
                    color: NSColor.labelColor.withAlphaComponent(0.58 * liveRingAmount),
                    lineWidth: 2.4)
            case .unavailable, .failed:
                drawUnavailableSlash(
                    center: center,
                    radius: radius,
                    alpha: liveRingAmount)
            }
        }

        if snapshot.provider == .codex {
            drawCodexCore(
                center: center,
                radius: 4.25,
                state: effectiveState,
                paceDeltaPercent: selfTestFrame?.paceDeltaPercent ?? snapshot.paceDeltaPercent)
        } else {
            drawProviderInitial(center: center)
        }
    }

    private var isOffline: Bool {
        snapshot.provider == .codex && connectivity == .unreachable && !isSelfTesting
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
                        nanoseconds: reduceMotion ? 1_000_000_000 : 33_000_000)
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
                    try await Task.sleep(nanoseconds: 33_000_000)
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
                .withAlphaComponent(dividerAlpha * normalAmount)
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

    /// 同色端点让剩余弧的边界在 22pt 尺寸下也清楚；满额时不重复绘制凸点。
    private func drawProgressEndpoint(
        center: NSPoint,
        radius: CGFloat,
        fraction: Double,
        alpha: CGFloat
    ) {
        guard fraction > 0.01, fraction < 0.99 else { return }
        let angle = CGFloat.pi / 2 - CGFloat.pi * 2 * CGFloat(fraction)
        let endpoint = NSPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius)
        let dotRadius: CGFloat = 1.35
        let dot = NSBezierPath(ovalIn: NSRect(
            x: endpoint.x - dotRadius,
            y: endpoint.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2))
        NSColor.labelColor.withAlphaComponent(alpha).setFill()
        dot.fill()
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
