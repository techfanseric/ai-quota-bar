import CodexBarCore
import CommonCrypto
import XCTest
@testable import AIQuotaBar

final class KimiWebSourceTests: XCTestCase {
    private let usage = Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"100","remaining":"71","resetTime":"2026-09-29T11:22:56.007158Z"},"limits":[{"detail":{"limit":100,"remaining":84,"resetTime":"2026-09-22T16:22:56Z"},"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}]}"#.utf8)

    private func defaults(_ mode: KimiDataSourceMode) -> UserDefaults {
        let name = "KimiWebSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(mode.rawValue, forKey: KimiDataSourceMode.storageKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testDecryptsElectronFixtureAndIgnoresRefreshToken() throws {
        let blob = Data(base64Encoded: "djEwYB7lpQcXAs4B4ScVNUAkltS5wY3vQdQ37kgpSNtHa4/YqOOJDTtOiIEDCQ8lz+DB4o2EzAxsN33rYE0PI7ItsuoSeN8qVvvpxV9TGhwk6PIgayEV8Pw9QNKyZC9M7liY/l6HRUYhZJGHh3s0M8KRkw==")!
        let decoded = try KimiDesktopSessionReader.decrypt(blob, password: Data("test-password".utf8))
        let session = try KimiDesktopSessionReader.decodeStore(decoded).validated()
        XCTAssertEqual(session.token, "fixture-token")
        XCTAssertEqual(session.origin, "https://www.kimi.com")
        XCTAssertThrowsError(try KimiDesktopSessionReader.decodeStore(KimiDesktopSessionReader.decrypt(blob, password: Data("wrong".utf8))))
        XCTAssertThrowsError(try KimiDesktopSessionReader.decrypt(Data("v11invalid".utf8), password: Data()))
        XCTAssertThrowsError(try KimiDesktopSessionReader.decodeStore(Data(#"{"origin":"https://www.kimi.com","tokens":{"refresh_token":"not-access"}}"#.utf8)))
    }

    func testValidatesExpiryAndExactOriginWithoutLeakingTokens() throws {
        let token = jwt(subject: "account-a", expiry: 200)
        let session = KimiWebSession(token: token, origin: "https://www.kimi.com")
        XCTAssertEqual(try session.validated(now: Date(timeIntervalSince1970: 100)).accountID, "account-a")
        XCTAssertThrowsError(try session.validated(now: Date(timeIntervalSince1970: 200)))
        for origin in ["http://www.kimi.com", "https://www.kimi.com.evil.test", "https://www.kimi.com@evil.test", "https://www.kimi.ai/path"] {
            XCTAssertThrowsError(try KimiWebSession(token: token, origin: origin).validated(now: Date(timeIntervalSince1970: 100)))
        }
        XCTAssertThrowsError(try KimiWebSession(token: "secret\nheader", origin: "https://www.kimi.com").validated()) { error in
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testMapsRealWebSchemaAndIndependentMembershipPool() throws {
        let stats = Data(#"{"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.42,"kimiCodeUsedRatio":0.01,"expireTime":"2026-10-01T00:00:00Z"}}"#.utf8)
        let snapshot = try KimiWebUsageClient.parse(usage, stats: stats)
        let mapped = try KimiUsageDataMapper.map(snapshot, source: "Kimi Desktop", accountName: "account-a")
        XCTAssertEqual(mapped.models.map(\.modelName), ["5h", "7d", "Total usage"])
        XCTAssertEqual(mapped.models.map(\.currentIntervalRemainingPercent), [84, 71, 58])
        XCTAssertTrue(mapped.models.allSatisfy { $0.accountName == "account-a" })
        XCTAssertNotNil(mapped.models[0].startTime)
        XCTAssertNotNil(mapped.models[1].endTime)
        XCTAssertNil(mapped.models[2].startTime) // No invented 30-day period.
        XCTAssertNotNil(mapped.models[2].endTime)
    }

    func testMembershipCanBeDisplayedWithoutCodeWindows() throws {
        let stats = Data(#"{"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.2}}"#.utf8)
        let snapshot = try KimiWebUsageClient.parse(Data(#"{"usages":[]}"#.utf8), stats: stats)
        let mapped = try KimiUsageDataMapper.map(snapshot, source: "Kimi Web")
        XCTAssertEqual(mapped.models.map(\.modelName), ["Total usage"])
        XCTAssertEqual(mapped.models.first?.currentIntervalRemainingPercent, 80)
        XCTAssertNil(mapped.models.first?.startTime)
    }

    func testMonthlyTotalUsageDerivesDisplayWindowFromExpiry() throws {
        let stats = Data(#"{"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.42,"expireTime":"2026-10-01T00:00:00Z"}}"#.utf8)
        let snapshot = try KimiWebUsageClient.parse(Data(#"{"usages":[]}"#.utf8), stats: stats)
        let mapped = try KimiUsageDataMapper.map(snapshot, source: "Kimi Web")
        let total = try XCTUnwrap(mapped.models.first)
        XCTAssertTrue(total.isKimiMonthlyTotalWindow)
        // 展示窗口按到期日回推一个自然月，但不写入 startTime（不参与节奏计算）
        XCTAssertNil(total.startTime)
        let window = try XCTUnwrap(total.quotaChartWindow())
        XCTAssertEqual(window.end, total.endTime)
        XCTAssertEqual(
            window.start,
            Calendar.current.date(byAdding: .month, value: -1, to: try XCTUnwrap(total.endTime)))
    }

    func testMonthlyTotalUsageEstimatesPaceFromDerivedWindow() throws {
        // 到期日在一周后：展示窗口回推一个自然月，elapsed 约 23/30，
        // 已用 58% 低于时间进度约 77%，应有 reserve（ahead）。
        let expiry = Date().addingTimeInterval(7 * 86_400)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let stats = Data(
            #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.42,"expireTime":"\#(formatter.string(from: expiry))"}}"#
                .utf8)
        let snapshot = try KimiWebUsageClient.parse(Data(#"{"usages":[]}"#.utf8), stats: stats)
        let mapped = try KimiUsageDataMapper.map(snapshot, source: "Kimi Web")
        let total = try XCTUnwrap(mapped.models.first)
        let pace = try XCTUnwrap(total.currentIntervalPace)
        XCTAssertTrue(pace.stage.isAhead)
        XCTAssertNotNil(total.currentIntervalPaceUsedPercent)
        XCTAssertNotNil(total.currentIntervalPaceDeltaPercent)
    }

    func testMalformedOptionalStatsDoNotDiscardCodeQuota() throws {
        let snapshot = try KimiWebUsageClient.parse(usage, stats: Data("invalid".utf8))
        XCTAssertEqual(snapshot.primary?.remainingPercent, 71)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 84)
        XCTAssertThrowsError(try KimiWebUsageClient.parse(Data(#"{"usages":[]}"#.utf8)))
        XCTAssertThrowsError(try KimiWebUsageClient.parse(Data(#"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"0","used":"0"}}]}"#.utf8)))
    }

    func testUnknownShortWindowIsNotLabeledFiveHours() throws {
        let data = Data(String(decoding: usage, as: UTF8.self).replacingOccurrences(of: "TIME_UNIT_MINUTE", with: "UNKNOWN").utf8)
        let mapped = try KimiUsageDataMapper.map(KimiWebUsageClient.parse(data), source: "Web")
        XCTAssertEqual(mapped.models[0].modelName, "Rate limit")
        XCTAssertNil(mapped.models[0].startTime)
    }

    func testDesktopSelectionIgnoresAPIKeyAndCLI() async throws {
        let expected = try KimiWebUsageClient.parse(usage)
        let session = KimiWebSession(token: jwt(subject: "desktop-account", expiry: 9_000_000_000), origin: "https://www.kimi.com")
        let service = KimiService(cliStatusProvider: FailingCLI(), defaults: defaults(.desktop),
            desktopSession: { session }, webUsage: { received in
                XCTAssertEqual(received.token, session.token)
                return expected
            }, cliAvailable: { true })
        let result = try await service.fetchUsage(apiKey: "must-not-be-used")
        XCTAssertTrue(result.models.allSatisfy { $0.detailText?.hasPrefix("Kimi Desktop") == true })
        XCTAssertEqual(result.models.first?.accountName, session.accountLabel)
        XCTAssertTrue(service.hasAutomaticSource)
    }

    func testAutoUsesDesktopWhenCLIAbsent() async throws {
        let expected = try KimiWebUsageClient.parse(usage)
        let service = KimiService(cliStatusProvider: FailingCLI(), defaults: defaults(.auto),
            desktopSession: { KimiWebSession(token: "fixture", origin: "https://www.kimi.com") },
            webUsage: { _ in expected }, cliAvailable: { false }, desktopAvailable: { true })
        XCTAssertTrue(service.hasAutomaticSource)
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertTrue(result.models[0].detailText!.hasPrefix("Kimi Desktop"))
    }

    func testAutoUsesCLIWhenDesktopAndSavedWebAreUnavailable() async {
        let service = KimiService(cliStatusProvider: FailingCLI(), defaults: defaults(.auto),
            desktopSession: { throw KimiSessionError.missing },
            webSession: { throw KimiSessionError.noBrowserSession },
            cliAvailable: { true }, browserDiscovery: KimiBrowserSessionDiscovery(scan: { [] }))
        do { _ = try await service.fetchUsage(apiKey: nil); XCTFail("Expected CLI error") } catch {}
    }

    func testWebSelectionDoesNotReadDesktopAndPreservesCancellation() async {
        let service = KimiService(defaults: defaults(.web),
            desktopSession: { XCTFail("Must not read Desktop"); throw KimiSessionError.missing },
            webSession: { throw CancellationError() }, cliAvailable: { true })
        do { _ = try await service.fetchUsage(apiKey: "ignored"); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingDesktopIsNotDetectedFromAnEmptyHome() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = KimiDesktopSessionReader(home: home)
        XCTAssertFalse(reader.isPresent)
        do {
            _ = try await reader.load()
            XCTFail("Expected a missing Desktop session")
        } catch {
            XCTAssertTrue(error is KimiSessionError)
        }
    }

    func testLoadUsesCachedSafeStorageKeyWithoutFreshKeychainRead() async throws {
        let home = try makeDesktopHome()
        var reads = 0
        var writes = 0
        var clears = 0
        let cache = KimiDesktopSessionReader.SafeStorageKeyCache(
            read: { reads += 1; return Data("test-password".utf8) },
            write: { _ in writes += 1 },
            clear: { clears += 1 })
        let reader = KimiDesktopSessionReader(home: home, keyCache: cache) { _ in
            XCTFail("Cached key must be used without touching Kimi's Keychain entry")
            throw KimiSessionError.missing
        }
        let session = try await reader.load()
        XCTAssertEqual(session.token, "fixture-token")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(clears, 0)
    }

    func testLoadCachesKeyAfterFreshAuthorizedRead() async throws {
        let home = try makeDesktopHome()
        var written: Data?
        var clears = 0
        let cache = KimiDesktopSessionReader.SafeStorageKeyCache(
            read: { nil },
            write: { written = $0 },
            clear: { clears += 1 })
        var freshCalls = 0
        let reader = KimiDesktopSessionReader(home: home, keyCache: cache) { allowInteraction in
            freshCalls += 1
            XCTAssertTrue(allowInteraction)
            return Data("test-password".utf8)
        }
        let session = try await reader.load(allowInteraction: true)
        XCTAssertEqual(session.token, "fixture-token")
        XCTAssertEqual(written, Data("test-password".utf8))
        XCTAssertEqual(freshCalls, 1)
        XCTAssertEqual(clears, 0)
    }

    func testBackgroundLoadWithoutCachedKeyNeverTouchesKeychain() async throws {
        let home = try makeDesktopHome()
        var writes = 0
        let cache = KimiDesktopSessionReader.SafeStorageKeyCache(
            read: { nil },
            write: { _ in writes += 1 },
            clear: {})
        let reader = KimiDesktopSessionReader(home: home, keyCache: cache) { _ in
            XCTFail("Background refresh must not read Kimi's Keychain entry")
            throw KimiSessionError.missing
        }
        do {
            _ = try await reader.load()
            XCTFail("Expected a keychain error")
        } catch {
            guard case let KimiSessionError.keychain(status) = error else {
                return XCTFail("Expected keychain error, got \(error)")
            }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
        }
        XCTAssertEqual(writes, 0)
    }

    func testStaleCachedKeyStaysSilentInBackgroundAndRefreshesInteractively() async throws {
        let home = try makeDesktopHome()
        var written: Data?
        var clears = 0
        let cache = KimiDesktopSessionReader.SafeStorageKeyCache(
            read: { Data("rotated-away".utf8) },
            write: { written = $0 },
            clear: { clears += 1 })
        var freshCalls = 0
        let reader = KimiDesktopSessionReader(home: home, keyCache: cache) { _ in
            freshCalls += 1
            return Data("test-password".utf8)
        }
        // Background: stale key must not trigger a fresh read or a vault write.
        do {
            _ = try await reader.load()
            XCTFail("Expected the background load to stay silent")
        } catch {}
        XCTAssertEqual(freshCalls, 0)
        XCTAssertEqual(clears, 0)
        XCTAssertNil(written)
        // Interactive: clear the stale copy, re-authorize once, cache the new key.
        let session = try await reader.load(allowInteraction: true)
        XCTAssertEqual(session.token, "fixture-token")
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(freshCalls, 1)
        XCTAssertEqual(written, Data("test-password".utf8))
    }

    func testUnrecoverableKeyFailsInsteadOfRetryingForever() async throws {
        let home = try makeDesktopHome()
        var freshCalls = 0
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .disabled
        ) { _ in
            freshCalls += 1
            return Data("wrong".utf8)
        }
        do {
            _ = try await reader.load(allowInteraction: true)
            XCTFail("Expected the unrecoverable key to fail")
        } catch {}
        XCTAssertEqual(freshCalls, 1)
    }

    private func makeDesktopHome() throws -> URL {
        try makeDesktopHome(envelope: Self.liveStoreEnvelope)
    }

    private func makeDesktopHome(envelope: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storeDirectory = home.appendingPathComponent("Library/Application Support/kimi-desktop/bridge-store")
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try envelope.write(
            to: storeDirectory.appendingPathComponent("token-store.json"),
            atomically: true,
            encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    /// A live desktop store: the access token is not a JWT, so it never
    /// expires and no renewal is attempted.
    private static let liveStoreEnvelope = """
    {"encryption":"safeStorage.v1","data":"djEwYB7lpQcXAs4B4ScVNUAkltS5wY3vQdQ37kgpSNtHa4/\
    YqOOJDTtOiIEDCQ8lz+DB4o2EzAxsN33rYE0PI7ItsuoSeN8qVvvpxV9TGhwk6PIgayEV8Pw9QNKyZC9M7liY/\
    l6HRUYhZJGHh3s0M8KRkw=="}
    """

    /// A desktop store whose access token is already expired.
    ///
    /// Encrypted with the same "test-password" the cached-key fixtures use, so
    /// the reader reaches the renewal path instead of the Keychain branch.
    /// The blobs are Electron safeStorage v10 payloads with an access token
    /// whose `exp` is in the past.
    private static let expiredStoreEnvelope = """
    {"encryption":"safeStorage.v1","data":"djEwYB7lpQcXAs4B4ScVNUAkltS5wY3vQdQ37kgpSNtHa4/\
    YqOOJDTtOiIEDCQ8lz+DBJdJvcDw9HL17WcgVaKANfpfjMDDfElMwC5mxoPTxQjMFrOjIn7Qh4x0Dyn3sleCLWEUFx9CZjSCzH8LpNoyRqQra17TR9RHifxtOcCLufDgdz+Q/erORZxknf8898LjHf/UanmQV62OlAxp1+o+geg=="}
    """

    /// The same expired store without a refresh token, so no renewal can be
    /// attempted.
    private static let expiredStoreEnvelopeWithoutRefreshToken = """
    {"encryption":"safeStorage.v1","data":"djEwYB7lpQcXAs4B4ScVNUAkltS5wY3vQdQ37kgpSNtHa4/\
    YqOOJDTtOiIEDCQ8lz+DBJdJvcDw9HL17WcgVaKANfpfjMDDfElMwC5mxoPTxQjMFrOjIn7Qh4x0Dyn3sleCLacDZZrrDAf3vX76EwBCPoA=="}
    """

    private static func expiredStore(includeRefreshToken: Bool) -> String {
        includeRefreshToken ? Self.expiredStoreEnvelope
            : Self.expiredStoreEnvelopeWithoutRefreshToken
    }

    // MARK: - Expired access token renewal

    /// A desktop store whose access token has expired but whose refresh token
    /// is still valid — the state that left the Kimi ring red.
    private func makeExpiredDesktopHome() throws -> URL {
        try makeDesktopHome(envelope: Self.expiredStore(includeRefreshToken: true))
    }

    func testExpiredDesktopAccessTokenIsRenewedFromTheStoredRefreshToken() async throws {
        let home = try makeExpiredDesktopHome()
        var receivedRefreshToken: String?
        var receivedOrigin: String?
        let renewed = jwt(subject: "desktop-account", expiry: 9_000_000_000)
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .init(read: { Data("test-password".utf8) }, write: { _ in }, clear: {}),
            renewAccessToken: { refreshToken, origin in
                receivedRefreshToken = refreshToken
                receivedOrigin = origin
                return KimiDesktopTokenRefresher.Refreshed(
                    accessToken: renewed, origin: origin, expiry: nil, accountID: "desktop-account")
            },
            tokenCache: KimiDesktopTokenCache())
        let session = try await reader.load()
        XCTAssertEqual(session.token, renewed)
        XCTAssertEqual(receivedRefreshToken, "refresh-fixture")
        XCTAssertEqual(receivedOrigin, "https://www.kimi.com")
    }

    func testRenewalFailureSurfacesTheOriginalFailureInsteadOfASilentEmptySession() async throws {
        let home = try makeExpiredDesktopHome()
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .init(read: { Data("test-password".utf8) }, write: { _ in }, clear: {}),
            renewAccessToken: { _, _ in throw KimiDesktopTokenRefresher.RefreshError.rejected },
            tokenCache: KimiDesktopTokenCache())
        do {
            _ = try await reader.load()
            XCTFail("Expected the expired session to fail")
        } catch {
            // A rejected renewal means the Desktop sign-in is gone, so the
            // user is told to sign in again rather than seeing a raw
            // transport failure.
            guard case KimiSessionError.expired = error else {
                return XCTFail("Expected an expired Desktop sign-in, got \(error)")
            }
        }
    }

    func testRenewedTokenIsValidatedLikeAnyOtherSession() async throws {
        let home = try makeExpiredDesktopHome()
        // A renewal that returns an already-expired token must not be accepted.
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .init(read: { Data("test-password".utf8) }, write: { _ in }, clear: {}),
            renewAccessToken: { _, origin in
                KimiDesktopTokenRefresher.Refreshed(
                    accessToken: self.jwt(subject: "desktop-account", expiry: 1),
                    origin: origin, expiry: nil, accountID: "desktop-account")
            },
            tokenCache: KimiDesktopTokenCache())
        do {
            _ = try await reader.load()
            XCTFail("Expected an expired renewed token to be rejected")
        } catch {
            guard case KimiSessionError.expired = error else {
                return XCTFail("Expected an expired Desktop sign-in, got \(error)")
            }
        }
    }

    func testValidDesktopAccessTokenIsUsedWithoutRenewal() async throws {
        let home = try makeDesktopHome()
        var renewalCalls = 0
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .init(read: { Data("test-password".utf8) }, write: { _ in }, clear: {}),
            renewAccessToken: { _, origin in
                renewalCalls += 1
                return KimiDesktopTokenRefresher.Refreshed(
                    accessToken: "renewed", origin: origin, expiry: nil, accountID: nil)
            },
            tokenCache: KimiDesktopTokenCache())
        let session = try await reader.load()
        XCTAssertEqual(session.token, "fixture-token")
        XCTAssertEqual(renewalCalls, 0, "A live access token must not trigger a renewal")
    }

    func testRenewalIsNotAttemptedWithoutARefreshToken() async throws {
        let home = try makeDesktopHome(
            envelope: Self.expiredStore(includeRefreshToken: false))
        var renewalCalls = 0
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .init(read: { Data("test-password".utf8) }, write: { _ in }, clear: {}),
            renewAccessToken: { _, origin in
                renewalCalls += 1
                return KimiDesktopTokenRefresher.Refreshed(
                    accessToken: "renewed", origin: origin, expiry: nil, accountID: nil)
            },
            tokenCache: KimiDesktopTokenCache())
        do {
            _ = try await reader.load()
            XCTFail("Expected the expired session to fail")
        } catch {
            guard case KimiSessionError.expired = error else {
                return XCTFail("Expected an expired Desktop sign-in, got \(error)")
            }
        }
        XCTAssertEqual(renewalCalls, 0)
    }

    func testARenewedTokenIsReusedOnTheNextPollInsteadOfRenewingAgain() async throws {
        let home = try makeExpiredDesktopHome()
        let cache = KimiDesktopTokenCache()
        var renewalCalls = 0
        let renewed = jwt(subject: "desktop-account", expiry: 9_000_000_000)
        let reader = KimiDesktopSessionReader(
            home: home,
            keyCache: .init(read: { Data("test-password".utf8) }, write: { _ in }, clear: {}),
            renewAccessToken: { _, origin in
                renewalCalls += 1
                return KimiDesktopTokenRefresher.Refreshed(
                    accessToken: renewed,
                    origin: origin,
                    expiry: nil,
                    accountID: "desktop-account")
            },
            tokenCache: cache)
        let first = try await reader.load()
        let second = try await reader.load()
        XCTAssertEqual(first.token, renewed)
        XCTAssertEqual(second.token, renewed)
        XCTAssertEqual(renewalCalls, 1, "A cached renewal must not be repeated")
    }

    func testACachedTokenIsNotReusedForAnotherAccount() {
        let cache = KimiDesktopTokenCache()
        cache.store("renewed", accountID: "account-a", origin: "https://www.kimi.com", expiry: nil)
        XCTAssertEqual(
            cache.token(accountID: "account-a", origin: "https://www.kimi.com"), "renewed")
        XCTAssertNil(
            cache.token(accountID: "account-b", origin: "https://www.kimi.com"),
            "A renewed token must never be served for another Kimi account")
        XCTAssertNil(
            cache.token(accountID: "account-a", origin: "https://www.kimi.ai"),
            "A renewed token must never cross regions")
    }

    func testACachedTokenAboutToExpireIsNotReused() {
        let cache = KimiDesktopTokenCache()
        let expiry = Date().addingTimeInterval(30)
        cache.store("renewed", accountID: "account-a", origin: "https://www.kimi.com", expiry: expiry)
        XCTAssertNil(
            cache.token(accountID: "account-a", origin: "https://www.kimi.com"),
            "A token that is about to expire must be renewed instead of reused")
    }

    func testLiveDesktopRenewalWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AIQUOTABAR_LIVE_KIMI_DESKTOP_TEST"] == "1" else {
            throw XCTSkip("Set AIQUOTABAR_LIVE_KIMI_DESKTOP_TEST=1 for a read-only Desktop quota request.")
        }
        let service = KimiService(defaults: defaults(.auto))
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertEqual(result.provider, .kimi)
        XCTAssertTrue(result.models.contains { $0.modelName == "5h" })
        XCTAssertTrue(result.models.contains { $0.modelName == "7d" })
    }

    func testLiveAutomaticDesktopWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["AIQUOTABAR_LIVE_KIMI_DESKTOP_TEST"] == "1" else {
            throw XCTSkip("Set AIQUOTABAR_LIVE_KIMI_DESKTOP_TEST=1 for a read-only Desktop quota request.")
        }
        let service = KimiService(defaults: defaults(.auto))
        let result = try await service.fetchUsage(apiKey: nil)
        XCTAssertEqual(result.provider, .kimi)
        XCTAssertTrue(result.models.contains { $0.modelName == "5h" })
        XCTAssertTrue(result.models.contains { $0.modelName == "7d" })
        XCTAssertTrue(result.models.allSatisfy { (0...100).contains($0.currentIntervalPercentageRemaining) })
        XCTAssertTrue(result.models.allSatisfy { $0.detailText?.hasPrefix("Kimi Desktop") == true })
    }

    private func jwt(subject: String, expiry: Int) -> String {
        let payload = Data("{\"sub\":\"\(subject)\",\"exp\":\(expiry)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "header.\(payload).signature"
    }

    private struct FailingCLI: KimiCLIStatusProviding {
        func fetchUsageSnapshot() async throws -> UsageSnapshot { throw KimiCLIStatusProbeError.statusUnavailable }
    }
}
