import AppKit
import SwiftUI

final class WarningPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<WarningPanelView>?

    func show(usageData: UsageData) {
        if panel == nil {
            createPanel()
        }

        hostingView?.rootView = WarningPanelView(usageData: usageData)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
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

        // Position at bottom-right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let panelX = screenFrame.maxX - 300
            let panelY = screenFrame.minY + 20
            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        let hostingView = NSHostingView(rootView: WarningPanelView(usageData: UsageData(remains: 0, total: 100, timestamp: Date())))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
    }
}