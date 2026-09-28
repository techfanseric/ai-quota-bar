import XCTest
@testable import AIQuotaBar

private final class FakeBrightness: DisplayBrightnessControlling {
    var canRead = true
    private(set) var value: Float = 0.75
    private(set) var appliedValues: [Float] = []

    /// Simulates macOS or the user raising the brightness behind our back.
    func simulateExternalChange(_ value: Float) {
        self.value = value
    }

    func currentBrightness() -> Float? {
        canRead ? value : nil
    }

    func setBrightness(_ value: Float) {
        self.value = value
        appliedValues.append(value)
    }
}

private final class FakeLidState: LidStateProviding {
    var closed = false

    func isLidClosed() -> Bool {
        closed
    }
}

@MainActor
final class ClosedLidBrightnessControllerTests: XCTestCase {
    private var brightness = FakeBrightness()
    private var lidState = FakeLidState()
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        brightness = FakeBrightness()
        lidState = FakeLidState()
        suiteName = "ClosedLidBrightness-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(
        brightness: FakeBrightness? = nil,
        lidState: FakeLidState? = nil
    ) -> ClosedLidBrightnessController {
        ClosedLidBrightnessController(
            brightness: brightness ?? self.brightness,
            lidState: lidState ?? self.lidState,
            defaults: defaults
        )
    }

    private var pendingSavedValue: Float? {
        defaults.object(
            forKey: "closedLidDimSavedBrightness"
        ) as? Float
    }

    func testLidCloseDimsAndLidOpenRestoresSavedBrightness() {
        let controller = makeController()
        controller.setArmed(true)
        XCTAssertFalse(controller.isDimmed)

        lidState.closed = true
        controller.refresh()

        XCTAssertTrue(controller.isDimmed)
        XCTAssertEqual(brightness.value, 0)
        XCTAssertEqual(brightness.appliedValues, [0])

        lidState.closed = false
        controller.refresh()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertEqual(brightness.appliedValues, [0, 0.75])
    }

    func testArmedWithLidOpenDoesNotTouchBrightness() {
        let controller = makeController()
        controller.setArmed(true)
        controller.refresh()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertTrue(brightness.appliedValues.isEmpty)
    }

    func testUnarmedRefreshNeverDims() {
        let controller = makeController()
        lidState.closed = true
        controller.refresh()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertTrue(brightness.appliedValues.isEmpty)
    }

    func testDisarmingRestoresImmediately() {
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()

        controller.setArmed(false)

        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertEqual(brightness.appliedValues, [0, 0.75])
    }

    func testStopRestoresDimmedBrightness() {
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()

        controller.stop()

        XCTAssertFalse(controller.isArmed)
        XCTAssertFalse(controller.isDimmed)
        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertEqual(brightness.appliedValues, [0, 0.75])
    }

    func testUnreadableBrightnessNeverDims() {
        brightness.canRead = false
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()

        XCTAssertFalse(controller.isDimmed)
        XCTAssertTrue(brightness.appliedValues.isEmpty)

        lidState.closed = false
        controller.refresh()
        XCTAssertTrue(brightness.appliedValues.isEmpty)
    }

    func testDimmedBrightnessIsReassertedAndSavedValueKept() {
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()

        brightness.simulateExternalChange(0.4)
        controller.refresh()

        XCTAssertEqual(brightness.value, 0)
        XCTAssertEqual(brightness.appliedValues, [0, 0])

        lidState.closed = false
        controller.refresh()

        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertEqual(brightness.appliedValues, [0, 0, 0.75])
    }

    func testDimPersistsSavedValueAndRestoreClearsIt() {
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()
        XCTAssertEqual(pendingSavedValue, 0.75)

        lidState.closed = false
        controller.refresh()

        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertNil(pendingSavedValue)
    }

    func testRestartWithLidOpenRecoversPendingBrightness() {
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()
        XCTAssertEqual(brightness.value, 0)

        let relaunched = makeController()
        XCTAssertFalse(relaunched.isDimmed)
        lidState.closed = false
        relaunched.recoverPendingRestore()

        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertNil(pendingSavedValue)
    }

    func testRestartWithLidClosedKeepsPendingValue() {
        let controller = makeController()
        controller.setArmed(true)
        lidState.closed = true
        controller.refresh()

        let relaunched = makeController()
        relaunched.recoverPendingRestore()
        XCTAssertEqual(pendingSavedValue, 0.75)
        XCTAssertEqual(brightness.value, 0)

        relaunched.setArmed(true)
        relaunched.refresh()
        XCTAssertEqual(pendingSavedValue, 0.75)

        lidState.closed = false
        relaunched.refresh()
        XCTAssertEqual(brightness.value, 0.75)
        XCTAssertNil(pendingSavedValue)
    }

    func testRecoverIsNoOpWithoutPendingValue() {
        makeController().recoverPendingRestore()
        XCTAssertTrue(brightness.appliedValues.isEmpty)
    }
}

@MainActor
final class ClosedLidModeManagerBrightnessArmingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var brightness: FakeBrightness!
    private var manager: ClosedLidModeManager!

    override func setUp() {
        super.setUp()
        suiteName = "ClosedLidArming-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        brightness = FakeBrightness()
        manager = ClosedLidModeManager(
            defaults: defaults,
            closedLidBrightnessController: ClosedLidBrightnessController(
                brightness: brightness,
                lidState: FakeLidState(),
                defaults: defaults
            )
        )
    }

    override func tearDown() {
        manager.stop()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTaskActiveArmsOnlyWhenEnabled() {
        manager.isEnabled = true
        manager.setTaskActive(false)
        XCTAssertFalse(manager.closedLidBrightnessController.isArmed)

        manager.setTaskActive(true)
        XCTAssertTrue(manager.closedLidBrightnessController.isArmed)
    }

    func testDisablingFeatureDisarmsBrightness() {
        manager.isEnabled = true
        manager.setTaskActive(true)
        XCTAssertTrue(manager.closedLidBrightnessController.isArmed)

        manager.isEnabled = false
        XCTAssertFalse(manager.closedLidBrightnessController.isArmed)
    }

    func testStopDisarmsBrightness() {
        manager.isEnabled = true
        manager.setTaskActive(true)
        manager.stop()
        XCTAssertFalse(manager.closedLidBrightnessController.isArmed)
    }

    func testStartRecoversPendingBrightnessFromCrashedSession() {
        defaults.set(
            Float(0.6),
            forKey: "closedLidDimSavedBrightness"
        )

        manager.start()

        XCTAssertEqual(brightness.value, 0.6)
        XCTAssertNil(
            defaults.object(forKey: "closedLidDimSavedBrightness"))
    }
}
