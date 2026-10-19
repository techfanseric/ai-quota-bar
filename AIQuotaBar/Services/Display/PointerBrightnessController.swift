import AppKit
import ApplicationServices
import Observation

/// NX_SYSDEFINED data1 contains a media-key code and a down/up state.
struct BrightnessKeyPress: Equatable {
    let direction: Double
    let isDown: Bool

    init?(subtype: Int, data: Int) {
        guard subtype == 8 else { return nil }
        let code = (data >> 16) & 0xffff
        let state = (data >> 8) & 0xff
        guard (code == 2 || code == 3), state == 0x0a || state == 0x0b else { return nil }
        direction = code == 2 ? 1 : -1
        isDown = state == 0x0a
    }

    func delta(fine: Bool) -> Double { direction * (fine ? 100.0 / 64 : 100.0 / 16) }
}

struct PointerBrightnessTarget: Equatable {
    let id: CGDirectDisplayID
    let key: String
    let builtin: Bool

    static func index(at point: NSPoint, frames: [NSRect]) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }
}

/// Blocking backend, called only inside StepAwayDimController's hardware gate.
/// Calibration baselines are stored separately from Dim targets and recovery.
final class PointerBrightnessBackend {
    struct SoftwareLevel: Codable {
        let baseline: DisplayGammaTable
        var factor: Float
    }
    static let levelsKey = "pointerBrightnessSoftwareLevels"
    private let builtin: DisplayBrightnessControlling
    private let external: ExternalDisplayBrightnessControlling
    private let gamma: DisplayGammaControlling
    private let defaults: UserDefaults
    private var software: [String: SoftwareLevel]

    init(builtin: DisplayBrightnessControlling = DisplayServicesBrightnessController(),
         external: ExternalDisplayBrightnessControlling = DDCBrightnessController(),
         gamma: DisplayGammaControlling = DisplayGammaController(), defaults: UserDefaults = .standard) {
        self.builtin = builtin
        self.external = external
        self.gamma = gamma
        self.defaults = defaults
        software = defaults.data(forKey: Self.levelsKey)
            .flatMap { try? JSONDecoder().decode([String: SoftwareLevel].self, from: $0) } ?? [:]
    }

    var calibrationBaselines: [String: DisplayGammaTable] {
        software.filter { $0.value.factor < 1 }.mapValues(\.baseline)
    }

    func targets() -> [PointerBrightnessTarget] {
        external.enumerateTargets().map { .init(id: $0.displayID, key: $0.persistenceKey, builtin: false) }
    }

    @discardableResult
    func adjust(_ selection: PointerBrightnessTarget, delta: Double) -> Double? {
        guard delta.isFinite else { return nil }
        if selection.builtin {
            guard let current = builtin.currentBrightness(), current.isFinite else { return nil }
            let desired = min(100, max(0, Double(current) * 100 + delta))
            builtin.setBrightness(Float(desired / 100))
            return desired
        }
        // Rebind by stable identity; a reconnect can change the display ID.
        guard let target = external.enumerateTargets().first(where: { $0.persistenceKey == selection.key }),
              let state = external.readState(of: target),
              let table = gamma.read(displayID: target.displayID), table.isValid else { return nil }
        let maximum = max(1, state.maximumLuminance ?? 100)
        guard state.luminance >= 0, state.luminance <= maximum else { return nil }
        var level = software[selection.key] ?? SoftwareLevel(baseline: table, factor: 1)
        // At normal output, adopt calibration changes made outside this app.
        if level.factor == 1 { level = SoftwareLevel(baseline: table, factor: 1) }
        let current = Self.combinedPercent(hardware: Double(state.luminance) / Double(maximum) * 100,
                                           factor: level.factor)
        let desired = min(100, max(0, current + delta))
        let plan = DisplayDimPlan(targetPercent: desired, builtin: false)
        let updated = ExternalDisplayState(luminance: Int((plan.hardwarePercent * Double(maximum) / 100).rounded()),
                                           maximumLuminance: maximum)
        external.applyState(updated, of: target)
        guard let actual = external.readState(of: target), abs(actual.luminance - updated.luminance) <= 1 else { return nil }
        // Persist the original calibration before changing gamma, including crash recovery.
        level.factor = plan.gammaFactor
        software[selection.key] = level
        persist()
        guard gamma.apply(level.baseline.scaled(by: plan.gammaFactor), displayID: target.displayID) else { return nil }
        return Self.combinedPercent(hardware: Double(actual.luminance) / Double(maximum) * 100,
                                    factor: level.factor)
    }

