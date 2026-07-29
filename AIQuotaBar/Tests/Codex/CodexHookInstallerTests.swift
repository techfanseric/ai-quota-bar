import Darwin
import XCTest
@testable import AIQuotaBar

final class CodexHookInstallerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testInstallPreservesExistingConfigurationAndHooks() throws {
        let hooksURL = temporaryDirectory.appendingPathComponent("hooks.json")
        let helperURL = try makeExecutableHelper()
        let existing: [String: Any] = [
            "customSetting": "keep-me",
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "'/usr/bin/existing-hook'",
                        "timeout": 3
                    ]]
                ]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: hooksURL)

        let status = CodexHookInstaller(
            hooksURL: hooksURL,
            helperURL: helperURL
        ).install()

        XCTAssertEqual(status, .installed)
        let root = try loadRoot(hooksURL)
        XCTAssertEqual(root["customSetting"] as? String, "keep-me")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertEqual(hooks.count, CodexHookEventName.allCases.count)
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopGroups.count, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: hooksURL
                    .appendingPathExtension("ai-quota-bar.backup")
                    .path
            )
        )
    }

    func testRepeatedInstallIsIdempotent() throws {
        let hooksURL = temporaryDirectory.appendingPathComponent("hooks.json")
        let helperURL = try makeExecutableHelper()
        let installer = CodexHookInstaller(
            hooksURL: hooksURL,
            helperURL: helperURL
        )

        XCTAssertEqual(installer.install(), .installed)
        let firstData = try Data(contentsOf: hooksURL)
        XCTAssertEqual(installer.install(), .installed)
        let secondData = try Data(contentsOf: hooksURL)

        XCTAssertEqual(firstData, secondData)
        let hooks = try XCTUnwrap(
            try loadRoot(hooksURL)["hooks"] as? [String: Any]
        )
        for event in CodexHookEventName.allCases {
            XCTAssertEqual(
                (hooks[event.rawValue] as? [[String: Any]])?.count,
                1
            )
        }
    }

    func testMissingHelperDoesNotModifyConfiguration() throws {
        let hooksURL = temporaryDirectory.appendingPathComponent("hooks.json")
        let original = Data(#"{"customSetting":"unchanged"}"#.utf8)
        try original.write(to: hooksURL)

        let status = CodexHookInstaller(
            hooksURL: hooksURL,
            helperURL: temporaryDirectory.appendingPathComponent("missing")
        ).install()

        XCTAssertEqual(status, .helperMissing)
        XCTAssertEqual(try Data(contentsOf: hooksURL), original)
    }

    func testDefaultHooksURLHonorsCodexHome() {
        let url = CodexHookInstaller.defaultHooksURL(
            environment: ["CODEX_HOME": "/tmp/custom-codex-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/ignored")
        )

        XCTAssertEqual(url.path, "/tmp/custom-codex-home/hooks.json")
    }

    private func makeExecutableHelper() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("AIQuotaBarHook")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, S_IRUSR | S_IWUSR | S_IXUSR), 0)
        return url
    }

    private func loadRoot(_ url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        )
        return try XCTUnwrap(object as? [String: Any])
    }
}
