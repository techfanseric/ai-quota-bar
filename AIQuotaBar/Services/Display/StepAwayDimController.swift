import AppKit
import Foundation
import OSLog

// MARK: - Activity monitoring (pointer + keyboard)

protocol ActivityMonitorInstalling: AnyObject {
    /// Starts reporting pointer and keyboard activity through the handler.
    func install(onActivity: @escaping () -> Void)

    /// Stops all monitoring.
    func removeAll()
}

/// Global input activity monitor: pointer moves, drags and scroll wheels
/// arrive through NSEvent global/local monitors (no permission needed),
/// key presses through a listen-only CGEventTap which requires the
/// Accessibility permission and is silently skipped when it is missing.
@MainActor
final class GlobalActivityMonitorInstaller: ActivityMonitorInstalling {
    private var globalMonitors: [Any] = []
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?

    func install(onActivity handler: @escaping () -> Void) {
        removeAll()
        let pointerMask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
        ]
        globalMonitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: pointerMask) { _ in
                handler()
            })
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: pointerMask
        ) { event in
            handler()
            return event
        }
        installKeyEventTap(handler: handler)
    }

    func removeAll() {
        for monitor in globalMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        KeyEventTapBridge.handler = nil
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }
    }

    private func installKeyEventTap(handler: @escaping () -> Void) {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: KeyEventTapBridge.callback,
            userInfo: nil) else {
            // Accessibility not granted: pointer activity still restores.
            return
        }
        KeyEventTapBridge.handler = handler
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTapSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

/// CGEventTap callbacks are plain C functions and cannot capture context,
/// so the handler hops through a process-wide bridge.
private enum KeyEventTapBridge {
    nonisolated(unsafe) static var handler: (() -> Void)?

