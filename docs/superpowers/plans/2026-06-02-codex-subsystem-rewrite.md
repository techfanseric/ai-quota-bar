# Codex 子系统重写实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 全面替换 ai-quota-bar 中 ChatGPT/Codex GPT 的数据读取与展示逻辑，引入 codexbar 的 `CodexBarCore` 作为本地 SwiftPM 依赖，写适配层把 `UsageSnapshot` 映射到现有 `UsageData`/`ModelUsageData`，UI 沿用现有规范。

**Architecture:** 依赖 `codexbar`（`../codexbar`）的 `CodexBarCore` 库；新增 `AIQuotaBar/Services/Codex/` 适配层（`CodexService` / `CodexDataSourceMode` / `CodexAccountCoordinator` / `CodexUsageDataMapper`），`UsageProvider.chatGPT` 重命名为 `.codex`，老 keychain 一次性丢弃，Settings 暴露 source mode + 多账号，MenuView 渲染 5h/Weekly/additional/credits。

**Tech Stack:** Swift 6.2+ / SwiftPM / SwiftUI / codexbar `CodexBarCore` 1.x（本地依赖）。

**Worktree:** 按 `CLAUDE.md` 的 Worktree 流程，在执行阶段用 `git worktree add -b feat/codex-subsystem-rewrite .worktrees/codex-rewrite` 创建。

**命名冲突：** codexbar 暴露 `public enum UsageProvider`，与本项目同名。适配层所有引用必须以 `CodexBarCore.UsageProvider` 完全限定。本地 `UsageProvider` 继续作为本项目的内部模型。

**Provider 映射：**
- 本地 `.codex` ↔ `CodexBarCore.UsageProvider.codex`
- 本地 `.miniMax` ↔ `CodexBarCore.UsageProvider.minimax`
- 本地 `.glm` ↔ `CodexBarCore.UsageProvider.zai`

---

## 任务 1：创建 worktree

**Files:** 无（Git 操作）

- [ ] **Step 1: 创建独立 worktree**

```bash
cd /Users/ericyim/ai-quota-bar
git worktree add -b feat/codex-subsystem-rewrite .worktrees/codex-rewrite main
```

- [ ] **Step 2: 进入 worktree**

```bash
cd .worktrees/codex-rewrite
git status
```

期望输出：On branch `feat/codex-subsystem-rewrite`，clean。

- [ ] **Step 3: 验证构建基线**

```bash
swift build -c release 2>&1 | tail -20
```

期望：build 成功（可能耗时较久）。失败则先修基线，不要继续。

- [ ] **Step 4: 提交工作区就绪标记**

```bash
git commit --allow-empty -m "chore: 启动 Codex 子系统重写 worktree

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 2：升级 Package.swift 引入 CodexBarCore

**Files:**
- Modify: `Package.swift:1-21`

- [ ] **Step 1: 修改 Package.swift**

完整替换 `Package.swift` 内容：

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "AIQuotaBar",
            targets: ["AIQuotaBar"]
        )
    ],
    dependencies: [
        .package(path: "../codexbar")
    ],
    targets: [
        .executableTarget(
            name: "AIQuotaBar",
            dependencies: [
                .product(name: "CodexBarCore", package: "codexbar")
            ],
            path: "AIQuotaBar",
            exclude: ["Resources/Assets.xcassets"]
        ),
        .testTarget(
            name: "AIQuotaBarTests",
            dependencies: ["AIQuotaBar", .product(name: "CodexBarCore", package: "codexbar")],
            path: "AIQuotaBar/Tests"
        )
    ]
)
```

- [ ] **Step 2: 验证依赖解析**

```bash
swift package resolve 2>&1 | tail -20
```

期望：能解析到 `codexbar / CodexBarCore` 产品。失败检查 `../codexbar` 路径是否正确。

- [ ] **Step 3: 验证编译**

```bash
swift build -c release 2>&1 | tail -30
```

期望：build 成功。本步不引用 `CodexBarCore` 类型，但拉取了依赖。

- [ ] **Step 4: 提交**

```bash
git add Package.swift
git commit -m "chore(deps): 引入 codexbar 的 CodexBarCore 作为本地依赖

- swift-tools-version 升级到 6.2
- 新增 local path 依赖 ../codexbar
- 新增 AIQuotaBarTests testTarget
- 传递依赖 swift-crypto / swift-log / SweetCookieKit 由 SwiftPM 自动解析

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 3：provider 改名 chatGPT → codex

**Files:**
- Modify: `AIQuotaBar/Models/UsageProvider.swift:1-37`
- Modify: `AIQuotaBar/Services/UsageService.swift:25-27, 215-217, 1064-1068, 1110-1112`
- Modify: `AIQuotaBar/Views/SettingsView.swift`（所有 `.chatGPT` 引用）
- Modify: `AIQuotaBar/ViewModels/UsageViewModel.swift`（如有 `.chatGPT` 引用）

- [ ] **Step 1: 重写 UsageProvider.swift**

完整替换 `AIQuotaBar/Models/UsageProvider.swift`：

```swift
import Foundation

