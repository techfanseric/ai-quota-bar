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

/// Shared target for the settings pane and dim controller, persisted across launches.
@MainActor
@Observable
final class StepAwayPreferences {
    static let shared = StepAwayPreferences()
    static let builtinKey = "builtin"
    static let displayTargetsKey = "stepAwayDisplayTargets"
    static let brightnessKey = "stepAwayTargetBrightnessPercent"
    static let brightnessRange: ClosedRange<Double> = 0...100

    private let defaults: UserDefaults
    private(set) var displayTargets: [String: Double]

    func targetPercent(for key: String) -> Double { displayTargets[key] ?? targetBrightnessPercent }
    func setTargetPercent(_ value: Double, for key: String) {
        displayTargets[key] = Self.clamped(value)
        defaults.set(displayTargets, forKey: Self.displayTargetsKey)
    }

    var targetBrightnessPercent: Double {
        didSet {
            let clamped = Self.clamped(targetBrightnessPercent)
            if targetBrightnessPercent != clamped {
                targetBrightnessPercent = clamped
            }
            defaults.set(targetBrightnessPercent, forKey: Self.brightnessKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayTargets = (defaults.dictionary(forKey: Self.displayTargetsKey) ?? [:])
            .compactMapValues { ($0 as? Double).map(Self.clamped) }
        targetBrightnessPercent = Self.clamped(
            defaults.object(forKey: Self.brightnessKey) as? Double ?? 0)
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }
}

// MARK: - Step-away dimming

struct SavedDisplayLevels: Codable, Equatable {
    /// Built-in user brightness, nil when it could not be read.
    var builtinBrightness: Float?
    /// Captured levels by persistence key; only displays whose luminance
    /// could be read are present, so nothing is ever dimmed blind.
    var externalStates: [String: ExternalDisplayState]
    var gammaTables: [String: DisplayGammaTable]? = nil
    /// Unscaled calibration when normal brightness already uses gamma.
    var dimmingGammaTables: [String: DisplayGammaTable]? = nil

    func gammaBaseline(for key: String) -> DisplayGammaTable? {
        dimmingGammaTables?[key] ?? gammaTables?[key]
    }

    func dimGammaFactor(for key: String, requested: Float) -> Float {
        guard let baseline = gammaBaseline(for: key), baseline.peak > 0,
              let original = gammaTables?[key] else { return requested }
        return min(requested, max(0, min(1, original.peak / baseline.peak)))
    }

    var isMeaningful: Bool {
        builtinBrightness != nil || !externalStates.isEmpty
    }
}

/// One-shot "step away" dimming: supported displays drop to the configured brightness
/// and manual action restores saved levels. Input activity can optionally
/// restore them when smart restore is enabled.
/// Levels are persisted while dimmed so a crashed session can restore on
/// the next launch.
@MainActor
@Observable
final class StepAwayDimController {
    static let shared = StepAwayDimController()
    private(set) var displays: [DisplayBrightnessReading] = []
    private(set) var isRefreshing = false
    private(set) var previewDisplayKey: String?
    private(set) var verification: [String: DisplayBrightnessVerification] = [:]
    private var previewRequest: Task<Void, Never>?
    private var editingDisplayKey: String?
    private var restoreAfterPreviewTransition = false
    private var activeTargetPercent: Double = 0
    private var activeTargets: [String: Double] = [:]
    private var needsDisplayMaintenance = false
    var normalGammaBaselines: () -> [String: DisplayGammaTable] = { [:] }

    static let savedLevelsKey = "stepAwayDimSavedLevels"
    static let smartRestoreKey = "stepAwaySmartRestoreEnabled"
    static let defaultGracePeriod: TimeInterval = 1.0

    /// True while dimmed, including a settings preview.
    private(set) var isActive = false
    /// True while the blocking brightness round-trip is in flight.
    private(set) var isTransitioning = false

    /// Opt-in automatic restoration on input activity. Manual mode is default.
    var smartRestoreEnabled: Bool {
        didSet {
            defaults.set(smartRestoreEnabled, forKey: Self.smartRestoreKey)
            if isActive { updateActivityMonitoring() }
        }
    }

    private let builtinBrightness: DisplayBrightnessControlling
    private let externalBrightness: ExternalDisplayBrightnessControlling
    private let gamma: DisplayGammaControlling
    private let maintenance: DimmingMaintenanceMonitoring
    private let monitors: ActivityMonitorInstalling
    private let defaults: UserDefaults
    private let preferences: StepAwayPreferences
    private let gracePeriod: TimeInterval
    private var savedLevels: SavedDisplayLevels?
    private var dimID: UUID?
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
        gamma: DisplayGammaControlling = DisplayGammaController(),
        maintenance: DimmingMaintenanceMonitoring? = nil,
        monitors: ActivityMonitorInstalling? = nil,
        preferences: StepAwayPreferences = .shared,
        defaults: UserDefaults = .standard,
        gracePeriod: TimeInterval = StepAwayDimController
            .defaultGracePeriod
    ) {
        self.builtinBrightness = builtinBrightness
        self.externalBrightness = externalBrightness
        self.gamma = gamma
        self.monitors = monitors ?? GlobalActivityMonitorInstaller()
        self.maintenance = maintenance ?? DimmingMaintenanceMonitor()
        self.preferences = preferences
        self.defaults = defaults
        self.smartRestoreEnabled = defaults.bool(forKey: Self.smartRestoreKey)
        self.gracePeriod = gracePeriod
    }

    /// All normal brightness operations share the Dim/preview hardware gate.
    /// A manual key explicitly leaves Dim before changing the selected display.
    func performManualBrightness<T>(_ operation: @escaping () -> T) async -> T {
        endPreview()
        while true {
            while isTransitioning || isRefreshing {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // Dim may have become active while we were waiting for its first
            // capture/write. Recheck after every transition, then wait for restore.
            guard isActive else { break }
            restore(reason: "brightness key")
        }
        isTransitioning = true
        let value = await Task.detached(priority: .userInitiated, operation: operation).value
        isTransitioning = false
        return value
    }

    func performIdleBrightnessMaintenance<T>(_ operation: @escaping () -> T?) async -> T? {
        guard !isActive, !isTransitioning, !isRefreshing, previewDisplayKey == nil else { return nil }
        isTransitioning = true
        let value = await Task.detached(priority: .utility, operation: operation).value
        isTransitioning = false
        return value
    }

    /// Shared by the menu button and the status-item right-button hold.
    func toggleDimming() {
        guard !isTransitioning else { return }
        if isActive {
            restore(reason: "manual")
        } else {
            dim()
        }
    }

    /// Lowers readable hardware brightness to the selected target. Displays without
    /// a safe restore value remain unchanged. Gamma extends external dimming.
    func dim() { beginDim(only: nil) }

    func endPreview() {
        previewRequest?.cancel()
        previewRequest = nil
        editingDisplayKey = nil
        if previewDisplayKey != nil { stop() }
    }

    func startPreviewEditing(displayKey: String) {
        guard !isActive || previewDisplayKey == displayKey else { return }
        editingDisplayKey = displayKey
        if !isActive { previewDisplayKey = displayKey }
        monitors.removeAll()
    }

    func finishPreviewEditing(displayKey: String) {
        editingDisplayKey = nil
        if previewDisplayKey != nil { updateActivityMonitoring() }
        requestPreview(displayKey: displayKey)
    }

    /// Coalesce slider movement and serialize writes without losing the latest value.
    func requestPreview(displayKey: String) {
        previewRequest?.cancel()
        previewRequest = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            guard let self else { return }
            while self.isTransitioning || self.isRefreshing {
                do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            self.preview(displayKey: displayKey)
        }
    }

    func preview(displayKey: String) {
        guard !isTransitioning, !isRefreshing else { return }
        if isActive {
            guard previewDisplayKey == displayKey, let saved = savedLevels else { return }
            reapplyPreview(saved)
        } else {
            previewDisplayKey = displayKey
            beginDim(only: displayKey)
        }
    }

    private func reapplyPreview(_ saved: SavedDisplayLevels) {
        let id = UUID()
        dimID = id
        isTransitioning = true
        let targetPercent = preferences.targetBrightnessPercent
        let targets = preferences.displayTargets
        activeTargetPercent = targetPercent
        activeTargets = targets
        let builtin = builtinBrightness
        let external = externalBrightness
        let gamma = self.gamma
        updateActivityMonitoring()
        Task.detached(priority: .userInitiated) { [weak self] in
            Self.applyDimmedLevels(saved, targetPercent: targetPercent, targets: targets,
                builtin: builtin, external: external, gamma: gamma)
            let actual = Self.captureLevels(builtin: builtin, external: external, gamma: gamma)
            let results = Self.verify(saved: saved, actual: actual,
                targetPercent: targetPercent, targets: targets)
            let finished = await MainActor.run { [weak self] in
                guard let self, self.dimID == id else { return false }
                self.verification.merge(results) { _, new in new }
                self.updateReadings(actual)
                self.finishDim(with: saved)
                return true
            }
            if !finished {
                Self.applyRestoredLevels(saved, builtin: builtin, external: external, gamma: gamma)
                await MainActor.run { [weak self] in
                    self?.savedLevels = nil
                    self?.isTransitioning = false
                    self?.defaults.removeObject(forKey: Self.savedLevelsKey)
                }
            }
        }
    }

    private func beginDim(only displayKey: String?) {
        guard !isActive, !isTransitioning, !isRefreshing else { return }
        if displays.isEmpty { displays = Self.connectedScreenRows() }
        let targetPercent = preferences.targetBrightnessPercent
        let targets = preferences.displayTargets
        activeTargetPercent = targetPercent
        activeTargets = targets
        let id = UUID()
        dimID = id
        isTransitioning = true
        let builtin = builtinBrightness
        let external = externalBrightness
        let gamma = self.gamma
        let normalBaselines = normalGammaBaselines()
        Task.detached(priority: .userInitiated) { [weak self] in
            var saved = Self.captureLevels(
                builtin: builtin, external: external, gamma: gamma)
            saved.dimmingGammaTables = normalBaselines.filter { saved.externalStates[$0.key] != nil }
            if let displayKey {
                if displayKey != StepAwayPreferences.builtinKey { saved.builtinBrightness = nil }
                saved.externalStates = saved.externalStates.filter { $0.key == displayKey }
                saved.gammaTables = saved.gammaTables?.filter { $0.key == displayKey }
                saved.dimmingGammaTables = saved.dimmingGammaTables?.filter { $0.key == displayKey }
            }
            let shouldApply = await MainActor.run { [weak self] in
                guard let self, self.dimID == id else { return false }
                // Persist before the first hardware write for crash recovery.
                self.savedLevels = saved
                if saved.isMeaningful,
                   let data = try? JSONEncoder().encode(saved) {
                    self.defaults.set(data, forKey: Self.savedLevelsKey)
                }
                return true
            }
            if shouldApply {
                Self.applyDimmedLevels(
                    saved, targetPercent: targetPercent, targets: targets,
                    builtin: builtin, external: external, gamma: gamma)
            }
            let actual = shouldApply ? Self.captureLevels(
                builtin: builtin, external: external, gamma: gamma) : saved
            let results = Self.verify(saved: saved, actual: actual,
                targetPercent: targetPercent, targets: targets)
            let finished = await MainActor.run { [weak self] in
                guard let self, self.dimID == id else { return false }
                self.verification.merge(results) { _, new in new }
                self.updateReadings(actual)
                self.finishDim(with: saved)
                return true
            }
            if !finished {
                // stop() may arrive during blocking DDC I/O. Restore only
                // after those writes finish, so no late write leaves it dim.
                if shouldApply {
                    Self.applyRestoredLevels(
                        saved, builtin: builtin, external: external, gamma: gamma)
                }
                await MainActor.run { [weak self] in
                    self?.savedLevels = nil
                    self?.isTransitioning = false
                    self?.defaults.removeObject(forKey: Self.savedLevelsKey)
                }
            }
        }
    }

    /// Restores immediately, e.g. from the menu row or app teardown.
    func restore(reason: String) {
        guard isActive else { return }
        isActive = false
        maintenance.removeAll()
        needsDisplayMaintenance = false
        previewRequest?.cancel()
        previewRequest = nil
        previewDisplayKey = nil
        editingDisplayKey = nil
        restoreAfterPreviewTransition = false
        if isTransitioning {
            // The in-flight write must finish before its rollback starts.
            dimID = nil
            monitors.removeAll()
            return
        }
        monitors.removeAll()
        let saved = savedLevels
        savedLevels = nil
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
        applyInBackground(saved, reason: "recovered after restart")
        logger.notice(
            "Recovered step-away dimmed levels from a previous session"
        )
    }

    /// Full teardown: restores and detaches every monitor.
    func stop() {
        maintenance.removeAll()
        needsDisplayMaintenance = false
        monitors.removeAll()
        // Invalidate pending work; it will restore after its final DDC write.
        dimID = nil
        previewDisplayKey = nil
        previewRequest?.cancel()
        editingDisplayKey = nil
        restoreAfterPreviewTransition = false
        restore(reason: "stopped")
    }

    private func finishDim(with saved: SavedDisplayLevels) {
        isTransitioning = false
        dimID = nil
        guard saved.isMeaningful else {
            savedLevels = nil
            previewDisplayKey = nil
            logger.notice("Step-away dimming skipped: no readable hardware brightness")
            return
        }
        isActive = true
        savedLevels = saved
        activityIgnoreUntil = Date().addingTimeInterval(gracePeriod)
        updateActivityMonitoring()
        maintenance.install { [weak self] configurationChanged in
            self?.maintainDimmingIfNeeded(configurationChanged: configurationChanged)
        }
        if restoreAfterPreviewTransition {
            restoreAfterPreviewTransition = false
            restore(reason: "preview activity during adjustment")
        }
        logger.notice("Stepping away: hardware brightness lowered")
    }

    private func updateActivityMonitoring() {
        monitors.removeAll()
        guard editingDisplayKey == nil,
              smartRestoreEnabled || previewDisplayKey != nil else { return }
        activityIgnoreUntil = previewDisplayKey != nil ? Date.distantPast
            : Date().addingTimeInterval(gracePeriod)
        monitors.install { [weak self] in
            self?.handleActivity()
        }
    }

    func handleActivity() {
        guard editingDisplayKey == nil,
              smartRestoreEnabled || previewDisplayKey != nil,
              Date() >= activityIgnoreUntil else { return }
        if previewDisplayKey != nil && isTransitioning {
            restoreAfterPreviewTransition = true
            return
        }
        if previewDisplayKey != nil && !isActive && !isTransitioning {
            endPreview()
            return
        }
        guard isActive else { return }
        // restore() serializes rollback after any maintenance write in flight.
        restore(reason: "activity")
    }

    /// Keep the original baseline and the target that was actually applied.
    /// Never recapture a reset gamma table as the user's restore value.
    func maintainDimmingIfNeeded(configurationChanged: Bool) {
        guard isActive else { return }
        needsDisplayMaintenance = needsDisplayMaintenance || configurationChanged
        guard !isTransitioning, !isRefreshing, let saved = savedLevels else { return }
        let checkHardware = needsDisplayMaintenance
        needsDisplayMaintenance = false
        let targetPercent = activeTargetPercent
        let targets = activeTargets
        let id = UUID()
        dimID = id
        isTransitioning = true
        let builtin = builtinBrightness
        let external = externalBrightness
        let gamma = self.gamma
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.maintainLevels(saved, targetPercent: targetPercent,
                targets: targets, builtin: builtin, external: external,
                gamma: gamma, checkHardware: checkHardware)
            let finished = await MainActor.run { [weak self] in
                guard let self, self.dimID == id, self.isActive else { return false }
                self.isTransitioning = false
                self.dimID = nil
                self.needsDisplayMaintenance = self.needsDisplayMaintenance || result.needsRetry
                if checkHardware {
                    self.displays = Self.connectedScreenRows()
                    self.updateReadings(result.observed)
                    self.verification.merge(Self.verify(saved: saved, actual: result.observed,
                        targetPercent: targetPercent, targets: targets)) { _, new in new }
                } else {
                    for key in saved.gammaTables?.keys.map({ $0 }) ?? [] {
                        guard let baseline = saved.gammaBaseline(for: key) else { continue }
                        guard var status = self.verification[key] else { continue }
                        status.actualGamma = baseline.peak > 0
                            ? result.observed.gammaTables?[key].map { $0.peak / baseline.peak } : nil
                        self.verification[key] = status
                    }
                }
                if result.didRepair {
                    self.logger.notice("Reapplied active dimming after display brightness/gamma reset")
                }
                if self.restoreAfterPreviewTransition {
                    self.restoreAfterPreviewTransition = false
                    self.restore(reason: "preview activity during maintenance")
                }
                return true
            }
            if !finished {
                // Manual/activity restore wins over a late maintenance write.
                Self.applyRestoredLevels(saved, builtin: builtin, external: external, gamma: gamma)
                await MainActor.run { [weak self] in
                    self?.savedLevels = nil
                    self?.isTransitioning = false
                    self?.defaults.removeObject(forKey: Self.savedLevelsKey)
                }
            }
        }
    }

    private struct MaintenanceResult {
        var observed = SavedDisplayLevels(builtinBrightness: nil, externalStates: [:], gammaTables: [:])
        var didRepair = false
        var needsRetry = false
    }

    nonisolated private static func maintainLevels(
        _ saved: SavedDisplayLevels, targetPercent: Double, targets: [String: Double],
        builtin: DisplayBrightnessControlling, external: ExternalDisplayBrightnessControlling,
        gamma: DisplayGammaControlling, checkHardware: Bool
    ) -> MaintenanceResult {
        var result = MaintenanceResult()
        if checkHardware, let original = saved.builtinBrightness {
            let desired = min(original, Float((targets[StepAwayPreferences.builtinKey] ?? targetPercent) / 100))
            if let current = builtin.currentBrightness() {
                if abs(current - desired) > 0.005 {
                    builtin.setBrightness(desired)
                    result.didRepair = true
                }
                result.observed.builtinBrightness = builtin.currentBrightness()
                result.needsRetry = result.observed.builtinBrightness.map { abs($0 - desired) > 0.005 } ?? true
            } else { result.needsRetry = true }
        }
        // Enumerate again so a recreated display ID is matched by stable identity.
        // Periodic gamma checks perform no DDC/I2C brightness reads or writes.
        for target in external.enumerateTargets() {
            let key = target.persistenceKey
            guard let original = saved.externalStates[key] else { continue }
            let plan = DisplayDimPlan(targetPercent: targets[key] ?? targetPercent, builtin: false)
            if checkHardware {
                let desired = original.dimmedLuminance(targetPercent: plan.hardwarePercent)
                if let current = external.readState(of: target) {
                    if current.luminance != desired {
                        external.applyDimmedState(to: target, original: original, targetPercent: plan.hardwarePercent)
                        result.didRepair = true
                        result.observed.externalStates[key] = external.readState(of: target)
                    } else { result.observed.externalStates[key] = current }
                    if result.observed.externalStates[key]?.luminance != desired { result.needsRetry = true }
                } else { result.needsRetry = true }
            }
            let factor = saved.dimGammaFactor(for: key, requested: plan.gammaFactor)
            guard factor < 1, let baseline = saved.gammaBaseline(for: key) else { continue }
            let expected = baseline.scaled(by: factor)
            let current = gamma.read(displayID: target.displayID)
            if current?.approximatelyMatches(expected) != true {
                gamma.apply(expected, displayID: target.displayID)
                result.didRepair = true
                result.observed.gammaTables?[key] = gamma.read(displayID: target.displayID)
            } else { result.observed.gammaTables?[key] = current }
        }
        return result
    }

    private func applyInBackground(
        _ saved: SavedDisplayLevels?,
        reason: String
    ) {
        isTransitioning = true
        let builtin = builtinBrightness
        let external = externalBrightness
        let gamma = self.gamma
        Task.detached(priority: .userInitiated) { [weak self] in
            Self.applyRestoredLevels(
                saved, builtin: builtin, external: external, gamma: gamma)
            let actual = Self.captureLevels(builtin: builtin, external: external, gamma: gamma)
            await MainActor.run { [weak self] in
                self?.updateReadings(actual)
                self?.defaults.removeObject(forKey: Self.savedLevelsKey)
                self?.isTransitioning = false
            }
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
        external: ExternalDisplayBrightnessControlling,
        gamma: DisplayGammaControlling
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
        var tables: [String: DisplayGammaTable] = [:]
        for target in targets where externalStates[target.persistenceKey] != nil {
            tables[target.persistenceKey] = gamma.read(displayID: target.displayID)
        }
        return SavedDisplayLevels(
            builtinBrightness: builtin.currentBrightness(),
            externalStates: externalStates, gammaTables: tables)
    }

    nonisolated private static func applyDimmedLevels(
        _ saved: SavedDisplayLevels,
        targetPercent: Double,
        targets: [String: Double],
        builtin: DisplayBrightnessControlling,
        external: ExternalDisplayBrightnessControlling,
        gamma: DisplayGammaControlling
    ) {
        if let original = saved.builtinBrightness {
            builtin.setBrightness(min(original, Float((targets[StepAwayPreferences.builtinKey] ?? targetPercent) / 100)))
        }
        // Only dim displays whose levels were captured; a display that
        // cannot be read has no restore values and is left alone rather
        // than being dimmed blind.
        forEachTargetParallel(external) { target in
            guard let original = saved.externalStates[
                target.persistenceKey] else {
                return
            }
            let plan = DisplayDimPlan(
                targetPercent: targets[target.persistenceKey] ?? targetPercent, builtin: false)
            external.applyDimmedState(
                to: target, original: original, targetPercent: plan.hardwarePercent)
            if let table = saved.gammaBaseline(for: target.persistenceKey) {
                let factor = saved.dimGammaFactor(for: target.persistenceKey, requested: plan.gammaFactor)
                gamma.apply(table.scaled(by: factor), displayID: target.displayID)
            }
        }
    }

    nonisolated private static func applyRestoredLevels(
        _ saved: SavedDisplayLevels?,
        builtin: DisplayBrightnessControlling,
        external: ExternalDisplayBrightnessControlling,
        gamma: DisplayGammaControlling
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
            if let table = saved.gammaTables?[target.persistenceKey] {
                gamma.apply(table, displayID: target.displayID)
            }
        }
    }
}

struct DisplayBrightnessReading: Identifiable {
    var id: String
    var name: String
    var builtin: Bool
    var currentPercent: Double?
    var rawValue: Int?
    var maximum: Int?
}

struct DisplayBrightnessVerification {
    var expectedHardware: Double
    var actualHardware: Double?
    var expectedGamma: Float
    var actualGamma: Float?
    var matches: Bool {
        guard let actualHardware, abs(actualHardware - expectedHardware) <= 1 else { return false }
        return expectedGamma >= 1 || actualGamma.map { abs($0 - expectedGamma) < 0.025 } == true
    }
}

extension StepAwayDimController {
    private static func connectedScreenRows() -> [DisplayBrightnessReading] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let builtin = CGDisplayIsBuiltin(id) != 0
            let key = builtin ? StepAwayPreferences.builtinKey
                : "ddc-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            return DisplayBrightnessReading(id: key,
                name: screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Display \(id)" : screen.localizedName,
                builtin: builtin, currentPercent: nil, rawValue: nil, maximum: nil)
        }
    }

    /// Read all connected screens, including ones without a usable DDC transport.
    func refreshDisplays() {
        guard !isRefreshing, !isTransitioning, !isActive else { return }
        isRefreshing = true
        let screens = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String, Bool)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return (id, screen.localizedName, CGDisplayIsBuiltin(id) != 0)
        }
        let builtin = builtinBrightness
        let external = externalBrightness
        let gamma = self.gamma
        Task.detached(priority: .userInitiated) { [weak self] in
            let targets = external.enumerateTargets()
            let levels = Self.captureLevels(builtin: builtin, external: external, gamma: gamma)
            let rows = screens.map { id, name, isBuiltin in
                let target = targets.first { $0.displayID == id }
                return DisplayBrightnessReading(
                    id: isBuiltin ? StepAwayPreferences.builtinKey : target?.persistenceKey ?? "unavailable-\(id)",
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Display \(id)" : name,
                    builtin: isBuiltin, currentPercent: nil, rawValue: nil, maximum: nil)
            }
            await MainActor.run { [weak self] in
                self?.displays = rows
                self?.updateReadings(levels)
                self?.isRefreshing = false
            }
        }
    }

    private func updateReadings(_ levels: SavedDisplayLevels) {
        displays = displays.map { row in
            var row = row
            if row.builtin {
                row.currentPercent = levels.builtinBrightness.map { Double($0) * 100 }
            } else {
                let state = levels.externalStates[row.id]
                row.rawValue = state?.luminance
                row.maximum = state?.maximumLuminance
                row.currentPercent = state.map { Double($0.luminance) * 100 / Double($0.maximumLuminance ?? 100) }
            }
            return row
        }
    }

    nonisolated static func verify(
        saved: SavedDisplayLevels, actual: SavedDisplayLevels,
        targetPercent: Double, targets: [String: Double]
    ) -> [String: DisplayBrightnessVerification] {
        var result: [String: DisplayBrightnessVerification] = [:]
        if let original = saved.builtinBrightness {
            result[StepAwayPreferences.builtinKey] = DisplayBrightnessVerification(
                expectedHardware: min(Double(original) * 100, targets[StepAwayPreferences.builtinKey] ?? targetPercent),
                actualHardware: actual.builtinBrightness.map { Double($0) * 100 },
                expectedGamma: 1, actualGamma: nil)
        }
        for (key, original) in saved.externalStates {
            let plan = DisplayDimPlan(targetPercent: targets[key] ?? targetPercent, builtin: false)
            let maximum = Double(original.maximumLuminance ?? 100)
            let peak = saved.gammaBaseline(for: key)?.peak ?? 0
            let actualPeak = actual.gammaTables?[key]?.peak
            result[key] = DisplayBrightnessVerification(
                expectedHardware: Double(original.dimmedLuminance(targetPercent: plan.hardwarePercent)) * 100 / maximum,
                actualHardware: actual.externalStates[key].map { Double($0.luminance) * 100 / maximum },
                expectedGamma: saved.dimGammaFactor(for: key, requested: plan.gammaFactor),
                actualGamma: peak > 0 ? actualPeak.map { $0 / peak } : nil)
        }
        return result
    }
}
