import SwiftUI
import XCTest
@testable import AIQuotaBar

/// 把「Codex 账号」分区离屏渲染成 PNG，供视觉验收。
/// 运行：swift test --filter CodexAccountSwitchPopoverRenderTests
@MainActor
final class CodexAccountSwitchPopoverRenderTests: XCTestCase {
    func testRenderAccountsSectionStatesToPNG() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-accounts-render")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        // 状态一：当前登录 + 三个备份 + 一条旧备份待导入。
        let normalStore = try makeStore(
            stashEmails: [
                "bob@example.com", "carol@example.com", "dave@example.com",
            ],
            legacy: true)
        try render(
            CodexAccountSwitchPopoverView(
                store: normalStore,
                isCollapsed: false,
                onToggleCollapse: {}),
            name: "accounts-normal",
            to: outputDirectory)

        // 状态二：切换被守卫挂起（桌面版 + CLI 都在运行）。
        let pendingStore = try makeStore(
            stashEmails: ["bob@example.com"],
            legacy: false,
            desktopRunning: true,
            cliRunning: true)
        pendingStore.requestSwitch(to: "bob")
        try render(
            CodexAccountSwitchPopoverView(
                store: pendingStore,
                isCollapsed: false,
                onToggleCollapse: {}),
            name: "accounts-pending",
            to: outputDirectory)
    }

    // MARK: - Fixtures

    private func makeStore(
        stashEmails: [String],
        legacy: Bool,
        desktopRunning: Bool = false,
        cliRunning: Bool = false
    ) throws -> CodexAuthAccountStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-\(UUID().uuidString)")
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accounts, withIntermediateDirectories: true)
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
        try Self.writeLoginFixture(
            email: "wangyang815@gmail.com", accountID: "account-current",
            to: root.appendingPathComponent("auth.json"))
        for (index, email) in stashEmails.enumerated() {
            try Self.writeLoginFixture(
                email: email, accountID: "account-\(index)",
                to: accounts.appendingPathComponent(
                    String(email.split(separator: "@").first ?? "user") + ".json"))
        }
        if legacy {
            try Self.writeLoginFixture(
                email: "marvaggarrett@gmail.com", accountID: "account-legacy",
                to: root.appendingPathComponent("auth yzx.json"))
        }
        let desktopFlag = desktopRunning
        let cliFlag = cliRunning
        let store = CodexAuthAccountStore(
            codexHome: root,
            companionAppsProvider: { [desktopFlag, cliFlag] in
                (desktopFlag || cliFlag)
                    ? [RunningAppSnapshot(
                        bundleIdentifier: "com.openai.chat",
                        processName: "ChatGPT")]
                    : []
            },
            cliProcessChecker: { cliFlag },
            notify: { _, _ in },
            openCompanionApp: {},
            quotaSnapshotProvider: { _ in
                CodexAccountQuotaSnapshot(
                    shortRemainingPercent: 68,
                    shortResetsAt: Date().addingTimeInterval(3_600),
                    longRemainingPercent: 41,
                    longResetsAt: Date().addingTimeInterval(3 * 86_400),
                    capturedAt: Date().addingTimeInterval(-600))
            })
        store.refresh()
        return store
    }

    private static func writeLoginFixture(
        email: String, accountID: String, to url: URL
    ) throws {
        func encode(_ dictionary: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: dictionary)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let payload: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "account_id": accountID,
                "id_token": [
                    encode(["alg": "RS256", "typ": "JWT"]),
                    encode(["email": email, "sub": "auth|\(accountID)"]),
                    "fixture-signature",
                ].joined(separator: "."),
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: url, options: .atomic)
    }

    // MARK: - 渲染

    private func render(
        _ view: CodexAccountSwitchPopoverView,
        name: String,
        to directory: URL
    ) throws {
        let width = ClashPopoverLayout.width
        let height = max(
            ClashPopoverLayout.accountsSectionMinimumHeight,
            ClashPopoverLayout.accountsContentHeight(
                stashCount: view.store.stashedAccounts.count,
                legacyCount: view.store.legacyBackupFileNames.count,
                hasPending: view.store.pendingRequest != nil,
                hasStatus: view.store.statusMessage != nil))
        let hostingView = NSHostingView(
            rootView: view.frame(width: width, height: height))
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds) else {
            XCTFail("Could not create a view bitmap for \(name).")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode the view bitmap for \(name).")
            return
        }
        try png.write(
            to: directory.appendingPathComponent("\(name).png"))
        print("[render] \(directory.appendingPathComponent("\(name).png")).path")
    }
}
