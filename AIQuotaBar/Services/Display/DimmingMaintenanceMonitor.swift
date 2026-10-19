import AppKit
import Foundation

protocol DimmingMaintenanceMonitoring: AnyObject {
    /// Periodic checks cover gamma resets that emit no display notification.
    /// A configuration event also requests hardware verification/rebinding.
    func install(onCheck: @escaping (_ configurationChanged: Bool) -> Void)
    func removeAll()
}

@MainActor
final class DimmingMaintenanceMonitor: DimmingMaintenanceMonitoring {
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func install(onCheck: @escaping (Bool) -> Void) {
        removeAll()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in onCheck(false) }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let workspace = NSWorkspace.shared.notificationCenter
        for (center, name) in [
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in onCheck(true) }
            }
            observers.append((center, token))
        }
    }

    func removeAll() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    deinit {
        timer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
    }
}
