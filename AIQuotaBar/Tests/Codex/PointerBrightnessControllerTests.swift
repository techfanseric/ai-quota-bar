import AppKit
import XCTest
@testable import AIQuotaBar

final class PointerBrightnessControllerTests: XCTestCase {
    func testMediaKeyDecodingHandlesReleaseAndRepeatWithoutConsumingOtherKeys() {
        XCTAssertEqual(BrightnessKeyPress(subtype: 8, data: (2 << 16) | 0x0a00)?.delta(fine: false), 6.25)
        XCTAssertEqual(BrightnessKeyPress(subtype: 8, data: (3 << 16) | 0x0a01)?.delta(fine: true), -1.5625)
        XCTAssertEqual(BrightnessKeyPress(subtype: 8, data: (2 << 16) | 0x0b00)?.isDown, false)
        XCTAssertNil(BrightnessKeyPress(subtype: 8, data: 0x0a00)) // Volume up
        XCTAssertNil(BrightnessKeyPress(subtype: 7, data: (2 << 16) | 0x0a00))
        XCTAssertNil(BrightnessKeyPress(subtype: 8, data: (2 << 16) | 0x0900))
    }

    func testPointerRoutingHandlesScreensLeftAndAboveMainScreen() {
        let frames = [NSRect(x: 0, y: 0, width: 100, height: 100),
                      NSRect(x: -200, y: 0, width: 200, height: 100),
                      NSRect(x: 0, y: 100, width: 100, height: 100)]
        XCTAssertEqual(PointerBrightnessTarget.index(at: .init(x: -50, y: 20), frames: frames), 1)
        XCTAssertEqual(PointerBrightnessTarget.index(at: .init(x: 20, y: 150), frames: frames), 2)
        XCTAssertEqual(PointerBrightnessTarget.index(at: .init(x: 0, y: 20), frames: frames), 0)
        XCTAssertNil(PointerBrightnessTarget.index(at: .init(x: 500, y: 20), frames: frames))
    }

    func testExternalAdjustmentTargetsOneDisplayAndSupportsPanelRange() {
        let fixture = Fixture()
        defer { fixture.clean() }
        let target = PointerBrightnessTarget(id: 999, key: "a", builtin: false) // Rebind stale ID.
        XCTAssertEqual(fixture.backend.adjust(target, delta: -6.25), 68.75)
        XCTAssertEqual(fixture.external.states["a"]?.luminance, 75) // max 200
        XCTAssertEqual(fixture.external.states["b"]?.luminance, 80)
        XCTAssertEqual(fixture.gamma.values[10], fixture.baseline)
        XCTAssertNil(fixture.defaults.object(forKey: StepAwayPreferences.displayTargetsKey))
        XCTAssertEqual(fixture.external.states["a"]?.contrast, nil)
    }

    func testCrossingHardwareMinimumUsesNonCumulativeGammaAndSurvivesResetAndRelaunch() {
        let fixture = Fixture()
        defer { fixture.clean() }
        fixture.external.states["a"]?.luminance = 0
        let target = PointerBrightnessTarget(id: 10, key: "a", builtin: false)
        XCTAssertEqual(fixture.backend.adjust(target, delta: -25)!, 25, accuracy: 0.001)
        XCTAssertTrue(fixture.gamma.values[10]!.approximatelyMatches(fixture.baseline.scaled(by: 0.575)))
        fixture.gamma.values[10] = fixture.baseline // UU/GPU reset
        fixture.backend.maintain()
        XCTAssertTrue(fixture.gamma.values[10]!.approximatelyMatches(fixture.baseline.scaled(by: 0.575)))
        let relaunched = PointerBrightnessBackend(builtin: fixture.builtin, external: fixture.external,
                                                  gamma: fixture.gamma, defaults: fixture.defaults)
        XCTAssertEqual(relaunched.adjust(target, delta: -25)!, 0, accuracy: 0.001)
        XCTAssertTrue(fixture.gamma.values[10]!.approximatelyMatches(fixture.baseline.scaled(by: 0.15)))
        XCTAssertEqual(relaunched.adjust(target, delta: 75), 75)
        XCTAssertEqual(fixture.external.states["a"]?.luminance, 100)
        XCTAssertEqual(fixture.gamma.values[10], fixture.baseline)
    }

