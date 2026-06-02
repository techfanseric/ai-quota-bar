# AI Quota Bar - Codex 子系统重写设计

**Date**: 2026-06-02
**Status**: Approved (pending user spec review)
**Scope**: 替换 ai-quota-bar 中现有的 ChatGPT/Codex GPT 读取与展示实现，全面对齐 codexbar 的 Codex 子系统

---

## 1. 背景与目标

ai-quota-bar 当前通过用户手动粘贴的 curl / session JSON 解析 ChatGPT 后端 API 响应（`https://chatgpt.com/backend-api/codex/usage`），自行实现了一套灵活 JSON 字段匹配（约 250 行启发式代码），硬塞进通用 `ModelUsageData` 模型。这套实现有以下问题：

- 缺少 `planType`、缺少 `additional_rate_limits`、缺少账户身份（email / plan）
- 5h / Weekly 窗口识别靠字符串匹配，对 OpenAI 后端响应字段变动脆弱
- 不支持 OAuth refresh；不支持 CLI；不支持 Web dashboard
- 多账号靠用户多次粘贴凭证实现，没有 account reconciliation

codexbar（`~/codexbar`）已经为 Codex 实现了工业级的多源策略（CLI / OAuth / Web）、`CodexReconciledState` 调和、强类型 `CodexUsageResponse` / `RateWindow` / `ProviderIdentitySnapshot` 模型。本次重写的目标是把这一套业务逻辑与数据流迁入 ai-quota-bar，UI 沿用 ai-quota-bar 现有规范。

**目标**：
- 完全照搬 codexbar 的 Codex 业务逻辑（CLI + OAuth + Web + 调和）
- CodexBarCore 单向参考，不修改 codexbar 任何文件
- ai-quota-bar 现有 UI 体系（UsageViewModel / MenuView / SettingsView / AppLanguage / KeychainService）保持不变，只增不改消费方

---

## 2. 范围

### 2.1 在范围内

- 引入 codexbar 的 `CodexBarCore` 作为本地 SwiftPM 依赖
- 编写 ai-quota-bar 适配层（`CodexService` 等），把 `UsageSnapshot` 映射到现有 `UsageData` / `ModelUsageData`
- `UsageProvider.chatGPT` 改名为 `UsageProvider.codex`
- 一次性丢弃老 `chatGPTCredential` keychain 残留
- Settings 面板新增 source mode 切换、Codex 账号列表、添加 / 移除账号
- MenuView 渲染新字段：plan_type 头标、5h / Weekly / additional_rate_limits / credits
- 单元测试：mapper、context 构造

### 2.2 不在范围内

- MiniMax、GLM 任何改造
- codexbar 其他 provider（Claude / Copilot / Cursor / Gemini / ...）
- codexbar 自身的 CodexWatchdog、ClaudeWebProbe、Widget 扩展
- 现有 `UsageViewModel` / `MenuView` 对 MiniMax / GLM 段的渲染逻辑
- 菜单栏 fallback 行为、警告面板、云备份、auto-launch
- 修改 codexbar 任何文件
- 实现 OAuth 登录流程本身（依赖 `codex` CLI / `~/.codex/auth.json` 已存在的 token；不在 app 内启动 OAuth 流程）

---

## 3. 架构

### 3.1 分层

```
codexbar (local path)              ai-quota-bar
├─ CodexBarCore                    ├─ Services/Codex/
│  ├─ CodexProviderDescriptor       │   ├─ CodexService.swift          ← 入口：fetchUsage(sourceMode:)
│  ├─ CodexOAuthUsageFetcher        │   ├─ CodexDataSourceMode.swift   ← enum: auto / oauth / cli / web
│  ├─ CodexOAuthCredentialsStore    │   ├─ CodexAccountCoordinator.swift ← 包装 CodexAccountReconciliationSnapshot
│  ├─ CodexWebDashboardStrategy     │   ├─ CodexUsageDataMapper.swift   ← UsageSnapshot → UsageData
│  ├─ CodexCLIUsageStrategy         │   └─ CodexAddAccountSheet.swift   ← SwiftUI：粘 token / 选 web cookie
│  ├─ CodexReconciledState          │
│  ├─ RateWindow                    ├─ Models/
│  ├─ NamedRateWindow               │   └─ UsageProvider.swift         ← .chatGPT → .codex
│  ├─ ProviderIdentitySnapshot      │
│  └─ UsageError                    ├─ Views/
                                   │   ├─ SettingsView.swift          ← 新 Codex 区
                                   │   └─ MenuView.swift              ← 新 Codex 卡片
                                   └─ App/
                                       └─ AppMigration.swift          ← 启动时清旧 keychain
```

