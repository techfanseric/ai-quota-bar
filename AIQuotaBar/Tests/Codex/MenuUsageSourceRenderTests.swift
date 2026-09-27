import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar
@testable import CodexLocalUsageCore

/// 离屏渲染菜单用量卡片的「本机/团队」切换，供视觉验收：
/// A 无团队连接（仅静态 Local 标签）→ B 有团队连接的本机视图（切换出现）
/// → C/D 团队视图（成员选择 + 空态，中英文）。
/// 运行：swift test --filter MenuUsageSourceRenderTests
@MainActor
final class MenuUsageSourceRenderTests: XCTestCase {
    func testRenderMenuUsageSourceSwitchToPNG() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-quota-bar-menu-usage-render")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 与本机 auth.json 对齐当前账号；onAppear 的 refreshCurrentAccount
        // 会覆盖 currentAccountID，样例数据必须落在真实账号上才可见。
        let localOnly = makeModel()
        localOnly.refreshCurrentAccount()
        localOnly.events = sampleEvents(account: localOnly.currentAccountID ?? "local")
        try render(CodexLocalUsageMenuCard(model: localOnly, language: .simplifiedChinese),
                   width: 420, height: 230,
                   name: "menu-usage-local-no-team", to: outputDirectory)

        let localWithTeam = makeModel()
        localWithTeam.refreshCurrentAccount()
        localWithTeam.events = sampleEvents(account: localWithTeam.currentAccountID ?? "local")
        localWithTeam.connection = makeConnection()
        try render(CodexLocalUsageMenuCard(model: localWithTeam, language: .simplifiedChinese),
                   width: 420, height: 230,
                   name: "menu-usage-local-with-team", to: outputDirectory)

        for language in [AppLanguage.simplifiedChinese, .english] {
            let team = makeModel()
            team.connection = makeConnection()
            team.menuUsageSource = .team
            team.teamRows = [row(id: "member-1", name: "Eric"), row(id: "member-2", name: "Wang Yang")]
            // 用样例事件模拟服务端已返回的团队聚合数据（UTC 日历，同 teamActivity）。
            let utc = Calendar(identifier: .gregorian)
            let events = sampleEvents(account: "member-1")
            team.teamMenuDaily = UsageHistory.buckets(events: events, prices: [], days: 30, calendar: utc)
            team.teamMenuHourly = UsageHistory.last24Hours(events: events, prices: [])
            try render(CodexLocalUsageMenuCard(model: team, language: language),
                       width: 420, height: 230,
                       name: "menu-usage-team-\(language == .simplifiedChinese ? "zh" : "en")",
                       to: outputDirectory)
        }
    }

    private func makeModel() -> CodexLocalUsageModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return CodexLocalUsageModel(databaseURL: directory.appendingPathComponent("test.sqlite"))
    }

    private func makeConnection() -> LocalUsageConnection {
        LocalUsageConnection(
            endpoint: "https://example.com",
            identity: UsageIdentity(
                team_name: "Design Team", team_id: "team-1", member_id: "member-1",
                member_name: "Eric", device_id: "device-1"),
            since: Date())
    }

    private func sampleEvents(account: String) -> [LocalUsageEvent] {
        let now = Date()
        var events: [LocalUsageEvent] = []
        for i in 0..<40 {
            let offset: TimeInterval = Double(-i) * 3600 * 3
            let tokens = UsageTokens(
                input: Int64(1200 + i * 37),
                cached: Int64(i * 11),
                output: Int64(400 + i * 5))
            events.append(LocalUsageEvent(
                id: "e\(i)",
                occurredAt: UsageTime.string(now.addingTimeInterval(offset)),
                model: "gpt-5.3",
                tokens: tokens,
                accountID: account))
        }
        return events
    }

    private func row(id: String, name: String) -> TeamUsageRow {
        TeamUsageRow(
            id: id, name: name, memberID: id, records: 12, input: 480_000, output: 96_000,
            cached: 30_000, cacheWrite: 0, reasoning: 8_000, estimatedRecords: 0, pricedRecords: 12,
            costUSD: 1.25, cacheHitRate: 0.38)
    }

    private func render(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        name: String,
        to directory: URL
    ) throws {
        let hostingView = NSHostingView(
            rootView: view
                .background(Color(nsColor: .controlBackgroundColor))
                .environment(\.colorScheme, .light)
                .frame(width: width, height: height))
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        hostingView.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)),
            styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = hostingView
        window.layoutIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("Could not create a view bitmap for \(name).")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name) to PNG.")
            return
        }
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