    nonisolated(unsafe) static let callback: CGEventTapCallBack = { _, _, event, _ in
        if event.type == .keyDown {
            DispatchQueue.main.async {
                handler?()
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Instant black shade

/// User preferences for the step-away shade.  A shared observable so the
/// settings pane and the dim controller always agree; backed by defaults.
@MainActor
@Observable
final class StepAwayPreferences {
    static let shared = StepAwayPreferences()
    static let opacityKey = "stepAwayShadeOpacityPercent"
    static let opacityRange: ClosedRange<Double> = 60...100

    private let defaults: UserDefaults

    /// Shade opacity in percent: 100 is fully black, lower values let the
    /// screen faintly show its content.
    var shadeOpacityPercent: Double {
        didSet {
            let clamped = shadeOpacityPercent.clamped(
                to: Self.opacityRange)
            if clamped != shadeOpacityPercent {
                shadeOpacityPercent = clamped
                return
            }
            defaults.set(shadeOpacityPercent, forKey: Self.opacityKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 90 by default: first-time users get a translucent "faintly
        // visible" shade instead of a startling full blackout.
        let stored = defaults.object(forKey: Self.opacityKey) as? Double
        shadeOpacityPercent = (stored ?? 90).clamped(to: Self.opacityRange)
    }

    var shadeAlpha: Double {
        shadeOpacityPercent / 100
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

protocol ScreenShadeInstalling: AnyObject {
    /// Covers every screen with a black shade of the given opacity.
    /// 1.0 is fully black; lower values faintly show content.
    func installShades(alpha: Double)

    /// Removes all shades.
    func removeShades()
}

/// One borderless black window per screen at the screen-saver level, so
/// content disappears the instant "step away" is pressed while the DDC
/// dimming continues in the background for energy saving.  The shades
/// accept mouse-moved events so the local activity monitor still sees
/// pointer movement over them.
@MainActor
final class ScreenShadeOverlayInstaller: ScreenShadeInstalling {
    private var windows: [NSWindow] = []

    func installShades(alpha: Double) {
        removeShades()
        let opaque = alpha >= 0.999
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            window.backgroundColor = .black
            window.isOpaque = opaque
            window.alphaValue = alpha
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary,
            ]
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func removeShades() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

// MARK: - Step-away dimming

struct SavedDisplayLevels: Codable, Equatable {
    /// Built-in user brightness, nil when it could not be read.
    var builtinBrightness: Float?
    /// Captured levels by persistence key; only displays whose luminance
    /// could be read are present, so nothing is ever dimmed blind.
    var externalStates: [String: ExternalDisplayState]

    var isMeaningful: Bool {
        builtinBrightness != nil || !externalStates.isEmpty
    }
}

/// One-shot "step away" dimming: every display drops to minimum brightness
/// and the first pointer or keyboard activity restores the saved levels.
/// Levels are persisted while dimmed so a crashed session can restore on
/// the next launch.
@MainActor
@Observable
final class StepAwayDimController {
    static let savedLevelsKey = "stepAwayDimSavedLevels"
    static let defaultGracePeriod: TimeInterval = 1.0

    /// True once every display is dimmed and input monitoring is live.
    private(set) var isActive = false
    /// True while the blocking brightness round-trip is in flight.
    private(set) var isTransitioning = false

    private let builtinBrightness: DisplayBrightnessControlling
    private let externalBrightness: ExternalDisplayBrightnessControlling
    private let monitors: ActivityMonitorInstalling
    private let shades: ScreenShadeInstalling
    private let preferences: StepAwayPreferences
    private let defaults: UserDefaults
    private let gracePeriod: TimeInterval
    private var savedLevels: SavedDisplayLevels?
    private var activityIgnoreUntil = Date.distantPast
    private let logger = Logger(
        subsystem: "com.techfanseric.aiquotabar",
        category: "StepAwayDim"
    )

    init(
        builtinBrightness: DisplayBrightnessControlling =
            DisplayServicesBrightnessController(),
        externalBrightness: ExternalDisplayBrightnessControlling =
            DDCBrightnessController(),
        monitors: ActivityMonitorInstalling? = nil,
        shades: ScreenShadeInstalling? = nil,
        preferences: StepAwayPreferences = .shared,
        defaults: UserDefaults = .standard,
        gracePeriod: TimeInterval = StepAwayDimController
            .defaultGracePeriod
    ) {
        self.builtinBrightness = builtinBrightness
        self.externalBrightness = externalBrightness
        self.monitors = monitors ?? GlobalActivityMonitorInstaller()
        self.shades = shades ?? ScreenShadeOverlayInstaller()
        self.preferences = preferences
        self.defaults = defaults
        self.gracePeriod = gracePeriod
    }

    /// Dims every reachable display.  The black shades go up immediately so
    /// content is hidden instantly; the brightness round-trip runs off the
    /// main thread for energy saving.  Input monitoring starts only after
    /// dimming completes so the click that triggered dimming cannot
    /// immediately restore.
    ///
    /// With a translucent shade (opacity below 100%) no brightness changes
    /// are made at all: dimming the panel would multiply with the shade and
    /// hide the faint content the user asked for, so that mode is
    /// shade-only.
    func dim() {
        guard !isActive, !isTransitioning else { return }
        let alpha = preferences.shadeAlpha
        if alpha < 0.999 {
            startShadeOnlyDim(alpha: alpha)
            return
        }
        isTransitioning = true
        shades.installShades(alpha: 1)
        let builtin = builtinBrightness
        let external = externalBrightness
        Task.detached(priority: .userInitiated) { [weak self] in
            let saved = Self.captureLevels(
                builtin: builtin, external: external)
            Self.applyDimmedLevels(
                saved, builtin: builtin, external: external)
            await MainActor.run { [weak self] in
                self?.finishDim(with: saved)
            }
        }
    }

    /// Shade-only mode: instant, no brightness round-trip, nothing to
    /// restore except the shades themselves.
    private func startShadeOnlyDim(alpha: Double) {
        shades.installShades(alpha: alpha)
        isActive = true
        savedLevels = nil
        activityIgnoreUntil = Date().addingTimeInterval(gracePeriod)
        monitors.install { [weak self] in
            self?.handleActivity()
        }
        logger.notice(
            "Stepping away: shade-only dim (alpha \(alpha))"
        )
    }

    /// Restores immediately, e.g. from the menu row or app teardown.
    func restore(reason: String) {
        guard isActive else { return }
        isActive = false
        monitors.removeAll()
        shades.removeShades()
        let saved = savedLevels
        savedLevels = nil
        defaults.removeObject(forKey: Self.savedLevelsKey)
        applyInBackground(saved, reason: reason)
        logger.notice(
            "Step-away dimming restored (\(reason, privacy: .public))")
    }

    /// Restores levels left dimmed by a crashed session.  Safe to call on
    /// every launch; a no-op unless a pending payload exists.
    func recoverPendingRestore() {
        guard !isActive, !isTransitioning,
              let data = defaults.data(forKey: Self.savedLevelsKey),
              let saved = try? JSONDecoder().decode(
                SavedDisplayLevels.self, from: data) else {
            return
        }
        defaults.removeObject(forKey: Self.savedLevelsKey)
        applyInBackground(saved, reason: "recovered after restart")
        logger.notice(
            "Recovered step-away dimmed levels from a previous session"
        )
    }

    /// Full teardown: restores and detaches every monitor.
    func stop() {
        monitors.removeAll()
        // A dim still in flight never reaches restore, so the shades must
        // come down here unconditionally.
        shades.removeShades()
        restore(reason: "stopped")
    }

    private func finishDim(with saved: SavedDisplayLevels) {
        isTransitioning = false
        guard saved.isMeaningful else {
            shades.removeShades()
            logger.notice(
                "Step-away dimming skipped: no display brightness readable"
            )
            return
        }
        isActive = true
        savedLevels = saved
        activityIgnoreUntil = Date().addingTimeInterval(gracePeriod)
        monitors.install { [weak self] in
            self?.handleActivity()
        }
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.savedLevelsKey)
        }
        logger.notice("Stepping away: all displays dimmed")
    }

    func handleActivity() {
        guard isActive, !isTransitioning,
              Date() >= activityIgnoreUntil else { return }
        restore(reason: "activity")
    }

    private func applyInBackground(
        _ saved: SavedDisplayLevels?,
        reason: String
    ) {
        let builtin = builtinBrightness
        let external = externalBrightness
        Task.detached(priority: .userInitiated) {
            Self.applyRestoredLevels(
                saved, builtin: builtin, external: external)
            _ = reason
        }
    }

    // MARK: Blocking helpers (off main thread)

    /// Runs a blocking DDC operation for every target in parallel — one
    /// worker per display, since each display owns an independent AV
    /// service.  Total latency becomes the slowest display instead of the
    /// sum of all of them.
    nonisolated private static func forEachTargetParallel(
        _ external: ExternalDisplayBrightnessControlling,
        _ body: @escaping (ExternalDDCDisplay) -> Void
    ) {
        let targets = external.enumerateTargets()
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            body(targets[0])
            return
        }
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            body(targets[index])
        }
    }

    nonisolated private static func captureLevels(
        builtin: DisplayBrightnessControlling,
        external: ExternalDisplayBrightnessControlling
    ) -> SavedDisplayLevels {
        let targets = external.enumerateTargets()
        var states = [ExternalDisplayState?](
            repeating: nil, count: targets.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let state = external.readState(of: targets[index])
            lock.lock()
            states[index] = state
            lock.unlock()
        }
        var externalStates: [String: ExternalDisplayState] = [:]
        for (index, target) in targets.enumerated() {
            if let state = states[index] {
                externalStates[target.persistenceKey] = state
            }
        }
        return SavedDisplayLevels(
            builtinBrightness: builtin.currentBrightness(),
            externalStates: externalStates)
    }

    nonisolated private static func applyDimmedLevels(
        _ saved: SavedDisplayLevels,
        builtin: DisplayBrightnessControlling,
        external: ExternalDisplayBrightnessControlling
    ) {
        if saved.builtinBrightness != nil {
            builtin.setBrightness(0)
        }
        // Only dim displays whose levels were captured; a display that
        // cannot be read has no restore values and is left alone rather
        // than being dimmed blind.
        forEachTargetParallel(external) { target in
            guard let original = saved.externalStates[
                target.persistenceKey] else {
                return
            }
            external.applyDimmedState(to: target, original: original)
        }
    }

    nonisolated private static func applyRestoredLevels(
        _ saved: SavedDisplayLevels?,
        builtin: DisplayBrightnessControlling,
        external: ExternalDisplayBrightnessControlling
    ) {
        guard let saved else { return }
        if let builtinBrightness = saved.builtinBrightness {
            builtin.setBrightness(builtinBrightness)
        }
        guard !saved.externalStates.isEmpty else { return }
        forEachTargetParallel(external) { target in
            guard let state = saved.externalStates[
                target.persistenceKey] else {
                return
            }
            external.applyState(state, of: target)
        }
    }
}
