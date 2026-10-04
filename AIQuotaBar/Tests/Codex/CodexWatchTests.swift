import XCTest
@testable import AIQuotaBar

/// 「关注账号」链路的定向测试。
///
/// 覆盖的是三处最容易出错、又最难靠肉眼发现的地方：
/// 授权判定（谁能被读到）、对外地址白名单（令牌会不会发去不该去的地方）、
/// 以及陈旧数据的表现（明确关注的账号会不会自己消失）。
final class CodexWatchTests: XCTestCase {

    // MARK: - 授权名单

    @MainActor
    private func makeGrantStore() -> (CodexWatchGrantStore, UserDefaults) {
        let suite = "codexWatch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CodexWatchGrantStore(defaults: defaults), defaults)
    }

    @MainActor
    func testGrantStoreDefaultsToDenyEverything() {
        let (store, defaults) = makeGrantStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        XCTAssertFalse(store.isServing, "Sharing must be opt-in, never on by default")
        XCTAssertFalse(store.isAllowed("someone@example.com"))
    }

    @MainActor
    func testGrantStoreAllowThenDenyRoundTrips() {
        let (store, defaults) = makeGrantStore()
        store.setAllowed(true, for: "Someone@Example.com")
        XCTAssertTrue(store.isAllowed("someone@example.com"),
                      "Allow must be case-insensitive: the owner types the email by hand")
        XCTAssertTrue(store.isAllowed("  Someone@Example.com  "),
                      "Surrounding whitespace must not break the lookup")

        store.setAllowed(false, for: "someone@EXAMPLE.com")
        XCTAssertFalse(store.isAllowed("Someone@Example.com"))
    }

    @MainActor
    func testGrantStoreDoesNotAccumulateDuplicateEntries() {
        let (store, defaults) = makeGrantStore()
        for _ in 0..<5 {
            store.setAllowed(true, for: "a@example.com")
            store.setAllowed(false, for: "a@example.com")
            store.setAllowed(true, for: "a@example.com")
        }
        let matching = store.grants.filter {
            $0.normalizedName == "a@example.com"
        }
        XCTAssertEqual(matching.count, 1,
                       "Repeated toggles must collapse to one entry, otherwise 'deny wins' starts masking a later allow")
        XCTAssertTrue(store.isAllowed("a@example.com"))
    }

    @MainActor
    func testGrantStorePersistsAcrossInstances() {
        let suite = "codexWatch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = CodexWatchGrantStore(defaults: defaults)
        first.isServing = true
        first.setAllowed(true, for: "kept@example.com")

        let second = CodexWatchGrantStore(defaults: defaults)
        XCTAssertTrue(second.isServing)
        XCTAssertTrue(second.isAllowed("kept@example.com"))
        defaults.removePersistentDomain(forName: suite)
    }

    @MainActor
    func testGrantStoreIgnoresBlankAccountNames() {
        let (store, defaults) = makeGrantStore()
        store.setAllowed(true, for: "   ")
        XCTAssertTrue(store.grants.isEmpty,
                      "A blank name can never be matched, so allowing it is meaningless state")
    }

    // MARK: - 对外投影

    private func source(
        _ account: String,
        windows: [CodexWatchWindow]
    ) -> CodexWatchProjector.SourceAccount {
        CodexWatchProjector.SourceAccount(
            accountName: account, plan: "Pro", windows: windows)
    }

    private func window(_ name: String, _ percent: Int) -> CodexWatchWindow {
        CodexWatchWindow(
            name: name,
            remainingPercent: percent,
            resetsAt: Date().addingTimeInterval(3600),
            sampledAt: Date())
    }

