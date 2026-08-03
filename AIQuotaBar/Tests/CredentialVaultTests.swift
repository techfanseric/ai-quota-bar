import Foundation
import Security
import XCTest
@testable import AIQuotaBar

final class CredentialVaultTests: XCTestCase {
    func testV1CodecReadsLegacyDictionaryWithoutLosingFields() throws {
        let legacy = [
            UsageProvider.miniMax.rawValue: "provider-secret",
            "cloudSyncToken": "cloud-secret",
            "mobileDashboardAccessToken": "must-not-revive",
            "unknown-provider": "preserve-me",
        ]
        let data = try JSONEncoder().encode(legacy)
        let vault = try CredentialVaultV1.decodeCompatible(from: data)

        XCTAssertEqual(vault.version, 1)
        XCTAssertEqual(
            vault.providers[UsageProvider.miniMax.rawValue],
            "provider-secret")
        XCTAssertEqual(
            vault.providers["unknown-provider"],
            "preserve-me")
        XCTAssertEqual(vault.cloudSyncToken, "cloud-secret")
        XCTAssertNil(vault.mobileDashboardAccessToken)
        XCTAssertEqual(
            try CredentialVaultV1.decodeCompatible(
                from: vault.encoded()),
            vault)
    }

    func testConcurrentConsumersCoalesceToOneVaultRead() async throws {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try CredentialVaultV1(
                providers: [
                    UsageProvider.miniMax.rawValue: "provider-secret",
                ],
                mobileDashboardAccessToken: "mobile-secret")
                .encoded())
        let gate = DispatchSemaphore(value: 0)
        backend.readGates[1] = gate
        let store = CredentialVaultStore(backend: backend)

        async let provider = store.credential(for: .miniMax)
        async let mobile = store.mobileDashboardAccessToken()
        try await waitUntil { backend.vaultReadCount == 1 }
        gate.signal()