    func testUnreadableOrFailedDDCDoesNotChangeGammaOrOtherScreen() {
        let fixture = Fixture()
        defer { fixture.clean() }
        fixture.external.rejectWrites = true
        XCTAssertNil(fixture.backend.adjust(.init(id: 10, key: "a", builtin: false), delta: -60))
        XCTAssertEqual(fixture.gamma.values[10], fixture.baseline)
        XCTAssertEqual(fixture.external.states["a"]?.luminance, 100)
        XCTAssertNil(fixture.backend.adjust(.init(id: 10, key: "missing", builtin: false), delta: -10))
    }

    func testBuiltinClampsAndDoesNotUseExternalOrGamma() {
        let fixture = Fixture()
        defer { fixture.clean() }
        let target = PointerBrightnessTarget(id: 1, key: "builtin", builtin: true)
        XCTAssertEqual(fixture.backend.adjust(target, delta: 100), 100)
        XCTAssertEqual(fixture.builtin.value, 1)
        XCTAssertEqual(fixture.backend.adjust(target, delta: -200), 0)
        XCTAssertEqual(fixture.gamma.values[10], fixture.baseline)
        XCTAssertEqual(fixture.external.states["a"]?.luminance, 100)
    }
}

private final class Fixture {
    let suite = "PointerBrightnessTests.\(UUID())"
    let defaults: UserDefaults
    let builtin = PointerFakeBuiltin()
    let external = PointerFakeExternal()
    let gamma = PointerFakeGamma()
    let baseline = DisplayGammaTable(red: [0, 0.9], green: [0, 1], blue: [0, 0.8])
    let backend: PointerBrightnessBackend
    init() {
        defaults = UserDefaults(suiteName: suite)!
        gamma.values = [10: baseline, 11: baseline]
        backend = PointerBrightnessBackend(builtin: builtin, external: external, gamma: gamma, defaults: defaults)
    }
    func clean() { defaults.removePersistentDomain(forName: suite) }
}
private final class PointerFakeBuiltin: DisplayBrightnessControlling {
    var value: Float = 0.8
    func currentBrightness() -> Float? { value }
    func setBrightness(_ value: Float) { self.value = value }
}
private final class PointerFakeGamma: DisplayGammaControlling {
    var values: [CGDirectDisplayID: DisplayGammaTable] = [:]
    func read(displayID: CGDirectDisplayID) -> DisplayGammaTable? { values[displayID] }
    func apply(_ table: DisplayGammaTable, displayID: CGDirectDisplayID) -> Bool {
        values[displayID] = table
        return true
    }
}
private final class PointerFakeExternal: ExternalDisplayBrightnessControlling {
    var states = ["a": ExternalDisplayState(luminance: 100, maximumLuminance: 200),
                  "b": ExternalDisplayState(luminance: 80, maximumLuminance: 100)]
    var rejectWrites = false
    func enumerateTargets() -> [ExternalDDCDisplay] {
        ["a", "b"].enumerated().map { index, key in
            ExternalDDCDisplay(displayID: UInt32(index + 10), name: key, persistenceKey: key,
                               avService: NSObject(), chipAddress: 0x37)
        }
    }
    func readState(of target: ExternalDDCDisplay) -> ExternalDisplayState? { states[target.persistenceKey] }
    func applyDimmedState(to target: ExternalDDCDisplay, original: ExternalDisplayState, targetPercent: Double) {}
    func applyState(_ state: ExternalDisplayState, of target: ExternalDDCDisplay) {
        if !rejectWrites { states[target.persistenceKey] = state }
    }
}
