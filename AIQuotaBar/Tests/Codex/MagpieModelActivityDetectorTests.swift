import XCTest
@testable import AIQuotaBar

final class MagpieModelActivityDetectorTests: XCTestCase {
    func testOnlyConfiguredLoopbackGatewaysAreRead() throws {
        let endpoint = try XCTUnwrap(MagpieModelActivityDetector.endpoint(in: """
        [model_providers.magpie]
        base_url = "http://localhost:3425/v1"
        [model_providers.custom]
        base_url = 'http://127.0.0.1:3425/v1'
        [model_providers.remote]
        base_url = "https://example.com/v1"
        """))
        XCTAssertEqual(endpoint.url.absoluteString, "http://127.0.0.1:3425")
        XCTAssertEqual(endpoint.providerIDs, ["magpie", "custom"])
        for raw in ["http://example.com", "http://127.0.0.1.example.com", "http://127.1",
            "http://user:secret@127.0.0.1:3425", "http://127.0.0.1:3425/v1?key=x",
            "http://127.0.0.1:3425/other", "file:///tmp/gateway"] {
            XCTAssertNil(MagpieModelActivityDetector.loopbackRoot(raw), raw)
        }
        XCTAssertNil(MagpieModelActivityDetector.endpoint(in: """
        [model_providers.a]
        base_url = "http://127.0.0.1:1111/v1"
        [model_providers.b]
        base_url = "http://127.0.0.1:2222/v1"
        """))
    }

    func testSingleUnrelatedProxyIsNotAMagpieGateway() {
        let config = """
        [model_providers.custom]
        base_url = "http://127.0.0.1:3425/v1"
        """
        XCTAssertNil(MagpieModelActivityDetector.endpoint(in: config))
        XCTAssertNotNil(MagpieModelActivityDetector.endpoint(in: config + "\nname = 'Magpie'"))
    }