**边界原则**：
- 适配层只做映射 / source-mode 包装 / 旧凭证丢弃；不重复实现 OAuth / CLI / Web 协议
- `CodexBarCore` 文件不被修改；新文件都不放 codexbar 目录
- 现有 `UsageProvider` 的 `case chatGPT` 改成 `case codex`（同时改 Keychain account key、displayName、SettingsView 文案、`UsageService.prepareCredentialForStorage` 分支、`KeychainService.legacyServices` 中的引用）

### 3.2 依赖

修改 `ai-quota-bar/Package.swift`：
- 升级 `swift-tools-version` 到 `6.2`（与 codexbar 一致；本机 Swift 6.3.2 兼容）
- 新增 local path 依赖：`package(path: "../codexbar")`
- AIQuotaBar target 添加 `.product(name: "CodexBarCore", package: "codexbar")`
- CodexBarCore 自身的传递依赖（`swift-crypto`、`swift-log`、`SweetCookieKit`）由 SwiftPM 自动解析

`Makefile` 同步：build / app / sign / install 流程不变；`swift build` 会自动拉取本地 codexbar 路径。

---

## 4. 数据流

### 4.1 一次 `CodexService.fetchUsage()` 调用

1. **入口**：`UsageViewModel.refresh()` 调 `CodexService.shared.fetchUsage(sourceMode: settings.codexSourceMode)`
2. **构造 Context**：根据 source mode 构造 `ProviderFetchContext`
   - `runtime = .app`（ai-quota-bar 永远在 app 上下文，不走 CLI runtime）
   - `sourceMode = 传入的 sourceMode`
   - `env = ProcessInfo.processInfo.environment`
   - `fetcher = UsageFetcher()`（来自 `CodexBarCore`，内部读 `~/.codex/auth.json`、`codex` CLI 等）
   - `webTimeout = 30s`、`verbose = false` 等用 ai-quota-bar 默认值
3. **选 strategy**：调 `CodexProviderDescriptor.resolveStrategies(context:)` 拿到有序策略列表
4. **依次尝试**：遍历 strategies，每失败一个就用 `shouldFallback(on:context:)` 决定是否继续；最终拿到 `ProviderFetchResult` 或抛错
5. **解析结果**：`result.usage: UsageSnapshot` 含 `primary` / `secondary` / `extraRateWindows` / `identity`；`result.credits: CreditsSnapshot?`；`result.sourceLabel: String`（如 "oauth" / "codex-cli" / "openai-web"）
6. **映射**：`CodexUsageDataMapper.mapToUsageData(snapshot:)` 转 `UsageData`
7. **返回**：标准 `UsageData` 给现有消费方
8. **UI 渲染**：现有 `UsageViewModel` / `MenuView` / `SettingsView` 不变

### 4.2 多账号路径

- `CodexAccountCoordinator` 包装 `CodexAccountReconciliationSnapshot` 决定 active account
- 对每个 stored account 独立调 `CodexService.fetchUsage(for: account)`，合并到同一个 `UsageData.models`（每个 model 的 `accountName` 来自 `identity.email`）
- 共享同一 `timestamp`

### 4.3 失败回退（auto 模式）

`CodexProviderDescriptor.resolveStrategies` 内部已实现：
- runtime = .app，sourceMode = .auto → 返回 `[oauth, cli]`
- oauth 失败且 `shouldFallback` 允许 → 试 cli
- cli 失败且 sourceMode = .auto → `CodexWebDashboardStrategy.shouldFallback` 允许 → 试 web
- 全部失败 → 抛 `UsageError.notConfigured` 或 `UsageError.networkError`

适配层捕获并按现有 `UsageError` 错误处理路径（`AppLanguage.errorDescription`）显示。

---

## 5. 字段映射（`UsageSnapshot` → `ModelUsageData`）

| codexbar 字段 | ai-quota-bar `ModelUsageData` 字段 |
|---|---|
| `primary` (5h RateWindow) | `modelName = "5h"`, `currentIntervalTotal = 100`, `valueSuffix = "%"`, `currentIntervalRemainingPercent = 100 - usedPercent`, `startTime = resetsAt - windowMinutes*60`, `endTime = resetsAt` |
| `secondary` (Weekly RateWindow) | `modelName = "Weekly"`, 同上但 window 7d |
| `extraRateWindows[i]` (NamedRateWindow) | `modelName = limitName ?? meteredFeature`, 其它同上 |
| `credits?.remaining` | `modelName = "Credits"`, `currentIntervalTotal = 1`, `currentIntervalUsed = 0 if unlimited else (1 - remaining/balance)` |
| `identity.email` | `accountName` |
| `identity.loginMethod` (plan_type) | 写入 `detailText` 顶部：`"Plan Pro · OAuth · 12:34"` |
| `sourceLabel` | 写入 `detailText` 中部 |

