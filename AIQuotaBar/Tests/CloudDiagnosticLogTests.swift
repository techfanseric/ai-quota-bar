import XCTest
@testable import AIQuotaBar

@MainActor
final class CloudDiagnosticLogTests: XCTestCase {
    func testHistoryGroupsRepeatedOutcomesAndSurvivesRestartWithoutSensitiveBody() throws {
        let name = "CloudLogTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let log = CloudDiagnosticLog(defaults: defaults)
        log.record("download", error: URLError(.secureConnectionFailed))
        log.record("upload", error: CloudSyncError.serverError(401, "secret-token and email@example.com"))
        log.record("download", error: URLError(.secureConnectionFailed))
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.entries.first?.occurrences, 2)
        XCTAssertEqual(log.entries.first?.message, "URL loading error (-1200)")
        log.record("download")
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertFalse(log.entries[0].failed)
        let restored = CloudDiagnosticLog(defaults: defaults)
        XCTAssertEqual(restored.entries.count, 3)
        XCTAssertFalse(restored.entries.contains { $0.message.contains("secret") })
        for i in 0..<220 { log.record("download", error: CloudSyncError.serverError(i, "private")) }
        XCTAssertEqual(log.entries.count, 200)
        log.clear()
        XCTAssertTrue(CloudDiagnosticLog(defaults: defaults).entries.isEmpty)
    }
}
