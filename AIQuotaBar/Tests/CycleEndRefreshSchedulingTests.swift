import XCTest
@testable import AIQuotaBar

final class CycleEndRefreshSchedulingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    func testEarliestFutureEndAcrossWindowsAndProviders() {
        let viewModel = UsageViewModel()
        let fiveHourEnd = base.addingTimeInterval(3_600)
        let weeklyEnd = base.addingTimeInterval(86_400)
        viewModel.providerUsageData = [
            .miniMax: makeUsageData(
                provider: .miniMax,
                endTime: fiveHourEnd,
                weeklyEndTime: weeklyEnd),
            .kimi: makeUsageData(
                provider: .kimi,
                endTime: base.addingTimeInterval(7_200),
                weeklyEndTime: nil),
        ]

        XCTAssertEqual(
            viewModel.nextCycleEndDate(
                at: base,
                fetchableProviders: [.miniMax, .kimi]),
            fiveHourEnd)
    }

    @MainActor
    func testPastEndTimesAreSkipped() {
        let viewModel = UsageViewModel()
        viewModel.providerUsageData = [
            .miniMax: makeUsageData(
                provider: .miniMax,
                endTime: base.addingTimeInterval(-60),
                weeklyEndTime: base.addingTimeInterval(-3_600)),
        ]

        XCTAssertNil(
            viewModel.nextCycleEndDate(
                at: base,
                fetchableProviders: [.miniMax]))
    }

    @MainActor
    func testNonFetchableProvidersAreExcluded() {
        let viewModel = UsageViewModel()
        let codexEnd = base.addingTimeInterval(600)
        let kimiEnd = base.addingTimeInterval(3_600)
        viewModel.providerUsageData = [
            .codex: makeUsageData(
                provider: .codex,
                endTime: codexEnd,
                weeklyEndTime: nil),
            .kimi: makeUsageData(
                provider: .kimi,
                endTime: kimiEnd,
                weeklyEndTime: nil),
        ]

        // Codex app not running → only Kimi participates.
        XCTAssertEqual(
            viewModel.nextCycleEndDate(
                at: base,
                fetchableProviders: [.kimi]),
            kimiEnd)
        XCTAssertNil(
            viewModel.nextCycleEndDate(
                at: base,
                fetchableProviders: []))
    }

    @MainActor
    func testCloudSyncedModelsDoNotParticipate() {
        let viewModel = UsageViewModel()
        viewModel.cloudProviderUsageData = [
            .codex: makeUsageData(
                provider: .codex,
                endTime: base.addingTimeInterval(600),
                weeklyEndTime: nil),
        ]

        XCTAssertNil(
            viewModel.nextCycleEndDate(
                at: base,
                fetchableProviders: [.codex]))
    }

    private func makeUsageData(
        provider: UsageProvider,
        endTime: Date?,
        weeklyEndTime: Date?
    ) -> UsageData {
        let model = ModelUsageData(
            provider: provider,
            accountName: nil,
            modelName: "model",
            currentIntervalTotal: 100,
            currentIntervalUsed: 80,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: base.addingTimeInterval(-3_600),
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: weeklyEndTime,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: 80,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
        return UsageData(
            provider: provider,
            remains: 80,
            total: 100,
            timestamp: base,
            models: [model],
            subscribeTitle: nil,
            subscribeEndTime: nil)
    }
}