    func testActualFallbackModelsDriveCountsNotClientOrRequestedGroup() throws {
        let concurrency = Data(#"{"object":"concurrency","active":[{"id":1,"agent":"codex","phase":"upstream","route":9},{"id":2,"agent":"codex","phase":"upstream","route":10},{"id":3,"agent":"codex","phase":"rpm","route":9},{"id":1,"agent":"codex","phase":"upstream","route":9},{"id":4,"agent":"other","phase":"upstream","route":9}]}"#.utf8)
        let trace = Data(#"{"object":"trace","routes":[{"id":9,"done":false,"provider":"group","model":"auto/k3","order":[{"id":"c","provider":"codex","model":"gpt-6"},{"id":"m","provider":"minimax-cn","model":"MiniMax-M3.1"}],"tries":[{"id":"c","model":"gpt-6","done":true},{"id":"m","model":"MiniMax-M3.1","done":false}]},{"id":10,"done":false,"order":[{"id":"g","provider":"zcode-plugin","model":"GLM-5.3"}],"tries":[{"id":"g","model":"GLM-5.3","done":false}]}]}"#.utf8)
        let requests = try MagpieModelActivityDetector.requests(concurrency: concurrency, trace: trace)
        XCTAssertEqual(requests, [
            .init(id: 1, provider: .miniMax, model: "MiniMax-M3.1"),
            .init(id: 2, provider: .glm, model: "GLM-5.3"),
        ])
        let finished = Data(#"{"object":"trace","routes":[{"id":9,"done":true,"order":[],"tries":[]}]}"#.utf8)
        XCTAssertEqual(try MagpieModelActivityDetector.requests(concurrency: concurrency, trace: finished), [])
        let canceled = Data(#"{"object":"concurrency","active":[]}"#.utf8)
        XCTAssertEqual(try MagpieModelActivityDetector.requests(concurrency: canceled, trace: trace), [])
        XCTAssertThrowsError(try MagpieModelActivityDetector.requests(concurrency: Data("{}".utf8), trace: trace))
    }

    func testMissingConfigurationDoesNotProbeDefaultPort() async {
        let detector = MagpieModelActivityDetector(configURL: URL(fileURLWithPath: "/nonexistent/aqb-test/config.toml"))
        let snapshot = await detector.snapshot()
        XCTAssertEqual(snapshot, .disabled)
    }

    func testTraceSeatAccountIdentityIsRetained() {
        // seat 的 `who` 是账号身份 —— 没有它就无法把在途请求归属到账号。
        let concurrency = Data(#"{"object":"concurrency","active":[{"id":1,"agent":"codex","phase":"upstream","route":9}]}"#.utf8)
        let trace = Data(#"{"object":"trace","routes":[{"id":9,"done":false,"order":[{"id":"codex","provider":"codex","model":"gpt-6.1-terra","who":"node.cyberic@gmail.com","kind":"account"}],"tries":[{"id":"codex","model":"gpt-6.1-terra","done":false}]}]}"#.utf8)
        let requests = try? MagpieModelActivityDetector.requests(concurrency: concurrency, trace: trace)
        XCTAssertEqual(requests?.first?.accountKey, "node.cyberic@gmail.com")
    }

    func testKeySeatIsNotAnAccount() {
        // Key 的 `who` 是 Key 名，不是邮箱 —— 不能当成账号。
        let concurrency = Data(#"{"object":"concurrency","active":[{"id":1,"agent":"codex","phase":"upstream","route":9}]}"#.utf8)
        let trace = Data(#"{"object":"trace","routes":[{"id":9,"done":false,"order":[{"id":"kimi-code#abc","provider":"kimi-code","model":"k3.1-pro","who":"my-key","kind":"key"}],"tries":[{"id":"kimi-code#abc","model":"k3.1-pro","done":false}]}]}"#.utf8)
        let requests = try? MagpieModelActivityDetector.requests(concurrency: concurrency, trace: trace)
        XCTAssertNil(requests?.first?.accountKey)
    }

    func testLanesAreDecodedFromConcurrencyData() {
        // 车道是网关自己的按账号计数，是账号级实时归属的第二个证据源。
        let concurrency = Data(#"{"object":"concurrency","active":[],"data":{"codex@a@example.com":{"busy":2,"waiting":0,"limit":0},"codex@b@example.com":{"busy":1,"waiting":3,"limit":0}}}"#.utf8)
        let trace = Data(#"{"object":"trace","routes":[]}"#.utf8)
        let snapshot = try? MagpieModelActivityDetector.snapshot(
            concurrency: concurrency, trace: trace)
        XCTAssertEqual(snapshot?.lanes, ["codex@a@example.com": 2, "codex@b@example.com": 1])
    }

    func testZeroBusyLanesAreNotReported() {
        // busy 为 0 的车道不是"在用"，不报。
        let concurrency = Data(#"{"object":"concurrency","active":[],"data":{"codex@a@example.com":{"busy":0,"waiting":0,"limit":0}}}"#.utf8)
        let trace = Data(#"{"object":"trace","routes":[]}"#.utf8)
        let snapshot = try? MagpieModelActivityDetector.snapshot(
            concurrency: concurrency, trace: trace)
        XCTAssertTrue(snapshot?.lanes.isEmpty == true)
    }

    func testRuntimeReadsIncrementalRoutesAndClearsFailedOrCanceledRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.toml")
        try "[model_providers.magpie]\nbase_url = \"http://127.0.0.1:3425/v1\""
            .write(to: file, atomically: true, encoding: .utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MagpieActivityFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let detector = MagpieModelActivityDetector(configURL: file, session: session)
        let active = #"{"object":"concurrency","active":[{"id":1,"agent":"codex","phase":"upstream","route":9}]}"#
        let full = #"{"object":"trace","seq":12,"pid":123,"routes":[{"id":9,"done":false,"order":[{"id":"m","provider":"minimax-cn","model":"MiniMax-M3"}],"tries":[{"id":"m","model":"MiniMax-M3","done":false}],"prompt":{"ignored":"never retained"}}]}"#
        MagpieActivityFixtureProtocol.prepare(active: active, trace: full)
        let first = await detector.snapshot()
        XCTAssertEqual(first.requests, [.init(id: 1, provider: .miniMax, model: "MiniMax-M3")])
        MagpieActivityFixtureProtocol.prepare(active: active,
            trace: #"{"object":"trace","seq":12,"pid":123,"routes":[]}"#)
        let unchanged = await detector.snapshot()
        XCTAssertEqual(unchanged.requests, first.requests)
        XCTAssertEqual(MagpieActivityFixtureProtocol.lastAfter, "12")
        let restarted = full.replacingOccurrences(of: "\"pid\":123", with: "\"pid\":124")
        MagpieActivityFixtureProtocol.prepare(active: active, trace: restarted)
        let changedOwner = await detector.snapshot()
        XCTAssertFalse(changedOwner.isAvailable)
        XCTAssertTrue(changedOwner.requests.isEmpty)
        MagpieActivityFixtureProtocol.prepare(active: active, trace: restarted)
        let freshOwner = await detector.snapshot()
        XCTAssertEqual(freshOwner.requests, first.requests)
        XCTAssertNil(MagpieActivityFixtureProtocol.lastAfter, "new owner needs a full route snapshot")
        MagpieActivityFixtureProtocol.prepare(active: active, trace: "unreadable")
        let failed = await detector.snapshot()
        XCTAssertFalse(failed.isAvailable)
        XCTAssertTrue(failed.requests.isEmpty)
        MagpieActivityFixtureProtocol.prepare(active: #"{"object":"concurrency","active":[]}"#, trace: full)
        let idle = await detector.snapshot()
        XCTAssertTrue(idle.isAvailable)
        XCTAssertTrue(idle.requests.isEmpty)
    }

    func testRuntimeKeepsAccountLanesWithoutCodexUpstreamRequests() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.toml")
        try "[model_providers.magpie]\nbase_url = \"http://127.0.0.1:3425/v1\""
            .write(to: file, atomically: true, encoding: .utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MagpieActivityFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let detector = MagpieModelActivityDetector(configURL: file, session: session)

        MagpieActivityFixtureProtocol.prepare(
            active: #"{"object":"concurrency","active":[{"id":1,"agent":"other","phase":"upstream","route":9}],"data":{"codex@a@example.com":{"busy":1,"waiting":0}}}"#,
            trace: #"{"object":"trace","routes":[]}"#)

        let snapshot = await detector.snapshot()
        XCTAssertTrue(snapshot.isAvailable)
        XCTAssertEqual(snapshot.lanes, ["codex@a@example.com": 1])
        XCTAssertEqual(
            MagpieAccountUsageResolver.resolve(snapshot).activeAccounts,
            ["a@example.com"])
    }
}

private final class MagpieActivityFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var active = ""
    private static var trace = ""
    private static var after: String?
    static var lastAfter: String? { lock.lock(); defer { lock.unlock() }; return after }
    static func prepare(active: String, trace: String) {
        lock.lock(); defer { lock.unlock() }
        self.active = active; self.trace = trace; after = nil
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "127.0.0.1", request.value(forHTTPHeaderField: "Authorization") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        Self.lock.lock()
        let isTrace = url.path.hasSuffix("/trace")
        let body = isTrace ? Self.trace : Self.active
        if isTrace { Self.after = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "after" })?.value }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
