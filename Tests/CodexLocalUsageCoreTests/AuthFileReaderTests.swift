import XCTest
@testable import CodexLocalUsageCore

final class AuthFileReaderTests: XCTestCase {
    // MARK: - Fixtures

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    /// 只需要三段式与 base64url 的 payload，签名段不参与解析。
    private func makeJWT(email: String?) -> String {
        func encode(_ dictionary: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: dictionary)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        var claims: [String: Any] = ["sub": "auth|fixture"]
        if let email { claims["email"] = email }
        return [
            encode(["alg": "RS256", "typ": "JWT"]),
            encode(claims),
            "fixture-signature",
        ].joined(separator: ".")
    }

    private func writeAuth(
        _ dictionary: [String: Any], to url: URL
    ) throws {
        try JSONSerialization.data(withJSONObject: dictionary)
            .write(to: url)
    }

    private func loginPayload(
        accountID: String, email: String?, mode: String? = "chatgpt"
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "tokens": [
                "account_id": accountID,
                "id_token": makeJWT(email: email),
                "access_token": "fixture-access",
                "refresh_token": "fixture-refresh",
            ]
        ]
        if let mode { payload["auth_mode"] = mode }
        return payload
    }

    // MARK: - 登录识别

    func testChatGPTLoginIsRecognizedWithEmail() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("auth.json")
        try writeAuth(
            loginPayload(accountID: "fixture-a", email: "alice@example.com"),
            to: url)

        guard case let .chatgptLogin(login) = CodexAuthFileReader.read(at: url)
        else {
            XCTFail("Expected chatgptLogin status.")
            return
        }
        XCTAssertEqual(login.email, "alice@example.com")
        XCTAssertEqual(login.accountDigest.count, 64)
        XCTAssertTrue(CodexAuthFileReader.read(at: url).isLoggedIn)
    }

    func testLegacyShapeWithoutAuthModeStillRecognized() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("auth.json")
        try writeAuth(
            loginPayload(accountID: "fixture-a", email: nil, mode: nil), to: url)

        guard case let .chatgptLogin(login) = CodexAuthFileReader.read(at: url)
        else {
            XCTFail("Expected chatgptLogin status for legacy auth without mode.")
            return
        }
        XCTAssertNil(login.email)
    }

    // MARK: - 非登录形态

    func testAPIKeyModeWinsOverStaleTokens() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("auth.json")
        var payload = loginPayload(accountID: "fixture-a", email: nil)
        payload["OPENAI_API_KEY"] = "sk-fixture"
        try writeAuth(payload, to: url)

        XCTAssertEqual(CodexAuthFileReader.read(at: url), .apiKeyMode)
    }

    func testMissingTokensIsUnauthenticated() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("auth.json")
        try writeAuth(["auth_mode": "chatgpt"], to: url)

        XCTAssertEqual(CodexAuthFileReader.read(at: url), .unauthenticated)
    }

    func testUnreadableForGarbageAndMissingFiles() throws {
        let root = try makeTemporaryDirectory()
        let garbage = root.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        let missing = root.appendingPathComponent("missing.json")

        XCTAssertEqual(CodexAuthFileReader.read(at: garbage), .unreadable)
        XCTAssertEqual(CodexAuthFileReader.read(at: missing), .unreadable)
    }

    // MARK: - 指纹稳定性与隐私

    func testDigestIsStableForSameAccountAndDiffersAcrossAccounts() throws {
        let root = try makeTemporaryDirectory()
        let first = root.appendingPathComponent("first.json")
        let second = root.appendingPathComponent("second.json")
        try writeAuth(
            loginPayload(accountID: "fixture-a", email: "alice@example.com"),
            to: first)
        try writeAuth(
            loginPayload(accountID: "fixture-a", email: nil), to: second)
        // token 内容不同（有无 id_token）但账号相同 → 指纹一致。
        guard case let .chatgptLogin(firstLogin) = CodexAuthFileReader.read(at: first),
              case let .chatgptLogin(secondLogin) = CodexAuthFileReader.read(at: second)
        else {
            XCTFail("Expected chatgptLogin statuses.")
            return
        }
        XCTAssertEqual(firstLogin.accountDigest, secondLogin.accountDigest)

        let third = root.appendingPathComponent("third.json")
        try writeAuth(
            loginPayload(accountID: "fixture-b", email: nil), to: third)
        guard case let .chatgptLogin(thirdLogin) = CodexAuthFileReader.read(at: third)
        else {
            XCTFail("Expected chatgptLogin status.")
            return
        }
        XCTAssertNotEqual(firstLogin.accountDigest, thirdLogin.accountDigest)
        // 指纹不能泄漏原始账号 ID。
        XCTAssertFalse(firstLogin.accountDigest.contains("fixture-a"))
    }

    func testUsageAccountObservationStillRecognizesLoginAfterRefactor() throws {
        let root = try makeTemporaryDirectory()
        try writeAuth(
            loginPayload(accountID: "fixture-a", email: "alice@example.com"),
            to: root.appendingPathComponent("auth.json"))

        let observation = UsageAccountObservation.read(root: root)
        XCTAssertEqual(observation.accountID?.count, 64)
        XCTAssertEqual(observation.label, "alice@example.com")
        XCTAssertNotNil(observation.generation)
    }

    // MARK: - 版本号必须跟得上文件改动

    /// 同一个 URL 实例上 URL.resourceValues 会缓存资源值：连续两次读到的
    /// modificationDate 完全一样，而文件其实已经被改写。撕裂防护要是建在
    /// 这上面，前后比的就是同一个缓存值，防护形同虚设。
    ///
    /// 这条测试守着 generation 走新鲜 stat——「内容变过」必须看得出来。
    func testGenerationChangesWhenFileIsRewritten() throws {
        let root = try makeTemporaryDirectory()
        let url = root.appendingPathComponent("auth.json")
        try writeAuth(
            loginPayload(accountID: "fixture-a", email: "alice@example.com"), to: url)

        let first = try XCTUnwrap(CodexAuthFileReader.readCredential(at: url))
        // 同一个 URL 实例——正是会触发资源值缓存的那个用法。
        var second = first
        for _ in 0..<5 {
            second = try XCTUnwrap(CodexAuthFileReader.readCredential(at: url))
        }
        XCTAssertEqual(first.generation, second.generation, "内容没变时版本号必须稳定")

        // 改写内容：大小变了（access_token 变长），mtime 也变了。
        var payload = loginPayload(accountID: "fixture-a", email: "alice@example.com")
        payload["tokens"] = [
            "account_id": "fixture-a",
            "id_token": makeJWT(email: "alice@example.com"),
            "access_token": "fixture-access-token-that-is-longer",
            "refresh_token": "fixture-refresh",
        ]
        try writeAuth(payload, to: url)

        let third = try XCTUnwrap(CodexAuthFileReader.readCredential(at: url))
        XCTAssertNotEqual(
            first.generation, third.generation,
            "文件被改写后版本号必须变化，否则 token 刷新这类改动看不出来")
    }
}
