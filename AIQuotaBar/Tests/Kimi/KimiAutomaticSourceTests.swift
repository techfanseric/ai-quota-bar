import CodexBarCore
import XCTest
@testable import AIQuotaBar

final class KimiAutomaticSourceTests: XCTestCase {
    private let snapshot = UsageSnapshot(primary: RateWindow(usedPercent: 20, windowMinutes: 10080,
        resetsAt: nil, resetDescription: nil), secondary: nil, updatedAt: Date())

    private func defaults() -> UserDefaults {
        let name = "KimiAutomaticSourceTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value // No source setting, exactly as on first launch.
    }

    func testFreshInstallChoosesDesktopBeforeCLIWithoutSettings() async throws {
        let expected = snapshot
        let service = KimiService(cliStatusProvider: UnexpectedCLI(), defaults: defaults(),
            desktopSession: { self.session("desktop") },
            webSession: { XCTFail("Desktop should win"); throw KimiSessionError.noBrowserSession },
            webUsage: { _ in expected }, cliAvailable: { true }, desktopAvailable: { true },
            browserDiscovery: Discovery(values: []))
        XCTAssertEqual(service.sourceMode, .auto)
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertTrue(result.models[0].detailText!.hasPrefix("Kimi Desktop"))
        XCTAssertEqual(result.models[0].accountName, "Kimi · desktop")
    }

    func testExpiredDesktopUsesSavedWebBeforeCLI() async throws {
        let expected = snapshot
        let service = KimiService(cliStatusProvider: UnexpectedCLI(), defaults: defaults(),
            desktopSession: { throw KimiSessionError.expired },
            webSession: { self.session("web") }, webUsage: { _ in expected },
            cliAvailable: { true }, browserDiscovery: Discovery(values: []))
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertTrue(result.models[0].detailText!.hasPrefix("Kimi Web"))
        XCTAssertEqual(result.models[0].accountName, "Kimi · web")
    }

    func testBrowserOnlySignInIsDiscoveredBeforeConfiguredProviderFiltering() async throws {
        let expected = snapshot
        let browser = KimiBrowserSessionDiscovery(scan: { [self.session("browser")] })
        let service = KimiService(defaults: defaults(), desktopSession: { throw KimiSessionError.missing },
            webSession: { throw KimiSessionError.noBrowserSession }, webUsage: { _ in expected },
            cliAvailable: { false }, desktopAvailable: { false }, browserDiscovery: browser)
        XCTAssertFalse(service.hasAutomaticSource)
        await service.discoverAutomaticSources()
        XCTAssertTrue(service.hasAutomaticSource)
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertTrue(result.models[0].detailText!.hasPrefix("Kimi Web (auto)"))
    }

    func testFailedCLIFallsBackToUniqueBrowser() async throws {
        let expected = snapshot
        let service = KimiService(cliStatusProvider: UnavailableCLI(), defaults: defaults(),
            desktopSession: { throw KimiSessionError.missing },
            webSession: { throw KimiSessionError.noBrowserSession }, webUsage: { _ in expected },
            cliAvailable: { true }, desktopAvailable: { false },
            browserDiscovery: Discovery(values: [session("browser")]))
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertTrue(result.models[0].detailText!.hasPrefix("Kimi Web (auto)"))
    }

    func testSavedWebOnlySignInIsDiscoveredWithoutScanningBrowsers() async {
        let service = KimiService(defaults: defaults(), desktopSession: { throw KimiSessionError.missing },
            webSession: { self.session("saved") }, cliAvailable: { false }, desktopAvailable: { false },
            browserDiscovery: KimiBrowserSessionDiscovery(scan: { XCTFail("No scan needed"); return [] }))
        await service.discoverAutomaticSources()
        XCTAssertTrue(service.hasAutomaticSource)
    }

    func testDesktopNetworkFailureDoesNotSwitchAccounts() async {
        let service = KimiService(cliStatusProvider: UnexpectedCLI(), defaults: defaults(),
            desktopSession: { self.session("desktop") },
            webSession: { XCTFail("Must not jump accounts on a network failure"); throw KimiSessionError.noBrowserSession },
            webUsage: { _ in throw URLError(.timedOut) }, cliAvailable: { true },
            browserDiscovery: Discovery(values: []))
        do { _ = try await service.fetchUsage(apiKey: nil); XCTFail("Expected network error") } catch {}
    }

    func testCancellationDuringDetectionDoesNotStartFallback() async {
        let service = KimiService(cliStatusProvider: UnexpectedCLI(), defaults: defaults(),
            desktopSession: { throw CancellationError() },
            webSession: { XCTFail("Cancelled discovery must stop"); throw KimiSessionError.noBrowserSession },
            cliAvailable: { true }, browserDiscovery: Discovery(values: []))
        do { _ = try await service.fetchUsage(apiKey: nil); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMultipleBrowserAccountsAreNotSilentlyChosen() throws {
        XCTAssertThrowsError(try KimiBrowserSessionDiscovery.uniqueSession([session("a"), session("b")]))
        let duplicate = try KimiBrowserSessionDiscovery.uniqueSession([session("a"), session("a")])
        XCTAssertEqual(duplicate?.accountID, "a")
        XCTAssertNil(try KimiBrowserSessionDiscovery.uniqueSession([]))
    }

    func testBrowserScansCachePositiveAndNegativeResults() async throws {
        for values in [[], [session("a")]] {
            let counter = Counter()
            let browser = KimiBrowserSessionDiscovery(scan: { counter.increment(); return values })
            async let first = browser.sessions()
            async let second = browser.sessions()
            _ = try await (first, second)
            _ = try await browser.sessions()
            XCTAssertEqual(counter.value, 1)
            XCTAssertEqual(browser.hasCachedSession, !values.isEmpty)
        }
    }

    func testBrowserCacheExpiresAndPicksUpLogout() async throws {
        let counter = Counter()
        let value = session("a")
        let browser = KimiBrowserSessionDiscovery(ttl: 0, scan: {
            counter.increment()
            return counter.value == 1 ? [value] : []
        })
        _ = try await browser.sessions()
        XCTAssertTrue(browser.hasCachedSession)
        _ = try await browser.sessions()
        XCTAssertFalse(browser.hasCachedSession)
    }

    private func session(_ subject: String) -> KimiWebSession {
        let body = Data("{\"sub\":\"\(subject)\",\"exp\":9000000000}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return KimiWebSession(token: "h.\(body).s", origin: "https://www.kimi.com")
    }
    private struct UnavailableCLI: KimiCLIStatusProviding {
        func fetchUsageSnapshot() async throws -> UsageSnapshot { throw KimiCLIStatusProbeError.statusUnavailable }
    }
    private struct UnexpectedCLI: KimiCLIStatusProviding {
        func fetchUsageSnapshot() async throws -> UsageSnapshot { XCTFail("Unexpected CLI request"); throw KimiSessionError.missing }
    }
    private struct Discovery: KimiBrowserSessionDiscovering {
        let values: [KimiWebSession]
        var hasCachedSession: Bool { !values.isEmpty }
        func sessions() async throws -> [KimiWebSession] { values }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
