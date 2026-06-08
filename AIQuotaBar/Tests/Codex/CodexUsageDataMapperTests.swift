import CodexBarCore
import XCTest
@testable import AIQuotaBar

final class CodexUsageDataMapperTests: XCTestCase {
    func testMapsPrimaryWindowTo5h() {
        let window = RateWindow(
            usedPercent: 35,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let snapshot = UsageSnapshot(
            primary: window,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(timeIntervalSince1970: 1_699_999_000),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")

        XCTAssertEqual(data.provider, .codex)
        XCTAssertEqual(data.models.count, 1)
        let model = data.models[0]
        XCTAssertEqual(model.modelName, "5h")
        XCTAssertEqual(model.valueSuffix, "%")
        XCTAssertEqual(model.currentIntervalRemainingPercent, 65)
        XCTAssertEqual(model.accountName, "user@example.com")
        XCTAssertEqual(model.weeklyTotal, 0)
        XCTAssertNotNil(model.endTime)
    }

    func testMapsSecondaryWindowToWeekly() {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: window,
            tertiary: nil,
            extraRateWindows: nil,
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "codex-cli")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertEqual(data.models[0].modelName, "Weekly")
        XCTAssertEqual(data.models[0].currentIntervalRemainingPercent, 100)
        XCTAssertNil(data.models[0].accountName)
    }

    func testMapsExtraRateWindows() {
        let extraWindow = RateWindow(
            usedPercent: 60,
            windowMinutes: 60,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let named = NamedRateWindow(
            id: "spark",
            title: "GPT-5.3-Codex-Spark",
            window: extraWindow)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [named],
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertEqual(data.models[0].modelName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(data.models[0].currentIntervalRemainingPercent, 40)
    }

    func testCodexFiveHourExtraUsesCanonicalHistoryIDButDoesNotRecordSlidingHistory() {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let named = NamedRateWindow(
            id: "spark",
            title: "Codex Spark 5-hour",
            window: window)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [named],
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")
        let model = data.models[0]

        XCTAssertEqual(model.id, "codex:user@example.com:Codex Spark 5-hour")
        XCTAssertEqual(model.codexFiveHourCanonicalHistoryID, "codex:user@example.com:5h")
        XCTAssertTrue(model.isCodexFiveHourHistoryWindow)
        XCTAssertTrue(model.isCodexSlidingFiveHourExtraWindow)
    }

    func testMapsCreditsAsExtraModel() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)
        let credits = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: Date())

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: credits,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertEqual(data.models[0].modelName, "Credits")
        XCTAssertEqual(data.models[0].currentIntervalRemaining, 1234)
    }

    func testMapsAllSectionsTogether() {
        let primary = RateWindow(
            usedPercent: 35,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let secondary = RateWindow(
            usedPercent: 0,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Date(timeIntervalSince1970: 1_700_100_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let extra = NamedRateWindow(
            id: "spark",
            title: "GPT-5.3-Codex-Spark",
            window: RateWindow(
                usedPercent: 60,
                windowMinutes: 60,
                resetsAt: Date(timeIntervalSince1970: 1_700_050_000),
                resetDescription: nil,
                nextRegenPercent: nil))
        let credits = CreditsSnapshot(remaining: 500, events: [], updatedAt: Date())
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: [extra],
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: credits,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 4)
        XCTAssertEqual(data.models[0].modelName, "5h")
        XCTAssertEqual(data.models[1].modelName, "Weekly")
        XCTAssertEqual(data.models[2].modelName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(data.models[3].modelName, "Credits")
        XCTAssertEqual(data.models[0].accountName, "user@example.com")
    }

    func testEmptySnapshotProducesNotConfiguredPlaceholder() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            kiroUsage: nil,
            providerCost: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertTrue(
            data.models[0].detailText?.contains("Codex not configured") == true,
            "Expected 'Codex not configured' placeholder, got \(data.models[0].detailText ?? "nil")")
    }
}
