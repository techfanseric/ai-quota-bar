import AppKit
import SwiftUI

enum MenuBarPanelLayout {
    static let width: CGFloat = 296
    static let cornerRadius: CGFloat = 12
    static let topGap: CGFloat = 2
    static let maximumHeightFraction: CGFloat = 0.9
    static let fallbackVisibleHeight: CGFloat = 600
    private static let leftMenuChromeHeight: CGFloat = 56

    static func maximumHeight(visibleHeight: CGFloat) -> CGFloat {
        floor(max(0, visibleHeight) * maximumHeightFraction)
    }

    static func maximumScrollableHeight(
        visibleHeight: CGFloat
    ) -> CGFloat {
        max(
            0,
            maximumHeight(visibleHeight: visibleHeight)
                - leftMenuChromeHeight)
    }
}

struct MenuBarPanelPlacement: Equatable {
    let buttonFrame: NSRect
    let visibleFrame: NSRect

    var maximumHeight: CGFloat {
        MenuBarPanelLayout.maximumHeight(
            visibleHeight: visibleFrame.height)
    }

    func panelFrame(contentSize: NSSize) -> NSRect {
        let width = min(contentSize.width, visibleFrame.width)
        let height = min(contentSize.height, maximumHeight)
        let centeredX = buttonFrame.midX - width / 2
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - width)
        let x = min(max(centeredX, visibleFrame.minX), maximumX)
        let topY = visibleFrame.maxY - MenuBarPanelLayout.topGap
        return NSRect(
            x: x,
            y: max(visibleFrame.minY, topY - height),
            width: width,
            height: height)
    }

    static func resolve(relativeTo button: NSStatusBarButton) -> Self? {
        guard let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrame = window.convertToScreen(frameInWindow)
        let buttonCenter = NSPoint(
            x: buttonFrame.midX,
            y: buttonFrame.midY)
        let screen = NSScreen.screens.first {
            NSMouseInRect(buttonCenter, $0.frame, false)
        } ?? window.screen
        guard let screen else { return nil }
        return Self(
            buttonFrame: buttonFrame,
            visibleFrame: screen.visibleFrame)
    }
}

struct MenuBarPanelSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: MenuBarPanelLayout.cornerRadius,
                    style: .continuous))
            .overlay {
                RoundedRectangle(
                    cornerRadius: MenuBarPanelLayout.cornerRadius,
                    style: .continuous)
                    .stroke(
                        Color(nsColor: .separatorColor)
                            .opacity(0.55),
                        lineWidth: 0.5)
            }
    }
}

@MainActor
final class MenuBarPanel: NSPanel {
    var onDismiss: (() -> Void)?

    private weak var anchorWindow: NSWindow?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient,
        ]
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(
        relativeTo button: NSStatusBarButton,
        placement: MenuBarPanelPlacement,
        contentSize: NSSize
    ) {
        anchorWindow = button.window
        setFrame(
            placement.panelFrame(contentSize: contentSize),
            display: true)
        makeKeyAndOrderFront(nil)
        startEventMonitoring()
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        stopEventMonitoring()
        onDismiss?()
    }

    private func startEventMonitoring() {
        stopEventMonitoring()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.isVisible else { return event }

            if event.type == .keyDown,
               event.keyCode == 53 {
                self.dismiss()
                return nil
            }

            if event.type == .leftMouseDown
                || event.type == .rightMouseDown {
                let eventWindow = event.window
                if eventWindow !== self,
                   eventWindow !== self.anchorWindow {
                    self.dismiss()
                }
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    private func stopEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    deinit {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
    }
}