enum UsageProvider: String, CaseIterable, Codable, Identifiable {
    case miniMax = "minimax"
    case glm = "glm"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .miniMax:
            return "MiniMax"
        case .glm:
            return "GLM"
        case .codex:
            return "Codex"
        }
    }

    var keychainAccount: String {
        switch self {
        case .miniMax:
            return "apiKey"
        case .glm:
            return "glmCredential"
        case .codex:
            return "codexCredential"
        }
    }

    /// 老 chatGPTCredential keychain account，用于一次性迁移
    static let legacyChatGPTKeychainAccount = "chatGPTCredential"

    static let storageKey = "usageProvider"
}
```

- [ ] **Step 2: 替换 UsageService.swift 中 .chatGPT 分支**

在 `AIQuotaBar/Services/UsageService.swift` 中：

- 第 25-27 行 `case .chatGPT: return try ChatGPTCredentialCollection.parseStorage(credential).storageString` 替换为：

```swift
        case .codex:
            // 适配层 CodexService 自管凭证存储；这里不再校验
            return credential.trimmingCharacters(in: .whitespacesAndNewlines)
```

- 第 215-217 行 `case .chatGPT:` 替换为：

```swift
        case .codex:
            return try await CodexService.shared.fetchUsage()
```

- 第 1064-1068 行 `case .chatGPT:` 替换为：

```swift
        case .codex:
            return try await CodexService.shared.testConnection()
```

- 删除 `prepareChatGPTCredentialsForStorage` 方法（第 30-32 行）。

- [ ] **Step 3: 检查并更新 Views 与 ViewModels**

```bash
grep -rn "\.chatGPT\|case chatGPT" /Users/ericyim/ai-quota-bar/.worktrees/codex-rewrite/AIQuotaBar/ 2>&1
```

对每个匹配文件，搜索 `\.chatGPT` 与 `case chatGPT`，全部替换为 `.codex` / `case codex`。

- [ ] **Step 4: 验证编译**

```bash
swift build -c release 2>&1 | tail -30
```

期望：build 失败，提示 `ChatGPTCredentialCollection` 等不存在（预期，尚未删除旧代码，任务 5 处理）。

- [ ] **Step 5: 提交**

```bash
git add AIQuotaBar/Models/UsageProvider.swift \
        AIQuotaBar/Services/UsageService.swift \
        AIQuotaBar/Views/SettingsView.swift \
        AIQuotaBar/ViewModels/UsageViewModel.swift
git commit -m "refactor(provider): 将 chatGPT 重命名为 codex

- UsageProvider.chatGPT → .codex
- Keychain account: chatGPTCredential → codexCredential
- 保留 legacyChatGPTKeychainAccount 用于一次性迁移
- SettingsView / ViewModel 同步引用

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 4：写 CodexDataSourceMode（TDD）

**Files:**
- Create: `AIQuotaBar/Services/Codex/CodexDataSourceMode.swift`
- Create: `AIQuotaBar/Tests/Codex/CodexDataSourceModeTests.swift`

- [ ] **Step 1: 写失败测试**

`AIQuotaBar/Tests/Codex/CodexDataSourceModeTests.swift`：

```swift
import XCTest
@testable import AIQuotaBar

final class CodexDataSourceModeTests: XCTestCase {
    func testRawValueRoundTrip() {
        for mode in CodexDataSourceMode.allCases {
            let encoded = mode.rawValue
            let decoded = CodexDataSourceMode(rawValue: encoded)
            XCTAssertEqual(decoded, mode, "Round trip failed for \(mode)")
        }
    }

    func testDisplayNamesAreUserFacing() {
        XCTAssertEqual(CodexDataSourceMode.auto.displayName, "Auto")
        XCTAssertEqual(CodexDataSourceMode.oauth.displayName, "OAuth")
        XCTAssertEqual(CodexDataSourceMode.cli.displayName, "CLI")
        XCTAssertEqual(CodexDataSourceMode.web.displayName, "Web dashboard")
    }

    func testStorageKeyIsStable() {
        XCTAssertEqual(CodexDataSourceMode.storageKey, "codexSourceMode")
    }

    func testMapsToProviderSourceMode() {
        XCTAssertEqual(CodexDataSourceMode.auto.codexbarSourceMode, .auto)
        XCTAssertEqual(CodexDataSourceMode.oauth.codexbarSourceMode, .oauth)
        XCTAssertEqual(CodexDataSourceMode.cli.codexbarSourceMode, .cli)
        XCTAssertEqual(CodexDataSourceMode.web.codexbarSourceMode, .web)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --filter CodexDataSourceModeTests 2>&1 | tail -15
```

期望：FAIL，`CodexDataSourceMode` not defined。

- [ ] **Step 3: 实现 CodexDataSourceMode**

`AIQuotaBar/Services/Codex/CodexDataSourceMode.swift`：

```swift
import CodexBarCore
import Foundation

enum CodexDataSourceMode: String, CaseIterable, Codable, Identifiable {
    case auto
    case oauth
    case cli
    case web

    var id: String { rawValue }

    static let storageKey = "codexSourceMode"

    static let `default`: CodexDataSourceMode = .auto

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .oauth: return "OAuth"
        case .cli: return "CLI"
        case .web: return "Web dashboard"
        }
    }

    var codexbarSourceMode: CodexBarCore.ProviderSourceMode {
        switch self {
        case .auto: return .auto
        case .oauth: return .oauth
        case .cli: return .cli
        case .web: return .web
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --filter CodexDataSourceModeTests 2>&1 | tail -15
```

期望：PASS（4 个测试）。

- [ ] **Step 5: 提交**

