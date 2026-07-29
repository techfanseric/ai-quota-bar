import AppKit
import XCTest
@testable import AIQuotaBar

@MainActor
final class SettingsWindowSmokeTests: XCTestCase {
    func testSettingsWindowCanBeCreatedAndShown() throws {
        let suiteName = "SettingsWindowSmokeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let controller = SettingsWindowController(viewModel: UsageViewModel())
        controller.showWindow(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(controller.window?.isVisible == true)
        controller.close()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
