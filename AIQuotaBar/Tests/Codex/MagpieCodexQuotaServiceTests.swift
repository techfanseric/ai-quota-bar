import XCTest
@testable import AIQuotaBar

final class MagpieCodexQuotaServiceTests: XCTestCase {
    @MainActor
    func testCodexPoolDrivesSingleRingAndHoverAccountDetails() throws {
        let defaults = UserDefaults.standard
        let keys = [
            MenuBarContentSelection.storageKey,
            MenuBarRingDisplayMode.storageKey,
            MenuBarRingPreferences.providersKey,
            MenuBarAppearance.storageKey,
            MenuBarRingQuotaWindow.storageKey,
            MenuBarReserveQuotaWindow.storageKey,
            MenuBarProviderRingWindows.storageKey,
            CloudSyncSettings.enabledKey,
            MenuAccountPrivacy.storageKey,
            CodexMagpieRingScope.storageKey,
        ]
        let previousValues = keys.map { key in
            (key: key, value: defaults.object(forKey: key))
        }
        defer {
            for previous in previousValues {
                if let value = previous.value {
                    defaults.set(value, forKey: previous.key)
                } else {
                    defaults.removeObject(forKey: previous.key)
                }
            }
        }
        defaults.set(MenuBarContentSelection.codex.rawValue, forKey: MenuBarContentSelection.storageKey)
        defaults.set(MenuBarAppearance.compactRing.rawValue, forKey: MenuBarAppearance.storageKey)
        defaults.set(MenuBarRingQuotaWindow.weekly.rawValue, forKey: MenuBarRingQuotaWindow.storageKey)
        defaults.set(MenuBarReserveQuotaWindow.synchronized.rawValue, forKey: MenuBarReserveQuotaWindow.storageKey)
        defaults.set(CodexMagpieRingScope.allAccounts.rawValue, forKey: CodexMagpieRingScope.storageKey)
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)
        defaults.set(false, forKey: MenuAccountPrivacy.storageKey)

        let now = Date()
        let payload = """
        {"object":"list","data":[
          {"provider":"codex","kind":"subscription","plan":"pro","user":"a@example.com","windows":[
            {"name":"5 hours","remaining":20,"resetsAt":"\(iso(now.addingTimeInterval(3 * 3600)))"},
            {"name":"7 days","remaining":30,"resetsAt":"\(iso(now.addingTimeInterval(8 * 24 * 3600)))"}
          ]},
          {"provider":"codex","kind":"subscription","plan":"prolite","user":"b@example.com","windows":[
            {"name":"7 days","remaining":0,"resetsAt":"\(iso(now.addingTimeInterval(7 * 24 * 3600)))"}
          ]},
          {"provider":"codex","kind":"subscription","plan":"pro","user":"c@example.com","windows":[
            {"name":"7 days","remaining":7,"resetsAt":"\(iso(now.addingTimeInterval(6 * 24 * 3600)))"}
          ]}
        ]}
        """
        let data = try MagpieCodexQuotaService.usageData(from: Data(payload.utf8))
        let viewModel = UsageViewModel()
        viewModel.menuBarRingSelectedProviders = Set(MenuBarRingPreferences.providerOrder)
        viewModel.usageData = data

