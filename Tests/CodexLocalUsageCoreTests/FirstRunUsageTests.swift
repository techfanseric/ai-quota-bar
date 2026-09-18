import XCTest
@testable import CodexLocalUsageCore

final class FirstRunUsageTests: XCTestCase {
    func testMissingLogDirectoriesAreEmptyRatherThanErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        let result = try await store.scan(root: directory.appendingPathComponent("no-codex-yet"))
        XCTAssertEqual(result.files, 0)
        XCTAssertEqual(result.issues, 0)
        XCTAssertTrue(result.events.isEmpty)
    }
    func testAFileInPlaceOfLogDirectoryStillReportsAnIssue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try UsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        try Data().write(to: directory.appendingPathComponent("sessions"))
        let result = try await store.scan(root: directory)
        XCTAssertEqual(result.issues, 1)
    }
}
