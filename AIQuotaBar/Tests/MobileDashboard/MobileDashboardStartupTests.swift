import Foundation
import Security
import XCTest
@testable import AIQuotaBar

@MainActor
final class MobileDashboardStartupTests: XCTestCase {
    func testStartReturnsInStartingWhileTokenReadIsDelayed()
        async throws
    {
        let fixture = try makeFixture(
            readResult: .found("existing-token"))

        fixture.service.startIfEnabled()
        fixture.service.startIfEnabled()

        XCTAssertEqual(fixture.service.state, .starting)
        try await waitUntil {
            fixture.store.readCallCount == 1
        }
        XCTAssertEqual(fixture.store.readCallCount, 1)
        XCTAssertEqual(fixture.store.saveCallCount, 0)

        fixture.service.isEnabled = false
        fixture.store.releaseRead.signal()
        await settle()
    }

    func testStopDiscardsDelayedNotFoundWithoutSavingOrStarting()
        async throws
    {
        let fixture = try makeFixture(readResult: .notFound)
        fixture.service.startIfEnabled()
        try await waitUntil {
            fixture.store.readCallCount == 1
        }

        fixture.service.isEnabled = false
        fixture.store.releaseRead.signal()
        await settle()

        XCTAssertEqual(fixture.service.state, .off)
        XCTAssertEqual(fixture.store.saveCallCount, 0)
        XCTAssertNil(fixture.service.accessURLString)
    }

    func testExplicitNotFoundGeneratesAndSavesOneToken()
        async throws
    {
        let fixture = try makeFixture(readResult: .notFound)
        fixture.service.startIfEnabled()
        try await waitUntil {
            fixture.store.readCallCount == 1
        }
        XCTAssertEqual(fixture.store.saveCallCount, 0)

        fixture.store.releaseRead.signal()
        try await waitUntil {
            fixture.store.saveCallCount == 1
        }

        let savedToken = try XCTUnwrap(
            fixture.store.savedTokens.first)
        XCTAssertEqual(savedToken.utf8.count, 43)
        XCTAssertEqual(fixture.store.saveCallCount, 1)
        fixture.service.isEnabled = false
    }

    func testExistingTokenIsUsedWithoutBeingOverwritten()
        async throws
    {
        let fixture = try makeFixture(
            readResult: .found("existing-mobile-token"))
        fixture.service.startIfEnabled()
        try await waitUntil {
            fixture.store.readCallCount == 1
        }

        fixture.store.releaseRead.signal()
        try await waitUntil {
            fixture.store.readCompleted
        }
        await settle()

        XCTAssertEqual(fixture.store.saveCallCount, 0)
        XCTAssertFalse(fixture.service.requiresPairingCode)
        XCTAssertNil(fixture.service.manualPairingCode)
        fixture.service.isEnabled = false
    }

    func testPairingPolicySwitchesCodesWithoutRotatingMasterToken()
        async throws
    {
        let fixture = try makeFixture(
            readResult: .found("stable-existing-token"),
            requiresPairingCode: true)
        fixture.service.startIfEnabled()
        try await waitUntil {
            fixture.store.readCallCount == 1
        }
        fixture.store.releaseRead.signal()
        try await waitUntil {
            fixture.service.manualPairingCode != nil
        }

        let firstCode = try XCTUnwrap(
            fixture.service.manualPairingCode)
        let firstExpiry = try XCTUnwrap(
            fixture.service.manualPairingCodeExpiresAt)
        XCTAssertEqual(firstCode.utf8.count, 8)
        XCTAssertGreaterThan(
            firstExpiry.timeIntervalSinceNow,
            MobileDashboardService.manualPairingCodeLifetime - 5)

        XCTAssertTrue(
            fixture.service.setRequiresPairingCode(false))
        XCTAssertNil(fixture.service.manualPairingCode)
        XCTAssertNil(fixture.service.manualPairingCodeExpiresAt)

        XCTAssertTrue(
            fixture.service.setRequiresPairingCode(true))
        let secondCode = try XCTUnwrap(
            fixture.service.manualPairingCode)
        XCTAssertNotEqual(secondCode, firstCode)
        XCTAssertEqual(fixture.store.saveCallCount, 0)
        fixture.service.isEnabled = false
    }

    func testKeychainFailureDoesNotGenerateOrSaveToken()
        async throws
    {
        let fixture = try makeFixture(
            readResult: .failure(errSecInteractionNotAllowed))
        fixture.service.startIfEnabled()
        XCTAssertEqual(fixture.service.state, .starting)
        try await waitUntil {
            fixture.store.readCallCount == 1
        }

        fixture.store.releaseRead.signal()
        try await waitUntil {
            if case .failed = fixture.service.state {
                return true
            }
            return false
        }

        XCTAssertEqual(fixture.store.saveCallCount, 0)
        XCTAssertNil(fixture.service.accessURLString)
        fixture.service.isEnabled = false
    }

    func testTaskProgressSharingDefaultsOffAndCannotEnableWithoutPairing()
        throws
    {
        let fixture = try makeFixture(
            readResult: .found("unused-token"),
            requiresPairingCode: false)

        XCTAssertFalse(fixture.service.shareTaskProgressText)
        fixture.service.shareTaskProgressText = true

        XCTAssertFalse(
            fixture.service.shareTaskProgressText,
            "Task text must fail closed when pairing is disabled.")
        XCTAssertFalse(
            fixture.defaults.bool(
                forKey: "mobileDashboardShareTaskProgressText"))
    }

