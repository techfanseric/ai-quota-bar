import XCTest
@testable import AIQuotaBar

final class DDCPacketBuilderTests: XCTestCase {
    func testGetLuminanceRequestLayout() {
        let request = DDCPacketBuilder.getLuminanceRequest()

        XCTAssertEqual(request.count, 4)
        XCTAssertEqual(request[0], 0x82)
        XCTAssertEqual(request[1], 0x01)
        XCTAssertEqual(request[2], 0x10)
        // DDC/CI checksum: XOR of the payload bytes equals the fixed 0x6E
        // offset (m1ddc wire format, verified against real panels).
        let xor = request.reduce(0) { $0 ^ $1 }
        XCTAssertEqual(xor, 0x6e)
    }

    func testSetLuminanceCommandLayout() {
        let command = DDCPacketBuilder.setLuminanceCommand(value: 42)

        XCTAssertEqual(command.count, 6)
        XCTAssertEqual(command[0], 0x84)
        XCTAssertEqual(command[1], 0x03)
        XCTAssertEqual(command[2], 0x10)
        XCTAssertEqual(command[3], 0)
        XCTAssertEqual(command[4], 42)
        // XOR of the command bytes plus the host address 0x51 is 0x6E,
        // so the full frame XORs to zero.
        let xor = command.reduce(0x51) { $0 ^ $1 }
        XCTAssertEqual(xor, 0x6E)
    }

    func testSetLuminanceCommandEncodesHighByte() {
        let command = DDCPacketBuilder.setLuminanceCommand(value: 0x0102)

        XCTAssertEqual(command[3], 0x01)
        XCTAssertEqual(command[4], 0x02)
    }

    func testSetLuminanceCommandClampsNegativeValues() {
        let command = DDCPacketBuilder.setLuminanceCommand(value: -5)

        XCTAssertEqual(command[3], 0)
        XCTAssertEqual(command[4], 0)
    }

    func testParseLuminanceReply() {
        var reply = [UInt8](repeating: 0, count: 12)
        reply[6] = 0x00
        reply[7] = 0x64  // maximum 100
        reply[8] = 0x00
        reply[9] = 0x33  // current 51

        let luminance = DDCPacketBuilder.parseLuminanceReply(reply)

        XCTAssertEqual(luminance?.current, 51)
        XCTAssertEqual(luminance?.maximum, 100)
    }

    func testParseLuminanceReplyRejectsGarbage() {
        // Slow panels return stale or zeroed buffers while waking up.
        var zeroed = [UInt8](repeating: 0, count: 12)
        XCTAssertNil(DDCPacketBuilder.parseLuminanceReply(zeroed))

        zeroed[6] = 0x02
        zeroed[7] = 0x00
        zeroed[8] = 0x03
        zeroed[9] = 0x00
        XCTAssertNil(
            DDCPacketBuilder.parseLuminanceReply(zeroed),
            "current above maximum must be rejected")

        let short = [UInt8](repeating: 0, count: 4)
        XCTAssertNil(DDCPacketBuilder.parseLuminanceReply(short))
    }
}

@MainActor
final class StepAwayDimControllerTests: XCTestCase {
    private var builtin = FakeStepAwayBuiltinBrightness()
    private var external = FakeStepAwayExternalBrightness()
    private var monitors = FakeActivityMonitors()
    private var shades = FakeScreenShades()
    private var preferences: StepAwayPreferences!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        builtin = FakeStepAwayBuiltinBrightness()
        external = FakeStepAwayExternalBrightness()
        monitors = FakeActivityMonitors()
        shades = FakeScreenShades()
        suiteName = "StepAwayDim-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = StepAwayPreferences(defaults: defaults)
        // The shipping default is 90 (translucent); most tests exercise the
        // full blackout path and pin 100 explicitly.
        preferences.shadeOpacityPercent = 100
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(
        gracePeriod: TimeInterval = 0
    ) -> StepAwayDimController {
        StepAwayDimController(
            builtinBrightness: builtin,
            externalBrightness: external,
            monitors: monitors,
            shades: shades,
            preferences: preferences,
            defaults: defaults,
            gracePeriod: gracePeriod)
    }

    private func runBackgroundWork() async {
        // Let detached dim/restore tasks finish.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        await Task.yield()
    }

