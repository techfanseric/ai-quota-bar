import XCTest
@testable import CodexLocalUsageCore

private final class UsageProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func requestBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

final class UsageClientTests: XCTestCase {
    private func client() throws -> UsageClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageProtocol.self]
        return try UsageClient(endpoint: "https://test.invalid", token: "test-device", session: URLSession(configuration: config))
    }
    private var event: LocalUsageEvent {
        LocalUsageEvent(id: String(repeating: "a", count: 64), occurredAt: "2026-01-02T12:00:00.000Z", model: "fixture", tokens: UsageTokens(input: 100, output: 10))
    }
    func testTimeoutLeavesDurableOutboxAndRetryAcknowledgesIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("test.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try UsageStore(url: url); try await store.insert([event], binding: "person", since: .distantPast)
        UsageProtocol.handler = { _ in throw URLError(.timedOut) }
        let client = try client()
        do { _ = try await client.send(try await store.pending(binding: "person")); XCTFail("Expected timeout") } catch {}
        let afterTimeout = try await store.pending(binding: "person"); XCTAssertEqual(afterTimeout.count, 1)
        let id = event.id
        UsageProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-device")
            XCTAssertEqual(request.url?.path, "/v1/usage/events/batch")
            return (200, Data("{\"accepted\":[\"\(id)\"],\"rejected\":[]}".utf8))
        }
        let receipt = try await client.send(afterTimeout)
        try await store.acknowledge(binding: "person", ids: receipt.accepted)
        let remaining = try await store.pending(binding: "person"); XCTAssertTrue(remaining.isEmpty)
    }
    func testMismatchedReceiptCannotLoseEvents() async throws {
        UsageProtocol.handler = { _ in (200, Data("{\"accepted\":[],\"rejected\":[]}".utf8)) }
        do { _ = try await client().send([event]); XCTFail("Missing acknowledgement must fail") } catch {}
    }
    func testRevokedCredentialFails() async throws {
        UsageProtocol.handler = { _ in (401, Data("{}".utf8)) }
        do { _ = try await client().identity(); XCTFail("Expected unauthorized") }
        catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
    private var protocolSession: URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UsageProtocol.self]
        return URLSession(configuration: config)
    }
    func testJoinSendsInviteCodeNameAndDeviceWithoutAnyCredential() async throws {
        UsageProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/usage/join")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            XCTAssertEqual(body?["inviteCode"] as? String, "ABCD2345EFGH")
            XCTAssertEqual(body?["memberName"] as? String, "Alice")
            XCTAssertEqual(body?["deviceID"] as? String, "d1")
            XCTAssertNil(body?["memberPassphrase"])
            return (200, Data(#"{"token":"aqu_join","identity":{"team_id":"t1","member_id":"m1","member_name":"Alice","device_id":"d1"}}"#.utf8))
        }
        let response = try await UsageClient.join(endpoint: "https://test.invalid", inviteCode: " abcd-2345-efgh ", memberName: " Alice ", deviceID: " d1 ", session: protocolSession)
        XCTAssertEqual(response.token, "aqu_join")
        XCTAssertEqual(response.identity.member_id, "m1")
    }
    func testJoinWithPassphraseAndReadableFailures() async throws {
        UsageProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            XCTAssertEqual(body?["memberPassphrase"] as? String, "hunter2")
            return (409, Data("{}".utf8))
        }
        do {
            _ = try await UsageClient.join(endpoint: "https://test.invalid", inviteCode: "ABCD-2345-EFGH", memberName: "Alice", deviceID: "d1", memberPassphrase: "hunter2", session: protocolSession)
            XCTFail("Expected name conflict")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Name taken")) }
        UsageProtocol.handler = { _ in (200, Data(#"{"token":"aqu_join","identity":{"team_id":"t1","member_id":"m1","member_name":"Alice","device_id":"other"}}"#.utf8)) }
        do {
            _ = try await UsageClient.join(endpoint: "https://test.invalid", inviteCode: "ABCD-2345-EFGH", memberName: "Alice", deviceID: "d1", session: protocolSession)
            XCTFail("Expected device mismatch")
        } catch { XCTAssertTrue(error.localizedDescription.contains("different device")) }
    }
    func testMemberPassphraseIsAuthenticated() async throws {
        UsageProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/usage/member/passphrase")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-device")
            let body = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any]
            XCTAssertEqual(body?["passphrase"] as? String, "correct horse")
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        try await client().setMemberPassphrase("correct horse")
    }
    func testRealLocalWorkerWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["USAGE_TEST_ENDPOINT"], let token = env["USAGE_TEST_TOKEN"] else { throw XCTSkip("Local HTTP integration server not requested") }
        let client = try UsageClient(endpoint: endpoint, token: token)
        let who = try await client.identity(); XCTAssertEqual(who.identity.member_id, "integration-member")
        let first = try await client.send([event]); let second = try await client.send([event])
        XCTAssertEqual(first.accepted, second.accepted)
        let rows = try await client.summary(from: UsageTime.parse("2026-01-01T00:00:00Z")!, to: UsageTime.parse("2026-02-01T00:00:00Z")!, group: "member")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].records, 1); XCTAssertEqual(rows[0].input, 100)
    }
    func testRealLocalTeamJoinWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["USAGE_TEST_ENDPOINT"], let invite = env["USAGE_TEST_INVITE"] else { throw XCTSkip("Local HTTP integration server not requested") }
        let joined = try await UsageClient.join(endpoint: endpoint, inviteCode: invite, memberName: "Join Member", deviceID: "integration-join-device", memberPassphrase: "integration-passphrase")
        XCTAssertEqual(joined.identity.member_name, "Join Member")
        let client = try UsageClient(endpoint: endpoint, token: joined.token)
        let who = try await client.identity()
        XCTAssertEqual(who.identity.device_id, "integration-join-device")
        try await client.setMemberPassphrase("integration-passphrase")
        let second = try await UsageClient.join(endpoint: endpoint, inviteCode: invite, memberName: "Join Member", deviceID: "integration-join-device-2", memberPassphrase: "integration-passphrase")
        XCTAssertEqual(second.identity.member_id, joined.identity.member_id)
        _ = try await client.send([event])
        let rows = try await client.summary(from: UsageTime.parse("2026-01-01T00:00:00Z")!, to: UsageTime.parse("2026-02-01T00:00:00Z")!, group: "member")
        XCTAssertTrue(rows.contains { $0.memberID == joined.identity.member_id && $0.input == 100 })
    }
}
