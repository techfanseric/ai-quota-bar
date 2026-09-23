import XCTest
@testable import AIQuotaBar

final class LeftClickMenuDisplayPreferencesTests: XCTestCase {
    func testDefaultsToShowingEveryAccountAndDimension() {
        let model = makeModel(account: "user@example.com", name: "5h")
        let preferences = LeftClickMenuDisplayPreferences()

        XCTAssertTrue(preferences.isAccountVisible(LeftClickMenuAccountKey(model: model)))
        XCTAssertTrue(preferences.isModelVisible(model))
        XCTAssertFalse(preferences.hasHiddenItems)
    }

    func testCanHideOneDimensionWithoutHidingItsAccount() {
        let fiveHour = makeModel(account: "user@example.com", name: "5h")
        let weekly = makeModel(account: "user@example.com", name: "Weekly")
        var preferences = LeftClickMenuDisplayPreferences()

        preferences.setModelVisible(false, key: fiveHour.mobileDashboardSelectionKey)

        XCTAssertFalse(preferences.isModelVisible(fiveHour))
        XCTAssertTrue(preferences.isModelVisible(weekly))
        XCTAssertTrue(preferences.isAccountVisible(LeftClickMenuAccountKey(model: fiveHour)))
    }

    func testRestoringAccountPreservesDimensionChoices() {
        let fiveHour = makeModel(account: "user@example.com", name: "5h")
        let weekly = makeModel(account: "user@example.com", name: "Weekly")
        let accountKey = LeftClickMenuAccountKey(model: fiveHour)
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.setModelVisible(false, key: weekly.mobileDashboardSelectionKey)

        preferences.setAccountVisible(false, key: accountKey)
        XCTAssertFalse(preferences.isModelVisible(fiveHour))
        XCTAssertFalse(preferences.isModelVisible(weekly))

        preferences.setAccountVisible(true, key: accountKey)
        XCTAssertTrue(preferences.isModelVisible(fiveHour))
        XCTAssertFalse(preferences.isModelVisible(weekly))
    }

    func testRoundTripsThroughUserDefaults() throws {
        let suiteName = "LeftClickMenuDisplayPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel(account: "User@Example.com", name: "5h")
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.setModelVisible(false, key: model.mobileDashboardSelectionKey)

        preferences.save(to: defaults)
        let restored = LeftClickMenuDisplayPreferences.load(from: defaults)

        XCTAssertEqual(restored, preferences)
        XCTAssertFalse(restored.isModelVisible(model))
    }

    func testDefaultOrderPutsCodexFirstAndMiniMaxLast() {
        let preferences = LeftClickMenuDisplayPreferences()

        XCTAssertFalse(preferences.hasCustomProviderOrder)
        XCTAssertEqual(
            preferences.providerOrder,
            [.codex, .kimi, .glm, .miniMax])
    }

    func testMoveProviderReordersNeighboursAndClampsAtEdges() {
        var preferences = LeftClickMenuDisplayPreferences()

        preferences.moveProvider(.kimi, byOffset: 0)
        XCTAssertFalse(preferences.hasCustomProviderOrder, "A zero-offset move must not mark the order as customized")

        preferences.moveProvider(.codex, byOffset: -1)
        XCTAssertEqual(
            preferences.providerOrder,
            [.codex, .kimi, .glm, .miniMax],
            "Moving the first provider up must clamp without changing the order")

        preferences.moveProvider(.glm, byOffset: -1)
        XCTAssertEqual(preferences.providerOrder, [.codex, .glm, .kimi, .miniMax])
        XCTAssertTrue(preferences.hasCustomProviderOrder)

        preferences.moveProvider(.miniMax, byOffset: 1)
        XCTAssertEqual(
            preferences.providerOrder,
            [.codex, .glm, .kimi, .miniMax],
            "Moving the last provider down must clamp without changing the order")
    }

    func testMovingBackToDefaultOrderClearsCustomPersistence() {
        var preferences = LeftClickMenuDisplayPreferences()

        preferences.moveProvider(.miniMax, byOffset: -1)
        XCTAssertEqual(preferences.providerOrder, [.codex, .kimi, .miniMax, .glm])
        XCTAssertTrue(preferences.hasCustomProviderOrder)

        preferences.moveProvider(.miniMax, byOffset: 1)
        XCTAssertEqual(preferences.providerOrder, UsageProvider.leftClickMenuDefaultOrder)
        XCTAssertFalse(
            preferences.hasCustomProviderOrder,
            "Restoring the default order manually should drop the custom payload")
    }