    func testTaskProgressSharingRoundTripsOnlyForPairedDashboard()
        throws
    {
        let fixture = try makeFixture(
            readResult: .found("unused-token"),
            requiresPairingCode: true,
            shareTaskProgressText: true)

        XCTAssertTrue(fixture.service.requiresPairingCode)
        XCTAssertTrue(fixture.service.shareTaskProgressText)
        XCTAssertTrue(
            fixture.defaults.bool(
                forKey: "mobileDashboardShareTaskProgressText"))

        XCTAssertTrue(fixture.service.setRequiresPairingCode(false))
        XCTAssertFalse(fixture.service.shareTaskProgressText)
        XCTAssertFalse(
            fixture.defaults.bool(
                forKey: "mobileDashboardShareTaskProgressText"),
            "Disabling pairing must persistently revoke text sharing.")

        XCTAssertTrue(fixture.service.setRequiresPairingCode(true))
        XCTAssertFalse(
            fixture.service.shareTaskProgressText,
            "Re-enabling pairing must not silently restore text sharing.")
    }

    func testPrivacySettingsChangeDuringStartupWithoutRestartingStartup()
        async throws
    {
        let fixture = try makeFixture(
            readResult: .found("stable-runtime-token"))
        fixture.service.startIfEnabled()
        try await waitUntil { fixture.store.readCallCount == 1 }
        XCTAssertEqual(fixture.service.state, .starting)

        fixture.service.masksAccountNames = false
        fixture.service.idleBlackoutMarqueeEnabled = false
        XCTAssertEqual(fixture.service.state, .starting)
        XCTAssertEqual(
            fixture.store.readCallCount,
            1,
            "Privacy changes must not start another token/server cycle.")
        XCTAssertEqual(
            fixture.defaults.object(
                forKey: "mobileDashboardMasksAccountNames") as? Bool,
            false)
        XCTAssertEqual(
            fixture.defaults.object(
                forKey: "mobileDashboardIdleBlackoutMarqueeEnabled")
                as? Bool,
            false)

        fixture.service.masksAccountNames = true
        fixture.service.idleBlackoutMarqueeEnabled = true
        XCTAssertEqual(fixture.service.state, .starting)
        XCTAssertEqual(fixture.store.readCallCount, 1)

        fixture.service.isEnabled = false
        fixture.store.releaseRead.signal()
        await settle()
        XCTAssertEqual(fixture.service.state, .off)
        XCTAssertEqual(fixture.store.saveCallCount, 0)
    }

    private func makeFixture(
        readResult: MobileDashboardAccessTokenLoadResult,
        requiresPairingCode: Bool = false,
        shareTaskProgressText: Bool = false
    ) throws -> (
        service: MobileDashboardService,
        store: ControlledMobileDashboardTokenStore,
        defaults: UserDefaults
    ) {
        let suiteName = "MobileDashboardStartupTests.\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "mobileDashboardEnabled")
        if requiresPairingCode {
            defaults.set(
                true,
                forKey: "mobileDashboardRequiresPairingCode")
        }
        if shareTaskProgressText {
            defaults.set(
                true,
                forKey: "mobileDashboardShareTaskProgressText")
        }
        let store = ControlledMobileDashboardTokenStore(
            readResult: readResult)
        let service = MobileDashboardService(
            defaults: defaults,
            accessTokenStore: store,
            snapshotProvider: { _, _, _, _ in
                fatalError("No viewer should request a snapshot.")
            },
            onViewerActivityChanged: { _ in },
            refreshRoute: {},
            testRoutes: {})
        addTeardownBlock {
            await MainActor.run {
                service.stopForApplicationTermination()
                UserDefaults(suiteName: suiteName)?
                    .removePersistentDomain(forName: suiteName)
            }
        }
        return (service, store, defaults)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for async startup state.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

private final class ControlledMobileDashboardTokenStore:
    MobileDashboardAccessTokenStoring,
    @unchecked Sendable
{
    let releaseRead = MobileDashboardAsyncGate()

    private let lock = NSLock()
    private let readResult: MobileDashboardAccessTokenLoadResult
    private var _readCallCount = 0
    private var _saveCallCount = 0
    private var _savedTokens: [String] = []
    private var _readCompleted = false

    init(readResult: MobileDashboardAccessTokenLoadResult) {
        self.readResult = readResult
    }

    var readCallCount: Int {
        lock.withLock { _readCallCount }
    }

    var saveCallCount: Int {
        lock.withLock { _saveCallCount }
    }

    var savedTokens: [String] {
        lock.withLock { _savedTokens }
    }

    var readCompleted: Bool {
        lock.withLock { _readCompleted }
    }

    func loadMobileDashboardAccessToken() async
        -> MobileDashboardAccessTokenLoadResult
    {
        lock.withLock {
            _readCallCount += 1
        }
        await releaseRead.wait()
        lock.withLock {
            _readCompleted = true
        }
        return readResult
    }

    func saveMobileDashboardAccessToken(_ token: String) -> Bool {
        lock.withLock {
            _saveCallCount += 1
            _savedTokens.append(token)
        }
        return true
    }
}

private final class MobileDashboardAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isSignaled {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func signal() {
        lock.lock()
        isSignaled = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
