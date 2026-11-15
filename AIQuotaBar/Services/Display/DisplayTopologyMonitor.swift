import AppKit
import Foundation

protocol DisplayTopologyMonitoring: AnyObject {
    /// Screen parameters change when a display is plugged in or unplugged.
    func install(onChange: @escaping () -> Void)
    func removeAll()
}

/// Watches display attach/detach so the display list stays current. The
/// settings pane has no other path to learn about a newly connected screen.
@MainActor
final class DisplayTopologyMonitor: DisplayTopologyMonitoring {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func install(onChange: @escaping () -> Void) {
        removeAll()
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in onChange() }
        }
        observers.append((NotificationCenter.default, token))
    }

    func removeAll() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }
}