    private var pendingPayload: SavedDisplayLevels? {
        guard let data = defaults.data(
            forKey: StepAwayDimController.savedLevelsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(
            SavedDisplayLevels.self, from: data)
    }

    func testDimCapturesLevelsAndZeroesEveryDisplay() async {
        let controller = makeController()

        controller.dim()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0)
        // Every captured lever bottoms out at zero; levers the panel does
        // not expose (ddc-b has luminance only) stay nil untouched.
        let fullState = external.states["ddc-a"]
        XCTAssertEqual(fullState?.luminance, 0)
        XCTAssertEqual(fullState?.contrast, 0)
        XCTAssertEqual(fullState?.redGain, 0)
        XCTAssertEqual(fullState?.greenGain, 0)
        XCTAssertEqual(fullState?.blueGain, 0)
        let bareState = external.states["ddc-b"]
        XCTAssertEqual(bareState?.luminance, 0)
        XCTAssertNil(bareState?.contrast)
        XCTAssertNil(bareState?.redGain)
        // Captured originals persist for crash recovery.
        XCTAssertEqual(pendingPayload?.builtinBrightness, 0.8)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-a"]?.luminance, 40)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-a"]?.contrast, 50)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-a"]?.redGain, 50)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-b"]?.luminance, 60)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-b"]?.contrast, nil)
        XCTAssertTrue(monitors.isInstalled)
    }

    func testActivityAfterGraceRestoresSavedLevels() async {
        let controller = makeController()
        controller.dim()
        await runBackgroundWork()

        controller.handleActivity()
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(monitors.isInstalled)
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertEqual(external.states["ddc-a"]?.contrast, 50)
        XCTAssertEqual(external.states["ddc-a"]?.redGain, 50)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 60)
        XCTAssertNil(pendingPayload)
    }

    func testActivityWithinGraceIsIgnored() async {
        let controller = makeController(gracePeriod: 60)
        controller.dim()
        await runBackgroundWork()

        controller.handleActivity()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        XCTAssertTrue(monitors.isInstalled)
        XCTAssertEqual(builtin.brightness, 0)
    }

    func testRestoreWhileIdleIsNoOp() async {
        let controller = makeController()

        controller.restore(reason: "menu")
        await runBackgroundWork()

        XCTAssertTrue(builtin.appliedValues.isEmpty)
        XCTAssertTrue(external.writes.isEmpty)
        XCTAssertEqual(shades.installCount, 0)
        XCTAssertEqual(shades.removeCount, 0)
    }

    func testShadesGoUpInstantlyAndComeDownOnRestore() async {
        let controller = makeController()

        controller.dim()
        // Shades cover before the background dim finishes.
        XCTAssertEqual(shades.installCount, 1)
        await runBackgroundWork()

        XCTAssertTrue(shades.isCovering)

        controller.handleActivity()
        await runBackgroundWork()

        XCTAssertFalse(shades.isCovering)
        XCTAssertEqual(shades.removeCount, 1)
    }

    func testShadesComeDownWhenNothingMeaningfulWasCaptured() async {
        builtin.canRead = false
        external.unreadableKeys = ["ddc-a", "ddc-b"]
        let controller = makeController()

        controller.dim()
        XCTAssertEqual(shades.installCount, 1)
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(shades.isCovering)
    }

    func testStopRemovesShadesEvenWhenDimIsStillRunning() async {
        let controller = makeController()

        controller.dim()
        controller.stop()

        XCTAssertFalse(shades.isCovering)
        XCTAssertFalse(controller.isActive)
    }

    func testTranslucentShadeSkipsBrightnessRoundTrip() async {
        preferences.shadeOpacityPercent = 80
        let controller = makeController()

        controller.dim()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(shades.installedAlphas, [0.8])
        // No brightness touching at all in shade-only mode.
        XCTAssertTrue(builtin.appliedValues.isEmpty)
        XCTAssertTrue(external.writes.isEmpty)
        XCTAssertNil(pendingPayload)
        XCTAssertTrue(monitors.isInstalled)

        controller.handleActivity()
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(shades.isCovering)
        XCTAssertEqual(builtin.brightness, 0.8)
    }

    func testOpaqueShadeStillDimsDisplays() async {
        preferences.shadeOpacityPercent = 100
        let controller = makeController()

        controller.dim()
        await runBackgroundWork()

        XCTAssertEqual(shades.installedAlphas, [1.0])
        XCTAssertEqual(builtin.brightness, 0)
        XCTAssertTrue(controller.isActive)
    }

    func testDefaultShadeOpacityIsTranslucent() {
        // First-time users get a faintly visible shade, not a startling
        // full blackout.  Uses untouched defaults: setUp writes 100.
        let cleanName = suiteName + "-default"
        let cleanDefaults = UserDefaults(suiteName: cleanName)!
        defer {
            cleanDefaults.removePersistentDomain(forName: cleanName)
        }
        let fresh = StepAwayPreferences(defaults: cleanDefaults)
        XCTAssertEqual(fresh.shadeOpacityPercent, 90)
        XCTAssertEqual(fresh.shadeAlpha, 0.9, accuracy: 0.001)
    }

    func testDefaultOpacitySkipsBrightnessRoundTrip() async {
        let cleanName = suiteName + "-default"
        let cleanDefaults = UserDefaults(suiteName: cleanName)!
        defer {
            cleanDefaults.removePersistentDomain(forName: cleanName)
        }
        let controller = StepAwayDimController(
            builtinBrightness: builtin,
            externalBrightness: external,
            monitors: monitors,
            shades: shades,
            preferences: StepAwayPreferences(defaults: cleanDefaults),
            defaults: cleanDefaults,
            gracePeriod: 0)

        controller.dim()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(shades.installedAlphas, [0.9])
        XCTAssertTrue(builtin.appliedValues.isEmpty)
        XCTAssertTrue(external.writes.isEmpty)
    }

    func testPreferencesClampToSupportedRange() {
        preferences.shadeOpacityPercent = 30
        XCTAssertEqual(preferences.shadeOpacityPercent, 60)
        preferences.shadeOpacityPercent = 150
        XCTAssertEqual(preferences.shadeOpacityPercent, 100)
    }

    func testPreferencesPersistAcrossInstances() {
        preferences.shadeOpacityPercent = 85

        let reloaded = StepAwayPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.shadeOpacityPercent, 85)
    }

    func testStopRestoresAndDetachesMonitors() async {
        let controller = makeController()
        controller.dim()
        await runBackgroundWork()

        controller.stop()
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertFalse(monitors.isInstalled)
    }

    func testUnreadableDisplaysAreSkippedNotBlindDimmed() async {
        builtin.canRead = false
        external.unreadableKeys = ["ddc-a", "ddc-b"]
        let controller = makeController()

        controller.dim()
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(monitors.isInstalled)
        XCTAssertTrue(builtin.appliedValues.isEmpty)
        XCTAssertTrue(external.writes.isEmpty)
        XCTAssertNil(pendingPayload)
    }

    func testLockedLeversAreSkippedAndOriginalsStillPersisted() async {
        // RV200-like panel: contrast and gains are locked (writes leave
        // them unchanged); only luminance dims.
        external = FakeStepAwayExternalBrightness(initialStates: [
            "rv": ExternalDisplayState(
                luminance: 50, contrast: 50,
                redGain: 45, greenGain: 45, blueGain: 50),
        ])
        external.lockedLevers["rv"] = [
            .contrast, .redGain, .greenGain, .blueGain,
        ]
        let controller = makeController()

        controller.dim()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        let state = external.states["rv"]
        XCTAssertEqual(state?.luminance, 0)
        XCTAssertEqual(state?.contrast, 50)
        XCTAssertEqual(state?.redGain, 45)
        // Originals persist untouched so a restore can write them back.
        XCTAssertEqual(pendingPayload?.externalStates["rv"]?.contrast, 50)
        XCTAssertEqual(pendingPayload?.externalStates["rv"]?.redGain, 45)

        controller.handleActivity()
        await runBackgroundWork()

        XCTAssertEqual(external.states["rv"]?.luminance, 50)
        XCTAssertEqual(external.states["rv"]?.contrast, 50)
        XCTAssertEqual(external.states["rv"]?.redGain, 45)
    }

    func testRecoverPendingRestoreAppliesPersistedLevels() async {
        let saved = SavedDisplayLevels(
            builtinBrightness: 0.55,
            externalStates: ["ddc-a": ExternalDisplayState(
                luminance: 25, contrast: 30,
                redGain: 40, greenGain: nil, blueGain: nil)])
        defaults.set(
            try! JSONEncoder().encode(saved),
            forKey: StepAwayDimController.savedLevelsKey)

        let controller = makeController()
        controller.recoverPendingRestore()
        await runBackgroundWork()

        XCTAssertEqual(builtin.brightness, 0.55)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 25)
        XCTAssertEqual(external.states["ddc-a"]?.contrast, 30)
        XCTAssertEqual(external.states["ddc-a"]?.redGain, 40)
        XCTAssertNil(pendingPayload)
    }

    func testRecoverWithoutPendingPayloadIsNoOp() async {
        let controller = makeController()

        controller.recoverPendingRestore()
        await runBackgroundWork()

        XCTAssertTrue(builtin.appliedValues.isEmpty)
        XCTAssertTrue(external.writes.isEmpty)
    }
}

