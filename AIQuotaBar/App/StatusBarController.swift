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
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var menuItem: NSMenuItem?
    private var hostingView: NSHostingView<MenuView>?

    private let statusView = StatusBarTwoLineView()

    init() {
        setupStatusItem()
        setupMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 110)

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp])
            button.toolTip = "Click to see usage details."
            statusView.translatesAutoresizingMaskIntoConstraints = true
            statusView.frame = NSRect(x: 0, y: 0, width: 110, height: 22)
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
            updateStatusItem()
            installActiveScreenObservers(button: button)
        }

        observe(viewModel, \.statusBarText) { [weak self] in
            self?.updateStatusItem()
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
        showMenu()
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

    // MARK: - Active screen dimming

    /// 监听"激活屏变化"和"window 跨屏",让 statusView 跟随系统半透明规范:
    /// 非激活屏 0.5 opacity(NSScreen.main 在 macOS 14+ 是用户当前激活屏)。
    private func installActiveScreenObservers(button: NSStatusBarButton) {
        let refresh = { [weak self, weak button] in
            guard let button else { return }
            // 优先用 button 所在 window 的 screen;fallback 走 NSScreen.screens 几何
            let screen = button.window?.screen ?? self?.screenContaining(button: button)
            let isActive = (screen == NSScreen.main)
            NSLog("[menubar-dim] screen=%@ main=%@ isActive=%d", String(describing: screen), String(describing: NSScreen.main), isActive ? 1 : 0)
            self?.statusView.applyDim(isOnActiveScreen: isActive)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in refresh() }

        if let win = button.window {
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: win, queue: .main
            ) { _ in refresh() }
        }
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
        // 解析 viewModel.statusBarText:两行用 "\n" 分隔
        // 每行格式: "M:85%·-69%·1.5h"
        let text = viewModel.statusBarText
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let line1 = parts.first ?? text
        let line2 = parts.count > 1 ? parts[1] : ""
        statusView.setLine1(line1)
        statusView.setLine2(line2)
    }
}

// MARK: - @Observable 持续追踪桥接
//
// `withObservationTracking` 只触发一次回调；要"持续追踪"需在 onChange 里
// 重新订阅。下面的工具方法把这段样板收拢,避免在调用处散落。

@MainActor
private func observe<Object: Observable, Value: Equatable>(
    _ object: Object,
    _ keyPath: KeyPath<Object, Value>,
    onChange: @escaping @MainActor () -> Void
) {
    withObservationTracking {
        _ = object[keyPath: keyPath]
    } onChange: {
        Task { @MainActor in
            onChange()
            observe(object, keyPath, onChange: onChange)
        }
    }
}

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

/// 两行 NSTextField 容器。直接 addSubview 到 NSStatusBarButton。
@MainActor
private final class StatusBarTwoLineView: NSView {
    private let line1Field = NSTextField(labelWithString: "...")
    private let line2Field = NSTextField(labelWithString: "")

    private let font: NSFont = {
        // 9pt 偏小被截；用 10pt 跟 codexbar 看起来更接近
        NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    }()

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
        line1Field.frame = NSRect(x: 0, y: lineHeight, width: bounds.width, height: lineHeight)
        line2Field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
    }

    func setLine1(_ text: String) {
        line1Field.stringValue = text
    }

    func setLine2(_ text: String) {
        line2Field.stringValue = text
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // macOS 14+ 把 NSStatusItem.button 挂在 NSScreen 自己的 NSStatusBarWindow 上;
        // 系统对 button 内置的 template image/title 会自动 dim 到 ~0.5 opacity,
        // 但 addSubview 的自定义 NSView 不在系统 dim 列表里,要自己处理。
        if let screen = window?.screen {
            applyDim(isOnActiveScreen: screen == NSScreen.main)
        }
    }

    func applyDim(isOnActiveScreen: Bool) {
        // 跟系统行为对齐:非激活屏 0.5 opacity
        wantsLayer = true
        layer?.opacity = isOnActiveScreen ? 1.0 : 0.5
    }
}
