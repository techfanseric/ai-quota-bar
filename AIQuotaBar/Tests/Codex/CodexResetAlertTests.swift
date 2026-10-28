import SwiftUI
import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexResetAlertTests: XCTestCase {
    private let now = CodexResetAlert.date("2026-10-28T04:00:00Z")!

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "CodexResetAlerts")))
    }

    private func makeStore(notifications: ResetNotificationSpy? = nil,
                           session: URLSession = .shared) throws -> (CodexResetAlertStore, UserDefaults) {
        let suite = "CodexResetAlertsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (CodexResetAlertStore(defaults: defaults, session: session, notifications: notifications ?? ResetNotificationSpy()), defaults)
    }

    private func alert(_ id: String = "post", source: CodexResetAlert.Source = .reset,
                       kind: CodexResetAlert.Kind = .clue, age: TimeInterval = 0,
                       text: String = "A reset is coming") -> CodexResetAlert {
        CodexResetAlert(key: "\(source.rawValue):\(id)", source: source, kind: kind,
            publishedAt: now.addingTimeInterval(-age), text: text, url: source.url, scheduledFor: nil)
    }

    func testRealTimelineKeepsPendingSeparateFromConfirmedAndIncludesBankedUpdates() throws {
        let alerts = try CodexResetFeed.timeline.decode(fixture("reset-timeline"), now: now)
        XCTAssertEqual(alerts.count, 6)
        XCTAssertEqual(alerts[0].kind, .clue)
        XCTAssertEqual(alerts[1].kind, .clue)
        XCTAssertTrue(alerts[1].text.contains(" & "))
        XCTAssertEqual(alerts[2].kind, .confirmed)
        XCTAssertEqual(alerts[4].kind, .banked)
        XCTAssertEqual(alerts[4].url, CodexResetAlert.Source.reset.url, "Observed events without an X URL link back to the credited site")
    }

    func testPublicStatusDistinguishesScheduleFromExecutionEvenAfterDeadline() throws {
        let alerts = try CodexResetFeed.status.decode(fixture("resets-status"), now: now.addingTimeInterval(86400))
        XCTAssertEqual(alerts.map(\.kind), [.confirmed, .scheduled])
        XCTAssertEqual(alerts[1].scheduledFor, CodexResetAlert.date("2026-10-28T07:00:00Z"))
        XCTAssertEqual(alerts[1].source, .resets)
    }

    func testPublicHistoryAndStatusShareSameSiteIdentity() throws {
        let history = try CodexResetFeed.history.decode(fixture("resets-history"), now: now)
        let status = try CodexResetFeed.status.decode(fixture("resets-status"), now: now)
        XCTAssertEqual(history[0].id, status[0].id)
        XCTAssertEqual(history.last?.kind, .banked)
        let (store, _) = try makeStore()
        store.ingest(status, feed: .status, now: now)
        store.ingest(history, feed: .history, now: now)
        XCTAssertEqual(store.entries.filter { $0.id == history[0].id }.count, 1)
    }

    func testWatchIsUnconfirmedExpiresAndProbabilityDoesNotTriggerNewRevision() throws {
        func data(probability: Int) -> Data {
            Data("""
            {"data":{"latest_reset":null,"scheduled_reset":null,"active_watch":{
              "observed_at":"2026-10-28T03:00:00Z","expires_at":"2026-10-28T05:00:00Z",
              "text":"A hint, not a promise","reset_chance_percent":\(probability),
              "source":{"url":"https://x.com/thsottiaux/status/123"}}}}
            """.utf8)
        }
        let first = try CodexResetFeed.status.decode(data(probability: 70), now: now)
        let next = try CodexResetFeed.status.decode(data(probability: 90), now: now)
        XCTAssertEqual(first.first?.kind, .clue)
        XCTAssertEqual(first.first?.id, next.first?.id)
        XCTAssertTrue(try CodexResetFeed.status.decode(data(probability: 90), now: now.addingTimeInterval(3600)).isEmpty)
    }

    func testUnknownStatusSchemaFailsInsteadOfEstablishingEmptyBaseline() {
        XCTAssertThrowsError(try CodexResetFeed.status.decode(Data(#"{"data":{}}"#.utf8)))
        XCTAssertThrowsError(try CodexResetFeed.timeline.decode(Data(#"{"error":"unavailable"}"#.utf8)))
    }

    func testInvalidDateAndNonResetEventsAreSkippedAndUnsafeURLCannotBeOpened() throws {
        let data = Data("""
        {"events":[
          {"id":"1","type":"boost","summary":"A model launch","announced_at":"2026-10-28T03:00:00Z"},
          {"id":"2","type":"reset","summary":"Reset","announced_at":"invalid"},
          {"id":"3","type":"reset","summary":"Reset","announced_at":"2026-10-28T03:00:00.123Z","url":"file:///etc/passwd"}
        ]}
        """.utf8)
        let alerts = try CodexResetFeed.timeline.decode(data)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].url, CodexResetAlert.Source.reset.url)
        XCTAssertEqual(alerts[0].publishedAt, CodexResetAlert.date("2026-10-28T03:00:00.123Z"))
    }

    func testFirstFetchBaselinesOldHistoryButRetainsRecentUnread() throws {
        let (store, _) = try makeStore()
        let recent = alert("recent", age: 3600)
        store.ingest([alert("old", age: 172800), recent], feed: .timeline, now: now)
        XCTAssertEqual(store.unread.map(\.id), [recent.id])
        XCTAssertEqual(store.entries.count, 2)
    }

    func testCrossSiteDuplicatesBothRemainUnread() throws {
        let (store, _) = try makeStore()
        store.ingest([alert(source: .reset)], feed: .timeline, now: now)
        store.ingest([alert(source: .resets)], feed: .status, now: now)
        XCTAssertEqual(store.unread.count, 2)
        XCTAssertEqual(Set(store.unread.map(\.alert.source)).count, 2)
    }

    func testAcknowledgementAndSeenRevisionsPersistAcrossRestart() throws {
        let (store, defaults) = try makeStore()
        let first = alert()
        store.ingest([first], feed: .timeline, now: now)
        let restoredUnread = CodexResetAlertStore(defaults: defaults, notifications: ResetNotificationSpy())
        XCTAssertEqual(restoredUnread.unread.map(\.id), [first.id])
        store.acknowledge(ids: [first.id])
        let restoredRead = CodexResetAlertStore(defaults: defaults, notifications: ResetNotificationSpy())
        restoredRead.ingest([first], feed: .timeline, now: now)
        XCTAssertTrue(restoredRead.unread.isEmpty)
    }

    func testConfirmationReopensReadPostAndOldNotificationCannotAcknowledgeIt() throws {
        let (store, _) = try makeStore()
        let preview = alert()
        let confirmed = alert(kind: .confirmed)
        store.ingest([preview], feed: .timeline, now: now)
        store.acknowledge(ids: [preview.id])
        store.ingest([confirmed], feed: .timeline, now: now)
        store.acknowledge(ids: [preview.id])
        XCTAssertEqual(store.unread.map(\.id), [confirmed.id])
        store.ingest([preview], feed: .timeline, now: now)
        XCTAssertEqual(store.unread.map(\.id), [confirmed.id])
    }

    func testStaleAcknowledgementLeavesNewerNotificationAndUnreadUntouched() throws {
        let spy = ResetNotificationSpy()
        let (store, _) = try makeStore(notifications: spy)
        let old = alert()
        store.ingest([old], feed: .timeline, now: now)
        store.ingest([alert(kind: .confirmed)], feed: .timeline, now: now)
        store.acknowledge(ids: [old.id])
        XCTAssertEqual(spy.clears, 0)
        XCTAssertEqual(store.unread.count, 1)
    }

    func testLatePreviewCannotRollConfirmationBack() throws {
        let (store, _) = try makeStore()
        let confirmed = alert(source: .resets, kind: .confirmed)
        store.ingest([confirmed], feed: .history, now: now)
        store.ingest([alert(source: .resets, kind: .scheduled)], feed: .status, now: now)
        XCTAssertEqual(store.unread.map(\.id), [confirmed.id])
    }

    func testFirstSuccessfulHistoryFeedDoesNotSilenceAnExistingAnnouncementUpgrade() throws {
        let (store, _) = try makeStore()
        let scheduled = alert(source: .resets, kind: .scheduled, age: 172800)
        let confirmed = alert(source: .resets, kind: .confirmed, age: 172800)
        store.ingest([scheduled], feed: .status, now: now)
        XCTAssertTrue(store.unread.isEmpty, "Old announcements establish a read baseline on first contact")

        // History can recover after status has already established this site's
        // announcement. A newly reported execution must still require review.
        store.ingest([confirmed], feed: .history, now: now)
        XCTAssertEqual(store.unread.map(\.id), [confirmed.id])
    }

    func testDelayedPublicationAfterBaselineIsUnreadAndFeedRemovalDoesNotClearIt() throws {
        let (store, _) = try makeStore()
        store.ingest([], feed: .timeline, now: now)
        let delayed = alert(age: 172800)
        store.ingest([delayed], feed: .timeline, now: now)
        store.ingest([], feed: .timeline, now: now)
        XCTAssertEqual(store.unread.map(\.id), [delayed.id])
    }

    func testOneFailedFeedDoesNotBlockOtherSiteAndRemindersRepeatUntilAcknowledged() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetFeedProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ResetFeedProtocol.set(status: try fixture("resets-status"))
        let spy = ResetNotificationSpy()
        let (store, defaults) = try makeStore(notifications: spy, session: session)
        await store.refresh(now: now)
        XCTAssertTrue(store.failures.contains(.timeline))
        XCTAssertEqual(store.unread.count, 1)
        XCTAssertEqual(spy.deliveries.count, 1)
        XCTAssertEqual(store.lastChecked[.status], now)
        XCTAssertNotNil(defaults.data(forKey: CodexResetAlertStore.storageKey))
        await store.refresh(now: now.addingTimeInterval(60))
        XCTAssertEqual(spy.deliveries.count, 1)
        await store.refresh(now: now.addingTimeInterval(300))
        XCTAssertEqual(spy.deliveries.count, 2)
        store.acknowledge(ids: Set(store.unread.map(\.id)))
        XCTAssertEqual(spy.clears, 1)
        await store.refresh(now: now.addingTimeInterval(600))
        XCTAssertEqual(spy.deliveries.count, 2)
        XCTAssertTrue(store.unread.isEmpty)
    }

    func testNotificationDenialDoesNotAcknowledgeAndContinuesToRetry() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetFeedProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ResetFeedProtocol.set(status: try fixture("resets-status"))
        let spy = ResetNotificationSpy()
        spy.result = .denied
        let (store, _) = try makeStore(notifications: spy, session: session)
        await store.refresh(now: now)
        XCTAssertTrue(store.notificationsDenied)
        XCTAssertFalse(store.unread.isEmpty)
        spy.result = .delivered
        await store.refresh(now: now.addingTimeInterval(300))
        XCTAssertFalse(store.notificationsDenied)
        XCTAssertFalse(store.unread.isEmpty)
        XCTAssertEqual(spy.deliveries.count, 2)
    }

    func testRenderUnreadInboxInBothLanguages() throws {
        let (store, _) = try makeStore()
        let status = try CodexResetFeed.status.decode(fixture("resets-status"), now: now)
        store.ingest(status, feed: .status, now: now)
        store.ingest([alert("clue", text: "Day 23/ Much requested iCloud Mail & Calendar plugins. Just kidding, today is a reset.")], feed: .timeline, now: now)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ai-quota-reset-preview")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in [AppLanguage.simplifiedChinese, .english] {
            let view = CodexResetAlertsView(language: language, store: store)
                .padding(10).frame(width: 340).background(Color(nsColor: .windowBackgroundColor))
            // ImageRenderer cannot draw AppKit-backed Link/borderless controls;
            // capture the actual hosting view so visual QA includes them.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("inbox-\(language == .simplifiedChinese ? "zh" : "en").png"))
            XCTAssertGreaterThan(host.frame.height, 180)
            XCTAssertLessThan(host.frame.height, 700)
        }
    }
}

@MainActor
private final class ResetNotificationSpy: CodexResetNotifying {
    var deliveries: [[CodexResetAlert]] = []
    var clears = 0
    var result: CodexResetNotificationService.Delivery = .delivered
    func notify(_ alerts: [CodexResetAlert], language: AppLanguage) async -> CodexResetNotificationService.Delivery {
        deliveries.append(alerts)
        return result
    }
    func clearDeliveredNotification() { clears += 1 }
}

private final class ResetFeedProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = Data()
    static func set(status: Data) {
        lock.lock(); defer { lock.unlock() }
        Self.status = status
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let status = Self.status
        Self.lock.unlock()
        let isStatus = request.url?.path == "/api/v1/status"
        let body = isStatus ? status : Data(#"{"error":"unavailable"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: isStatus ? 200 : 503,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