```bash
git add AIQuotaBar/Services/Codex/CodexDataSourceMode.swift \
        AIQuotaBar/Tests/Codex/CodexDataSourceModeTests.swift
git commit -m "feat(codex): 新增 CodexDataSourceMode 枚举

- 4 种 mode：auto / oauth / cli / web
- 持久化到 UserDefaults codexSourceMode
- 映射到 codexbar ProviderSourceMode

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 5：写 CodexUsageDataMapper（TDD）

**Files:**
- Create: `AIQuotaBar/Services/Codex/CodexUsageDataMapper.swift`
- Create: `AIQuotaBar/Tests/Codex/CodexUsageDataMapperTests.swift`
- Create: `AIQuotaBar/Tests/Codex/Fixtures/codex-snapshot-with-primary.json`（如需要可省略，纯代码构造 fixture）

- [ ] **Step 1: 写失败测试**

`AIQuotaBar/Tests/Codex/CodexUsageDataMapperTests.swift`：

```swift
import CodexBarCore
import XCTest
@testable import AIQuotaBar

final class CodexUsageDataMapperTests: XCTestCase {
    func testMapsPrimaryWindowTo5h() {
        let window = RateWindow(
            usedPercent: 35,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let snapshot = UsageSnapshot(
            primary: window,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            providerCost: nil,
            kiroUsage: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(timeIntervalSince1970: 1_699_999_000),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")

        XCTAssertEqual(data.provider, .codex)
        XCTAssertEqual(data.models.count, 1)
        let model = data.models[0]
        XCTAssertEqual(model.modelName, "5h")
        XCTAssertEqual(model.valueSuffix, "%")
        XCTAssertEqual(model.currentIntervalRemainingPercent, 65)
        XCTAssertEqual(model.accountName, "user@example.com")
        XCTAssertEqual(model.weeklyTotal, 0)
        XCTAssertNotNil(model.endTime)
    }

    func testMapsSecondaryWindowToWeekly() {
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: window,
            tertiary: nil,
            extraRateWindows: nil,
            providerCost: nil,
            kiroUsage: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "codex-cli")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertEqual(data.models[0].modelName, "Weekly")
        XCTAssertEqual(data.models[0].currentIntervalRemainingPercent, 100)
        XCTAssertNil(data.models[0].accountName)
    }

    func testMapsExtraRateWindows() {
        let extraWindow = RateWindow(
            usedPercent: 60,
            windowMinutes: 60,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let named = NamedRateWindow(
            id: "spark",
            title: "GPT-5.3-Codex-Spark",
            window: extraWindow)
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [named],
            providerCost: nil,
            kiroUsage: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertEqual(data.models[0].modelName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(data.models[0].currentIntervalRemainingPercent, 40)
    }

    func testMapsCreditsAsExtraModel() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            providerCost: nil,
            kiroUsage: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)
        let credits = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: Date())

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: credits,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertEqual(data.models[0].modelName, "Credits")
        XCTAssertEqual(data.models[0].currentIntervalRemaining, 1234)
    }

    func testMapsAllSectionsTogether() {
        let primary = RateWindow(
            usedPercent: 35,
            windowMinutes: 300,
            resetsAt: Date(timeIntervalSince1970: 1_700_000_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let secondary = RateWindow(
            usedPercent: 0,
            windowMinutes: 7 * 24 * 60,
            resetsAt: Date(timeIntervalSince1970: 1_700_100_000),
            resetDescription: nil,
            nextRegenPercent: nil)
        let extra = NamedRateWindow(
            id: "spark",
            title: "GPT-5.3-Codex-Spark",
            window: RateWindow(
                usedPercent: 60,
                windowMinutes: 60,
                resetsAt: Date(timeIntervalSince1970: 1_700_050_000),
                resetDescription: nil,
                nextRegenPercent: nil))
        let credits = CreditsSnapshot(remaining: 500, events: [], updatedAt: Date())
        let snapshot = UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            extraRateWindows: [extra],
            providerCost: nil,
            kiroUsage: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "user@example.com",
                accountOrganization: nil,
                loginMethod: "pro"))

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: credits,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 4)
        XCTAssertEqual(data.models[0].modelName, "5h")
        XCTAssertEqual(data.models[1].modelName, "Weekly")
        XCTAssertEqual(data.models[2].modelName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(data.models[3].modelName, "Credits")
        XCTAssertEqual(data.models[0].accountName, "user@example.com")
    }

    func testEmptySnapshotProducesNotConfiguredPlaceholder() {
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            extraRateWindows: nil,
            providerCost: nil,
            kiroUsage: nil,
            zaiUsage: nil,
            minimaxUsage: nil,
            updatedAt: Date(),
            identity: nil)

        let data = CodexUsageDataMapper.mapToUsageData(
            snapshot: snapshot,
            credits: nil,
            sourceLabel: "oauth")

