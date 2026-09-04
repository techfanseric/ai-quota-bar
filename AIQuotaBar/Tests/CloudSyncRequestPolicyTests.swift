import Foundation
import XCTest
@testable import AIQuotaBar

@MainActor
final class CloudSyncRequestPolicyTests: XCTestCase {
    private func fixture(_ replies: [CloudSyncStubProtocol.Reply]) -> (CloudSyncService, URLSession) {
        CloudSyncStubProtocol.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudSyncStubProtocol.self]
        let session = URLSession(configuration: configuration)
        return (CloudSyncService(session: session, retryBackoffs: [0, 0, 0]), session)
    }

    private func send(_ service: CloudSyncService) async throws {
        var request = URLRequest(url: URL(string: "https://cloud-sync-test.invalid/v1/quota-samples")!)
        request.httpMethod = "POST"
        try await service.sendWithRetry(request: request, body: Data("{}".utf8))
    }

    func testUnauthorizedIsNotRetried() async {
        let (service, session) = fixture([.http(401, "unauthorized")])
        defer { session.invalidateAndCancel() }
        do {
            try await send(service)
            XCTFail("Expected HTTP error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths, ["/v1/quota-samples"])
    }

    func testDailyQuota503IsNotRetried() async {
        let (service, session) = fixture([.http(503, "{\"error\":\"d1_daily_limit_exceeded\"}")])
        defer { session.invalidateAndCancel() }
        do {
            try await send(service)
            XCTFail("Expected quota error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 1)
    }

    func testRawD1RowsQuota500IsNotRetried() async {
        let (service, session) = fixture([.http(500,
            "{\"error\":\"internal_error\",\"message\":\"D1_ERROR: exceeded D1's free tier daily row read limit\"}")])
        defer { session.invalidateAndCancel() }
        do {
            try await send(service)
            XCTFail("Expected quota error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 1)
    }

    func testExplicitDailyReadLimit503IsNotRetried() async {
        let (service, session) = fixture([.http(503, "{\"error\":\"D1_DAILY_READ_LIMIT\"}")])
        defer { session.invalidateAndCancel() }
        do {
            try await send(service)
            XCTFail("Expected quota error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 1)
    }

    func testUnrelatedQuota500StillRetries() async {
        let (service, session) = fixture(Array(repeating: .http(500, "model quota unavailable"), count: 4))
        defer { session.invalidateAndCancel() }
        do {
            try await send(service)
            XCTFail("Expected server error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 4)
    }

    func testOrdinary503StillRetriesFourTimes() async {
        let (service, session) = fixture(Array(repeating: .http(503, "temporarily unavailable"), count: 4))
        defer { session.invalidateAndCancel() }
        do {
            try await send(service)
            XCTFail("Expected server error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 4)
    }

    func testNetworkFailureCanRecoverOnRetry() async throws {
        let (service, session) = fixture([.network(.cannotConnectToHost), .http(200, "{}")])
        defer { session.invalidateAndCancel() }
        try await send(service)
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 2)
    }

    func testFetchRetriesNetworkErrorThenRecovers() async throws {
        let (service, session) = fixture([
            .network(.timedOut), .http(200, "{\"ok\":true,\"samples\":[]}")
        ])
        defer { session.invalidateAndCancel() }
        let data = try await service.fetchRemoteUsageData()
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 2)
    }

    func testFetchDoesNotRetryServerError() async {
        let (service, session) = fixture([.http(500, "D1 unavailable")])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await service.fetchRemoteUsageData()
            XCTFail("Expected server error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths.count, 1)
    }

    func testAccountSummary404FallsBackToLatestSamples() async throws {
        let (service, session) = fixture([
            .http(404, "not found"), .http(200, "{\"ok\":true,\"samples\":[]}")
        ])
        defer { session.invalidateAndCancel() }
        let accounts = try await service.fetchRemoteAccountSummaries(
            endpointURLString: "https://cloud-sync-test.invalid", token: "test-only")
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths, ["/v1/account-summaries", "/v1/quota-samples"])
    }

    func testAccountSummaryServerErrorDoesNotTriggerAnotherRead() async {
        let (service, session) = fixture([.http(500, "D1 unavailable")])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await service.fetchRemoteAccountSummaries(
                endpointURLString: "https://cloud-sync-test.invalid", token: "test-only")
            XCTFail("Expected server error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths, ["/v1/account-summaries"])
    }

    func testValidEmptyAccountSummaryDoesNotTriggerAnotherRead() async throws {
        let (service, session) = fixture([.http(200, "{\"ok\":true,\"accounts\":[]}")])
        defer { session.invalidateAndCancel() }
        let accounts = try await service.fetchRemoteAccountSummaries(
            endpointURLString: "https://cloud-sync-test.invalid", token: "test-only")
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths, ["/v1/account-summaries"])
    }

    func testMalformedAccountSummaryDoesNotTriggerAnotherRead() async {
        let (service, session) = fixture([.http(200, "not JSON")])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await service.fetchRemoteAccountSummaries(
                endpointURLString: "https://cloud-sync-test.invalid", token: "test-only")
            XCTFail("Expected decoding error")
        } catch {}
        XCTAssertEqual(CloudSyncStubProtocol.requestPaths, ["/v1/account-summaries"])
    }

    func testTimeoutErrorDescriptionIncludesProxyHint() {
        let error = CloudSyncError.network(URLError(.timedOut))
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("workers.dev"), description)
        XCTAssertTrue(description.contains("代理"), description)
    }

    func testDNSErrorDescriptionMentionsPollution() {
        let error = CloudSyncError.network(URLError(.cannotFindHost))
        XCTAssertTrue(error.errorDescription?.contains("DNS") == true)
    }

    func testD1DailyLimitServerErrorHasPlainLanguageDescription() {
        let coded = CloudSyncError.serverError(503, "{\"error\":\"d1_daily_limit_exceeded\"}")
        XCTAssertEqual(
            coded.errorDescription,
            "Cloud database daily quota exceeded; it resets at 00:00 UTC.")

        let legacy = CloudSyncError.serverError(
            500, "{\"error\":\"internal_error\",\"message\":\"D1_ERROR: exceeded D1's free tier daily row read limit\"}")
        XCTAssertEqual(legacy.errorDescription, coded.errorDescription)

        let otherD1 = CloudSyncError.serverError(503, "{\"error\":\"d1_error\",\"message\":\"D1_ERROR: no such table\"}")
        XCTAssertTrue(otherD1.errorDescription?.contains("Cloud database error") == true)

        let unrelated = CloudSyncError.serverError(500, "model quota unavailable")
        XCTAssertTrue(unrelated.errorDescription?.contains("Cloud sync failed (500)") == true)
    }

    func testD1UsageStateDecodesAvailablePayload() throws {
        let json = """
        {"ok":true,"rowsRead":2500000,"rowsWritten":12000,"databaseRowsRead":400000,
         "databaseRowsWritten":9000,"remaining":2500000,"limit":5000000,"pct":50.0,
         "observedAt":"2026-09-03T00:00:00.000Z","resetsAt":"2026-09-04T00:00:00.000Z"}
        """
        let usage = try JSONDecoder().decode(CloudD1Usage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.rowsRead, 2_500_000)
        XCTAssertEqual(usage.severity, .warning)
        XCTAssertEqual(d1Usage(pct: 10).severity, .normal)
        XCTAssertEqual(d1Usage(pct: 80).severity, .critical)
    }

    private func d1Usage(pct: Double) -> CloudD1Usage {
        let json = """
        {"ok":true,"rowsRead":0,"rowsWritten":0,"databaseRowsRead":0,
         "databaseRowsWritten":0,"remaining":0,"limit":5000000,"pct":\(pct),
         "observedAt":"","resetsAt":""}
        """
        return try! JSONDecoder().decode(CloudD1Usage.self, from: Data(json.utf8))
    }
}

private final class CloudSyncStubProtocol: URLProtocol {
    enum Reply {
        case http(Int, String)
        case network(URLError.Code)
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var paths: [String] = []

    static var requestPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static func reset(_ newReplies: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        replies = newReplies
        paths = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.paths.append(request.url!.path)
        let reply = Self.replies.isEmpty ? Reply.http(599, "unexpected retry") : Self.replies.removeFirst()
        Self.lock.unlock()
        switch reply {
        case let .http(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .network(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
