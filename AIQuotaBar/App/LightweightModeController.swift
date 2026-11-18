import AppKit
import Observation
import OSLog

/// Reclaims closed presentation resources only. No quota, ring, activity,
/// power, reporting or LAN service is owned by this controller.
@MainActor
@Observable
final class LightweightModeController {
    static let shared = LightweightModeController()
    static let enabledKey = "lightweightModeEnabled"
    static let defaultIdleDelay: TimeInterval = 60

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.enabledKey)
            // Enabling starts a fresh grace period, never an immediate purge.
            for id in Array(resources.keys) {
                let hidden = resources[id]?.isOpen() == false ? now() : nil
                resources[id]?.hiddenSince = hidden
            }
            schedule()
        }
    }

    private struct Resource {
        var hiddenSince: TimeInterval?
        let isOpen: () -> Bool
        let release: () -> Void
    }

    private let defaults: UserDefaults
    private let idleDelay: TimeInterval
    private let now: () -> TimeInterval
    @ObservationIgnored private var resources: [String: Resource] = [:]
    @ObservationIgnored private var timer: Timer?
    private let logger = Logger(subsystem: "com.techfanseric.aiquotabar", category: "Lightweight")
    private(set) var releasedResourceCount = 0

    init(defaults: UserDefaults = .standard, idleDelay: TimeInterval = 60,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.idleDelay = max(0, idleDelay)
        self.now = now
        isEnabled = defaults.object(forKey: Self.enabledKey) == nil
            ? true : defaults.bool(forKey: Self.enabledKey)
    }

    func register(_ id: String, isOpen: @escaping () -> Bool, release: @escaping () -> Void) {
        resources[id] = Resource(hiddenSince: isOpen() ? nil : now(), isOpen: isOpen, release: release)
        schedule()
    }

    func didShow(_ id: String) {
        resources[id]?.hiddenSince = nil
        schedule()
    }

    func didHide(_ id: String) {
        resources[id]?.hiddenSince = now()
        schedule()
    }

    /// Visible, miniaturized and sheet-owning windows are still open. A
    /// covered window is not a closed window, nor is merely losing focus.
    static func isOpen(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized || !window.sheets.isEmpty
    }

    func reclaimDueResources() {
        guard isEnabled else { return }
        let time = now()
        for id in Array(resources.keys) {
            guard let resource = resources[id], let hidden = resource.hiddenSince,
                  time - hidden >= idleDelay else { continue }
            guard !resource.isOpen() else {
                resources[id]?.hiddenSince = nil
                continue
            }
            // Remove before callbacks: closing a native window can reenter.
            resources.removeValue(forKey: id)
            resource.release()
            releasedResourceCount += 1
            logger.notice("Released closed presentation: \(id, privacy: .public)")
        }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isEnabled,
              let hidden = resources.values.compactMap(\.hiddenSince).min() else { return }
        let delay = max(0.01, hidden + idleDelay - now())
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaimDueResources() }
        }
        next.tolerance = min(1, idleDelay * 0.05)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        resources.removeAll()
    }

    deinit { timer?.invalidate() }
}
