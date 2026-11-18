import AppKit
import SwiftUI

@MainActor
final class WarningPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<WarningPanelView>?
    private let lightweightMode: LightweightModeController

    init(lightweightMode: LightweightModeController? = nil) {
        self.lightweightMode = lightweightMode ?? .shared
        super.init()
    }

    func show(usageData: UsageData) {
        if panel == nil {
            createPanel()
        }

        hostingView?.rootView = WarningPanelView(usageData: usageData, language: AppLanguage.current)
        panel?.orderFrontRegardless()
        lightweightMode.didShow("warning")
    }

    func hide() {
        panel?.orderOut(nil)
        lightweightMode.didHide("warning")
    }

    func windowWillClose(_ notification: Notification) {
        lightweightMode.didHide("warning")
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // Position at bottom-right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelX = screenFrame.maxX - 280
            let panelY = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        let hostingView = NSHostingView(
            rootView: WarningPanelView(
                usageData: UsageData(provider: .miniMax, remains: 0, total: 1, timestamp: Date(), models: [], subscribeTitle: nil, subscribeEndTime: nil),
                language: AppLanguage.current
            )
        )
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = NSView.AutoresizingMask(arrayLiteral: .width, .height)

        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        lightweightMode.register("warning", isOpen: { [weak panel] in
            LightweightModeController.isOpen(panel)
        }, release: { [weak self] in
            self?.panel?.delegate = nil
            self?.panel?.contentView = nil
            self?.hostingView = nil
            self?.panel?.close()
            self?.panel = nil
        })
    }
}
