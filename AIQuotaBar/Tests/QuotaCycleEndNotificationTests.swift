import XCTest
@testable import AIQuotaBar

@MainActor
final class QuotaCycleEndNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDueEventsCoverDistinctWindowsAndDeduplicateMirroredResets() {
        let shortEnd = now.addingTimeInterval(-1)
        let weeklyEnd = now.addingTimeInterval(-2)
        let mirroredEnd = now.addingTimeInterval(-3)
        let data: [UsageProvider: UsageData] = [
            .codex: makeUsageData(
                modelName: "Weekly",
                endTime: shortEnd,
                weeklyEndTime: weeklyEnd),
            .glm: makeUsageData(
                provider: .glm,
                modelName: "Credits",
                endTime: mirroredEnd,
                weeklyEndTime: mirroredEnd),
        ]

        let events = QuotaCycleEndEvent.due(
            in: data,
            fetchableProviders: [.codex, .glm],
            now: now)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.filter { $0.provider == .codex }.map(\.scope), [.weekly, .current])
        XCTAssertEqual(events.filter { $0.provider == .glm }.count, 1)
    }

    func testFutureAndUnregisteredCyclesDoNotNotify() {
        let data: [UsageProvider: UsageData] = [
            .codex: makeUsageData(
                modelName: "Weekly",
                endTime: now.addingTimeInterval(60),
                weeklyEndTime: nil),
            .kimi: makeUsageData(
                modelName: "Total usage",
                endTime: now.addingTimeInterval(-60),
                weeklyEndTime: nil),
        ]

        XCTAssertTrue(QuotaCycleEndEvent.due(
            in: data,
            fetchableProviders: [.codex],
            now: now).isEmpty)
    }

    func testNotificationSummarizesOldAndRefreshedCycleAndMasksAccount() {
        let event = QuotaCycleEndEvent.due(
            in: [
                .codex: makeUsageData(
                    modelName: "5h",
                    endTime: now.addingTimeInterval(-15),
                    weeklyEndTime: nil),
            ],
            fetchableProviders: [.codex],
            now: now)[0]
        let refreshed = makeUsageData(
            modelName: "5h",
            endTime: now.addingTimeInterval(5 * 3600),
            weeklyEndTime: nil,
            remaining: 100)

        let payload = QuotaCycleEndNotificationFormatter.payloads(
            for: [event],
            refreshedData: [.codex: refreshed],
            language: .simplifiedChinese,
            masksAccountNames: true)[0]

        XCTAssertEqual(payload.title, "额度周期已重置")
        XCTAssertTrue(payload.subtitle.contains("c****e@example.com"))
        XCTAssertFalse(payload.subtitle.contains("complete@example.com"))
        XCTAssertTrue(payload.body.contains("上个5 小时周期用掉 92%"))
        XCTAssertTrue(payload.body.contains("结束时剩 8%"))
        XCTAssertTrue(payload.body.contains("未用完"))
        XCTAssertTrue(payload.body.contains("刷新后新周期剩 100%"))
    }

    func testCoordinatorMarksOnlySuccessfullyDeliveredEvents() async throws {
        let suiteName = "quota-cycle-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let spy = QuotaCycleEndNotificationSpy()
        spy.result = true
        let coordinator = QuotaCycleEndNotificationCoordinator(
            notifier: spy,
            defaults: defaults)
        let event = QuotaCycleEndEvent.due(
            in: [.glm: makeUsageData(
                modelName: "Credits",
                endTime: now.addingTimeInterval(-1),
                weeklyEndTime: nil)],
            fetchableProviders: [.glm],
            now: now)[0]

        await coordinator.deliver(
            [event],
            refreshedData: [:],
            language: .english,
            masksAccountNames: false)
        await coordinator.deliver(
            [event],
            refreshedData: [:],
            language: .english,
            masksAccountNames: false)
        XCTAssertEqual(spy.payloads.count, 1)

        spy.result = false
        let nextEvent = QuotaCycleEndEvent(
            provider: event.provider,
            accountName: event.accountName,
            modelName: event.modelName,
            scope: event.scope,
            startedAt: event.startedAt,
            endedAt: event.endedAt.addingTimeInterval(3600),
            duration: event.duration,
            endingRemainingText: event.endingRemainingText,
            endingRemainingPercent: event.endingRemainingPercent,
            endingUsedPercent: event.endingUsedPercent,
            modelKey: event.modelKey)
        await coordinator.deliver(
            [nextEvent],
            refreshedData: [:],
            language: .english,
            masksAccountNames: false)
        await coordinator.deliver(
            [nextEvent],
            refreshedData: [:],
            language: .english,
            masksAccountNames: false)
        XCTAssertEqual(spy.successfulPayloads.count, 1)
        XCTAssertEqual(spy.payloads.count, 3)
    }

    func testRefreshNotifiesOnlyAfterProviderRefreshSucceeds() async throws {
        let spy = QuotaCycleEndNotificationSpy()
        let now = Date()
        let oldModel = makeModel(
            provider: .codex,
            modelName: "5h",
            endTime: now.addingTimeInterval(-1),
            weeklyEndTime: nil,
            remaining: 8)
        let newModel = makeModel(
            provider: .codex,
            modelName: "5h",
            endTime: now.addingTimeInterval(5 * 3600),
            weeklyEndTime: nil,
            remaining: 100)
        let viewModel = UsageViewModel(
            providerPresence: { $0 == .codex },
            cycleEndNotifier: spy,
            fetchProviderUsage: { provider in
                guard provider == .codex else { throw UsageError.networkError(URLError(.notConnectedToInternet)) }
                return UsageData(
                    provider: provider,
                    remains: 1,
                    total: 1,
                    timestamp: now,
                    models: [newModel],
                    subscribeTitle: nil,
                    subscribeEndTime: nil)
            })
        viewModel.providerUsageData = [.codex: UsageData(
            provider: .codex,
            remains: 1,
            total: 1,
            timestamp: now,
            models: [oldModel],
            subscribeTitle: nil,
            subscribeEndTime: nil)]

        await viewModel.refresh(showIconSelfTest: false)
        for _ in 0..<100 where spy.payloads.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(spy.payloads.count, 1)
        XCTAssertTrue(spy.payloads[0].body.contains("the new cycle has 100% left"))
    }

    private func makeUsageData(
        provider: UsageProvider = .codex,
        modelName: String,
        endTime: Date?,
        weeklyEndTime: Date?,
        remaining: Int = 8
    ) -> UsageData {
        let model = ModelUsageData(
            provider: provider,
            accountName: "complete@example.com",
            modelName: modelName,
            currentIntervalTotal: 100,
            currentIntervalUsed: remaining,
            weeklyTotal: 100,
            weeklyUsed: remaining,
            remainsTime: 3_600_000,
            startTime: endTime.map { $0.addingTimeInterval(-5 * 3600) },
            endTime: endTime,
            weeklyStartTime: weeklyEndTime.map { $0.addingTimeInterval(-7 * 86_400) },
            weeklyEndTime: weeklyEndTime,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remaining,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
        return UsageData(
            provider: provider,
            remains: 1,
            total: 1,
            timestamp: now,
            models: [model],
            subscribeTitle: nil,
            subscribeEndTime: nil)
    }

    private func makeModel(
        provider: UsageProvider,
        modelName: String,
        endTime: Date?,
        weeklyEndTime: Date?,
        remaining: Int
    ) -> ModelUsageData {
        ModelUsageData(
            provider: provider,
            accountName: "cycle@example.com",
            modelName: modelName,
            currentIntervalTotal: 100,
            currentIntervalUsed: remaining,
            weeklyTotal: 100,
            weeklyUsed: remaining,
            remainsTime: 3_600_000,
            startTime: endTime.map { $0.addingTimeInterval(-5 * 3600) },
            endTime: endTime,
            weeklyStartTime: weeklyEndTime.map { $0.addingTimeInterval(-7 * 86_400) },
            weeklyEndTime: weeklyEndTime,
            valueSuffix: "%",
            detailText: nil,
            currentIntervalRemainingPercent: remaining,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: nil)
    }
}

@MainActor
private final class QuotaCycleEndNotificationSpy: QuotaCycleEndNotifying {
    var payloads: [QuotaCycleEndNotificationPayload] = []
    var successfulPayloads: [QuotaCycleEndNotificationPayload] = []
    var result = true

    func deliver(_ payload: QuotaCycleEndNotificationPayload) async -> Bool {
        payloads.append(payload)
        if result { successfulPayloads.append(payload) }
        return result
    }
}