        XCTAssertEqual(data.models.count, 1)
        XCTAssertTrue(
            data.models[0].detailText?.contains("Codex not configured") == true,
            "Expected 'Codex not configured' placeholder, got \(data.models[0].detailText ?? "nil")")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --filter CodexUsageDataMapperTests 2>&1 | tail -15
```

期望：FAIL，`CodexUsageDataMapper` not defined。

- [ ] **Step 3: 实现 CodexUsageDataMapper**

`AIQuotaBar/Services/Codex/CodexUsageDataMapper.swift`：

```swift
import CodexBarCore
import Foundation

enum CodexUsageDataMapper {
    static func mapToUsageData(
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?,
        sourceLabel: String) -> UsageData
    {
        var models: [ModelUsageData] = []
        let accountName = snapshot.identity?.accountEmail
        let planType = snapshot.identity?.loginMethod

        if let primary = snapshot.primary {
            models.append(makeModel(
                name: "5h",
                window: primary,
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        if let secondary = snapshot.secondary {
            models.append(makeModel(
                name: "Weekly",
                window: secondary,
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        if let extras = snapshot.extraRateWindows {
            for named in extras {
                models.append(makeModel(
                    name: named.title.isEmpty ? named.id : named.title,
                    window: named.window,
                    accountName: accountName,
                    planType: planType,
                    sourceLabel: sourceLabel))
            }
        }

        if let credits, !credits.unlimited, let remaining = credits.remaining {
            models.append(makeCreditsModel(
                remaining: remaining,
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        if models.isEmpty {
            models.append(makeNotConfiguredPlaceholder(
                accountName: accountName,
                planType: planType,
                sourceLabel: sourceLabel))
        }

        let readyCount = models.filter(\.isCurrentIntervalAvailable).count
        let total = max(models.count, 1)

        return UsageData(
            provider: .codex,
            remains: readyCount,
            total: total,
            timestamp: snapshot.updatedAt,
            models: models)
    }

    private static func makeModel(
        name: String,
        window: RateWindow,
        accountName: String?,
        planType: String?,
        sourceLabel: String) -> ModelUsageData
    {
        let remainingPercent = Int((100 - window.usedPercent).rounded())
        let endTime = window.resetsAt
        let startTime = endTime.map { end in
            end.addingTimeInterval(-Double(window.windowMinutes ?? 0) * 60)
        }
        let detail = makeDetailText(
            planType: planType,
            sourceLabel: sourceLabel,
            endTime: endTime)

        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: name,
            currentIntervalTotal: 100,
            currentIntervalUsed: remainingPercent,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: endTime.map { Int($0.timeIntervalSince(Date()) * 1000) } ?? 0,
            startTime: startTime,
            endTime: endTime,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: "%",
            detailText: detail,
            currentIntervalRemainingPercent: remainingPercent,
            weeklyRemainingPercent: nil)
    }

    private static func makeCreditsModel(
        remaining: Double,
        accountName: String?,
        planType: String?,
        sourceLabel: String) -> ModelUsageData
    {
        let intRemaining = Int(remaining.rounded())
        let detail = makeDetailText(
            planType: planType,
            sourceLabel: sourceLabel,
            endTime: nil)

        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: "Credits",
            currentIntervalTotal: 1,
            currentIntervalUsed: intRemaining > 0 ? 0 : 1,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: nil,
            detailText: detail,
            currentIntervalRemainingPercent: nil,
            weeklyRemainingPercent: nil)
    }

    private static func makeNotConfiguredPlaceholder(
        accountName: String?,
        planType: String?,
        sourceLabel: String) -> ModelUsageData
    {
        let detail = makeDetailText(
            planType: planType,
            sourceLabel: sourceLabel,
            endTime: nil)
        return ModelUsageData(
            provider: .codex,
            accountName: accountName,
            modelName: "Codex",
            currentIntervalTotal: 1,
            currentIntervalUsed: 1,
            weeklyTotal: 0,
            weeklyUsed: 0,
            remainsTime: 0,
            startTime: nil,
            endTime: nil,
            weeklyStartTime: nil,
            weeklyEndTime: nil,
            valueSuffix: nil,
            detailText: detail ?? "Codex not configured — run `codex` to sign in",
            currentIntervalRemainingPercent: 0,
            weeklyRemainingPercent: nil)
    }

    private static func makeDetailText(
        planType: String?,
        sourceLabel: String?,
        endTime: Date?) -> String?
    {
        var parts: [String] = []
        if let planType, !planType.isEmpty {
            let capitalized = planType.prefix(1).uppercased() + planType.dropFirst()
            parts.append("Plan \(capitalized)")
        }
        if let sourceLabel, !sourceLabel.isEmpty {
            parts.append(sourceLabel)
        }
        if let endTime {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "MM/dd HH:mm"
            parts.append("resets \(formatter.string(from: endTime))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --filter CodexUsageDataMapperTests 2>&1 | tail -15
```

期望：PASS（6 个测试）。如有失败，按错误信息修 mapper。

- [ ] **Step 5: 提交**

```bash
git add AIQuotaBar/Services/Codex/CodexUsageDataMapper.swift \
        AIQuotaBar/Tests/Codex/CodexUsageDataMapperTests.swift
git commit -m "feat(codex): 新增 UsageSnapshot → UsageData 适配器

- 覆盖 primary / secondary / extra / credits / 占位五种情形
- detailText 包含 plan · source · reset time
- 6 个单测覆盖所有路径

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 6：写 CodexService

**Files:**
- Create: `AIQuotaBar/Services/Codex/CodexService.swift`

- [ ] **Step 1: 实现 CodexService**

`AIQuotaBar/Services/Codex/CodexService.swift`：

```swift
import CodexBarCore
import Foundation

/// 适配层入口：把 codexbar 的 ProviderFetchResult 转换为 ai-quota-bar 的 UsageData
final class CodexService {
    static let shared = CodexService()

    private let descriptor: ProviderDescriptor
    private let fetcher: UsageFetcher
    private let browserDetection: BrowserDetection

    private init() {
        self.descriptor = CodexProviderDescriptor.descriptor
        self.fetcher = UsageFetcher()
        self.browserDetection = BrowserDetection()
    }

    /// 当前 source mode（持久化在 UserDefaults）
    var sourceMode: CodexDataSourceMode {
        get {
            guard
                let raw = UserDefaults.standard.string(forKey: CodexDataSourceMode.storageKey),
                let mode = CodexDataSourceMode(rawValue: raw)
            else {
                return .default
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: CodexDataSourceMode.storageKey)
        }
    }

    /// 拉取当前 source mode 下的 Codex usage
    func fetchUsage() async throws -> UsageData {
        let context = makeContext(sourceMode: sourceMode)
        do {
            let result = try await descriptor.fetch(context: context)
            return CodexUsageDataMapper.mapToUsageData(
                snapshot: result.usage,
                credits: result.credits,
                sourceLabel: result.sourceLabel)
        } catch let error as CodexOAuthFetchError {
            throw mapCodexError(error)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.networkError(error)
        }
    }

    /// 测试当前 source mode 是否能拉到数据
    func testConnection() async throws -> Bool {
        _ = try await fetchUsage()
        return true
    }

    private func makeContext(sourceMode: CodexDataSourceMode) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode.codexbarSourceMode,
            includeCredits: true,
            includeOptionalUsage: true,
            webTimeout: 30,
            webDebugDumpHTML: false,
            verbose: false,
            env: ProcessInfo.processInfo.environment,
            settings: nil,
            fetcher: fetcher,
            claudeFetcher: ClaudeUsageFetcher(),
            browserDetection: browserDetection)
    }

    private func mapCodexError(_ error: CodexOAuthFetchError) -> UsageError {
        switch error {
        case .unauthorized:
            return .apiError("Codex token expired — run `codex` to refresh")
        case .invalidResponse:
            return .invalidResponse
        case let .serverError(code, _):
            return .apiError("Codex API error \(code)")
        case let .networkError(inner):
            return .networkError(inner)
        }
    }
}
```

- [ ] **Step 2: 检查 ClaudeUsageFetcher 是否暴露**

```bash
grep -rn "public.*class ClaudeUsageFetcher\|public.*struct ClaudeUsageFetcher\|public protocol ClaudeUsageFetching" /Users/ericyim/codexbar/Sources/CodexBarCore/ 2>&1 | head -5
```

如果没找到，临时改 `CodexService.swift` 中 `claudeFetcher: ClaudeUsageFetcher()` 改为 `claudeFetcher: NoopClaudeUsageFetcher()` 并添加：

```swift
private final class NoopClaudeUsageFetcher: ClaudeUsageFetching {
    // 由 codexbar 决定协议要求；先全部抛 notImplemented
}
```

如果连 `ClaudeUsageFetching` 协议都不存在，回到 `CodexService.swift` 把 `claudeFetcher:` 参数整行删掉，看 `ProviderFetchContext` 是否所有参数都还有默认值可填。

- [ ] **Step 3: 验证编译**

```bash
swift build -c release 2>&1 | tail -30
```

期望：build 通过。如失败，按错误信息调整。

- [ ] **Step 4: 提交**

```bash
git add AIQuotaBar/Services/Codex/CodexService.swift
git commit -m "feat(codex): 新增 CodexService 适配入口

- 包装 CodexProviderDescriptor 与 UsageFetcher
- 暴露 source mode 持久化
- CodexOAuthFetchError → UsageError 错误映射
- 若 ClaudeUsageFetcher 不可用，按 Step 2 调整

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 7：删除旧 ChatGPTCredential 与老 keychain 迁移

**Files:**
- Delete: `AIQuotaBar/Services/ChatGPTCredential.swift`
- Delete: `AIQuotaBar/Services/GLMCredential.swift`（**不删！** GLM 仍在范围内，跳过本步）
- Modify: `AIQuotaBar/App/AppMigration.swift`

- [ ] **Step 1: 读 AppMigration 现有结构**

```bash
cat /Users/ericyim/ai-quota-bar/.worktrees/codex-rewrite/AIQuotaBar/App/AppMigration.swift
```

按现有模式追加新步骤。

- [ ] **Step 2: 在 AppMigration 中追加 chatGPT → codex 迁移**

在 `runIfNeeded` 末尾追加：

```swift
private static let codexMigrationKey = "codexMigration_v1"

static func runCodexMigrationIfNeeded() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: codexMigrationKey) else { return }

    // 1. 老 keychain 项 chatGPTCredential → 丢弃
    let oldAccount = "chatGPTCredential"
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KeychainService.shared.serviceIdentifier,
        kSecAttrAccount as String: oldAccount
    ]
    SecItemDelete(query as CFDictionary)

    // 2. 老 UserDefaults provider 值映射
    if let oldProvider = defaults.string(forKey: "usageProvider"),
       oldProvider == "chatgpt" {
        defaults.set("codex", forKey: "usageProvider")
    }

    defaults.set(true, forKey: codexMigrationKey)
}
```

并在合适位置（如 `AppDelegate.applicationDidFinishLaunching`）调用 `AppMigration.runCodexMigrationIfNeeded()`。

- [ ] **Step 3: 删除 ChatGPTCredential.swift**

```bash
git rm AIQuotaBar/Services/ChatGPTCredential.swift
```

- [ ] **Step 4: 验证编译**

```bash
swift build -c release 2>&1 | tail -30
```

期望：build 通过（可能仍有引用未删，按错误定位后修复）。

- [ ] **Step 5: 跑全测**

```bash
swift test 2>&1 | tail -15
```

期望：所有测试通过。

- [ ] **Step 6: 提交**

```bash
git add -A AIQuotaBar/App/AppMigration.swift
git commit -m "chore(codex): 删除旧 ChatGPTCredential 一次性迁移

- 启动时丢弃 chatGPTCredential keychain 项
- UserDefaults 老 chatgpt provider 值映射为 codex
- 删除 Services/ChatGPTCredential.swift
- 迁移由 codexMigration_v1 一次性标记

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 8：改造 SettingsView Codex 段

**Files:**
- Modify: `AIQuotaBar/Views/SettingsView.swift`（Codex 段）

- [ ] **Step 1: 定位当前 ChatGPT 段**

```bash
grep -n "ChatGPT\|chatGPT\|ChatGPTCredential" /Users/ericyim/ai-quota-bar/.worktrees/codex-rewrite/AIQuotaBar/Views/SettingsView.swift | head -30
```

- [ ] **Step 2: 替换 ChatGPT 段为 Codex 段**

找到 `ChatGPTCredentialListSection` 调用处（约 129-135 行附近），整段替换为新 Codex 段。新代码结构：

```swift
CodexSection(
    sourceMode: $codexSourceMode,
    accounts: $codexAccounts,
    viewModel: viewModel,
    onAdd: addCodexAccount,
    onRemove: removeCodexAccount,
    onRefresh: { id in await refreshCodexAccount(id: id) },
    onSignOut: { id in signOutCodexAccount(id: id) }
)
```

并在 SettingsView 顶部 state 区追加：

```swift
@State private var codexSourceMode: CodexDataSourceMode = .default
@State private var codexAccounts: [CodexAccountDraft] = []
```

添加对应 helper 方法（参考现有 `loadChatGPTCredentialDrafts` / `addChatGPTAccount` 写法，路径换成 Codex）。

- [ ] **Step 3: 新建 CodexSection SwiftUI 组件**

新建 `AIQuotaBar/Views/CodexSection.swift`（先放在同一目录便于合并审查，下一任务拆文件）：

```swift
import SwiftUI

struct CodexAccountDraft: Identifiable {
    let id: String
    var name: String
    var email: String
    var planType: String
    var sourceLabel: String
    var lastRefresh: Date?
    var isActive: Bool
}

struct CodexSection: View {
    @Binding var sourceMode: CodexDataSourceMode
    @Binding var accounts: [CodexAccountDraft]
    let viewModel: UsageViewModel
    let onAdd: () -> Void
    let onRemove: (String) -> Void
    let onRefresh: (String) async -> Void
    let onSignOut: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex")
                    .font(.headline)
                Spacer()
                Picker("Source", selection: $sourceMode) {
                    ForEach(CodexDataSourceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            if accounts.isEmpty {
                Text("Codex not configured — run `codex` in Terminal to sign in, then click Add account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    CodexAccountRow(
                        account: account,
                        onRefresh: { Task { await onRefresh(account.id) } },
                        onSignOut: { onSignOut(account.id) },
                        onRemove: { onRemove(account.id) })
                }
            }

            Button("Add account", action: onAdd)
        }
        .padding(.vertical, 8)
    }
}

private struct CodexAccountRow: View {
    let account: CodexAccountDraft
    let onRefresh: () -> Void
    let onSignOut: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if account.isActive {
                    Circle().fill(.green).frame(width: 8, height: 8)
                }
                Text(account.email.isEmpty ? account.name : account.email)
                    .font(.body.weight(.medium))
                Spacer()
                Text(account.sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if !account.planType.isEmpty {
                    Text("Plan \(account.planType.capitalized)")
                        .font(.caption)
                }
                if let last = account.lastRefresh {
                    Text("Last refreshed \(last.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("Refresh", action: onRefresh)
                Button("Sign out", action: onSignOut)
                Button(role: .destructive, action: onRemove) { Text("Remove") }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
```

- [ ] **Step 4: 写 Codex 账号数据源（包装 codexbar FileManagedCodexAccountStore）**

新建 `AIQuotaBar/Services/Codex/CodexAccountCoordinator.swift`：

```swift
import CodexBarCore
import Foundation

/// 协调 codexbar 的 FileManagedCodexAccountStore，
/// 提供 Settings 面板所需的账号列表
final class CodexAccountCoordinator {
    static let shared = CodexAccountCoordinator()

    private let store: FileManagedCodexAccountStore

    private init() {
        self.store = FileManagedCodexAccountStore()
    }

    /// 返回所有 stored accounts 的摘要，用于 Settings 列表渲染
    func listAccountDrafts() -> [CodexAccountDraft] {
        do {
            let set = try store.loadAccounts()
            return set.accounts.map { account in
                CodexAccountDraft(
                    id: account.id.uuidString,
                    name: account.workspaceLabel ?? account.email,
                    email: account.email,
                    planType: "",
                    sourceLabel: sourceLabel(for: account),
                    lastRefresh: account.lastAuthenticatedAt.map {
                        Date(timeIntervalSince1970: $0)
                    },
                    isActive: false)
            }
        } catch {
            return []
        }
    }

    private func sourceLabel(for account: ManagedCodexAccount) -> String {
        let hasAuth = CodexAuthFingerprint.fingerprint(
            homePath: account.managedHomePath) != nil
        return hasAuth ? "OAuth" : "Unknown"
    }

    /// 删除指定账号
    func removeAccount(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        do {
            var set = try store.loadAccounts()
            let remaining = set.accounts.filter { $0.id != uuid }
            set = ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: remaining)
            try store.storeAccounts(set)
        } catch {
            // 静默失败；UI 已显示删除意图
        }
    }

    /// 全删（不暴露给 UI，仅供 reset 使用）
    func removeAll() {
        do {
            try store.storeAccounts(ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: []))
        } catch {
            // 静默失败
        }
    }
}
```

- [ ] **Step 5: 验证 FileManagedCodexAccountStore / ManagedCodexAccount / CodexAuthFingerprint 公开 API**

```bash
grep -n "public.*currentVersion\|public.*loadAccounts\|public.*storeAccounts" /Users/ericyim/codexbar/Sources/CodexBarCore/ManagedCodexAccountStore.swift 2>&1
grep -n "public.*fingerprint\|public.*normalize" /Users/ericyim/codexbar/Sources/CodexBarCore/CodexManagedAccounts.swift 2>&1
```

确认 `FileManagedCodexAccountStore.currentVersion`、`loadAccounts`、`storeAccounts`、`CodexAuthFingerprint.fingerprint(homePath:)` 全部存在。如命名不一致，按实际接口调整 Coordinator。

- [ ] **Step 6: 验证编译 + 跑全测**

```bash
swift build -c release 2>&1 | tail -30
swift test 2>&1 | tail -15
```

期望：build 与 test 全部通过。

- [ ] **Step 7: 提交**

```bash
git add AIQuotaBar/Views/SettingsView.swift \
        AIQuotaBar/Views/CodexSection.swift \
        AIQuotaBar/Services/Codex/CodexAccountCoordinator.swift
git commit -m "feat(codex): 改造 Settings 面板为新 Codex 段

- Picker 选择 source mode
- 多账号行：状态 / email / plan / source / refresh / sign out / remove
- CodexAccountCoordinator 包装 ManagedCodexAccountStore
- 替换原 ChatGPTCredentialListSection

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 9：改造 MenuView 渲染 Codex 卡片

**Files:**
- Modify: `AIQuotaBar/Views/MenuView.swift`（Codex 段渲染）

- [ ] **Step 1: 定位现有 Codex/ChatGPT 段**

```bash
grep -n "codex\|Codex\|chatGPT\|ChatGPT" /Users/ericyim/ai-quota-bar/.worktrees/codex-rewrite/AIQuotaBar/Views/MenuView.swift | head -20
```

- [ ] **Step 2: 调整 render 分支**

现有 MenuView 大概率按 `usageData.provider` 走不同 `render(...)` 路径。Codex 路径仅需保证：

- `modelName` 直接来自 codexbar 映射（"5h" / "Weekly" / "GPT-5.3-Codex-Spark" / "Credits"）
- `accountName` 来自 `identity.email`，按它做分组
- `detailText` 含 plan · source
- 趋势图对 `additional` 限同样适用

如现有 render 路径已能消费上述字段，仅替换文案与配色；否则抽出 `renderCodexSection(usage:)` 私有方法。

- [ ] **Step 3: 验证编译**

```bash
swift build -c release 2>&1 | tail -30
```

- [ ] **Step 4: 提交**

```bash
git add AIQuotaBar/Views/MenuView.swift
git commit -m "feat(codex): 改造 MenuView 渲染新 Codex 字段

- 按 accountName 分组卡片
- 5h / Weekly / additional / credits 全部渲染
- plan · source 显示在 detail

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 10：菜单栏 fallback 验证（无须改代码，确认现状）

**Files:** 无（验证 + 微调）

- [ ] **Step 1: 读 StatusBarController 现有 fallback 逻辑**

```bash
grep -n "codex\|Codex\|chatGPT\|exhausted\|fallback" /Users/ericyim/ai-quota-bar/.worktrees/codex-rewrite/AIQuotaBar/App/StatusBarController.swift | head -20
```

- [ ] **Step 2: 验证现有 fallback 是否已能消费新 ModelUsageData**

- `isCurrentIntervalAvailable` / `currentIntervalRemainingPercent` 等都在新 model 上
- 不必改 fallback 逻辑
- 如有特定 Codex 路径 if/else，确认未被遗留的 `.chatGPT` 字面量锁死

- [ ] **Step 3: 必要时微调**

只改 `.chatGPT` 字面量为 `.codex`；不重构。

- [ ] **Step 4: 提交（如有改动）**

```bash
git add AIQuotaBar/App/StatusBarController.swift
git commit -m "refactor(codex): 状态栏 fallback 引用 .codex

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 11：构建并手动验证

**Files:** 无（验证）

- [ ] **Step 1: 完整 release 构建**

```bash
swift build -c release 2>&1 | tail -10
```

期望：build 成功。

- [ ] **Step 2: 跑全测**

```bash
swift test 2>&1 | tail -10
```

期望：所有测试通过。

- [ ] **Step 3: 启动 app**

按 `CLAUDE.md` macOS MenuBar 流程：

```bash
rm -rf .build && swift build -c release && \
  cp .build/arm64-apple-macosx/release/AIQuotaBar "dist/AIQuotaBar.app/Contents/MacOS/AIQuotaBar" && \
  pkill -f "AIQuotaBar" 2>/dev/null; sleep 1; \
  open "dist/AIQuotaBar.app"
pgrep -fl "AIQuotaBar"
```

- [ ] **Step 4: 手动验证清单**

按 spec §9.2 逐项验证：

1. 无凭证 → Menu Bar 占位文案 "Codex not configured"
2. 添加 OAuth 账号（`~/.codex/auth.json` 存在）→ 自动拉取
3. 添加 Web 账号（从浏览器导入 cookie）→ 拉取
4. source mode 切到 OAuth → 不报 CLI 缺失
5. source mode 切到 CLI（`codex` 存在）→ 拉取
6. auto + token 故意改坏 → 回退到 CLI 或 Web
7. 多账号 → 各自一段卡片
8. 5h 用尽 → 菜单栏 fallback 到 Weekly
9. 全部用尽 → fallback 到下一账号
10. 老 keychain 残留 → 启动时被清
11. 字段缺失（plan / additional / credits）→ UI 不崩
12. OAuth refresh 失败 → 报错但不崩
13. 云备份（如果有账号）→ snapshot 写入正常
14. 警告面板 / 通知 / auto-launch 不受影响

每项不通过则开 issue 修；通过后继续。

- [ ] **Step 5: 回归 MiniMax / GLM**

按现有 dev 流程，确保 MiniMax 拉取、GLM 拉取、设置保存 / 加载、右键循环、显示格式切换都未受影响。

---

## 任务 12：文档与发布说明

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`（如有）

- [ ] **Step 1: 更新 README 中 ChatGPT 段**

将 "## ChatGPT/Codex GPT support" 整段重写为 "## Codex support"，内容对齐新行为：

- 删除 curl / session JSON 粘贴说明
- 新增 source mode (Auto / OAuth / CLI / Web) 说明
- 新增多账号说明
- 新增 OAuth / CLI / Web 设置步骤

- [ ] **Step 2: 写 Release Note 草稿**

在 README 末尾 "## Release highlights" 添加新版本条目：

```markdown
### 2.0.0

- 全面重写 Codex 模块：参考 codexbar 的 CodexBarCore 实现
- 数据源策略：CLI / OAuth / Web dashboard
- 多账号支持，含 codexbar 的 account reconciliation
- 显示新字段：plan_type、additional_rate_limits、credits
- 老 chatGPTCredential 凭证一次性丢弃
- Provider 重命名：chatGPT → codex
```

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: 同步 README 与 Codex 改造

- 替换 ChatGPT/Codex GPT 章节为新 Codex 章节
- 新增 source mode / 多账号 / OAuth refresh / Web cookie 说明
- 标注老凭证需重新连接

Co-Authored-By: Eric Yim <eric.yim@foxmail.com>"
```

---

## 任务 13：合并前准备

**Files:**
- Modify: 仓库根（提交 + push + 提 PR）

- [ ] **Step 1: 自查**

```bash
git log main..HEAD --oneline
git diff main..HEAD --stat
```

期望：commit 数 8-12，文件改动集中于 `AIQuotaBar/Services/Codex/`、`AIQuotaBar/Models/`、`AIQuotaBar/Views/`、`Package.swift`、测试目录、文档。

- [ ] **Step 2: 跑全测最后一次**

```bash
swift test 2>&1 | tail -10
```

- [ ] **Step 3: 关闭 dev 进程**

```bash
pkill -f "AIQuotaBar" 2>/dev/null
```

- [ ] **Step 4: 推送分支**

```bash
git push -u origin feat/codex-subsystem-rewrite
```

- [ ] **Step 5: 通知用户验证**

按 `CLAUDE.md` "合并前必须询问用户" 原则，告知用户推送完成，让用户自行验证。**不要自动合并。**

---

## 自审清单（执行前请逐条过）

- [x] Spec §3.2 依赖：任务 2 改 Package.swift
- [x] Spec §3.1 分层：任务 4/5/6/8 创建 `Services/Codex/`，任务 8/9 改 Views
- [x] Spec §4 数据流：任务 6 CodexService + 任务 5 mapper
- [x] Spec §5 字段映射：任务 5 mapper 测试覆盖所有路径
- [x] Spec §6 UI：任务 8 Settings + 任务 9 MenuView
- [x] Spec §7 数据迁移：任务 7 AppMigration
- [x] Spec §8 错误处理：任务 6 mapCodexError + CodexService 错误路径
- [x] Spec §9 测试：任务 4/5 单测 + 任务 11 手动验证
- [x] Spec §10 风险：升级 swift-tools-version 已处理
- [x] Spec §11 实施分阶段：13 个任务按阶段排序
- [x] Spec §12 验收标准：任务 11 全部通过才进任务 12/13

---

## 备注

- 所有 Codex 业务逻辑都来自 codexbar，单向参考，**不修改 codexbar 任何文件**
- 命名冲突：所有 codexbar 类型用 `CodexBarCore.<Type>` 完全限定
- 每次 commit 中文，遵循 `CLAUDE.md` 格式
- 合并前必须等用户确认
