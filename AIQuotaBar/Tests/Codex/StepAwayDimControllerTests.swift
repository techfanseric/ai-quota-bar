import XCTest
@testable import AIQuotaBar

final class DDCPacketBuilderTests: XCTestCase {
    func testCombinedScaleExtendsBelowHardwareMinimumWithoutOverlay() {
        XCTAssertEqual(DisplayDimPlan(targetPercent: 75, builtin: false).hardwarePercent, 50)
        XCTAssertEqual(DisplayDimPlan(targetPercent: 50, builtin: false).gammaFactor, 1)
        XCTAssertEqual(DisplayDimPlan(targetPercent: 0, builtin: false).gammaFactor, 0.15)
        XCTAssertEqual(DisplayDimPlan(targetPercent: 25, builtin: true).hardwarePercent, 25)
        let table = DisplayGammaTable(red: [0, 0.9], green: [0, 1], blue: [0, 0.8])
        XCTAssertEqual(table.scaled(by: 0.5).red, [0, 0.45])
    }

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

    func testDimmingPercentageUsesHardwareRangeWithoutRaisingBrightness() {
        let state = ExternalDisplayState(luminance: 140, maximumLuminance: 200)
        XCTAssertEqual(state.dimmedLuminance(targetPercent: 25), 50)
        XCTAssertEqual(state.dimmedLuminance(targetPercent: 100), 140)
        XCTAssertEqual(state.dimmedLuminance(targetPercent: 0), 0)
        XCTAssertEqual(state.dimmedLuminance(targetPercent: .infinity), 0)
        let lower = ExternalDisplayState(luminance: 10, maximumLuminance: 100)
        XCTAssertEqual(lower.dimmedLuminance(targetPercent: 25), 10)
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
    private var gamma = FakeDisplayGamma()
    private var preferences: StepAwayPreferences!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        builtin = FakeStepAwayBuiltinBrightness()
        external = FakeStepAwayExternalBrightness()
        gamma = FakeDisplayGamma()
        monitors = FakeActivityMonitors()
        suiteName = "StepAwayDim-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        preferences = StepAwayPreferences(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(
        gracePeriod: TimeInterval = 0,
        smartRestore: Bool = true
    ) -> StepAwayDimController {
        let controller = StepAwayDimController(
            builtinBrightness: builtin,
            externalBrightness: external,
            gamma: gamma,
            monitors: monitors,
            preferences: preferences,
            defaults: defaults,
            gracePeriod: gracePeriod)
        controller.smartRestoreEnabled = smartRestore
        return controller
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
        // Only hardware luminance changes; contrast and colors stay intact.
        let fullState = external.states["ddc-a"]
        XCTAssertEqual(fullState?.luminance, 0)
        XCTAssertEqual(fullState?.contrast, 50)
        XCTAssertEqual(fullState?.redGain, 50)
        XCTAssertEqual(fullState?.greenGain, 50)
        XCTAssertEqual(fullState?.blueGain, 50)
        let bareState = external.states["ddc-b"]
        XCTAssertEqual(bareState?.luminance, 0)
        XCTAssertNil(bareState?.contrast)
        XCTAssertNil(bareState?.redGain)
        // Captured originals persist for crash recovery.
        XCTAssertEqual(pendingPayload?.builtinBrightness, 0.8)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-a"]?.luminance, 40)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-a"]?.contrast, nil)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-a"]?.redGain, nil)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-b"]?.luminance, 60)
        XCTAssertEqual(
            pendingPayload?.externalStates["ddc-b"]?.contrast, nil)
        XCTAssertTrue(monitors.isInstalled)
    }

    func testIndependentTargetsAndGammaRestore() async {
        preferences.setTargetPercent(30, for: StepAwayPreferences.builtinKey)
        preferences.setTargetPercent(25, for: "ddc-a")
        preferences.setTargetPercent(75, for: "ddc-b")
        let controller = makeController(smartRestore: false)
        controller.dim()
        await runBackgroundWork()
        XCTAssertEqual(builtin.brightness, 0.3)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 0)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 50)
        XCTAssertEqual(gamma.read(displayID: 1)?.peak ?? 0, 0.575, accuracy: 0.001)
        XCTAssertEqual(gamma.read(displayID: 2)?.peak, 1)
        XCTAssertTrue(controller.verification["ddc-a"]?.matches == true)
        controller.restore(reason: "test")
        await runBackgroundWork()
        XCTAssertEqual(gamma.read(displayID: 1)?.peak, 1)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertEqual(StepAwayPreferences(defaults: defaults).targetPercent(for: "ddc-b"), 75)
    }

    func testPreviewOnlyTouchesSelectedDisplayAndActivityRestores() async {
        let controller = makeController(smartRestore: false)
        controller.preview(displayKey: "ddc-b")
        await runBackgroundWork()
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 0)
        XCTAssertEqual(gamma.read(displayID: 2)?.peak ?? 0, 0.15, accuracy: 0.001)
        XCTAssertNil(pendingPayload?.builtinBrightness)
        XCTAssertEqual(pendingPayload?.externalStates.count, 1)
        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 60)
        XCTAssertEqual(gamma.read(displayID: 2)?.peak, 1)
        XCTAssertNil(pendingPayload)
    }

    func testPreviewDoesNotRestoreWhileDraggingButRestoresAfterRelease() async {
        let controller = makeController()
        controller.startPreviewEditing(displayKey: StepAwayPreferences.builtinKey)
        controller.preview(displayKey: StepAwayPreferences.builtinKey)
        await runBackgroundWork()
        controller.handleActivity()
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(monitors.isInstalled)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        controller.finishPreviewEditing(displayKey: StepAwayPreferences.builtinKey)
        try? await Task.sleep(nanoseconds: 150_000_000)
        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertNil(controller.previewDisplayKey)
    }

    func testMovingPreviewSliderUsesOriginalBaselineWithoutAccumulatingGamma() async {
        let controller = makeController(smartRestore: false)
        controller.startPreviewEditing(displayKey: "ddc-a")
        preferences.setTargetPercent(0, for: "ddc-a")
        controller.preview(displayKey: "ddc-a")
        await runBackgroundWork()
        XCTAssertEqual(gamma.read(displayID: 1)?.peak ?? 0, 0.15, accuracy: 0.001)
        preferences.setTargetPercent(25, for: "ddc-a")
        controller.preview(displayKey: "ddc-a")
        await runBackgroundWork()
        XCTAssertEqual(gamma.read(displayID: 1)?.peak ?? 0, 0.575, accuracy: 0.001)
        preferences.setTargetPercent(100, for: "ddc-a")
        controller.preview(displayKey: "ddc-a")
        await runBackgroundWork()
        XCTAssertEqual(gamma.read(displayID: 1)?.peak, 1)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        controller.endPreview()
        await runBackgroundWork()
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertEqual(gamma.read(displayID: 1)?.peak, 1)
    }

    func testActivityAfterSliderReleaseCancelsPendingPreview() async {
        let controller = makeController(smartRestore: false)
        controller.startPreviewEditing(displayKey: "ddc-a")
        controller.finishPreviewEditing(displayKey: "ddc-a")
        controller.handleActivity()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(controller.previewDisplayKey)
        XCTAssertTrue(external.writes.isEmpty)
    }

    func testLeavingSettingsCancelsQueuedPreview() async {
        let controller = makeController(smartRestore: false)
        controller.startPreviewEditing(displayKey: "ddc-a")
        controller.requestPreview(displayKey: "ddc-a")
        controller.endPreview()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isTransitioning)
        XCTAssertTrue(external.writes.isEmpty)
        XCTAssertEqual(builtin.brightness, 0.8)
    }

    func testStoppingDuringPreviewUpdateRestoresAfterFinalWrite() async {
        let controller = makeController(smartRestore: false)
        controller.startPreviewEditing(displayKey: "ddc-a")
        controller.preview(displayKey: "ddc-a")
        await runBackgroundWork()
        let started = expectation(description: "preview update started")
        let gate = DispatchSemaphore(value: 0)
        external.beforeDim = {
            started.fulfill()
            _ = gate.wait(timeout: .now() + 2)
        }
        preferences.setTargetPercent(25, for: "ddc-a")
        controller.preview(displayKey: "ddc-a")
        await fulfillment(of: [started], timeout: 2)
        controller.endPreview()
        gate.signal()
        await runBackgroundWork()
        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isTransitioning)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertEqual(gamma.read(displayID: 1)?.peak, 1)
        XCTAssertNil(pendingPayload)
    }

    func testRestartRecoveryRestoresGammaAlongsideHardwareBrightness() async throws {
        let baseline = try XCTUnwrap(gamma.read(displayID: 1))
        gamma.apply(baseline.scaled(by: 0.15), displayID: 1)
        let saved = SavedDisplayLevels(builtinBrightness: nil,
            externalStates: ["ddc-a": ExternalDisplayState(luminance: 70)],
            gammaTables: ["ddc-a": baseline])
        defaults.set(try JSONEncoder().encode(saved), forKey: StepAwayDimController.savedLevelsKey)
        let controller = makeController(smartRestore: false)
        controller.recoverPendingRestore()
        await runBackgroundWork()
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 70)
        XCTAssertEqual(gamma.read(displayID: 1), baseline)
        XCTAssertNil(pendingPayload)
    }

    func testFailedReadbackIsNotReportedAsSuccess() {
        let original = SavedDisplayLevels(builtinBrightness: nil,
            externalStates: ["ddc-a": ExternalDisplayState(luminance: 40)])
        let results = StepAwayDimController.verify(saved: original, actual: original,
            targetPercent: 0, targets: [:])
        XCTAssertFalse(results["ddc-a"]!.matches)
        XCTAssertEqual(results["ddc-a"]?.actualHardware, 40)
    }

    func testTargetBrightnessPersistsAndClampsInvalidValues() {
        XCTAssertEqual(preferences.targetBrightnessPercent, 0)
        preferences.targetBrightnessPercent = 25
        XCTAssertEqual(StepAwayPreferences(defaults: defaults).targetBrightnessPercent, 25)
        preferences.targetBrightnessPercent = -10
        XCTAssertEqual(preferences.targetBrightnessPercent, 0)
        preferences.targetBrightnessPercent = 130
        XCTAssertEqual(StepAwayPreferences(defaults: defaults).targetBrightnessPercent, 100)
        preferences.targetBrightnessPercent = .nan
        XCTAssertEqual(preferences.targetBrightnessPercent, 0)
    }

    func testSelectedBrightnessUsesPanelRangeAndRestoresOriginals() async {
        external = FakeStepAwayExternalBrightness(initialStates: [
            "ddc-a": ExternalDisplayState(luminance: 150, maximumLuminance: 200),
            "ddc-b": ExternalDisplayState(luminance: 10, maximumLuminance: 100),
        ])
        preferences.targetBrightnessPercent = 75
        let controller = makeController(smartRestore: false)
        controller.toggleDimming()
        await runBackgroundWork()

        XCTAssertEqual(builtin.brightness, 0.75)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 100)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 10)
        XCTAssertEqual(pendingPayload?.externalStates["ddc-a"]?.luminance, 150)
        XCTAssertEqual(pendingPayload?.externalStates["ddc-a"]?.maximumLuminance, 200)
        controller.toggleDimming()
        await runBackgroundWork()
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 150)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 10)
    }

    func testTargetDoesNotRaiseBuiltinBrightnessAndChangesApplyNextTime() async {
        preferences.targetBrightnessPercent = 100
        let controller = makeController(smartRestore: false)
        controller.dim()
        await runBackgroundWork()
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        preferences.targetBrightnessPercent = 20
        XCTAssertEqual(builtin.brightness, 0.8)
        controller.toggleDimming()
        await runBackgroundWork()
        controller.toggleDimming()
        await runBackgroundWork()
        XCTAssertEqual(builtin.brightness, 0.2)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 0)
        controller.stop()
        await runBackgroundWork()
    }

    func testSmartRestoreDefaultsOffAndPersistsOptIn() {
        let controller = StepAwayDimController(defaults: defaults)
        XCTAssertFalse(controller.smartRestoreEnabled)
        controller.smartRestoreEnabled = true
        XCTAssertTrue(StepAwayDimController(defaults: defaults).smartRestoreEnabled)
        controller.smartRestoreEnabled = false
        XCTAssertFalse(StepAwayDimController(defaults: defaults).smartRestoreEnabled)
    }

    func testManualModeIgnoresActivityAndSecondToggleRestores() async {
        let controller = makeController(smartRestore: false)
        controller.toggleDimming()
        await runBackgroundWork()
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(monitors.isInstalled)

        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 0)
        XCTAssertNotNil(pendingPayload)

        controller.toggleDimming()
        await runBackgroundWork()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertNil(pendingPayload)
    }

    func testChangingSmartRestoreWhileDimmedUpdatesMonitoring() async {
        let controller = makeController(smartRestore: false)
        controller.dim()
        await runBackgroundWork()
        XCTAssertFalse(monitors.isInstalled)

        controller.smartRestoreEnabled = true
        XCTAssertTrue(monitors.isInstalled)
        controller.smartRestoreEnabled = false
        XCTAssertFalse(monitors.isInstalled)
        // A callback already queued before disabling must not restore.
        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertTrue(controller.isActive)

        controller.smartRestoreEnabled = true
        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0.8)
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
    }

    func testStopDuringCaptureDoesNotActivateDimming() async {
        let controller = makeController()

        controller.dim()
        controller.stop()
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isTransitioning)
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertNil(pendingPayload)
    }

    func testStopDuringHardwareWriteRestoresAfterWriteCompletes() async {
        let writeStarted = expectation(description: "hardware dim started")
        let gate = DispatchSemaphore(value: 0)
        external.beforeDim = {
            writeStarted.fulfill()
            _ = gate.wait(timeout: .now() + 2)
        }
        // Use one target so the barrier observes exactly one dim operation.
        external.targets = Array(external.targets.prefix(1))
        let controller = makeController()
        controller.dim()
        await fulfillment(of: [writeStarted], timeout: 2)

        XCTAssertEqual(pendingPayload?.builtinBrightness, 0.8)
        controller.stop()
        gate.signal()
        await runBackgroundWork()

        XCTAssertFalse(controller.isActive)
        XCTAssertFalse(controller.isTransitioning)
        XCTAssertFalse(monitors.isInstalled)
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertNil(pendingPayload)
    }

    func testOldShadePreferenceDoesNotAffectHardwareDimming() async {
        defaults.set(60, forKey: "stepAwayShadeOpacityPercent")
        let controller = makeController()
        controller.dim()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 0)
        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertEqual(builtin.brightness, 0.8)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
    }

    func testMixedSupportOnlyDimsReadableDisplays() async {
        external.unreadableKeys = ["ddc-b"]
        let controller = makeController()
        controller.dim()
        await runBackgroundWork()

        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(builtin.brightness, 0)
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 0)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 60)
        XCTAssertNil(pendingPayload?.externalStates["ddc-b"])

        controller.handleActivity()
        await runBackgroundWork()
        XCTAssertEqual(external.states["ddc-a"]?.luminance, 40)
        XCTAssertEqual(external.states["ddc-b"]?.luminance, 60)
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

    func testContrastAndColorsChangedWhileDimmedAreNotOverwritten() async {
        let controller = makeController()
        controller.dim()
        await runBackgroundWork()

        external.setContrastAndColors(35, for: "ddc-a")
        controller.handleActivity()
        await runBackgroundWork()

        let state = external.states["ddc-a"]
        XCTAssertEqual(state?.luminance, 40)
        XCTAssertEqual(state?.contrast, 35)
        XCTAssertEqual(state?.redGain, 35)
        XCTAssertEqual(state?.greenGain, 35)
        XCTAssertEqual(state?.blueGain, 35)
        XCTAssertTrue(external.writes.allSatisfy { $0.lever == .luminance })
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
        XCTAssertEqual(external.states["ddc-a"]?.contrast, 50)
        XCTAssertEqual(external.states["ddc-a"]?.redGain, 50)
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
    var beforeDim: (() -> Void)?
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
        guard !unreadableKeys.contains(target.persistenceKey),
              let state = storedStates[target.persistenceKey] else { return nil }
        return ExternalDisplayState(
            luminance: state.luminance, maximumLuminance: state.maximumLuminance)
    }

    func applyDimmedState(
        to target: ExternalDDCDisplay,
        original: ExternalDisplayState,
        targetPercent: Double
    ) {
        beforeDim?()
        dim(.luminance, original.luminance, target,
            desired: original.dimmedLuminance(targetPercent: targetPercent))
    }

    func applyState(
        _ state: ExternalDisplayState,
        of target: ExternalDDCDisplay
    ) {
        lock.lock()
        defer { lock.unlock() }
        storedStates[target.persistenceKey]?.luminance = state.luminance
        storedWrites.append((target.persistenceKey, .luminance, state.luminance))
    }

    func setContrastAndColors(_ value: Int, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        storedStates[key]?.contrast = value
        storedStates[key]?.redGain = value
        storedStates[key]?.greenGain = value
        storedStates[key]?.blueGain = value
    }

    private func dim(
        _ lever: FakeLever, _ originalValue: Int,
        _ target: ExternalDDCDisplay, desired: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        let locked = lockedLevers[target.persistenceKey]?
            .contains(lever) == true
        guard originalValue >= desired, !locked else {
            return
        }
        storedWrites.append((target.persistenceKey, lever, desired))
        applyLocked(lever, desired, target.persistenceKey)
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

private final class FakeDisplayGamma: DisplayGammaControlling {
    private let lock = NSLock()
    private var tables: [CGDirectDisplayID: DisplayGammaTable] = [:]
    private let baseline = DisplayGammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])
    func read(displayID: CGDirectDisplayID) -> DisplayGammaTable? {
        lock.lock(); defer { lock.unlock() }
        return tables[displayID] ?? baseline
    }
    @discardableResult
    func apply(_ table: DisplayGammaTable, displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        tables[displayID] = table
        return true
    }
}