        let values = await (provider, mobile)
        XCTAssertEqual(values.0, "provider-secret")
        XCTAssertEqual(values.1, .found("mobile-secret"))
        XCTAssertEqual(backend.vaultReadCount, 1)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
    }

    func testMissingMobileGeneratesFreshTokenAndNeverReadsLegacyItem()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try JSONEncoder().encode([
                UsageProvider.miniMax.rawValue: "provider-secret",
                "cloudSyncToken": "cloud-secret",
            ]))
        backend.items[backend.mobileLegacyKey] = .found(
            Data("legacy-mobile".utf8))
        let generator = SpyMobileTokenGenerator(tokens: [freshToken])
        let store = CredentialVaultStore(
            backend: backend,
            mobileTokenGenerator: { generator.generate() })

        let migratedToken = await store.mobileDashboardAccessToken()
        XCTAssertEqual(migratedToken, .found(freshToken))
        let written = try XCTUnwrap(backend.lastVaultWrite)
        let vault = try CredentialVaultV1.decodeCompatible(from: written)
        XCTAssertEqual(
            vault.providers[UsageProvider.miniMax.rawValue],
            "provider-secret")
        XCTAssertEqual(vault.cloudSyncToken, "cloud-secret")
        XCTAssertEqual(
            vault.mobileDashboardAccessToken,
            freshToken)
        XCTAssertEqual(
            vault.mobileDashboardTokenMigration,
            MobileDashboardTokenMigrationStateV1(
                status: .generatedFresh))
        XCTAssertEqual(backend.deleteCallCount, 0)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        XCTAssertEqual(backend.vaultReadCount, 1)
        XCTAssertEqual(generator.callCount, 1)

        let cachedToken = await store.mobileDashboardAccessToken()
        XCTAssertEqual(cachedToken, .found(freshToken))
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        XCTAssertEqual(generator.callCount, 1)
    }

    func testGeneratedTokenWriteFailureIsNotCachedAndSafelyRetries()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try CredentialVaultV1().encoded())
        backend.items[backend.mobileLegacyKey] = .found(
            Data("legacy-mobile".utf8))
        backend.writeStatuses = [errSecAuthFailed, errSecSuccess]
        let generator = SpyMobileTokenGenerator(
            tokens: [failedToken, retryToken])
        let store = CredentialVaultStore(
            backend: backend,
            mobileTokenGenerator: { generator.generate() })

        let firstToken = await store.mobileDashboardAccessToken()
        XCTAssertEqual(firstToken, .failure(errSecAuthFailed))
        XCTAssertNil(backend.lastVaultWrite)
        XCTAssertEqual(backend.deleteCallCount, 0)

        let retriedToken = await store.mobileDashboardAccessToken()
        XCTAssertEqual(retriedToken, .found(retryToken))
        XCTAssertEqual(backend.writeCallCount, 2)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        XCTAssertEqual(generator.callCount, 2)
        XCTAssertEqual(backend.deleteCallCount, 0)
        let written = try XCTUnwrap(backend.lastVaultWrite)
        XCTAssertEqual(
            try CredentialVaultV1.decodeCompatible(from: written)
                .mobileDashboardAccessToken,
            retryToken)
    }

    func testDecodeFailureNeverGeneratesReadsLegacyOrOverwrites()
        async
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            Data("not-json".utf8))
        backend.items[backend.mobileLegacyKey] = .found(
            Data("legacy-mobile".utf8))
        let generator = SpyMobileTokenGenerator(tokens: [freshToken])
        let store = CredentialVaultStore(
            backend: backend,
            mobileTokenGenerator: { generator.generate() })

        let firstToken = await store.mobileDashboardAccessToken()
        let secondToken = await store.mobileDashboardAccessToken()
        XCTAssertEqual(firstToken, .failure(errSecDecode))
        XCTAssertEqual(secondToken, .failure(errSecDecode))
        XCTAssertEqual(backend.vaultReadCount, 2)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        XCTAssertEqual(generator.callCount, 0)
        XCTAssertEqual(backend.writeCallCount, 0)
        XCTAssertEqual(backend.deleteCallCount, 0)
    }

    func testConcurrentProviderAndMobileWritesCannotLoseFields()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try CredentialVaultV1().encoded())
        let coldLoadGate = DispatchSemaphore(value: 0)
        backend.readGates[1] = coldLoadGate
        let store = CredentialVaultStore(backend: backend)

        async let providerSaved = store.saveCredential(
            "provider-secret",
            for: .miniMax)
        async let mobileSaved = store.saveMobileDashboardAccessToken(
            "new-mobile")
        try await waitUntil { backend.vaultReadCount == 1 }
        coldLoadGate.signal()
        let results = await (providerSaved, mobileSaved)
        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)

        let data = try XCTUnwrap(backend.lastVaultWrite)
        let vault = try CredentialVaultV1.decodeCompatible(from: data)
        XCTAssertEqual(
            vault.providers[UsageProvider.miniMax.rawValue],
            "provider-secret")
        XCTAssertEqual(
            vault.mobileDashboardAccessToken,
            "new-mobile")
        XCTAssertEqual(backend.vaultReadCount, 1)
    }

    func testConcurrentFirstProvisionGeneratesAndWritesOnlyOnce()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try CredentialVaultV1().encoded())
        let gate = DispatchSemaphore(value: 0)
        backend.readGates[1] = gate
        let generator = SpyMobileTokenGenerator(tokens: [freshToken])
        let store = CredentialVaultStore(
            backend: backend,
            mobileTokenGenerator: { generator.generate() })

        async let first = store.mobileDashboardAccessToken()
        async let second = store.mobileDashboardAccessToken()
        try await waitUntil { backend.vaultReadCount == 1 }
        gate.signal()

        let results = await (first, second)
        XCTAssertEqual(results.0, .found(freshToken))
        XCTAssertEqual(results.1, .found(freshToken))
        XCTAssertEqual(generator.callCount, 1)
        XCTAssertEqual(backend.vaultReadCount, 1)
        XCTAssertEqual(backend.writeCallCount, 1)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        let data = try XCTUnwrap(backend.lastVaultWrite)
        XCTAssertEqual(
            try CredentialVaultV1.decodeCompatible(from: data)
                .mobileDashboardAccessToken,
            freshToken)
        XCTAssertEqual(backend.deleteCallCount, 0)
    }

    func testExistingVaultMobileTokenIsNeverRotatedOrMigrated()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try CredentialVaultV1(
                mobileDashboardAccessToken: existingToken)
                .encoded())
        backend.items[backend.mobileLegacyKey] = .found(
            Data("legacy-mobile".utf8))
        let generator = SpyMobileTokenGenerator(tokens: [freshToken])
        let store = CredentialVaultStore(
            backend: backend,
            mobileTokenGenerator: { generator.generate() })

        let result = await store.mobileDashboardAccessToken()
        XCTAssertEqual(result, .found(existingToken))
        XCTAssertEqual(generator.callCount, 0)
        XCTAssertEqual(backend.vaultReadCount, 1)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        XCTAssertEqual(backend.writeCallCount, 0)
        XCTAssertEqual(backend.deleteCallCount, 0)
    }

    func testFailedCoalescedLoadCanRetryWithoutOldWaiterClearingNewLoad()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.vaultReadSequence = [
            .failure(errSecInteractionNotAllowed),
            .found(try CredentialVaultV1(
                providers: [
                    UsageProvider.miniMax.rawValue: "provider-secret",
                ],
                mobileDashboardAccessToken: "mobile-secret")
                .encoded()),
        ]
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        backend.readGates[1] = firstGate
        backend.readGates[2] = secondGate
        let store = CredentialVaultStore(backend: backend)

        async let oldProvider = store.credential(for: .miniMax)
        async let oldMobile = store.mobileDashboardAccessToken()
        try await waitUntil { backend.vaultReadCount == 1 }
        firstGate.signal()
        _ = await oldProvider

        async let newProvider = store.credential(for: .miniMax)
        async let newMobile = store.mobileDashboardAccessToken()
        try await waitUntil { backend.vaultReadCount == 2 }
        secondGate.signal()

        _ = await oldMobile
        let retried = await (newProvider, newMobile)
        XCTAssertEqual(retried.0, "provider-secret")
        XCTAssertEqual(retried.1, .found("mobile-secret"))
        XCTAssertEqual(backend.vaultReadCount, 2)
    }

    func testFreshProvisionRejectsLegacyTokenAndAuthenticatesManualSSE()
        async throws
    {
        let backend = FakeCredentialVaultBackend()
        backend.items[backend.vaultKey] = .found(
            try CredentialVaultV1().encoded())
        let oldToken = String(repeating: "O", count: 43)
        backend.items[backend.mobileLegacyKey] = .found(
            Data(oldToken.utf8))
        let generator = SpyMobileTokenGenerator(tokens: [freshToken])
        let store = CredentialVaultStore(
            backend: backend,
            mobileTokenGenerator: { generator.generate() })
        let provisioned = await store.mobileDashboardAccessToken()
        guard case let .found(newToken) = provisioned else {
            return XCTFail("Fresh token provisioning failed.")
        }
        XCTAssertEqual(newToken, freshToken)
        XCTAssertNotEqual(newToken, oldToken)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)

        let port = UInt16.random(in: 45_000...49_999)
        let ready = expectation(description: "Fresh token server ready")
        let server = MobileDashboardHTTPServer(
            stateHandler: { state in
                if case .ready = state { ready.fulfill() }
            },
            viewerCountHandler: { _ in },
            sensitiveCORSHostProvider: { ["127.0.0.2"] })
        server.start(
            port: port,
            accessToken: newToken,
            manualPairingCode: "12345678",
            manualPairingCodeExpiresAt:
                Date().addingTimeInterval(300))
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        let origin = "http://127.0.0.2:\(port)"
        let eventsURL = try XCTUnwrap(URL(string:
            "http://127.0.0.1:\(port)/api/v1/events"))
        var oldRequest = URLRequest(url: eventsURL)
        oldRequest.timeoutInterval = 5
        oldRequest.setValue(origin, forHTTPHeaderField: "Origin")
        oldRequest.setValue(
            "Bearer \(oldToken)",
            forHTTPHeaderField: "Authorization")
        let (_, oldResponse) = try await URLSession.shared.data(
            for: oldRequest)
        XCTAssertEqual(
            (oldResponse as? HTTPURLResponse)?.statusCode,
            401)

        let claimURL = try XCTUnwrap(URL(string:
            "http://127.0.0.1:\(port)/api/v1/pwa/manual-claim"))
        var claim = URLRequest(url: claimURL)
        claim.httpMethod = "POST"
        claim.timeoutInterval = 5
        claim.setValue(origin, forHTTPHeaderField: "Origin")
        claim.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type")
        claim.httpBody = Data("{\"code\":\"12345678\"}".utf8)
        let (claimData, claimResponse) = try await URLSession.shared.data(
            for: claim)
        XCTAssertEqual(
            (claimResponse as? HTTPURLResponse)?.statusCode,
            200)
        let claimObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: claimData)
                as? [String: String])
        XCTAssertEqual(claimObject["token"], newToken)

        var newRequest = URLRequest(url: eventsURL)
        newRequest.timeoutInterval = 5
        newRequest.setValue(origin, forHTTPHeaderField: "Origin")
        newRequest.setValue(
            "Bearer \(newToken)",
            forHTTPHeaderField: "Authorization")
        let eventSession = URLSession(configuration: .ephemeral)
        defer { eventSession.invalidateAndCancel() }
        let (_, newResponse) = try await eventSession.bytes(
            for: newRequest)
        XCTAssertEqual(
            (newResponse as? HTTPURLResponse)?.statusCode,
            200)
        XCTAssertEqual(backend.legacyMobileReadCount, 0)
        XCTAssertEqual(backend.deleteCallCount, 0)
    }

    func testHasCredentialUsesDefaultsWithoutReadingKeychain() throws {
        let backend = FakeCredentialVaultBackend()
        let vault = CredentialVaultStore(backend: backend)
        let suite = "CredentialVaultTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            [UsageProvider.miniMax.rawValue],
            forKey: "keychainConfiguredProviderKeys")
        let service = KeychainService(vault: vault, defaults: defaults)

        XCTAssertTrue(service.hasCredential(for: .miniMax))
        XCTAssertFalse(service.hasCredential(for: .glm))
        XCTAssertEqual(backend.totalReadCount, 0)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for deterministic backend state.")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private var freshToken: String { String(repeating: "N", count: 43) }
    private var failedToken: String { String(repeating: "F", count: 43) }
    private var retryToken: String { String(repeating: "R", count: 43) }
    private var existingToken: String { String(repeating: "E", count: 43) }
}