    static func combinedPercent(hardware: Double, factor: Float) -> Double {
        if hardware > 0 { return min(100, 50 + hardware / 2) }
        return min(50, max(0, (Double(factor) - 0.15) / 0.85 * 50))
    }

    /// Retain normal software brightness through a GPU reset (including UU).
    func maintain() {
        guard software.values.contains(where: { $0.factor < 1 }) else { return }
        for target in external.enumerateTargets() {
            guard let level = software[target.persistenceKey], level.factor < 1 else { continue }
            let expected = level.baseline.scaled(by: level.factor)
            if let actual = gamma.read(displayID: target.displayID), !actual.approximatelyMatches(expected) {
                gamma.apply(expected, displayID: target.displayID)
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(software) { defaults.set(data, forKey: Self.levelsKey) }
    }
}

@MainActor @Observable
final class PointerBrightnessController {
    static let shared = PointerBrightnessController()
    static let enabledKey = "pointerBrightnessKeysEnabled"
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled { start() } else { removeTap() }
        }
    }
    private(set) var listening = false
    private(set) var lastAdjustment: String?
    private let defaults: UserDefaults
    private let backend: PointerBrightnessBackend
    private let dim: StepAwayDimController
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var targets: [PointerBrightnessTarget] = []
    private var pending: [(PointerBrightnessTarget, Double)] = []
    private var worker: Task<Void, Never>?
    private var servicing = false
    private var maintenanceTick = 0
    private var heldKeys: Set<Int> = []

    init(defaults: UserDefaults = .standard, backend: PointerBrightnessBackend = PointerBrightnessBackend(),
         dim: StepAwayDimController? = nil) {
        self.defaults = defaults
        self.backend = backend
        self.dim = dim ?? .shared
        self.dim.normalGammaBaselines = { [backend] in backend.calibrationBaselines }
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
    }

    func start() {
        if timer == nil {
            timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.service() }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
        guard enabled else { return }
        installTap()
        service()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending.removeAll()
        removeTap()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<PointerBrightnessController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard let ns = NSEvent(cgEvent: event),
                      owner.handle(ns) else { return Unmanaged.passUnretained(event) }
                return nil
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(1 << 14), callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        listening = true
    }

    private func removeTap() {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        listening = false
        heldKeys.removeAll()
    }

    /// Runs on the main run loop; never performs DDC I/O inside the event tap.
    private func handle(_ event: NSEvent) -> Bool {
        guard enabled, event.type == .systemDefined,
              let key = BrightnessKeyPress(subtype: Int(event.subtype.rawValue), data: event.data1) else { return false }
        let code = (event.data1 >> 16) & 0xffff
        if !key.isDown { return heldKeys.remove(code) != nil }
        let screens = NSScreen.screens
        guard let index = PointerBrightnessTarget.index(at: NSEvent.mouseLocation, frames: screens.map(\.frame)),
              let id = (screens[index].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
        let selection: PointerBrightnessTarget
        if CGDisplayIsBuiltin(id) != 0 { selection = .init(id: id, key: StepAwayPreferences.builtinKey, builtin: true) }
        else if let target = targets.first(where: {
            $0.id == id || $0.key == "ddc-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        }) { selection = .init(id: id, key: target.key, builtin: false) }
        else { return false } // Preserve native behavior for unsupported displays.
        heldKeys.insert(code)
        let fine = event.modifierFlags.contains([.option, .shift])
        let delta = key.delta(fine: fine)
        if let last = pending.last, last.0 == selection, last.1.sign == delta.sign { pending[pending.count - 1].1 += delta }
        else { pending.append((selection, delta)) }
        drain()
        return true
    }

    private func drain() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty, enabled {
                let (target, delta) = pending.removeFirst()
                let result = await dim.performManualBrightness { [backend] in backend.adjust(target, delta: delta) }
                lastAdjustment = result.map { "\(target.builtin ? "Built-in" : target.key): \(Int($0.rounded()))%" }
                    ?? "Brightness adjustment failed"
            }
            worker = nil
        }
    }

    private func service() {
        guard enabled else { return }
        if !AXIsProcessTrusted() { removeTap() } else { installTap() }
        guard !servicing else { return }
        servicing = true
        maintenanceTick += 1
        let refresh = targets.isEmpty || maintenanceTick % 3 == 0
        Task { [weak self] in
            guard let self else { return }
            let refreshed = await dim.performIdleBrightnessMaintenance { [backend] in
                backend.maintain()
                return refresh ? backend.targets() : nil
            }
            if let refreshed { targets = refreshed }
            servicing = false
        }
    }
}