    func testResetProviderOrderReturnsToDefaults() {
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.moveProvider(.codex, byOffset: 2)
        XCTAssertTrue(preferences.hasCustomProviderOrder)

        preferences.resetProviderOrder()

        XCTAssertFalse(preferences.hasCustomProviderOrder)
        XCTAssertEqual(preferences.providerOrder, UsageProvider.leftClickMenuDefaultOrder)
    }

    func testLegacyPayloadWithoutOrderKeepsHiddenItemsAndFallsBackToDefaultOrder() throws {
        let legacyPayload = Data("""
        {"hiddenAccounts":[],"hiddenModels":[]}
        """.utf8)

        let restored = try JSONDecoder().decode(
            LeftClickMenuDisplayPreferences.self,
            from: legacyPayload)

        XCTAssertNil(restored.customProviderOrder)
        XCTAssertFalse(restored.hasHiddenItems)
        XCTAssertEqual(restored.providerOrder, UsageProvider.leftClickMenuDefaultOrder)
    }

    func testRoundTripsCustomOrderThroughUserDefaults() throws {
        let suiteName = "LeftClickMenuDisplayPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.moveProvider(.miniMax, byOffset: -2)

        preferences.save(to: defaults)
        let restored = LeftClickMenuDisplayPreferences.load(from: defaults)

        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.providerOrder, [.codex, .miniMax, .kimi, .glm])
    }

    func testDecodingDropsUnknownProvidersAndAppendsMissingOnes() throws {
        let payload = Data("""
        {"customProviderOrder":["kimi","unknown-provider","kimi"]}
        """.utf8)

        let restored = try JSONDecoder().decode(
            LeftClickMenuDisplayPreferences.self,
            from: payload)

        XCTAssertTrue(restored.hasCustomProviderOrder)
        XCTAssertEqual(restored.providerOrder, [.kimi, .miniMax, .codex, .glm])
    }

    func testDecodingExplicitDefaultOrderClearsCustomFlag() throws {
        let payload = Data("""
        {"customProviderOrder":["codex","kimi","glm","minimax"]}
        """.utf8)

        let restored = try JSONDecoder().decode(
            LeftClickMenuDisplayPreferences.self,
            from: payload)

        XCTAssertNil(restored.customProviderOrder)
        XCTAssertFalse(restored.hasCustomProviderOrder)
    }

    @MainActor
    func testLeftClickMenuSectionsFollowConfiguredProviderOrder() {
        let defaults = UserDefaults.standard
        let keys = [
            LeftClickMenuDisplayPreferences.storageKey,
            CloudSyncSettings.enabledKey,
        ]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.set(false, forKey: CloudSyncSettings.enabledKey)
        defaults.removeObject(forKey: LeftClickMenuDisplayPreferences.storageKey)

        let viewModel = UsageViewModel()
        var preferences = LeftClickMenuDisplayPreferences()
        preferences.moveProvider(.codex, byOffset: 2)
        viewModel.leftClickMenuDisplayPreferences = preferences

        let now = Date()
        let menuProviders: Set<UsageProvider> = [.codex, .kimi, .glm, .miniMax]
        viewModel.providerUsageData = Dictionary(uniqueKeysWithValues: menuProviders.map { provider in
            (provider, UsageData(
                provider: provider,
                remains: 1,
                total: 1,
                timestamp: now,
                models: [makeMenuModel(provider: provider, remainingPercent: 50, now: now)],
                subscribeTitle: nil,
                subscribeEndTime: nil))
        })

        func displayedProviders() -> [UsageProvider] {
            viewModel.leftClickMenuUsageSections
                .filter { menuProviders.contains($0.provider) }
                .map(\.provider)
        }

        XCTAssertEqual(
            displayedProviders(),
            [.kimi, .glm, .codex, .miniMax],
            "Menu sections follow the configured order")

        viewModel.leftClickMenuDisplayPreferences = LeftClickMenuDisplayPreferences()
        XCTAssertEqual(
            displayedProviders(),
            [.codex, .kimi, .glm, .miniMax],
            "Default order keeps Codex on top and MiniMax at the bottom")
    }

    private func makeMenuModel(
        provider: UsageProvider,
        remainingPercent: Int,
        now: Date
    ) -> ModelUsageData {
        ModelUsageData(
            provider: provider,
            accountName: nil,
            modelName: provider.displayName,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: now.addingTimeInterval(-3_600),
            endTime: now.addingTimeInterval(3_600),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }

    private func makeModel(account: String?, name: String) -> ModelUsageData {
        ModelUsageData(
            provider: .codex,
            accountName: account,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: 75,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: 75,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }
}
