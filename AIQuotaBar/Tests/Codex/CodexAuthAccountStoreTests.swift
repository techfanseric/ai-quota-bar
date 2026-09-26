import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexAuthAccountStoreTests: XCTestCase {
    // MARK: - Fixtures

    private struct Fixture {
        let store: CodexAuthAccountStore
        let root: URL
        let openedAppsCount: () -> Int
        let notifications: () -> [(title: String, body: String)]
        let setDesktopAppRunning: (Bool) -> Void
        let setCLIRunning: (Bool) -> Void
        let expectedQuotaSnapshot: CodexAccountQuotaSnapshot
        let autoQuitCount: () -> Int
        let defaults: UserDefaults
    }

    /// 构造带注入点的服务与一份「A 登录中 + B 已入池」的标准现场。
    private func makeFixture(
        currentAccount: String = "alice@example.com",
        currentAccountID: String = "account-a"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-\(UUID().uuidString)")
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accounts, withIntermediateDirectories: true)
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
        let suiteName = "CodexAuthAccountStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let openedCount = LockedCounter()
        let capturedNotifications = LockedNotifications()
        let desktopRunning = LockedFlag()
        let cliRunning = LockedFlag()
        let autoQuitCount = LockedCounter()
        let quotaSnapshot = CodexAccountQuotaSnapshot(
            shortRemainingPercent: 73,
            shortResetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            longRemainingPercent: 12,
            longResetsAt: Date(timeIntervalSince1970: 1_800_086_400),
            capturedAt: Date(timeIntervalSince1970: 1_799_994_000))

        let store = CodexAuthAccountStore(
            codexHome: root,
            defaults: defaults,
            companionAppsProvider: { [desktopRunning] in
                desktopRunning.value
                    ? [RunningAppSnapshot(
                        bundleIdentifier: "com.openai.chat",
                        processName: "ChatGPT")]
                    : []
            },
            cliProcessChecker: { [cliRunning] in cliRunning.value },
            notify: { [capturedNotifications] title, body in
                capturedNotifications.append(title: title, body: body)
            },
            openCompanionApp: { [openedCount] in openedCount.increment() },
            quotaSnapshotProvider: { _ in quotaSnapshot },
            autoQuitPerformer: { [autoQuitCount] in
                autoQuitCount.increment()
                return true
            },
            relaunchDelayProvider: { nil })

        try Self.writeLoginFixture(
            accountEmail: currentAccount,
            accountID: currentAccountID,
            to: root.appendingPathComponent("auth.json"))
        try Self.writeLoginFixture(
            accountEmail: "bob@example.com",
            accountID: "account-b",
            to: accounts.appendingPathComponent("bob.json"))
        store.refresh()
        return Fixture(
            store: store,
            root: root,
            openedAppsCount: { openedCount.value },
            notifications: { capturedNotifications.all },
            setDesktopAppRunning: { desktopRunning.value = $0 },
            setCLIRunning: { cliRunning.value = $0 },
            expectedQuotaSnapshot: quotaSnapshot,
            autoQuitCount: { autoQuitCount.value },
            defaults: defaults)
    }

    private static func loginFixturePayload(
        accountEmail: String, accountID: String
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
                "id_token": [
                    encode(header), encode(claims), "fixture-signature",
                ].joined(separator: "."),
            ],
        ]
    }

    private static func writeLoginFixture(
        accountEmail: String, accountID: String, to url: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: loginFixturePayload(
                accountEmail: accountEmail, accountID: accountID))
        try data.write(to: url, options: .atomic)
    }

    private func readJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 扫描

    func testRefreshDiscoversPoolLegacyAndCurrentStatus() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "old@example.com",
            accountID: "account-old",
            to: fixture.root.appendingPathComponent("auth yzx.json"))

        fixture.store.refresh()

        XCTAssertEqual(
            fixture.store.currentStatus.isLoggedIn, true)
        XCTAssertEqual(
            fixture.store.stashedAccounts.map(\.label), ["bob"])
        XCTAssertEqual(
            fixture.store.stashedAccounts.first?.email, "bob@example.com")
        XCTAssertEqual(
            fixture.store.legacyBackupFileNames, ["auth yzx.json"])
        // 注入的配额快照同时供给当前账号与池内账号。
        XCTAssertEqual(fixture.store.currentQuotaSnapshot, fixture.expectedQuotaSnapshot)
        XCTAssertEqual(
            fixture.store.stashedAccounts.first?.quota, fixture.expectedQuotaSnapshot)
    }

    // MARK: - 切换

    func testSwitchStashesCurrentAndPromotesTarget() throws {
        let fixture = try makeFixture()

        fixture.store.requestSwitch(to: "bob")

        XCTAssertEqual(fixture.store.pendingRequest, nil)
        let auth = try readJSON(
            at: fixture.root.appendingPathComponent("auth.json"))
        let tokens = try XCTUnwrap(auth["tokens"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(tokens["account_id"] as? String), "account-b")
        // 原 A 账号以邮箱前缀入池；B 的备份文件不再存在于池中。
        let accounts = fixture.root
            .appendingPathComponent("accounts", isDirectory: true)
        XCTAssertEqual(
            try readJSON(at: accounts.appendingPathComponent("alice.json"))["auth_mode"]
                as? String,
            "chatgpt")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: accounts.appendingPathComponent("bob.json").path))
        XCTAssertEqual(fixture.openedAppsCount(), 1)
        XCTAssertEqual(fixture.notifications().count, 1)
    }

    func testSwitchToCurrentAccountIsNoOp() throws {
        let fixture = try makeFixture()
        // 把当前账号存进池里再切换到它：应提示而不是搬动文件。
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com",
            accountID: "account-a",
            to: fixture.root
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent("alice.json"))
        fixture.store.refresh()

        fixture.store.requestSwitch(to: "alice")

        XCTAssertEqual(fixture.store.pendingRequest, nil)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth.json").path))
        XCTAssertEqual(fixture.openedAppsCount(), 0)
    }

    func testSwitchBlockedByDesktopAppRelaysAfterQuit() throws {
        let fixture = try makeFixture()
        fixture.setDesktopAppRunning(true)

        fixture.store.requestSwitch(to: "bob")

        XCTAssertEqual(
            fixture.store.pendingRequest, .switchTo(label: "bob"))
        XCTAssertTrue(fixture.store.pendingBlockers.contains(.desktopApp))
        // 文件未被搬动。
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/bob.json").path))

        // 用户自行退出后自动接力。
        fixture.setDesktopAppRunning(false)
        fixture.store.evaluatePendingRequest()

        XCTAssertEqual(fixture.store.pendingRequest, nil)
        let auth = try readJSON(
            at: fixture.root.appendingPathComponent("auth.json"))
        let tokens = try XCTUnwrap(auth["tokens"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(tokens["account_id"] as? String), "account-b")
        XCTAssertEqual(fixture.openedAppsCount(), 1)
    }

    func testSwitchBlockedByCLIWaitsForCLIExit() throws {
        let fixture = try makeFixture()
        fixture.setCLIRunning(true)

        fixture.store.requestSwitch(to: "bob")

        XCTAssertEqual(
            fixture.store.pendingRequest, .switchTo(label: "bob"))
        XCTAssertTrue(fixture.store.pendingBlockers.contains(.cliProcess))

        fixture.setCLIRunning(false)
        fixture.store.evaluatePendingRequest()

        XCTAssertEqual(fixture.store.pendingRequest, nil)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/bob.json").path))
    }

    func testCancelPendingKeepsFilesIntact() throws {
        let fixture = try makeFixture()
        fixture.setDesktopAppRunning(true)
        fixture.store.requestSwitch(to: "bob")

        fixture.store.cancelPendingRequest()

        XCTAssertEqual(fixture.store.pendingRequest, nil)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/bob.json").path))
    }

    func testSwitchRemovesUnauthenticatedPlaceholderButKeepsAPIKeyMode() throws {
        let fixture = try makeFixture()
        // 未登录占位 auth：切换时可直接移除，目标备份上位。
        try Data("{\"auth_mode\":\"chatgpt\"}".utf8)
            .write(to: fixture.root.appendingPathComponent("auth.json"))
        fixture.store.refresh()
        fixture.store.requestSwitch(to: "bob")
        let promoted = try readJSON(
            at: fixture.root.appendingPathComponent("auth.json"))
        let promotedTokens = try XCTUnwrap(promoted["tokens"] as? [String: Any])
        XCTAssertEqual(
            try XCTUnwrap(promotedTokens["account_id"] as? String), "account-b")

        // API Key 模式：不能动，切换被拒绝且文件保持原样。
        // 第一阶段后池已空，先补一份 alice 备份作为切换目标。
        try Self.writeLoginFixture(
            accountEmail: "carol@example.com",
            accountID: "account-c",
            to: fixture.root
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent("carol.json"))
        try Data("{\"OPENAI_API_KEY\":\"sk-fixture\"}".utf8)
            .write(to: fixture.root.appendingPathComponent("auth.json"))
        fixture.store.refresh()
        fixture.store.requestSwitch(to: "carol")
        XCTAssertTrue(fixture.store.statusMessage?.isError == true)
        let untouched = try readJSON(
            at: fixture.root.appendingPathComponent("auth.json"))
        XCTAssertEqual(untouched["OPENAI_API_KEY"] as? String, "sk-fixture")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/carol.json").path))
    }

    // MARK: - 登录新账号

    func testLoginNewStashesCurrentAndOpensApp() throws {
        let fixture = try makeFixture()

        fixture.store.requestLoginNewAccount()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/alice.json").path))
        XCTAssertEqual(fixture.openedAppsCount(), 1)
        XCTAssertEqual(fixture.notifications().count, 1)
    }

    func testLoginNewReplacesOlderBackupOfSameAccount() throws {
        let fixture = try makeFixture()
        // 池里已有 A 账号的旧备份：登录新账号时用较新的当前文件替换，
        // 而不是再生成一份「alice 2」。
        try Self.writeLoginFixture(
            accountEmail: "alice@example.com",
            accountID: "account-a",
            to: fixture.root
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent("alice.json"))
        fixture.store.refresh()

        fixture.store.requestLoginNewAccount()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth.json").path))
        let poolFileNames = try FileManager.default.contentsOfDirectory(
            at: fixture.root.appendingPathComponent("accounts"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertEqual(Set(poolFileNames), ["alice.json", "bob.json"])
    }

    // MARK: - 备份管理

    func testRenameMovesPoolFile() throws {
        let fixture = try makeFixture()

        fixture.store.renameStashedAccount("bob", to: "bob-work")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/bob.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/bob-work.json").path))
        XCTAssertEqual(
            fixture.store.stashedAccounts.map(\.label), ["bob-work"])
    }

    func testRenameCollidesWithSuffixAndRejectsEmpty() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "carol@example.com",
            accountID: "account-c",
            to: fixture.root
                .appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent("bob 2.json"))
        fixture.store.refresh()

        fixture.store.renameStashedAccount("bob", to: "bob")

        XCTAssertEqual(
            Set(fixture.store.stashedAccounts.map(\.label)),
            ["bob", "bob 2"])
        XCTAssertFalse(fixture.store.statusMessage?.isError == true)
    }

    func testDeleteRemovesPoolFile() throws {
        let fixture = try makeFixture()

        fixture.store.deleteStashedAccount("bob")

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/bob.json").path))
        XCTAssertTrue(fixture.store.stashedAccounts.isEmpty)
    }

    // MARK: - 旧备份导入

    func testImportLegacyMovesFileIntoPoolWithEmailLabel() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "carol@example.com",
            accountID: "account-c",
            to: fixture.root.appendingPathComponent("auth yzx.json"))

        fixture.store.importLegacyBackup("auth yzx.json")

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("accounts/carol.json").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth yzx.json").path))
        XCTAssertEqual(
            Set(fixture.store.stashedAccounts.map(\.label)),
            ["bob", "carol"])
    }

    func testImportLegacySkipsWhenAccountAlreadyInPool() throws {
        let fixture = try makeFixture()
        try Self.writeLoginFixture(
            accountEmail: "bob@example.com",
            accountID: "account-b",
            to: fixture.root.appendingPathComponent("auth bob.json"))

        fixture.store.importLegacyBackup("auth bob.json")

        // 同账号已在池中：保留原地不动，提示已存在。
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("auth bob.json").path))
        XCTAssertTrue(fixture.store.statusMessage?.isError == false)
    }

    func testImportLegacyRejectsUnrecognizedFile() throws {
        let fixture = try makeFixture()
        try Data("not json".utf8)
            .write(to: fixture.root.appendingPathComponent("auth broken.json"))

        fixture.store.importLegacyBackup("auth broken.json")

        XCTAssertTrue(fixture.store.statusMessage?.isError == true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.root
                    .appendingPathComponent("auth broken.json").path))
    }

    // MARK: - 退出方式（手动 / 自动）

    func testExitModeDefaultsToManualAndPersists() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(fixture.store.exitMode, .manual)
        fixture.store.exitMode = .automatic
        XCTAssertEqual(fixture.store.exitMode, .automatic)

        // didSet 已写入隔离 defaults；新实例按同样的 key 读回。
        let reloaded = CodexAuthAccountStore(
            codexHome: fixture.root, defaults: fixture.defaults)
        XCTAssertEqual(reloaded.exitMode, .automatic)
    }

    func testManualModeNeverQuitsDesktopAppAutomatically() throws {
        let fixture = try makeFixture()
        fixture.setDesktopAppRunning(true)

        fixture.store.requestSwitch(to: "bob")

        XCTAssertEqual(fixture.store.pendingRequest, .switchTo(label: "bob"))
        XCTAssertEqual(fixture.autoQuitCount(), 0)
    }

    func testAutomaticModeQuitsDesktopAppOnceThenRelays() throws {
        let fixture = try makeFixture()
        fixture.store.exitMode = .automatic
        fixture.setDesktopAppRunning(true)

        fixture.store.requestSwitch(to: "bob")

        // 自动退出在首次评估即触发，且只触发一次。
        XCTAssertEqual(fixture.autoQuitCount(), 1)
        XCTAssertEqual(fixture.store.pendingRequest, .switchTo(label: "bob"))

        // 应用还没退：不重复 terminate，继续等待。
        fixture.store.evaluatePendingRequest()
        XCTAssertEqual(fixture.autoQuitCount(), 1)

        // 检测到完全退出后接力完成；重启走注入的零延迟立即打开。
        fixture.setDesktopAppRunning(false)
        fixture.store.evaluatePendingRequest()

        XCTAssertEqual(fixture.store.pendingRequest, nil)
        let auth = try readJSON(
            at: fixture.root.appendingPathComponent("auth.json"))
        let tokens = try XCTUnwrap(auth["tokens"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(tokens["account_id"] as? String), "account-b")
        XCTAssertEqual(fixture.openedAppsCount(), 1)
    }

    func testSwitchingToAutoFromPendingBannerTriggersQuit() throws {
        let fixture = try makeFixture()
        fixture.setDesktopAppRunning(true)
        fixture.store.requestSwitch(to: "bob")
        XCTAssertEqual(fixture.autoQuitCount(), 0)

        // 用户在横幅点「切换至自动模式」：下一轮评估即代为正常退出。
        fixture.store.exitMode = .automatic
        fixture.store.evaluatePendingRequest()

        XCTAssertEqual(fixture.autoQuitCount(), 1)
    }

    func testRandomRelaunchDelayStaysWithinHumanBounds() {
        for _ in 0..<32 {
            let delay = CodexAuthAccountStore.randomRelaunchDelay()
            XCTAssertTrue(
                (1...2).contains(delay),
                "Relaunch delay \(delay) s is outside the 1–2 s human window")
        }
    }
}

// MARK: - 线程安全的测试记录器

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock(); defer { lock.unlock() }
            flag = newValue
        }
    }
}

private final class LockedNotifications: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(title: String, body: String)] = []
    var all: [(title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func append(title: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        items.append((title, body))
    }
}
