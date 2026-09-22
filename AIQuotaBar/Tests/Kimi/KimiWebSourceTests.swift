import CodexBarCore
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

    func testMissingDesktopIsNotDetectedFromAnEmptyHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reader = KimiDesktopSessionReader(home: home)
        XCTAssertFalse(reader.isPresent)
        XCTAssertThrowsError(try reader.load())
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
