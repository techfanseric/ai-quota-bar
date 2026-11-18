import XCTest
@testable import AIQuotaBar

final class ModelActivityAttributionTests: XCTestCase {
    func testCodexClientModelsBelongToTheirOwnProviderRings() {
        let turns: [CodexActivityTracker.TurnKey: CodexLocalActivitySnapshot.ActiveTurn] = [
            .init(sessionID: "a", turnID: "1"): .init(rootSessionID: "a", startedAt: nil, model: "MiniMax-M3.1"),
            .init(sessionID: "b", turnID: "2"): .init(rootSessionID: "b", startedAt: nil, model: "glm-5.3"),
            .init(sessionID: "c", turnID: "3"): .init(rootSessionID: "c", startedAt: nil, model: "kimi-k3"),
            .init(sessionID: "d", turnID: "4"): .init(rootSessionID: "d", startedAt: nil, model: "gpt-6.1-sol"),
        ]
        let activity = ProviderModelActivity.codex(turns: turns, gateway: .disabled)
        XCTAssertEqual(activity.counts, [.miniMax: 1, .glm: 1, .kimi: 1, .codex: 1])
        XCTAssertEqual(activity.localTasks[.glm], ["glm-5.3": 1])
        XCTAssertEqual(ModelActivityAttribution.provider(model: "GLM-5.3", provider: "openai"), .glm)
    }

    func testChildModelsRemainIndependentWhileSameModelRootIsDeduplicated() {
        let turns: [CodexActivityTracker.TurnKey: CodexLocalActivitySnapshot.ActiveTurn] = [
            .init(sessionID: "a", turnID: "1"): .init(rootSessionID: "root", startedAt: nil, model: "glm-5.3"),
            .init(sessionID: "b", turnID: "2"): .init(rootSessionID: "root", startedAt: nil, model: "glm-5.3"),
            .init(sessionID: "c", turnID: "3"): .init(rootSessionID: "root", startedAt: nil, model: "MiniMax-M3"),
        ]
        let activity = ProviderModelActivity.codex(turns: turns, gateway: .disabled)
        XCTAssertEqual(activity.counts, [.glm: 1, .miniMax: 1])
    }

    func testGatewayActualRequestReplacesConfiguredModelRatherThanAddingToIt() {
        let turns: [CodexActivityTracker.TurnKey: CodexLocalActivitySnapshot.ActiveTurn] = [
            .init(sessionID: "a", turnID: "1"): .init(
                rootSessionID: "root", startedAt: nil, model: "codex/gpt-6.1-sol", modelProvider: "magpie"),
            .init(sessionID: "b", turnID: "2"): .init(
                rootSessionID: "other", startedAt: nil, model: "gpt-6.1-sol", modelProvider: "custom"),
        ]
        let gateway = MagpieModelActivitySnapshot(isConfigured: true, isAvailable: true,
            providerIDs: ["magpie", "custom"], requests: [
                .init(id: 1, provider: .kimi, model: "kimi-k3"),
                .init(id: 2, provider: .miniMax, model: "MiniMax-M3.1"),
                .init(id: 3, provider: .miniMax, model: "MiniMax-M3.1"),
            ])
        let activity = ProviderModelActivity.codex(turns: turns, gateway: gateway)
        XCTAssertEqual(activity.counts, [.kimi: 1, .miniMax: 2])
        XCTAssertNil(activity.counts[.codex])
        XCTAssertTrue(activity.localTasks.isEmpty)
        let hover = activity.tooltip(language: .english, providers: Set(UsageProvider.allCases))
        XCTAssertTrue(hover.contains("MiniMax-M3.1 × 2"))
        XCTAssertTrue(hover.contains("kimi-k3 × 1"))
    }

    func testUnknownAliasesAndGatewayFailureDoNotGuessCodex() {
        XCTAssertNil(ModelActivityAttribution.provider(model: "auto/k3"))
        XCTAssertNil(ModelActivityAttribution.provider(model: "custom-model"))
        let turns: [CodexActivityTracker.TurnKey: CodexLocalActivitySnapshot.ActiveTurn] = [
            .init(sessionID: "a", turnID: "1"): .init(
                rootSessionID: "a", startedAt: nil, model: "auto/minimax-m3.1-flash", modelProvider: "magpie"),
        ]
        let failed = MagpieModelActivitySnapshot(
            isConfigured: true, isAvailable: false, providerIDs: ["magpie"], requests: [])
        let activity = ProviderModelActivity.codex(turns: turns, gateway: failed)
        XCTAssertTrue(activity.counts.isEmpty)
        XCTAssertTrue(activity.gatewayUnavailable)
        XCTAssertTrue(activity.tooltip(language: .simplifiedChinese, providers: [.codex]).contains("暂不可用"))
    }

    func testMatchingGatewaySessionPreventsDoubleCountingStaleLocalProvider() {
        let turn: [CodexActivityTracker.TurnKey: CodexLocalActivitySnapshot.ActiveTurn] = [
            .init(sessionID: "child", turnID: "1"): .init(
                rootSessionID: "root", startedAt: nil, model: "gpt-6", modelProvider: "openai"),
        ]
        let gateway = MagpieModelActivitySnapshot(isConfigured: true, isAvailable: true,
            providerIDs: ["magpie"], requests: [
                .init(id: 1, provider: .miniMax, model: "MiniMax-M3", sessionID: "root"),
            ])
        XCTAssertEqual(ProviderModelActivity.codex(turns: turn, gateway: gateway).counts, [.miniMax: 1])
    }
}
