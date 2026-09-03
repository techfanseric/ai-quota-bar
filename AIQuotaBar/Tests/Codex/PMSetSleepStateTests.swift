import AIQuotaBarSleepShared
import XCTest

final class PMSetSleepStateTests: XCTestCase {
    func testCurrentParserReadsSystemWideSleepDisabled() {
        let state = PMSetSleepStateCodec.parseCurrentOutput(
            """
            System-wide power settings:
             SleepDisabled        1
            Currently in use:
             sleep                0
            """)

        XCTAssertEqual(state.global, true)
        XCTAssertNil(state.battery)
        XCTAssertNil(state.charger)
    }

    func testParserTreatsMissingDisableSleepKeysAsOff() {
        let output = """
        Battery Power:
         sleep                 1
        AC Power:
         sleep                 0
        """

        XCTAssertEqual(
            PMSetSleepStateCodec.parseCustomOutput(output),
            PMSetSleepState(battery: false, charger: false)
        )
    }

    func testParserPreservesDifferentPowerSourceValues() {
        let output = """
        Battery Power:
         disablesleep         0
        AC Power:
         disablesleep         1
        UPS Power:
         disablesleep         0
        """

        XCTAssertEqual(
            PMSetSleepStateCodec.parseCustomOutput(output),
            PMSetSleepState(
                battery: false,
                charger: true,
                ups: false
            )
        )
    }

    func testRestorePlanRestoresEveryPowerSourceIndependently() {
        let commands = PMSetSleepStateCodec.restorationCommands(
            for: PMSetSleepState(
                battery: false,
                charger: true,
                ups: false
            )
        )

        XCTAssertEqual(commands, [
            PMSetCommand(arguments: ["-b", "disablesleep", "0"]),
            PMSetCommand(arguments: ["-c", "disablesleep", "1"]),
            PMSetCommand(arguments: ["-u", "disablesleep", "0"])
        ])
    }

    func testRestorePlanPrefersSystemWideState() {
        let commands = PMSetSleepStateCodec
            .restorationCommands(
                for: PMSetSleepState(
                    global: true,
                    battery: false,
                    charger: false))

        XCTAssertEqual(
            commands,
            [
                PMSetCommand(
                    arguments: [
                        "-a",
                        "disablesleep",
                        "1",
                    ])
            ])
    }

    func testRestorePlanFailsSafeWhenNoSourceCouldBeRead() {
        XCTAssertEqual(
            PMSetSleepStateCodec.restorationCommands(
                for: PMSetSleepState()
            ),
            [PMSetCommand(arguments: ["-a", "disablesleep", "0"])]
        )
    }

    func testIsSleepDisabledReadsSystemWideFlag() {
        XCTAssertTrue(PMSetSleepState(global: true).isSleepDisabled)
        XCTAssertFalse(PMSetSleepState(global: false).isSleepDisabled)
    }

    func testIsSleepDisabledRequiresEverySourceDisabled() {
        XCTAssertTrue(
            PMSetSleepState(battery: true, charger: true).isSleepDisabled)
        XCTAssertFalse(
            PMSetSleepState(battery: true, charger: false).isSleepDisabled)
    }

    func testIsSleepDisabledTreatsUnknownStateAsNotDisabled() {
        XCTAssertFalse(PMSetSleepState().isSleepDisabled)
    }
}