    func testProjectorOnlyEmitsAllowedAccounts() {
        let response = CodexWatchProjector.response(
            sourceAccounts: [
                source("mine@example.com", windows: [window("5h", 60)]),
                source("notshared@example.com", windows: [window("5h", 10)]),
            ],
            isServing: true,
            isAllowed: { $0.caseInsensitiveCompare("mine@example.com") == .orderedSame },
            allowedAccountNames: ["mine@example.com"],
            hostName: "Studio",
            appVersion: "1.0")

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.accounts.map(\.accountName), ["mine@example.com"],
                       "An unlisted account must never reach the wire, even with real data behind it")
    }

    func testProjectorReportsDisabledWhenNotServing() {
        let response = CodexWatchProjector.response(
            sourceAccounts: [source("mine@example.com", windows: [window("5h", 60)])],
            isServing: false,
            isAllowed: { _ in true },
            allowedAccountNames: ["mine@example.com"],
            hostName: nil,
            appVersion: nil)
        XCTAssertEqual(response.status, .disabled)
        XCTAssertTrue(response.accounts.isEmpty)
    }

    func testProjectorSeparatesPendingFromRevokedGrants() {
        // 授权了、但这台设备现在没跑 Codex → 对端应看到「等待」，
        // 而不是「你没授权」：这两种状态用户的动作完全不同。
        let response = CodexWatchProjector.response(
            sourceAccounts: [],
            isServing: true,
            isAllowed: { _ in true },
            allowedAccountNames: ["idle@example.com"],
            hostName: nil,
            appVersion: nil)
        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(response.accounts.isEmpty)
        XCTAssertEqual(response.pendingAccountNames, ["idle@example.com"])
    }

    func testProjectorDropsAccountsWithoutUsableWindows() {
        let response = CodexWatchProjector.response(
            sourceAccounts: [source("empty@example.com", windows: [])],
            isServing: true,
            isAllowed: { _ in true },
            allowedAccountNames: ["empty@example.com"],
            hostName: nil,
            appVersion: nil)
        XCTAssertTrue(response.accounts.isEmpty)
        // 授权仍在，但没有窗口可给 → 归入 pending，而不是假装没授权。
        XCTAssertEqual(response.pendingAccountNames, ["empty@example.com"])
    }

    func testProjectorClampsOutOfRangePercentages() {
        // 对端会把这个数直接当进度条比例，越界会画出负宽度或溢出。
        XCTAssertEqual(CodexWatchWindow(
            name: "5h", remainingPercent: 180, resetsAt: nil, sampledAt: nil
        ).remainingPercent, 100)
        XCTAssertEqual(CodexWatchWindow(
            name: "5h", remainingPercent: -5, resetsAt: nil, sampledAt: nil
        ).remainingPercent, 0)
    }

    func testProjectorNeverReSharesRelayedAccounts() {
        // B 关注了 C，B 又被 A 关注。若 B 把「从 C 看来的」额度当成自己的
        // 再发出去，C 就被一条它从未授权的路径读取了。分享只能来自本机登录。
        let relayed = ModelUsageData(
            provider: .codex,
            accountName: "c@example.com @ C的Mac",
            modelName: "5h",
            currentIntervalTotal: 100,
            currentIntervalUsed: 40,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(3600),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: "Pro · Peer C的Mac",
            currentIntervalRemainingPercent: 40,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: Date())

        let own = ModelUsageData(
            provider: .codex,
            accountName: "mine@example.com",
            modelName: "5h",
            currentIntervalTotal: 100,
            currentIntervalUsed: 70,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 3_600_000,
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(3600),
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: "Pro · OAuth",
            currentIntervalRemainingPercent: 70,
            weeklyRemainingPercent: nil,
            progressBarPercentOverride: nil,
            progressBarRightText: nil,
            sampledAt: Date())

        let section = UsageData(
            provider: .codex,
            remains: 2,
            total: 2,
            timestamp: Date(),
            models: [relayed, own],
            subscribeTitle: nil,
            subscribeEndTime: nil)

        let accounts = CodexWatchProjector.sourceAccounts(from: [section])
        XCTAssertEqual(accounts.map(\.accountName), ["mine@example.com"],
                       "An account learned from another Mac must never become shareable here")
    }

    // MARK: - 对端地址白名单

    func testAllowedHostsCoverPrivateRangesOnly() {
        for host in ["127.0.0.1", "10.1.2.3", "192.168.1.20", "172.16.0.1",
                     "172.31.255.254", "169.254.10.10", "localhost"] {
            XCTAssertTrue(CodexWatchPeerClient.isAllowedHost(host),
                          "\(host) must be allowed")
        }
        // 公网地址必须被挡住：这个请求会带上 Bearer 令牌。
        for host in ["8.8.8.8", "172.32.0.1", "172.15.0.1", "1.1.1.1",
                     "203.0.113.7"] {
            XCTAssertFalse(CodexWatchPeerClient.isAllowedHost(host),
                           "\(host) must be rejected — the token would leave the LAN")
        }
    }

    func testBareHostnamesRemainUsable() {
        // 局域网里用 .local 名字连机器是常规做法，且解析结果不由本机决定，
        // 因此放行裸主机名。
        XCTAssertTrue(CodexWatchPeerClient.isAllowedHost("studio.local"))
    }

    func testMakeURLAcceptsPastedForms() {
        XCTAssertEqual(
            CodexWatchPeerClient.makeURL(host: "192.168.1.5", port: 18_765)?
                .absoluteString,
            "http://192.168.1.5:18765/api/v1/watch/quota")
        XCTAssertEqual(
            CodexWatchPeerClient.makeURL(
                host: "http://192.168.1.5:18765", port: 18_765)?
                .absoluteString,
            "http://192.168.1.5:18765/api/v1/watch/quota")
        XCTAssertEqual(
            CodexWatchPeerClient.makeURL(host: "192.168.1.5:1234", port: 18_765)?
                .absoluteString,
            "http://192.168.1.5:1234/api/v1/watch/quota")
    }

    func testMakeURLRejectsHostileInput() {
        for host in ["https://evil.example.com", "8.8.8.8",
                     "user@192.168.1.5", "192.168.1.5?x=1", ""] {
            XCTAssertNil(CodexWatchPeerClient.makeURL(host: host, port: 18_765),
                         "\(host) must not produce a request")
        }
    }

    func testMakeURLDropsAnyPastedPath() {
        // 用户粘一整条 URL 进来是常态。路径与查询必须被丢掉而不是拼进去：
        // 我们自己决定打哪个端点，绝不能让粘贴内容改写请求目标。
        XCTAssertEqual(
            CodexWatchPeerClient.makeURL(
                host: "http://192.168.1.5:18765/api/v1/watch/quota",
                port: 18_765)?.absoluteString,
            "http://192.168.1.5:18765/api/v1/watch/quota")
        XCTAssertEqual(
            CodexWatchPeerClient.makeURL(
                host: "192.168.1.5/evil/path", port: 18_765)?.absoluteString,
            "http://192.168.1.5:18765/api/v1/watch/quota")
    }

    // MARK: - 陈旧数据

    /// 建一个只含一台对端的 store，不触碰钥匙串。
    @MainActor
    private func makePeerStore() -> (CodexWatchPeerStore, CodexWatchPeer, UserDefaults) {
        let suite = "codexWatch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = CodexWatchPeerStore(
            defaults: defaults,
            client: CodexWatchPeerClient(),
            credentialStore: KeychainService.shared)
        let peer = CodexWatchPeer(name: "Studio", host: "192.168.1.5", port: 18_765)
        store.seedForTesting(peer)
        return (store, peer, defaults)
    }

    private func response(
        accounts: [CodexWatchAccount],
        generatedAt: Date = Date()
    ) -> CodexWatchResponse {
        CodexWatchResponse(
            status: .ok,
            hostName: "Studio",
            appVersion: "1.32.0",
            generatedAt: generatedAt,
            accounts: accounts,
            pendingAccountNames: [])
    }

    @MainActor
    func testWatchedAccountSurvivesAnExpiredWindow() {
        // 这是「关注」最核心的承诺：明确要看一个账号，它不能因为
        // 对端安静下来、额度窗口走完，就自己从菜单里消失。
        let (store, peer, defaults) = makePeerStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        store.apply(.ok(response(accounts: [
            CodexWatchAccount(
                accountName: "watched@example.com",
                plan: "Pro",
                windows: [CodexWatchWindow(
                    name: "5h",
                    remainingPercent: 42,
                    resetsAt: Date().addingTimeInterval(-600),
                    sampledAt: Date().addingTimeInterval(-900))])
        ])), for: peer.id)

        let now = Date()
        let models = store.displayModels(now: now)
        XCTAssertEqual(models.count, 1,
                       "An expired window must not silently drop the account the user asked to watch")
        let model = try? XCTUnwrap(models.first)
        XCTAssertNotNil(model)
        XCTAssertTrue(
            model?.containsCurrentInterval(at: now) ?? false,
            "The synthetic window must still cover 'now' so the menu renders it")
        XCTAssertEqual(model?.currentIntervalRemainingPercent, 42)
        XCTAssertTrue(
            (model?.detailText ?? "").contains("stale"),
            "Stale data has to say so; an unmarked old number reads as current")
    }

    @MainActor
    func testWatchedAccountSurvivesPeerGoingOffline() {
        let (store, peer, defaults) = makePeerStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let lastGood = Date().addingTimeInterval(-120)
        store.apply(.ok(response(
            accounts: [CodexWatchAccount(
                accountName: "watched@example.com",
                plan: "Pro",
                windows: [CodexWatchWindow(
                    name: "5h",
                    remainingPercent: 30,
                    resetsAt: lastGood.addingTimeInterval(3600),
                    sampledAt: lastGood)])],
            generatedAt: lastGood)), for: peer.id)
        // 现在对端联系不上了。
        store.apply(.unreachable("network"), for: peer.id)

        let models = store.displayModels(now: Date())
        XCTAssertEqual(models.count, 1,
                       "A brief network blip must read as 'offline', not as 'quota went to zero'")
        XCTAssertEqual(models.first?.currentIntervalRemainingPercent, 30)
        XCTAssertTrue((models.first?.detailText ?? "").contains("stale"))
    }

    @MainActor
    func testRevokedAuthorizationEmptiesTheLocalCache() {
        // owner 侧撤销授权后，对端不能继续显示上一份缓存。
        let (store, peer, defaults) = makePeerStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        store.apply(.ok(response(accounts: [CodexWatchAccount(
            accountName: "watched@example.com",
            plan: "Pro",
            windows: [CodexWatchWindow(
                name: "5h", remainingPercent: 30,
                resetsAt: Date().addingTimeInterval(3600), sampledAt: Date())]
        )])), for: peer.id)
        XCTAssertEqual(store.displayModels().count, 1)

        store.apply(.notAuthorized(CodexWatchResponse(
            status: .notAuthorized,
            hostName: "Studio",
            appVersion: nil,
            generatedAt: Date(),
            accounts: [],
            pendingAccountNames: [])), for: peer.id)

        XCTAssertTrue(store.displayModels().isEmpty,
                      "Once the owner revokes access the last cached quota must go too")
    }

    @MainActor
    func testFailedPeerProducesNoModels() {
        let (store, peer, defaults) = makePeerStore()
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        store.apply(.invalidToken, for: peer.id)
        XCTAssertTrue(store.displayModels().isEmpty)
        store.apply(.disabled(CodexWatchResponse.failure(.disabled)), for: peer.id)
        XCTAssertTrue(store.displayModels().isEmpty)
    }

    // MARK: - 线格式

    func testPayloadRoundTripsThroughISO8601() {
        let original = CodexWatchResponse(
            status: .ok,
            hostName: "Studio",
            appVersion: "1.32.0",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            accounts: [
                CodexWatchAccount(
                    accountName: "a@example.com",
                    plan: "Pro",
                    windows: [CodexWatchWindow(
                        name: "5h",
                        remainingPercent: 61,
                        resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                        sampledAt: Date(timeIntervalSince1970: 1_700_000_000))])
            ],
            pendingAccountNames: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try? encoder.encode(original)
        XCTAssertNotNil(data)
        XCTAssertEqual(try? decoder.decode(CodexWatchResponse.self, from: data ?? Data()),
                       original)
    }

    func testPeerCredentialBindingsAreIsolatedFromDeviceCredentials() {
        let peer = CodexWatchPeer(id: UUID(), name: "a", host: "b", port: 1)
        XCTAssertTrue(peer.credentialBinding.hasPrefix("codexWatch.peer."),
                      "Watch tokens need their own keyspace so a peer record is never mistaken for this Mac's own device credential")
        XCTAssertNotEqual(peer.credentialBinding, UUID().uuidString)
    }
}
