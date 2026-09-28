import SwiftUI
import XCTest
@testable import AIQuotaBar

/// 把右键面板整版离屏渲染成 PNG，供高度自适应布局的视觉验收。
/// 覆盖三种屏幕预算：无约束（大屏）、中等屏（1000）、紧凑屏（787），
/// 以及账号分区收起的常态。运行：
/// swift test --filter ClashPopoverAdaptiveLayoutRenderTests
@MainActor
final class ClashPopoverAdaptiveLayoutRenderTests: XCTestCase {
    func testRenderPanelAtDifferentScreenBudgets() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-panel-render")
        try FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        let store = try makeStore(stashCount: 8)
        try render(
            store: store,
            name: "panel-unconstrained",
            maximumHeight: nil,
            collapsedSections: [],
            to: outputDirectory)
        try render(
            store: store,
            name: "panel-screen-1000",
            maximumHeight: 1000,
            collapsedSections: [],
            to: outputDirectory)
        try render(
            store: store,
            name: "panel-screen-787",
            maximumHeight: 787,
            collapsedSections: [],
            to: outputDirectory)
        try render(
            store: store,
            name: "panel-accounts-collapsed",
            maximumHeight: nil,
            collapsedSections: [.accounts],
            to: outputDirectory)
    }

    // MARK: - Fixtures

    private func makeDefaults(_ prefix: String) throws -> UserDefaults {
        let suiteName = "\(prefix).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { [suiteName] in
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeStore(stashCount: Int) throws -> CodexAuthAccountStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-home-\(UUID().uuidString)")
        let accounts = root.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: accounts, withIntermediateDirectories: true)
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root)
        }
        try Self.writeLoginFixture(
            email: "current@example.com", accountID: "account-current",
            to: root.appendingPathComponent("auth.json"))
        for index in 0..<stashCount {
            try Self.writeLoginFixture(
                email: "user\(index)@example.com",
                accountID: "account-stash-\(index)",
                to: accounts.appendingPathComponent("user\(index).json"))
        }
        let store = CodexAuthAccountStore(
            codexHome: root,
            defaults: try makeDefaults("PanelRender.Accounts"),
            companionAppsProvider: { [] },
            cliProcessChecker: { false },
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
        store: CodexAuthAccountStore,
        name: String,
        maximumHeight: CGFloat?,
        collapsedSections: Set<ClashPanelSection>,
        to directory: URL
    ) throws {
        let displayStore = ClashPanelDisplayStore(
            defaults: try makeDefaults("PanelRender.Display"))
        for section in collapsedSections {
            displayStore.setCollapsed(true, section: section)
        }
        displayStore.panelMaximumHeight = maximumHeight

        let height = ClashPopoverLayout.panelHeight(
            routesCollapsed: displayStore.isRoutesCollapsed,
            connectionsCollapsed: displayStore.isConnectionsCollapsed,
            accountsCollapsed: displayStore.isAccountsCollapsed,
            accountsContentHeight: ClashPopoverLayout.accountsContentHeight(
                stashCount: store.stashedAccounts.count,
                legacyCount: store.legacyBackupFileNames.count,
                hasPending: store.pendingRequest != nil,
                hasStatus: store.statusMessage != nil),
            maximumHeight: maximumHeight)

        let hostingView = NSHostingView(
            rootView: ClashPopoverView(
                routeViewModel: ClashRouteViewModel(
                    defaults: try makeDefaults("PanelRender.Route")),
                connectionViewModel: ClashConnectionViewModel(),
                sleepProtectionCoordinator: CodexSleepProtectionCoordinator(
                    localActivityProvider: nil),
                displayStore: displayStore,
                accountStore: store))
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: ClashPopoverLayout.width, height: height))
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
        let fileURL = directory.appendingPathComponent("\(name)-\(Int(height)).png")
        try png.write(to: fileURL)
        print("[render] \(fileURL.path)")
    }
}
