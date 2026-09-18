import XCTest
@testable import AIQuotaBar

@MainActor
final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.18.0", than: "1.17.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.17.0", than: "1.17.1"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.17.1", than: "1.17.1"))
    }

    func testSuccessCachesUpdateAndInstalledVersionClearsVisibility() async throws {
        let suite = "UpdateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let release = UpdateRelease(version: "1.18.0", releaseURL: URL(string: "https://github.com/techfanseric/ai-quota-bar/releases/tag/v1.18.0")!)
        let checker = UpdateChecker(defaults: defaults, currentVersion: { "1.17.1" }, releaseLoader: { release })
        _ = try await checker.checkForUpdates()
        XCTAssertEqual(checker.availableRelease?.version, "1.18.0")
        XCTAssertFalse(checker.shouldRunAutomaticDailyCheck())
        XCTAssertNotNil(checker.lastCheckedAt)
        XCTAssertEqual(UpdateChecker(defaults: defaults, currentVersion: { "1.17.1" }).availableRelease?.version, "1.18.0")
        XCTAssertNil(UpdateChecker(defaults: defaults, currentVersion: { "1.18.0" }).availableRelease)
        XCTAssertEqual(release.downloadURL.absoluteString, "https://github.com/techfanseric/ai-quota-bar/releases/download/v1.18.0/AIQuotaBar.dmg")
    }

    func testFailureRetriesAfterFifteenMinutesNotOneDay() async {
        let suite = "UpdateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, currentVersion: { "1.17.1" }, releaseLoader: { throw URLError(.notConnectedToInternet) })
        _ = try? await checker.checkForUpdates()
        XCTAssertNil(checker.lastCheckedAt)
        XCTAssertNotNil(checker.lastError)
        XCTAssertFalse(checker.shouldRunAutomaticDailyCheck())
        XCTAssertTrue(checker.shouldRunAutomaticDailyCheck(now: Date().addingTimeInterval(16 * 60)))
    }

    func testUntrustedReleaseCannotBeOffered() async {
        let suite = "UpdateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(defaults: defaults, currentVersion: { "1" }, releaseLoader: {
            UpdateRelease(version: "2", releaseURL: URL(string: "https://example.com/malware")!)
        })
        _ = try? await checker.checkForUpdates()
        XCTAssertNil(checker.availableRelease)
        XCTAssertNotNil(checker.lastError)
    }
    func testConcurrentChecksShareRequestAndFailureKeepsCachedUpdate() async throws {
        let suite = "UpdateTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        let checker = UpdateChecker(defaults: defaults, currentVersion: { "1.17.1" }, releaseLoader: {
            calls += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            return UpdateRelease(version: "1.18.0", releaseURL: URL(string: "https://github.com/techfanseric/ai-quota-bar/releases/tag/v1.18.0")!)
        })
        async let first = checker.checkForUpdates()
        async let second = checker.checkForUpdates()
        _ = try await (first, second)
        XCTAssertEqual(calls, 1)
        let offline = UpdateChecker(defaults: defaults, currentVersion: { "1.17.1" }, releaseLoader: { throw URLError(.timedOut) })
        _ = try? await offline.checkForUpdates()
        XCTAssertEqual(offline.availableRelease?.version, "1.18.0")
    }

}