        XCTAssertEqual(viewModel.menuBarSnapshot.remainingPercent, 9)
        XCTAssertEqual(viewModel.menuBarSnapshot.ringPercent, 9)
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("a@example.com · Pro 20x · 5h · 20% left"))
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("b@example.com · Pro 5x · Weekly · 0% left"))
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("c@example.com · Pro 20x · Weekly · 7% left"))

        defaults.set(true, forKey: MenuAccountPrivacy.storageKey)
        viewModel.usageData = data
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("Magpie · 3/3 accounts"))
        XCTAssertTrue(viewModel.menuBarSnapshot.tooltip.contains("****@example.com · Pro 20x · 5h · 20% left"))
        XCTAssertFalse(viewModel.menuBarSnapshot.tooltip.contains("a@example.com"))
    }

    func testMapsThreeMagpieAccountsIntoPoolAndPerAccountRows() throws {
        let payload = """
        {"object":"list","data":[
          {"provider":"codex","kind":"subscription","plan":"pro","user":"a@example.com","readAt":"2026-11-13T02:48:40.610252Z","windows":[
            {"name":"5 hours","used":80,"remaining":20,"resetsAt":"2026-11-13T07:00:00Z"},
            {"name":"7 days","used":70,"remaining":30,"resetsAt":"2026-11-13T21:00:00Z"}
          ]},
          {"provider":"codex","kind":"subscription","plan":"prolite","user":"b@example.com","readAt":"2026-11-13T02:48:40.185382Z","windows":[
            {"name":"7 days","used":100,"remaining":0,"resetsAt":"2026-11-13T09:00:00Z"},
            {"name":"Image generation","text":true,"used":0,"remaining":100}
          ]},
          {"provider":"codex","kind":"subscription","plan":"pro","user":"c@example.com","readAt":"2026-11-13T02:48:40.306589Z","windows":[
            {"name":"7 days","used":93,"remaining":7,"resetsAt":"2026-11-13T16:00:00Z"}
          ]}
        ]}
        """

        let data = try MagpieCodexQuotaService.usageData(from: Data(payload.utf8))

        XCTAssertEqual(data.models.count, 6)
        let pool = try XCTUnwrap(data.models.first(where: \.isCodexPoolQuota))
        XCTAssertEqual(pool.currentIntervalRemainingPercent, 9)
        XCTAssertEqual(pool.weeklyRemainingPercent, 9)
        XCTAssertTrue(pool.detailText?.contains("3/3 accounts") == true)
        XCTAssertEqual(data.models.filter { $0.accountName == "a@example.com" }.count, 2)
        XCTAssertEqual(data.models.filter { $0.accountName == "b@example.com" }.count, 1)
    }

    func testFailedAccountCountsAgainstPoolButStaysVisibleAsDetail() throws {
        let payload = """
        {"object":"list","data":[
          {"provider":"codex","kind":"subscription","plan":"pro","user":"good@example.com","windows":[
            {"name":"7 days","used":80,"remaining":20,"resetsAt":"2026-11-13T21:00:00Z"}
          ]},
          {"provider":"codex","kind":"subscription","plan":"pro","user":"bad@example.com","error":"provider refused","windows":[]}
        ]}
        """

        let data = try MagpieCodexQuotaService.usageData(from: Data(payload.utf8))

        XCTAssertEqual(data.models.count, 4)
        let pool = try XCTUnwrap(data.models.first(where: \.isCodexPoolQuota))
        XCTAssertEqual(pool.currentIntervalRemainingPercent, 10)
        XCTAssertTrue(pool.detailText?.contains("1/2 accounts") == true)
        let failed = try XCTUnwrap(data.models.first { $0.accountName == "bad@example.com" })
        XCTAssertEqual(failed.currentIntervalRemainingPercent, 0)
    }

    func testNonCodexOnlyReportThrowsAndCodexServiceFallsBack() async throws {
        let payload = #"{"object":"list","data":[{"provider":"kimi","kind":"subscription","windows":[]}]}"#
        XCTAssertThrowsError(try MagpieCodexQuotaService.usageData(from: Data(payload.utf8)))

        let fallback = UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: Date(),
            models: [],
            subscribeTitle: nil,
            subscribeEndTime: nil)
        let service = CodexService(
            magpieQuotaService: ThrowingMagpieQuotaStub(),
            activeUsageFetcher: { fallback })
        let result = try await service.fetchUsage()
        XCTAssertEqual(result.provider, .codex)
        XCTAssertEqual(result.total, fallback.total)
    }

    func testMissingMagpieConfigurationFallsBackWithoutActiveAccountReadFailure() async throws {
        let missingConfig = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-missing-\(UUID().uuidString).toml")
        let fallback = UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: Date(),
            models: [],
            subscribeTitle: nil,
            subscribeEndTime: nil)
        let service = CodexService(
            magpieQuotaService: MagpieCodexQuotaService(configURL: missingConfig),
            activeUsageFetcher: { fallback })

        let result = try await service.fetchUsage()

        XCTAssertEqual(result.total, fallback.total)
        XCTAssertTrue(result.models.isEmpty)
    }

    func testCodexServiceUsesMagpieBeforeActiveAccountReader() async throws {
        let magpie = UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: Date(),
            models: [],
            subscribeTitle: nil,
            subscribeEndTime: nil)
        let active = ActiveAccountReaderStub()
        let service = CodexService(
            magpieQuotaService: SuccessMagpieQuotaStub(data: magpie),
            activeUsageFetcher: { try await active.fetch() })

        let result = try await service.fetchUsage()

        XCTAssertEqual(result.total, magpie.total)
        let activeCalls = await active.callCount
        XCTAssertEqual(activeCalls, 0)
    }

}

private struct SuccessMagpieQuotaStub: MagpieCodexQuotaProviding {
    let data: UsageData

    func fetchUsage() async throws -> UsageData? {
        data
    }
}

private struct ThrowingMagpieQuotaStub: MagpieCodexQuotaProviding {
    struct Failed: Error {}

    func fetchUsage() async throws -> UsageData? {
        throw Failed()
    }
}

private actor ActiveAccountReaderStub {
    private(set) var callCount = 0

    func fetch() async throws -> UsageData {
        callCount += 1
        return UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: Date(),
            models: [],
            subscribeTitle: nil,
            subscribeEndTime: nil)
    }
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