**未配置态**：保留 `ModelUsageData` 占位行，文案改为 `"Codex not configured — run \`codex\` to sign in"`，detailText 为 nil。

**displayName 规则**（`ModelUsageData.displayName` 已有）：
- 有 accountName → `"email · modelName"`
- 无 → `"modelName"`

---

## 6. UI 改造

### 6.1 Settings 面板（替换现有 ChatGPT 多账号区）

```
[Codex]                              ← 分组标题
  Source mode: Auto / OAuth / CLI / Web  ← Picker（默认 Auto）
  ─────────────────────────────
  Account 1
    ● active · last refreshed 12:34
    email: user@example.com
    login method: Pro
    source: OAuth (~/.codex/auth.json)
    [Refresh] [Sign out] [Remove]
  ─────────────────────────────
  Account 2
    ...
  ─────────────────────────────
  [+ Add account]                ← 弹窗：粘 accessToken / 选 OAuth 文件 / 选 Web cookie
  When no accounts: 帮助文字 + "Run `codex` to sign in" 按钮（如可探测到 codex 二进制）
```

### 6.2 Menu Bar

行为完全保持。优先级：active 5h（最低 usedPercent） → Weekly → additional → 下一账号。`MenuBarStatusItemDefaultsRepair` 现有 fallback 逻辑复用。

### 6.3 Dropdown Menu（每个 account 一段卡片）

```
┌─ user@example.com (Pro) ───────── OAuth · 12:34 ─┐
│  5h                65% left   resets 17:00         │
│   ████████░░░░░░░░░░░░░░░░░░  趋势图              │
│  Weekly            100% left  resets 04/08 00:00   │
│   ████████████████████░░░░░                       │
│  GPT-5.3-Codex-Spark 40% left   resets 18:30       │  ← additional
│  Credits            1234 left                      │  ← credits（如果存在）
│  Plan Pro · OAuth                                    │
└────────────────────────────────────────────────────┘
```

`resetTimeText` 现有逻辑（`UsageData.swift:254-329`）直接复用：
- < 24h 窗口 → 显示起止时间段 "Today 13:00-18:00"
- 完整 24h 窗口 → 显示截止时间 "MM/dd HH:mm"

### 6.4 不变的部分

- 菜单栏状态项、警告面板、云备份、auto-launch、右键循环、刷新频率、显示格式
- MiniMax / GLM 区段的所有 UI

---

## 7. 数据迁移

`App/app.swift` 启动时执行一次性迁移（在 `AppMigration.runIfNeeded()` 中追加）：

```swift
// 旧 chatGPTCredential 一次性丢弃
if let old = KeychainService.shared.legacyRetrieve(
    service: "com.techfanseric.aiquotabar",
    account: "chatGPTCredential"
) {
    KeychainService.shared.legacyDelete(
        service: "com.techfanseric.aiquotabar",
        account: "chatGPTCredential"
    )
    // 不抛错；用户重新配置 Codex 即可
}
```

老 keychain 项用同 `KeychainService` 提供的 `legacyRetrieve` / `legacyDelete` 私有方法操作（已有现成实现，见 `KeychainService.swift:50-68`）。

`UserDefaults` 同步处理：
- `usageProvider` 老值 `"chatgpt"` → 启动时一次性映射为 `"codex"`
- 其他 Codex 相关的 UserDefaults key 全部清除

迁移失败不影响 app 启动；老凭证只是被丢弃，用户首次启动后引导添加新 Codex 账号。

---

## 8. 错误处理

| 场景 | 处理 |
|---|---|
| `~/.codex/auth.json` 不存在 / token 过期 | OAuth strategy 抛 `CodexOAuthFetchError.unauthorized` → 适配层转 `UsageError.apiError("Codex token expired — run \`codex\` to refresh")` |
| `codex` 二进制不存在 | `CodexCLIUsageStrategy.isAvailable` 返回 false → 该 strategy 被跳过 |
| Web dashboard 失败（cookie 失效） | `OpenAIDashboardFetcher.FetchError.loginRequired` → 适配层转 `UsageError.apiError("Browser session expired — re-import cookie")` |
| 全部 strategy 失败 | 抛 `UsageError.notConfigured` 或 `UsageError.networkError` |
| OAuth refresh 失败 | `CodexTokenRefresher.RefreshError` → 适配层保留原 `UsageError` 类型 |
| 解析 codexbar 响应失败 | 抛 `UsageError.invalidResponse` |
| 老 keychain 残留存在但格式不识别 | 静默丢弃；用户重连 |

