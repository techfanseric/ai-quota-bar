import XCTest
import CodexLocalUsageCore
@testable import AIQuotaBar

/// 守护镜像的行为约定：
///
/// 1. 镜像目录在真正写入前不存在（不预建目录）；
/// 2. 镜像内容与源凭据逐字节一致，目录 0700、文件 0600；
/// 3. 账号池里的备份同样进镜像；
/// 4. 同一账号换了 token → 副本跟着更新；
/// 5. 换了账号 → 报 accountChanged，且**被换走的账号副本仍在镜像里**；
/// 6. store 能把「外部工具切了账号」和「本应用自己切的」分开。
@MainActor
final class CodexAuthMirrorTests: XCTestCase {
    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let authURL: URL
        let accountsDirectory: URL
        let mirror: CodexAuthMirror
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-mirror-\(UUID().uuidString)")
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accounts, withIntermediateDirectories: true)
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root,
            authURL: root.appendingPathComponent("auth.json"),
            accountsDirectory: accounts,
            mirror: CodexAuthMirror(
                directory: root.appendingPathComponent("auth-mirror", isDirectory: true)))
    }

    private static func loginFixturePayload(
        accountEmail: String, accountID: String, refreshToken: String
    ) -> [String: Any] {
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims = ["email": accountEmail, "sub": "auth|\(accountID)"]
        func encode(_ dictionary: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: dictionary)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return [
            "auth_mode": "chatgpt",
            "tokens": [
                "account_id": accountID,
                "refresh_token": refreshToken,
                "id_token": [
                    encode(header), encode(claims), "fixture-signature",
                ].joined(separator: "."),
            ],
        ]
    }

    @discardableResult
    private static func writeLoginFixture(
        accountEmail: String, accountID: String,
        refreshToken: String = "refresh-1", to url: URL
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: loginFixturePayload(
                accountEmail: accountEmail, accountID: accountID,
                refreshToken: refreshToken))
        try data.write(to: url, options: .atomic)
        guard case let .chatgptLogin(login) = CodexAuthFileReader.read(at: url) else {
            throw XCTSkip("fixture 不是登录态")
        }
        return login.accountDigest
    }

    private func permissions(atPath path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: - 目录

    func testMirrorDirectoryIsNotCreatedBeforeFirstWrite() throws {
        let fixture = try makeFixture()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.mirror.directoryURL.path),
            "镜像目录不该在写入之前就存在")

        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mirror.directoryURL.path))
    }

    // MARK: - 写盘

    func testMirroredCredentialMatchesSourceByteForByte() throws {
        let fixture = try makeFixture()
        let digest = try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)

        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        let source = try Data(contentsOf: fixture.authURL)
        let mirrored = try Data(contentsOf: fixture.mirror.mirrorURL(for: digest))
        XCTAssertEqual(mirrored, source)
    }

    func testMirroredCredentialIsOwnerOnly() throws {
        let fixture = try makeFixture()
        let digest = try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)

        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        XCTAssertEqual(
            try permissions(atPath: fixture.mirror.directoryURL.path), 0o700,
            "镜像目录必须只有本人可读写")
        XCTAssertEqual(
            try permissions(atPath: fixture.mirror.mirrorURL(for: digest).path), 0o600,
            "镜像里的凭据文件必须只有本人可读写")
    }

    func testPoolBackupsAreMirroredToo() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        let poolDigest = try Self.writeLoginFixture(
            accountEmail: "bob@example.com", accountID: "account-b",
            to: fixture.accountsDirectory.appendingPathComponent("bob.json"))

        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.mirror.mirrorURL(for: poolDigest).path),
            "账号池里的备份也要进镜像，否则池文件被误删就找不回来了")
    }

    // MARK: - 变化判定

    func testFirstSyncIsUnchanged() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)

        let result = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        XCTAssertEqual(result, .unchanged)
    }

    func testTokenRefreshUpdatesMirroredCredential() throws {
        let fixture = try makeFixture()
        let digest = try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a",
            refreshToken: "refresh-1", to: fixture.authURL)
        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        // 同一个账号，token 被轮换：内容变了，账号没变。
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a",
            refreshToken: "refresh-2", to: fixture.authURL)
        let result = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        XCTAssertEqual(result, .tokenRefreshed(digest))
        let mirrored = try Data(contentsOf: fixture.mirror.mirrorURL(for: digest))
        let source = try Data(contentsOf: fixture.authURL)
        XCTAssertEqual(mirrored, source, "刷新后的凭据要写回镜像，否则副本会变成死凭据")
    }

    func testAccountSwapIsReportedAsAccountChanged() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        let nextDigest = try Self.writeLoginFixture(
            accountEmail: "bob@example.com", accountID: "account-b", to: fixture.authURL)
        let result = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        XCTAssertEqual(
            result, .accountChanged(digest: nextDigest, previousEmail: "alice@example.com"))
    }

    // MARK: - 防丢

    func testReplacedAccountKeepsItsCredentialInMirror() throws {
        let fixture = try makeFixture()
        let originalDigest = try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a",
            refreshToken: "refresh-1", to: fixture.authURL)
        let originalBytes = try Data(contentsOf: fixture.authURL)
        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        // 外部工具（magpie 这类网关）把登录换成了别人。
        try Self.writeLoginFixture(
            accountEmail: "bob@example.com", accountID: "account-b",
            refreshToken: "refresh-2", to: fixture.authURL)
        _ = fixture.mirror.sync(
            authURL: fixture.authURL, accountsDirectory: fixture.accountsDirectory)

        let kept = try Data(contentsOf: fixture.mirror.mirrorURL(for: originalDigest))
        XCTAssertEqual(
            kept, originalBytes,
            "被换走的账号必须还留有一份副本，否则它在文件层面就丢了")
    }

    // MARK: - store 归因

    private func makeStore(
        codexHome: URL, mirror: CodexAuthMirror
    ) throws -> CodexAuthAccountStore {
        let suiteName = "CodexAuthMirrorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return CodexAuthAccountStore(
            codexHome: codexHome,
            defaults: defaults,
            authMirror: mirror,
            companionAppsProvider: { [] },
            cliProcessChecker: { false },
            notify: { _, _ in },
            openCompanionApp: {},
            quotaSnapshotProvider: { _ in nil },
            usageAccountRefresher: {},
            autoQuitPerformer: { false },
            relaunchDelayProvider: { nil })
    }

    func testStoreRecordsExternalAccountChange() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        let store = try makeStore(codexHome: fixture.root, mirror: fixture.mirror)
        store.refresh()
        XCTAssertNil(store.lastExternalAccountChange)

        // 外部工具换走了登录。
        try Self.writeLoginFixture(
            accountEmail: "bob@example.com", accountID: "account-b", to: fixture.authURL)
        store.refresh()

        let change = try XCTUnwrap(store.lastExternalAccountChange)
        XCTAssertEqual(change.email, "bob@example.com")
        XCTAssertEqual(change.previousEmail, "alice@example.com")
    }

    func testStoreDoesNotReportItsOwnSwitchAsExternal() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        try Self.writeLoginFixture(
            accountEmail: "bob@example.com", accountID: "account-b",
            to: fixture.accountsDirectory.appendingPathComponent("bob.json"))
        let store = try makeStore(codexHome: fixture.root, mirror: fixture.mirror)
        store.refresh()

        store.requestSwitch(to: "bob")
        store.refresh()

        XCTAssertNil(
            store.lastExternalAccountChange,
            "本应用自己切的账号不能被算成外部工具切号")
        XCTAssertEqual(store.stashedAccounts.map(\.label), ["alice"])
    }

    /// 装上监听就要立刻建立基线。
    ///
    /// 目录事件只在有变化时才来；不先同步一次的话，app 启动后遇到第一次
    /// 外部改写时，那个账号同样来不及进镜像——护栏等于没上线。
    func testWatchingEstablishesBaselineWithoutWaitingForAnyEvent() throws {
        let fixture = try makeFixture()
        let digest = try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        let store = try makeStore(codexHome: fixture.root, mirror: fixture.mirror)
        store.startAuthWatching()
        defer { store.stopAuthWatching() }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.mirror.mirrorURL(for: digest).path),
            "装上监听就该立刻把当前账号留一份在 ~/.codex 之外")
    }

    /// 原地写入不会产生任何目录事件，只有文件自身的事件。
    /// 只盯目录的话，这种改写完全看不见——magpie 两种写法都可能用。
    func testWatcherDetectsInPlaceRewrite() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        let store = try makeStore(codexHome: fixture.root, mirror: fixture.mirror)
        store.refresh()
        store.startAuthWatching()
        defer { store.stopAuthWatching() }

        // 原地覆盖成另一个账号的凭据：不产生 rename，目录事件为 0。
        let payload = try JSONSerialization.data(
            withJSONObject: Self.loginFixturePayload(
                accountEmail: "bob@example.com", accountID: "account-b",
                refreshToken: "refresh-2"))
        let handle = try FileHandle(forWritingTo: fixture.authURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: payload)
        try handle.close()

        let deadline = Date().addingTimeInterval(10)
        while store.lastExternalAccountChange == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let change = try XCTUnwrap(
            store.lastExternalAccountChange,
            "原地改写没被抓到——文件级监听没生效")
        XCTAssertEqual(change.email, "bob@example.com")
        XCTAssertEqual(change.previousEmail, "alice@example.com")
    }

    /// 面板没打开时也要能发现外部改写——这正是目录监听存在的理由。
    /// 轮询（展示期 5 秒 / 后台 60 秒）会留下窗口，外部工具在这个窗口里
    /// 换走账号，那个账号就来不及进镜像。
    func testWatcherDetectsExternalRewriteWithoutPanelOpen() throws {

        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com", accountID: "account-a", to: fixture.authURL)
        let store = try makeStore(codexHome: fixture.root, mirror: fixture.mirror)
        store.refresh()
        store.startAuthWatching()
        defer { store.stopAuthWatching() }

        try Self.writeLoginFixture(
            accountEmail: "bob@example.com", accountID: "account-b", to: fixture.authURL)

        // 目录事件是异步的，等它被合并成一次同步。
        let deadline = Date().addingTimeInterval(10)
        while store.lastExternalAccountChange == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let change = try XCTUnwrap(
            store.lastExternalAccountChange,
            "目录监听没抓到 auth.json 被改写")
        XCTAssertEqual(change.email, "bob@example.com")
        XCTAssertEqual(change.previousEmail, "alice@example.com")
    }
}
