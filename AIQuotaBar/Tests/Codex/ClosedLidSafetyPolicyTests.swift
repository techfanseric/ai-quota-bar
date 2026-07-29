import Foundation
import XCTest
@testable import AIQuotaBar

final class ClosedLidSafetyPolicyTests: XCTestCase {
    func testBatteryBelowFloorIsSuspended() {
        XCTAssertEqual(
            ClosedLidSafetyPolicy.evaluate(
                batteryPercentage: 19,
                hasInternalBattery: true,
                isOnACPower: false,
                thermalState: .nominal
            ),
            .lowBattery(19)
        )
    }

    func testACPowerAllowsLowBattery() {
        XCTAssertEqual(
            ClosedLidSafetyPolicy.evaluate(
                batteryPercentage: 5,
                hasInternalBattery: true,
                isOnACPower: true,
                thermalState: .nominal
            ),
            .allowed
        )
    }

    func testDesktopWithoutBatteryIsAllowed() {
        XCTAssertEqual(
            ClosedLidSafetyPolicy.evaluate(
                batteryPercentage: nil,
                hasInternalBattery: false,
                isOnACPower: false,
                thermalState: .nominal
            ),
            .allowed
        )
    }

    func testSeriousAndCriticalThermalPressureAreSuspended() {
        for thermalState in [
            ProcessInfo.ThermalState.serious,
            ProcessInfo.ThermalState.critical
        ] {
            XCTAssertEqual(
                ClosedLidSafetyPolicy.evaluate(
                    batteryPercentage: 100,
                    hasInternalBattery: true,
                    isOnACPower: true,
                    thermalState: thermalState
                ),
                .thermalPressure
            )
        }
    }

    func testMaximumDurationBoundary() {
        let start = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(
            ClosedLidSafetyPolicy.hasReachedMaximumDuration(
                startedAt: start,
                now: start.addingTimeInterval(43_199),
                maximumDuration: 43_200
            )
        )
        XCTAssertTrue(
            ClosedLidSafetyPolicy.hasReachedMaximumDuration(
                startedAt: start,
                now: start.addingTimeInterval(43_200),
                maximumDuration: 43_200
            )
        )
    }
}