错误信息走 `AppLanguage.errorDescription(for:)` 现有本地化路径。

---

## 9. 测试

### 9.1 单元测试（`AIQuotaBar/Tests/Codex/` 目录，新）

- `CodexUsageDataMapperTests`：用 fixtures 验证 `UsageSnapshot` → `UsageData` 转换
  - 仅 primary / 仅 secondary / 同时有 / 同时有 additional / 含 credits / credits unlimited
  - identity 缺失 / plan_type 缺失
  - `usedPercent = 0` / `usedPercent = 100` 边界
- `CodexDataSourceModeTests`：枚举 rawValue 持久化往返

### 9.2 手动验证

按项目 dev 流程（`make build && make run` + 状态栏交互）逐项：

1. 启动后无任何 Codex 凭证 → Menu Bar 显示 "Codex 未配置" 占位
2. 添加 OAuth 账号（粘 accessToken）→ 拉取 5h / Weekly / additional（如有）/ credits
3. 添加 Web 账号（导入 cookie）→ 拉取成功
4. source mode 切到 OAuth → CLI 不可用场景下不报错
5. source mode 切到 CLI（需 `codex` 二进制）→ 拉取成功
6. source mode 切到 auto → OAuth token 故意失效 → 触发 CLI 回退
7. 多账号（≥ 2）→ MenuView 各自一段卡片，accountName 正确
8. 5h 用尽（让 primary 100%）→ 菜单栏 fallback 到 Weekly
9. 全部用尽 → 菜单栏 fallback 到下一账号
10. 老 keychain 残留 → 启动时被清，UI 不再尝试使用
11. plan_type 缺失 / additional 缺失 / credits 缺失 → UI 不崩
12. OAuth token 过期（手动改 auth.json）→ 触发 refresh；如 refresh 失败 → 报错
13. 云备份仍正常（UsageData schema 不变）
14. 警告面板 / 通知 / auto-launch 不受影响

### 9.3 回归

- MiniMax 拉取、GLM 拉取、菜单栏刷新频率、设置保存 / 加载、右键循环、显示格式切换

---

## 10. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Swift toolchain mismatch（5.9 vs 6.2） | 升级 ai-quota-bar/Package.swift 到 `swift-tools-version: 6.2`；本机 6.3.2 兼容 |
| `SweetCookieKit` 首次拉取失败 | 明确写进 README；提供 `CODEXBAR_USE_LOCAL_SWEETCOOKIEKIT=1` env var 备选 |
| codexbar `CodexBarCore` 公共 API 后续变动 | 单向参考承诺，不做自动同步；如必须跟进，由人工 cherry-pick |
| 老用户丢凭证体验差 | Release notes 显式提示；启动时 banner 告知"Codex 已重写，请重新连接" |
| codexbar Codex 子系统持续演化（我们不跟进） | 把这个约束写入 spec 顶部；README 中标"参考 codexbar v0.x 实现" |
| 升级 Swift toolchain 引入新编译警告 | 单独 commit 处理；不混入本次重写 |

---

## 11. 实施分阶段（一次 worktree 跑完）

1. **依赖接入**：改 `Package.swift`，跑 `swift build` 验证 CodexBarCore 可用
2. **provider 改名**：`UsageProvider.chatGPT` → `.codex`，同步引用
3. **删旧代码**：`ChatGPTCredential.swift` 删除；`UsageService.swift` chatGPT 分支替换为 `CodexService` 调用
4. **写适配层**：`CodexDataSourceMode` / `CodexService` / `CodexUsageDataMapper` / `CodexAccountCoordinator`
5. **写迁移**：`AppMigration` 加丢弃老 keychain
6. **Settings 改造**：Codex 段（source mode + accounts）
7. **MenuView 改造**：Codex 卡片新字段
8. **写单元测试**：mapper tests + mode tests
9. **手动验证**：按 §9.2 逐项
10. **回归**：MiniMax / GLM / 云备份 / 警告

每个阶段独立 commit；commit message 中文，参考 `CLAUDE.md` 格式。

---

## 12. 验收标准

- `swift build -c release` 通过
- `make app && make sign && make install` 可生成可运行 app
- 启动后无 Codex 凭证 → 显示 "Codex 未配置" 占位
- 配 OAuth 凭证后 → 菜单栏 / 下拉显示 5h / Weekly / additional / credits（如有）
- source mode 切换立即生效
- 多账号并行显示
- 老 keychain 残留被清
- MiniMax / GLM 完全不受影响
- 云备份 schema 不变
- 单测全部通过
- 手动验证 §9.2 全部通过