private final class SpyMobileTokenGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private var _callCount = 0

    init(tokens: [String]) {
        self.tokens = tokens
    }

    var callCount: Int { lock.withLock { _callCount } }

    func generate() -> String? {
        lock.withLock {
            _callCount += 1
            return tokens.isEmpty ? nil : tokens.removeFirst()
        }
    }
}

private final class FakeCredentialVaultBackend:
    CredentialVaultBackend,
    @unchecked Sendable
{
    struct Key: Hashable {
        let service: String
        let account: String
    }

    let service = KeychainService.service
    let vaultAccount = "providerCredentials"
    let mobileLegacyAccount = "mobileDashboardAccessToken"
    private let lock = NSLock()
    var items: [Key: CredentialVaultItemReadResult] = [:]
    var vaultReadSequence: [CredentialVaultItemReadResult] = []
    var readGates: [Int: DispatchSemaphore] = [:]
    var writeGates: [Int: DispatchSemaphore] = [:]
    var writeStatuses: [OSStatus] = []
    private var _totalReadCount = 0
    private var _vaultReadCount = 0
    private var _legacyMobileReadCount = 0
    private var _writeCallCount = 0
    private var _deleteCallCount = 0
    private var _lastVaultWrite: Data?

    var vaultKey: Key {
        Key(service: service, account: vaultAccount)
    }

    var mobileLegacyKey: Key {
        Key(service: service, account: mobileLegacyAccount)
    }

    var totalReadCount: Int { lock.withLock { _totalReadCount } }
    var vaultReadCount: Int { lock.withLock { _vaultReadCount } }
    var legacyMobileReadCount: Int {
        lock.withLock { _legacyMobileReadCount }
    }
    var writeCallCount: Int { lock.withLock { _writeCallCount } }
    var deleteCallCount: Int { lock.withLock { _deleteCallCount } }
    var lastVaultWrite: Data? { lock.withLock { _lastVaultWrite } }

    func read(
        account: String,
        service: String
    ) -> CredentialVaultItemReadResult {
        let key = Key(service: service, account: account)
        let vaultCall: Int? = lock.withLock {
            _totalReadCount += 1
            if key == vaultKey {
                _vaultReadCount += 1
                return _vaultReadCount
            }
            if key == mobileLegacyKey {
                _legacyMobileReadCount += 1
            }
            return nil
        }
        if let vaultCall {
            lock.withLock { readGates[vaultCall] }?.wait()
        }
        return lock.withLock {
            if key == vaultKey, !vaultReadSequence.isEmpty {
                return vaultReadSequence.removeFirst()
            }
            return items[key] ?? .notFound
        }
    }

    func write(
        _ data: Data,
        account: String,
        service: String
    ) -> OSStatus {
        let key = Key(service: service, account: account)
        let call: Int = lock.withLock {
            _writeCallCount += 1
            return _writeCallCount
        }
        lock.withLock { writeGates[call] }?.wait()
        return lock.withLock {
            let status = writeStatuses.isEmpty
                ? errSecSuccess
                : writeStatuses.removeFirst()
            if status == errSecSuccess {
                items[key] = .found(data)
                if key == vaultKey {
                    _lastVaultWrite = data
                }
            }
            return status
        }
    }

    func delete(account: String, service: String) -> OSStatus {
        lock.withLock {
            _deleteCallCount += 1
            items.removeValue(forKey: Key(
                service: service,
                account: account))
            return errSecSuccess
        }
    }
}