// MARK: - Fakes

private final class FakeStepAwayBuiltinBrightness:
    DisplayBrightnessControlling
{
    var canRead = true
    private(set) var brightness: Float = 0.8
    private(set) var appliedValues: [Float] = []

    func currentBrightness() -> Float? {
        canRead ? brightness : nil
    }

    func setBrightness(_ value: Float) {
        brightness = value
        appliedValues.append(value)
    }
}

/// Levers a fake panel may refuse to apply.
private enum FakeLever: String, Hashable {
    case luminance, contrast, redGain, greenGain, blueGain
}

private final class FakeStepAwayExternalBrightness:
    ExternalDisplayBrightnessControlling
{
    var targets: [ExternalDDCDisplay] = []
    /// Keys whose luminance cannot be read at all.
    var unreadableKeys: Set<String> = []
    /// Levers panels lock (writes leave the value unchanged, like the
    /// RV200's gains).
    var lockedLevers: [String: Set<FakeLever>] = [:]
    private let lock = NSLock()
    private var storedStates: [String: ExternalDisplayState] = [:]
    private var storedWrites: [(key: String, lever: FakeLever, value: Int)] = []

    var states: [String: ExternalDisplayState] {
        lock.lock()
        defer { lock.unlock() }
        return storedStates
    }

    var writes: [(key: String, lever: FakeLever, value: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return storedWrites
    }

    init(
        initialStates: [String: ExternalDisplayState] = [
            "ddc-a": ExternalDisplayState(
                luminance: 40, contrast: 50,
                redGain: 50, greenGain: 50, blueGain: 50),
            "ddc-b": ExternalDisplayState(
                luminance: 60, contrast: nil,
                redGain: nil, greenGain: nil, blueGain: nil),
        ]
    ) {
        storedStates = initialStates
        targets = initialStates.keys.sorted().enumerated().map {
            index, key in
            ExternalDDCDisplay(
                displayID: CGDirectDisplayID(index + 1),
                name: key,
                persistenceKey: key,
                avService: NSObject(),
                chipAddress: 0x37)
        }
    }

    func enumerateTargets() -> [ExternalDDCDisplay] {
        targets
    }

    func readState(
        of target: ExternalDDCDisplay
    ) -> ExternalDisplayState? {
        lock.lock()
        defer { lock.unlock() }
        return unreadableKeys.contains(target.persistenceKey)
            ? nil
            : storedStates[target.persistenceKey]
    }

    func applyDimmedState(
        to target: ExternalDDCDisplay,
        original: ExternalDisplayState
    ) {
        dim(.luminance, original.luminance, target)
        if let contrast = original.contrast {
            dim(.contrast, contrast, target)
        }
        if let redGain = original.redGain {
            dim(.redGain, redGain, target)
        }
        if let greenGain = original.greenGain {
            dim(.greenGain, greenGain, target)
        }
        if let blueGain = original.blueGain {
            dim(.blueGain, blueGain, target)
        }
    }

    func applyState(
        _ state: ExternalDisplayState,
        of target: ExternalDDCDisplay
    ) {
        lock.lock()
        defer { lock.unlock() }
        storedStates[target.persistenceKey] = state
        storedWrites.append((target.persistenceKey, .luminance, state.luminance))
        if let contrast = state.contrast {
            storedWrites.append((target.persistenceKey, .contrast, contrast))
        }
        if let redGain = state.redGain {
            storedWrites.append((target.persistenceKey, .redGain, redGain))
        }
        if let greenGain = state.greenGain {
            storedWrites.append((target.persistenceKey, .greenGain, greenGain))
        }
        if let blueGain = state.blueGain {
            storedWrites.append((target.persistenceKey, .blueGain, blueGain))
        }
    }

    private func dim(
        _ lever: FakeLever, _ originalValue: Int,
        _ target: ExternalDDCDisplay
    ) {
        lock.lock()
        defer { lock.unlock() }
        let locked = lockedLevers[target.persistenceKey]?
            .contains(lever) == true
        guard originalValue > 0, !locked else {
            return
        }
        storedWrites.append((target.persistenceKey, lever, 0))
        applyLocked(lever, 0, target.persistenceKey)
    }

    private func applyLocked(
        _ lever: FakeLever, _ value: Int, _ key: String
    ) {
        guard var state = storedStates[key] else { return }
        switch lever {
        case .luminance: state.luminance = value
        case .contrast: state.contrast = value
        case .redGain: state.redGain = value
        case .greenGain: state.greenGain = value
        case .blueGain: state.blueGain = value
        }
        storedStates[key] = state
    }
}

private final class FakeActivityMonitors: ActivityMonitorInstalling {
    private(set) var isInstalled = false

    func install(onActivity: @escaping () -> Void) {
        isInstalled = true
    }

    func removeAll() {
        isInstalled = false
    }
}

private final class FakeScreenShades: ScreenShadeInstalling {
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var installedAlphas: [Double] = []

    var isCovering: Bool { installCount > removeCount }

    func installShades(alpha: Double) {
        installCount += 1
        installedAlphas.append(alpha)
    }

    func removeShades() {
        removeCount += 1
    }
}
