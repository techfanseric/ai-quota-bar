# Phase 0 / S1：CodexBarCore 使用面切割清单

- 日期：2026-09-24（macOS 侧静态分析，未运行 dotnet / git）
- 分析对象：`.dependencies/codexbar/Sources/CodexBarCore`（690 个 Swift 文件，180,494 行，wc -l 口径）
- 使用方：`AIQuotaBar/`（含 `AIQuotaBar/Tests/`）中 `import CodexBarCore` 的 23 个文件（已确认仓库内无其他使用方；`UsageAccountObservation` 等来自应用自有 target `CodexLocalUsageCore`，不在本清单范围）
- 产出脚本（未入仓库）：`/tmp/cutlist/analyze*.py`、`/tmp/cutlist/gen_report.py`

## 1. 结论数字

| 口径 | 文件数 | 行数 | 说明 |
|---|---|---|---|
| **PORT**（App 直接使用其公共 API） | **25** | **10,914** | App 源码中出现其公共类型/函数 |
| **DEPENDS（裁剪后）**（PORT 的传递依赖） | **238** | **83,206** | 排除 ProviderManifest 级联（见 §3 裁剪点） |
| **DEPENDS（严格编译闭包）** | 532 | 142,172 | 若照搬 `ProviderManifest` 全量注册则需全部存在 |
| SKIP | 133 | 27,408 | 完全未用到（其余 294 个文件仅因 manifest 注册被拉入，归入上一行的差额） |

- **建议 C# 移植面（PORT ∪ 裁剪后 DEPENDS）＝ 263 个文件 / 94,120 行 ≈ 全库的 52%**。
- 若进一步执行 §8 的二级裁剪（去掉 UsageSnapshot 的其他 provider 专属字段、stub 插件系统），估计可再砍约 25k 行（其他 provider 60 文件/20,707 行 + Plugins 8 文件/4,347 行的大部）；若进一步断开 Claude（35 文件/15,313 行）与 CostUsage vendored（14 文件/12,946 行），合计可超 50k 行。

## 2. 方法与可信度

1. 枚举 CodexBarCore 全部顶层声明（`class/struct/enum/protocol/actor/typealias/func`，含 public 标记）；嵌套类型不进跨文件符号表（只能经 `Outer.Inner` 限定访问，已由 Outer 解析覆盖）。
2. 使用方语料 = 23 个 `import CodexBarCore` 文件的全文。符号必须出现在**使用位置**才计入：构造调用 `Name(`、静态访问 `Name.`、`Name.self`、类型位置 `: Name` / `-> Name` / `[Name` / `<Name`、`some/any/as/is Name`。纯注释/散文中的同名词不计。
3. 排除 App 本地同名类型遮蔽（如 App 自有 `UsageError`、`KimiWebSession`、`KeychainService`、`QuotaConsumptionForecaster`）。
4. 传递闭包：对 PORT 文件用同样的使用位置模式在整个 CodexBarCore 符号表上迭代至不动点；同名符号定义于多文件时按全部候选连边（轻微过拟合方向）。
5. 局限：未做 Swift 编译器级的精确解析；字符串/反射引用无法覆盖；DEPENDS 是**上界近似**，PORT 是**下界**（已抽查 CodexService/KimiService/KimiCLIStatusProbe 等主要使用方逐行核对）。

## 3. 关键结构发现：ProviderManifest 级联

- `Providers/ProviderDescriptor.swift`（PORT）内的 `ProviderDescriptorRegistry.store` 静态初始化时遍历 `ProviderManifest.allDescriptors`（生成文件，硬编码全部 ~60 家 provider 的 descriptor）。
- 这是真实编译期依赖：照搬会把 60 家 provider 的 fetcher/models/settings（如 MiniMax 16 文件、Alibaba 15 文件、Grok 13 文件…）全部拖入 → 532 文件/142k 行。
- **建议裁剪点（SEVER）**：C# 侧把注册表改为只注册 App 实际用到的 Codex / Kimi /（可选）Claude descriptor。App 从不调用 `ProviderManifest`，只通过 `CodexProviderDescriptor.descriptor` 直取。

## 4. App 实际使用的公共 API 面（按使用方文件）

| App 文件（AIQuotaBar/…） | 使用的 CodexBarCore 符号 |
|---|---|
| `Services/Codex/CodexService.swift` | ProviderDescriptor, CodexProviderDescriptor, UsageFetcher, ProviderFetchContext, BrowserDetection, ClaudeUsageFetcher, CodexOAuthFetchError |
| `Services/Codex/CodexAccountCoordinator.swift` | FileManagedCodexAccountStore, ManagedCodexAccount(Set), CodexAuthFingerprint |
| `Services/Codex/CodexSubscriptionStatus.swift` | UsageSnapshot |
| `Services/Codex/CodexUsageDataMapper.swift` | UsageSnapshot, CreditsSnapshot, RateWindow, UsageFormatter, CodexPlanFormatting |
| `Services/Codex/CodexDataSourceMode.swift` | ProviderSourceMode（唯一 `CodexBarCore.` 限定引用） |
| `Services/Kimi/KimiService.swift` | UsageSnapshot, UsageFetcher, KimiUsageFetcher, KimiSettingsReader, KimiAPIError |
| `Services/Kimi/KimiCLIStatusProbe.swift` | TTYCommandRunner, TextParsing, UsageSnapshot, RateWindow |
| `Services/Kimi/KimiWebUsageClient.swift` | KimiUsageDetail, UsageSnapshot, RateWindow, NamedRateWindow |
| `Services/Kimi/KimiDesktopSessionReader.swift` | KimiDesktopAuthToken |
| `Services/Kimi/KimiBrowserSessionDiscovery.swift` | KimiCookieImporter, ProviderInteractionContext |
| `Services/Kimi/KimiUsageDataMapper.swift` | UsageSnapshot, RateWindow |
| `Settings/Components/CodexSettingsSection.swift` | CodexPlanFormatting |
| `Settings/Components/KimiSourceSection.swift` | BrowserCookieAccessGate, KimiCookieImporter, ProviderInteractionContext |
| `Models/UsageData.swift` | UsagePace |
| `Models/AppLanguage.swift` | UsagePace |
| `Views/MenuView.swift` | UsagePace |
| `Services/MobileDashboard/MobileDashboardSnapshotBuilder.swift` | UsagePace |
| `Tests/Codex/*（2 文件）` | UsageSnapshot, CreditsSnapshot, RateWindow, NamedRateWindow, ProviderIdentitySnapshot |
| `Tests/Kimi/*（4 文件）` | UsageSnapshot, RateWindow, Browser |

注：`KimiWebSession`、`KimiBrowserSessionDiscovery`、`KeychainService`、`QuotaConsumptionForecaster`、`UsageData/UsageError` 均为 App 本地类型，勿混淆。

## 5. PORT 完整清单（25 文件）

| # | 文件 | 行数 | App 使用的符号 | 平台特征 |
|---|---|---|---|---|
| 1 | `UsageFetcher.swift` | 1,535 | NamedRateWindow, RateWindow, UsageFetcher, UsageSnapshot | GCD Process |
| 2 | `UsageFormatter.swift` | 514 | UsageFormatter |  |
| 3 | `BrowserCookieAccessGate.swift` | 452 | BrowserCookieAccessGate | os_log |
| 4 | `BrowserDetection.swift` | 439 | BrowserDetection | Darwin os_log |
| 5 | `CreditsModels.swift` | 378 | CreditsSnapshot | CryptoKit |
| 6 | `UsagePace.swift` | 263 | UsagePace |  |
| 7 | `CodexManagedAccounts.swift` | 177 | CodexAuthFingerprint, ManagedCodexAccount, ManagedCodexAccountSet |  |
| 8 | `ManagedCodexAccountStore.swift` | 113 | FileManagedCodexAccountStore |  |
| 9 | `TextParsing.swift` | 88 | TextParsing |  |
| 10 | `BrowserCookieImportOrder.swift` | 66 | Browser |  |
| 11 | `ProviderIdentitySnapshot.swift` | 46 | ProviderIdentitySnapshot |  |
| 12 | `Providers/ProviderDescriptor.swift` | 440 | ProviderDescriptor |  |
| 13 | `Providers/ProviderFetchPlan.swift` | 423 | ProviderFetchContext |  |
| 14 | `Providers/ProviderInteractionContext.swift` | 33 | ProviderInteractionContext |  |
| 15 | `Providers/Claude/ClaudeUsageFetcher.swift` | 1,614 | ClaudeUsageFetcher | Process |
| 16 | `Providers/Codex/CodexProviderDescriptor.swift` | 984 | CodexProviderDescriptor |  |
| 17 | `Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift` | 803 | CodexOAuthFetchError | FndNetworking |
| 18 | `Providers/Codex/CodexPlanFormatting.swift` | 59 | CodexPlanFormatting |  |
| 19 | `Providers/Kimi/KimiUsageFetcher.swift` | 417 | KimiUsageFetcher | FndNetworking |
| 20 | `Providers/Kimi/KimiModels.swift` | 237 | KimiUsageDetail |  |
| 21 | `Providers/Kimi/KimiSettingsReader.swift` | 189 | KimiSettingsReader |  |
| 22 | `Providers/Kimi/KimiDesktopAuthToken.swift` | 140 | KimiDesktopAuthToken | SQLite |
| 23 | `Providers/Kimi/KimiCookieImporter.swift` | 129 | KimiCookieImporter |  |
| 24 | `Providers/Kimi/KimiAPIError.swift` | 41 | KimiAPIError |  |
| 25 | `Host/PTY/TTYCommandRunner.swift` | 1,334 | TTYCommandRunner | Darwin PTY Process |

## 6. DEPENDS 完整清单（裁剪后 238 文件，按目录分组）

「拉入依据」列为被哪个文件的哪个符号引到（取一条样例）。`←` 读作“被 … 引用”。


### CodexBarCore 根目录（核心模型与工具）（47 文件 / 16,819 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 1 | `CostUsageFetcher.swift` | 1,708 | `CostUsageFetcher` ← Providers/OpenCodeGo/OpenCodeGoUsageSnapshot.swift |  |
| 2 | `CookieHeaderCache.swift` | 1,432 | `CookieHeaderCache` ← Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift | CryptoKit Darwin |
| 3 | `PathEnvironment.swift` | 1,311 | `BinaryLocator` ← Providers/Codex/CodexProviderDescriptor.swift | Darwin GCD Process |
| 4 | `CostUsageModels.swift` | 1,302 | `CostUsageTokenSnapshot` ← UsageFetcher.swift |  |
| 5 | `CodexLocalProjectUsageIndexer.swift` | 1,257 | `CodexLocalProjectUsageIndexer` ← CostUsageFetcher.swift |  |
| 6 | `PiSessionCostScanner.swift` | 1,115 | `PiSessionCostScanner` ← CostUsageFetcher.swift |  |
| 7 | `CodexWorkspaceUsageSidecar.swift` | 994 | `CodexWorkspaceUsageSidecar` ← CostUsageFetcher.swift | SQLite |
| 8 | `KeychainCacheStore.swift` | 960 | `KeychainCacheStore` ← KeychainSecurity.swift | Darwin Keychain |
| 9 | `CodexModelsAnalyticsModels.swift` | 883 | `CodexModelsUsageFragment` ← CodexLocalProjectUsageIndexer.swift |  |
| 10 | `CodexLocalProjectUsageModels.swift` | 676 | `CodexLocalProjectUsageSnapshot` ← CostUsageFetcher.swift |  |
| 11 | `OpenAIDashboardModels.swift` | 429 | `OpenAIDashboardSnapshot` ← Providers/ProviderFetchPlan.swift |  |
| 12 | `KeychainAccessPreflight.swift` | 406 | `KeychainAccessPreflight` ← BrowserCookieAccessGate.swift | Darwin Keychain |
| 13 | `WidgetSnapshot.swift` | 390 | `WidgetSnapshot` ← Providers/ProviderUsagePresentation.swift |  |
| 14 | `ProviderDetailSection.swift` | 339 | `ProviderDetailSection` ← UsageFetcher.swift |  |
| 15 | `CodexThreadCatalogReader.swift` | 261 | `CodexThreadCatalog` ← CodexWorkspaceUsageSidecar.swift | SQLite |
| 16 | `CostProvenance.swift` | 258 | `CostProvenance` ← CostUsageModels.swift |  |
| 17 | `ProviderEndpointOverrideValidator.swift` | 256 | `ProviderEndpointOverrideValidator` ← Providers/Kimi/KimiUsageFetcher.swift |  |
| 18 | `AppGroupSupport.swift` | 247 | `AppGroupSupport` ← KeychainAccessGate.swift |  |
| 19 | `ProviderHTTPClient.swift` | 247 | `ProviderHTTPTransport` ← Providers/Kimi/KimiUsageFetcher.swift | FndNetworking |
| 20 | `TokenAccounts.swift` | 195 | `ProviderTokenAccount` ← Providers/ProviderCredentialAdapter.swift |  |
| 21 | `CodexCredentialFileAccess.swift` | 185 | `CodexCredentialFileAccess` ← CodexManagedAccounts.swift |  |
| 22 | `KeychainAccessGate.swift` | 170 | `KeychainAccessGate` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 23 | `CostUsageScanExecutor.swift` | 164 | `CostUsageScanExecutor` ← CostUsageFetcher.swift | GCD |
| 24 | `CurrencyExchange.swift` | 160 | `CurrencyExchange` ← UsageFormatter.swift | FndNetworking |
| 25 | `KeychainSecurity.swift` | 150 | `KeychainTestSafety` ← BrowserCookieAccessGate.swift | Keychain |
| 26 | `TokenAccountSupport.swift` | 129 | `TokenAccountSupport` ← Providers/ProviderCredentialAdapter.swift |  |
| 27 | `PiSessionCostCache.swift` | 124 | `PiSessionCostCacheIO` ← PiSessionCostScanner.swift |  |
| 28 | `CodexBarCoreResources.swift` | 105 | `CodexBarCoreResources` ← Plugins/UserProviderPlugins.swift | Bundle.module Darwin |
| 29 | `ProviderCostSnapshot.swift` | 93 | `ProviderCostSnapshot` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 30 | `CookieHeaderNormalizer.swift` | 92 | `CookieHeaderNormalizer` ← Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift |  |
| 31 | `CredentialFileWriter.swift` | 84 | `CredentialFileWriter` ← ManagedCodexAccountStore.swift | Darwin |
| 32 | `BrowserCookieProfiles.swift` | 67 | `BrowserCookieProfiles` ← Providers/Kimi/KimiCookieImporter.swift |  |
| 33 | `CodexLocalDataScope.swift` | 64 | `CodexLocalDataScope` ← CostUsageFetcher.swift |  |
| 34 | `CodexLocalProjectRootResolver.swift` | 64 | `CodexLocalProjectRootResolver` ← CodexLocalProjectUsageIndexer.swift | CryptoKit |
| 35 | `ChromiumLocalStorageDiscovery.swift` | 58 | `ChromiumLocalStorageDiscovery` ← Providers/Windsurf/WindsurfDevinSessionImporter.swift |  |
| 36 | `CodexModelsTelemetry.swift` | 57 | `CodexModelsTelemetry` ← CodexLocalProjectUsageIndexer.swift | os_log |
| 37 | `CookiePropertyJSON.swift` | 54 | `CookiePropertyJSON` ← Providers/Cursor/CursorStatusProbe.swift | FndNetworking |
| 38 | `OpenAISubscriptionMetadataModels.swift` | 52 | `OpenAISubscriptionMetadata` ← OpenAIDashboardModels.swift |  |
| 39 | `CodexExecutableResolver.swift` | 51 | `CodexExecutableResolver` ← UsageFetcher.swift |  |
| 40 | `AsyncOperationGate.swift` | 45 | `AsyncOperationGate` ← Providers/Claude/ClaudeCLISession.swift | actor |
| 41 | `CodexHomeScope.swift` | 43 | `CodexHomeScope` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 42 | `KeychainNoUIQuery.swift` | 41 | `KeychainNoUIQuery` ← KeychainAccessPreflight.swift | Darwin |
| 43 | `ProviderSessionStoreFile.swift` | 30 | `ProviderSessionStoreFile` ← Providers/Cursor/CursorStatusProbe.swift |  |
| 44 | `UsagePercent.swift` | 24 | `UsagePercent` ← UsageFetcher.swift |  |
| 45 | `FormURLEncoding.swift` | 22 | `FormURLEncoding` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift |  |
| 46 | `ProviderTransportError.swift` | 13 | `ProviderTransportError` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 47 | `ISO8601DateParser.swift` | 12 | `ISO8601DateParser` ← Providers/Claude/ClaudeUsageFetcher.swift |  |

### Providers/(共享)（13 文件 / 2,666 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 48 | `Providers/ProviderUsagePresentation.swift` | 643 | `ProviderIdentityPresentation` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 49 | `Providers/ProviderDiagnosticExport.swift` | 585 | `ProviderDiagnosticAuthSummary` ← Providers/ProviderCredentialAdapter.swift |  |
| 50 | `Providers/ProviderVersionDetector.swift` | 339 | `ProviderVersionDetector` ← Providers/Codex/CodexProviderDescriptor.swift | Darwin Process |
| 51 | `Providers/ProviderCredentialAdapter.swift` | 310 | `ProviderCredentialAdapter` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 52 | `Providers/Providers.swift` | 243 | `UsageProvider` ← UsageFormatter.swift |  |
| 53 | `Providers/ProviderSettingsSnapshot.swift` | 217 | `ProviderSettingsSectionRegistration` ← Providers/ProviderDescriptor.swift |  |
| 54 | `Providers/ProviderBranding.swift` | 87 | `ProviderColor` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 55 | `Providers/ProviderCLIConfig.swift` | 64 | `ProviderCLIConfig` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 56 | `Providers/ProviderInstanceID.swift` | 53 | `ProviderInstanceID` ← UsageFetcher.swift |  |
| 57 | `Providers/ProviderTokenResolver.swift` | 43 | `ProviderTokenResolution` ← Providers/ProviderCredentialAdapter.swift |  |
| 58 | `Providers/ProviderCandidateRetryRunner.swift` | 31 | `ProviderCandidateRetryRunnerError` ← Providers/Ollama/OllamaUsageFetcher.swift |  |
| 59 | `Providers/ProviderCookieSource.swift` | 26 | `ProviderCookieSource` ← Providers/ProviderCredentialAdapter.swift |  |
| 60 | `Providers/ProviderCookieSettingsResolver.swift` | 25 | `ProviderCookieSettingsResolver` ← Providers/ProviderCredentialAdapter.swift |  |

### Providers/Alibaba（1 文件 / 128 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 61 | `Providers/Alibaba/AlibabaTokenPlanAPIRegion.swift` | 128 | `AlibabaTokenPlanAPIRegion` ← Config/CodexBarConfig.swift |  |

### Providers/Antigravity（5 文件 / 2,575 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 62 | `Providers/Antigravity/AntigravityCLISession.swift` | 1,305 | `AntigravityCLISession` ← Providers/ProviderFetchPlan.swift | Darwin PTY actor |
| 63 | `Providers/Antigravity/AntigravityOAuthCredentialsStore.swift` | 525 | `AntigravityOAuthConfig` ← Providers/Gemini/GeminiConsumerTierMigration.swift |  |
| 64 | `Providers/Antigravity/AntigravityProtoReader.swift` | 320 | `AntigravityProtoReader` ← Providers/Antigravity/AntigravityLocalReader.swift |  |
| 65 | `Providers/Antigravity/AntigravityLocalReader.swift` | 314 | `AntigravityLocalReader` ← CostUsageFetcher.swift |  |
| 66 | `Providers/Antigravity/AntigravityStatusProbe+ResponseModels.swift` | 111 | `PlanStatus` ← Providers/Windsurf/WindsurfWebFetcher.swift |  |

### Providers/Bedrock（6 文件 / 1,170 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 67 | `Providers/Bedrock/BedrockUsageStats.swift` | 503 | `BedrockUsageFetcher` ← CostUsageFetcher.swift | FndNetworking |
| 68 | `Providers/Bedrock/BedrockCloudWatchUsage.swift` | 231 | `BedrockClaudeActivity` ← Providers/Bedrock/BedrockUsageStats.swift | FndNetworking |
| 69 | `Providers/Bedrock/BedrockAWSSigner.swift` | 179 | `BedrockAWSSigner` ← Providers/Bedrock/BedrockUsageStats.swift | CryptoKit FndNetworking |
| 70 | `Providers/Bedrock/BedrockSettingsReader.swift` | 92 | `BedrockSettingsReader` ← Providers/Bedrock/BedrockUsageStats.swift |  |
| 71 | `Providers/Bedrock/BedrockProfileCredentialProvider.swift` | 87 | `BedrockProfileCredentialProvider` ← Providers/Bedrock/BedrockCredentialResolver.swift |  |
| 72 | `Providers/Bedrock/BedrockCredentialResolver.swift` | 78 | `BedrockCredentialResolver` ← CostUsageFetcher.swift |  |

### Providers/Claude（34 文件 / 13,699 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 73 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift` | 3,374 | `ClaudeOAuthCredentialsStore` ← Providers/Claude/ClaudeUsageFetcher.swift | FndNetworking Keychain |
| 74 | `Providers/Claude/ClaudeStatusProbe.swift` | 1,507 | `ClaudeStatusSnapshot` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 75 | `Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift` | 1,451 | `ClaudeWebAPIFetcher` ← Providers/Claude/ClaudeUsageFetcher.swift | FndNetworking |
| 76 | `Providers/Claude/ClaudeProviderDescriptor.swift` | 1,228 | `ClaudeCLIBackgroundAvailability` ← Providers/ProviderVersionDetector.swift |  |
| 77 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthDelegatedRefreshCoordinator.swift` | 771 | `ClaudeOAuthDelegatedRefreshCoordinator` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 78 | `Providers/Claude/ClaudeCLISession.swift` | 612 | `ClaudeCLISession` ← Providers/Claude/ClaudeUsageFetcher.swift | Darwin PTY Process actor |
| 79 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthRefreshFailureGate.swift` | 589 | `ClaudeOAuthRefreshFailureGate` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift | os_log |
| 80 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthPendingCacheClearStore.swift` | 443 | `ClaudeOAuthPendingCacheClearStore` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift | Darwin |
| 81 | `Providers/Claude/ClaudeAdminAPIUsageFetcher.swift` | 432 | `ModelAccumulator` ← Providers/OpenAI/OpenAIAPIUsageSnapshot.swift | FndNetworking |
| 82 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift` | 428 | `ClaudeOAuthFetchError` ← Providers/Claude/ClaudeUsageFetcher.swift | FndNetworking |
| 83 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentialModels.swift` | 305 | `ClaudeOAuthCredentials` ← Providers/Claude/ClaudeUsageFetcher.swift | CryptoKit |
| 84 | `Providers/Claude/ClaudeAdminAPIUsageSnapshot.swift` | 271 | `ClaudeAdminAPIUsageSnapshot` ← Providers/Claude/ClaudeAdminAPIUsageFetcher.swift |  |
| 85 | `Providers/Claude/ClaudeSourcePlanner.swift` | 235 | `ClaudeSourcePlanningInput` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 86 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainPromptMode.swift` | 217 | `ClaudeOAuthKeychainPromptMode` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 87 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainAccessGate.swift` | 211 | `ClaudeOAuthKeychainAccessGate` ← Providers/Claude/ClaudeUsageFetcher.swift | os_log |
| 88 | `Providers/Claude/ClaudePlan.swift` | 195 | `ClaudePlan` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 89 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainPreAlertGate.swift` | 169 | `ClaudeOAuthKeychainPreAlertGate` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift | os_log |
| 90 | `Providers/Claude/ClaudeCLIUsageSpawnThrottle.swift` | 132 | `ClaudeCLIUsageSpawnThrottle` ← Providers/Claude/ClaudeProviderDescriptor.swift |  |
| 91 | `Providers/Claude/ClaudeAccountProfile.swift` | 102 | `ClaudeAccountProfile` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift | CryptoKit |
| 92 | `Providers/Claude/ClaudeCredentialRouting.swift` | 102 | `ClaudeCredentialRouting` ← TokenAccountSupport.swift |  |
| 93 | `Providers/Claude/ClaudeUsageFetcher+DelegatedRefreshMessages.swift` | 100 | `ClaudeOAuthUnreadableCredentialsError` ← Providers/Claude/ClaudeProviderDescriptor.swift |  |
| 94 | `Providers/Claude/ClaudeWeb/ClaudeWebExtraRateWindowParser.swift` | 97 | `ClaudeWebExtraRateWindowParser` ← Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift |  |
| 95 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageRateLimitGate.swift` | 89 | `ClaudeOAuthUsageRateLimitGate` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift |  |
| 96 | `Providers/Claude/ClaudeCLIAuthStatusProbe.swift` | 88 | `ClaudeCLIAuthStatusProbe` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 97 | `Providers/Claude/ClaudeConfigPaths.swift` | 88 | `ClaudeConfigPaths` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift |  |
| 98 | `Providers/Claude/ClaudeScopedWeeklyLimitMapper.swift` | 72 | `ClaudeScopedWeeklyLimitMapper` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 99 | `Providers/Claude/ClaudeProbeSessionArtifactCleaner.swift` | 70 | `ClaudeProbeSessionArtifactCleaner` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 100 | `Providers/Claude/ClaudeCLIRateLimitGate.swift` | 64 | `ClaudeCLIRateLimitGate` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 101 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthDirectKeychainReadConsent.swift` | 62 | `ClaudeOAuthDirectKeychainReadConsent` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift |  |
| 102 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainReadStrategy.swift` | 49 | `ClaudeOAuthKeychainReadStrategyPreference` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 103 | `Providers/Claude/ClaudeProviderSettings.swift` | 45 | `ClaudeProviderSettings` ← Providers/Claude/ClaudeProviderDescriptor.swift |  |
| 104 | `Providers/Claude/ClaudeUsageDataSource.swift` | 38 | `ClaudeUsageDataSource` ← Providers/Claude/ClaudeUsageFetcher.swift |  |
| 105 | `Providers/Claude/ClaudeAdminAPISettingsReader.swift` | 32 | `ClaudeAdminAPISettingsReader` ← Providers/Claude/ClaudeProviderDescriptor.swift |  |
| 106 | `Providers/Claude/ClaudeOAuth/ClaudeOAuthKeychainQueryTiming.swift` | 31 | `ClaudeOAuthKeychainQueryTiming` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift |  |

### Providers/Codebuff（5 文件 / 739 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 107 | `Providers/Codebuff/CodebuffUsageFetcher.swift` | 358 | `CodebuffUsageFetcher` ← Providers/Codebuff/CodebuffProviderDescriptor.swift | FndNetworking |
| 108 | `Providers/Codebuff/CodebuffUsageSnapshot.swift` | 149 | `CodebuffUsageSnapshot` ← Providers/Codebuff/CodebuffUsageFetcher.swift |  |
| 109 | `Providers/Codebuff/CodebuffProviderDescriptor.swift` | 121 | `CodebuffSettingsError` ← Providers/Codebuff/CodebuffSettingsReader.swift |  |
| 110 | `Providers/Codebuff/CodebuffSettingsReader.swift` | 71 | `CredentialsFile` ← Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift |  |
| 111 | `Providers/Codebuff/CodebuffUsageError.swift` | 40 | `CodebuffUsageError` ← Providers/Codebuff/CodebuffProviderDescriptor.swift |  |

### Providers/Codex（28 文件 / 4,546 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 112 | `Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift` | 593 | `CodexOAuthCredentials` ← Providers/Codex/CodexProviderDescriptor.swift | Darwin |
| 113 | `Providers/Codex/CodexAccountReconciliation.swift` | 536 | `AccountIdentity` ← Providers/Claude/ClaudeStatusProbe.swift |  |
| 114 | `Providers/Codex/CodexCLISession.swift` | 375 | `CodexCLISession` ← Providers/Codex/CodexStatusProbe.swift | Darwin PTY Process actor |
| 115 | `Providers/Codex/CodexWebDashboardStrategy.swift` | 369 | `CodexWebDashboardStrategy` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 116 | `Providers/Codex/CodexDashboardAuthority.swift` | 354 | `CodexDashboardKnownOwnerCandidate` ← Providers/Codex/CodexProviderSettings.swift |  |
| 117 | `Providers/Codex/CodexStatusProbe.swift` | 294 | `CodexStatusSnapshot` ← UsageFetcher.swift |  |
| 118 | `Providers/Codex/CodexCLIBackendConfiguration.swift` | 207 | `CodexCLIBackendRateLimitError` ← UsageFetcher.swift |  |
| 119 | `Providers/Codex/CodexReconciledState.swift` | 194 | `CodexReconciledState` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 120 | `Providers/Codex/CodexPAT/CodexPATFetchStrategy.swift` | 185 | `CodexPATFetchStrategy` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 121 | `Providers/Codex/CodexPAT/CodexPATUsageFetcher.swift` | 155 | `CodexPATWhoami` ← Providers/Codex/CodexPAT/CodexPATFetchStrategy.swift | FndNetworking |
| 122 | `Providers/Codex/CodexSpendControlsMonthlyUsage.swift` | 145 | `CodexSpendControlsMonthlyUsageResponse` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 123 | `Providers/Codex/CodexExtraUsageCost.swift` | 135 | `CodexExtraUsageCost` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 124 | `Providers/Codex/CodexOAuth/CodexTokenRefresher.swift` | 125 | `CodexTokenRefresher` ← Providers/Codex/CodexProviderDescriptor.swift | FndNetworking |
| 125 | `Providers/Codex/CodexOpenAIWorkspaceResolver.swift` | 123 | `CodexOpenAIWorkspaceIdentity` ← Providers/Codex/CodexOpenAIWorkspaceIdentityCache.swift | FndNetworking |
| 126 | `Providers/Codex/CodexOpenAIWorkspaceIdentityCache.swift` | 119 | `CodexOpenAIWorkspaceIdentityCache` ← Providers/Codex/CodexSystemAccountObserver.swift |  |
| 127 | `Providers/Codex/CodexCLILaunchGate.swift` | 70 | `CodexCLILaunchGate` ← UsageFetcher.swift | PTY |
| 128 | `Providers/Codex/CodexSystemAccountObserver.swift` | 69 | `ObservedSystemCodexAccount` ← Providers/Codex/CodexAccountReconciliation.swift |  |
| 129 | `Providers/Codex/CodexCLIDashboardAuthorityContext.swift` | 66 | `CodexCLIDashboardAuthorityContext` ← Providers/Codex/CodexWebDashboardStrategy.swift |  |
| 130 | `Providers/Codex/CodexRateWindowNormalizer.swift` | 66 | `CodexRateWindowNormalizer` ← Providers/Codex/CodexReconciledState.swift |  |
| 131 | `Providers/Codex/CodexProviderSettings.swift` | 62 | `CodexProviderSettingsKey` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 132 | `Providers/Codex/CodexAuthenticatedHTTPTransport.swift` | 57 | `CodexAuthenticatedHTTPTransport` ← Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift | FndNetworking |
| 133 | `Providers/Codex/CodexPAT/CodexCLIUserAgent.swift` | 54 | `CodexCLIUserAgent` ← Providers/Codex/CodexPAT/CodexPATUsageFetcher.swift |  |
| 134 | `Providers/Codex/CodexIdentity.swift` | 47 | `CodexIdentityResolver` ← UsageFetcher.swift |  |
| 135 | `Providers/Codex/CodexStatusProbeIsolation.swift` | 46 | `CodexStatusProbeIsolation` ← Providers/Codex/CodexStatusProbe.swift |  |
| 136 | `Providers/Codex/CodexSpendControlNumber.swift` | 36 | `CodexSpendControlNumber` ← UsageFetcher.swift |  |
| 137 | `Providers/Codex/CodexUsageDataSource.swift` | 34 | `CodexUsageDataSource` ← Providers/Codex/CodexProviderDescriptor.swift |  |
| 138 | `Providers/Codex/CodexStatusMarkers.swift` | 19 | `CodexStatusMarkers` ← Host/PTY/TTYCommandRunner.swift |  |
| 139 | `Providers/Codex/CodexPAT/CodexPATCredentials.swift` | 11 | `CodexPATCredentials` ← Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift |  |

### Providers/Cursor（7 文件 / 3,273 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 140 | `Providers/Cursor/CursorStatusProbe.swift` | 1,625 | `CursorStatusProbe` ← CostUsageFetcher.swift | FndNetworking actor |
| 141 | `Providers/Cursor/CursorUsageEventsFetcher.swift` | 857 | `CursorUsageEventsFetcher` ← Providers/Cursor/CursorStatusProbe.swift | FndNetworking |
| 142 | `Providers/Cursor/CursorAppAuth.swift` | 369 | `CursorSessionIdentity` ← Providers/Cursor/CursorStatusProbe.swift | FndNetworking SQLite |
| 143 | `Providers/Cursor/CursorLocalCSVReader.swift` | 200 | `CursorLocalCSVReader` ← CostUsageFetcher.swift |  |
| 144 | `Providers/Cursor/CursorTeamSpend.swift` | 137 | `CursorTeamSpend` ← Providers/Cursor/CursorStatusProbe.swift | FndNetworking |
| 145 | `Providers/Cursor/CursorSandUsage.swift` | 62 | `CursorSandUsageStatus` ← Providers/Cursor/CursorStatusProbe.swift |  |
| 146 | `Providers/Cursor/CursorRequestUsage.swift` | 23 | `CursorRequestUsage` ← Providers/Cursor/CursorStatusProbe.swift |  |

### Providers/DeepSeek（3 文件 / 2,073 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 147 | `Providers/DeepSeek/DeepSeekUsageCostParser.swift` | 1,040 | `DeepSeekUsageSummary` ← Providers/DeepSeek/DeepSeekUsageFetcher.swift |  |
| 148 | `Providers/DeepSeek/DeepSeekUsageFetcher.swift` | 991 | `DeepSeekDetailedUsageState` ← UsageFetcher.swift | FndNetworking |
| 149 | `Providers/DeepSeek/DeepSeekPlatformBalanceOwner.swift` | 42 | `DeepSeekPlatformBalanceOwner` ← UsageFetcher.swift | CryptoKit |

### Providers/Devin（3 文件 / 1,040 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 150 | `Providers/Devin/DevinSessionImporter.swift` | 440 | `DevinSessionImporter` ← Providers/Windsurf/WindsurfWebFetcher.swift |  |
| 151 | `Providers/Devin/DevinUsageSnapshot.swift` | 340 | `DevinUsageError` ← Providers/Devin/DevinUsageFetcher.swift |  |
| 152 | `Providers/Devin/DevinUsageFetcher.swift` | 260 | `DevinUsageFetcher` ← Providers/Devin/DevinSessionImporter.swift | FndNetworking |

### Providers/Gemini（4 文件 / 1,709 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 153 | `Providers/Gemini/GeminiStatusProbe.swift` | 1,505 | `GeminiStatusProbe` ← Providers/Gemini/GeminiProviderDescriptor.swift | Darwin FndNetworking GCD Process |
| 154 | `Providers/Gemini/GeminiProviderDescriptor.swift` | 89 | `GeminiProviderDescriptor` ← Providers/ProviderVersionDetector.swift |  |
| 155 | `Providers/Gemini/GeminiOAuthConfig.swift` | 77 | `GeminiOAuthConfig` ← Providers/Gemini/GeminiStatusProbe.swift |  |
| 156 | `Providers/Gemini/GeminiConsumerTierMigration.swift` | 38 | `GeminiConsumerTierMigration` ← Providers/Gemini/GeminiStatusProbe.swift |  |

### Providers/Kimi（4 文件 / 721 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 157 | `Providers/Kimi/KimiProviderDescriptor.swift` | 412 | `KimiProviderDescriptor` ← Providers/Kimi/KimiUsageSnapshot.swift |  |
| 158 | `Providers/Kimi/KimiUsageSnapshot.swift` | 178 | `KimiUsageSnapshot` ← Providers/Kimi/KimiUsageFetcher.swift |  |
| 159 | `Providers/Kimi/KimiCookieHeader.swift` | 98 | `KimiCookieHeader` ← Providers/Kimi/KimiProviderDescriptor.swift |  |
| 160 | `Providers/Kimi/KimiProviderSettings.swift` | 33 | `KimiProviderSettings` ← Providers/Kimi/KimiProviderDescriptor.swift |  |

### Providers/MiniMax（11 文件 / 3,014 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 161 | `Providers/MiniMax/MiniMaxUsageFetcher.swift` | 1,645 | `MiniMaxBaseResponse` ← Providers/MiniMax/MiniMaxBillingHistory.swift | FndNetworking |
| 162 | `Providers/MiniMax/MiniMaxBillingHistory.swift` | 360 | `MiniMaxBillingSummary` ← Providers/MiniMax/MiniMaxUsageSnapshot.swift |  |
| 163 | `Providers/MiniMax/MiniMaxUsageSnapshot.swift` | 298 | `MiniMaxUsageSnapshot` ← Providers/ProviderDiagnosticExport.swift |  |
| 164 | `Providers/MiniMax/MiniMaxServiceUsage.swift` | 225 | `MiniMaxServiceUsage` ← Providers/ProviderDiagnosticExport.swift |  |
| 165 | `Providers/MiniMax/MiniMaxCookieHeader.swift` | 118 | `MiniMaxCookieHeader` ← Providers/MiniMax/MiniMaxSettingsReader.swift |  |
| 166 | `Providers/MiniMax/MiniMaxSettingsReader.swift` | 101 | `MiniMaxSettingsError` ← Providers/ProviderDiagnosticExport.swift |  |
| 167 | `Providers/MiniMax/MiniMaxAPIRegion.swift` | 82 | `MiniMaxAPIRegion` ← Providers/MiniMax/MiniMaxUsageFetcher.swift |  |
| 168 | `Providers/MiniMax/MiniMaxModelRemains.swift` | 68 | `MiniMaxModelRemains` ← Providers/MiniMax/MiniMaxUsageFetcher.swift |  |
| 169 | `Providers/MiniMax/MiniMaxAPISettingsReader.swift` | 50 | `MiniMaxAPISettingsError` ← Providers/ProviderDiagnosticExport.swift |  |
| 170 | `Providers/MiniMax/MiniMaxDecoding.swift` | 46 | `MiniMaxDecoding` ← Providers/MiniMax/MiniMaxBillingHistory.swift |  |
| 171 | `Providers/MiniMax/MiniMaxUsageError.swift` | 21 | `MiniMaxUsageError` ← Providers/MiniMax/MiniMaxBillingHistory.swift |  |

### Providers/Mistral（4 文件 / 1,158 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 172 | `Providers/Mistral/MistralUsageFetcher.swift` | 565 | `ModelAccumulator` ← Providers/OpenAI/OpenAIAPIUsageSnapshot.swift | FndNetworking |
| 173 | `Providers/Mistral/MistralModels.swift` | 551 | `MistralUsageSnapshot` ← UsageFetcher.swift |  |
| 174 | `Providers/Mistral/MistralErrors.swift` | 35 | `MistralUsageError` ← Providers/Mistral/MistralUsageFetcher.swift |  |
| 175 | `Providers/Mistral/MistralTokenMath.swift` | 7 | `MistralTokenMath` ← Providers/Mistral/MistralModels.swift |  |

### Providers/Ollama（5 文件 / 1,761 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 176 | `Providers/Ollama/OllamaUsageFetcher.swift` | 1,086 | `normalizedOllamaTokenAccountHeader` ← Providers/Ollama/OllamaProviderDescriptor.swift | FndNetworking |
| 177 | `Providers/Ollama/OllamaProviderDescriptor.swift` | 315 | `OllamaStatusFetchStrategy` ← Providers/Claude/ClaudeWeb/ClaudeWebAPIFetcher.swift |  |
| 178 | `Providers/Ollama/OllamaUsageParser.swift` | 229 | `OllamaUsageParser` ← Providers/Ollama/OllamaUsageFetcher.swift |  |
| 179 | `Providers/Ollama/OllamaUsageSnapshot.swift` | 98 | `OllamaUsageSnapshot` ← Providers/Ollama/OllamaProviderDescriptor.swift |  |
| 180 | `Providers/Ollama/OllamaProviderSettings.swift` | 33 | `OllamaProviderSettings` ← Providers/Ollama/OllamaProviderDescriptor.swift |  |

### Providers/OpenAI（3 文件 / 903 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 181 | `Providers/OpenAI/OpenAIAPIUsageFetcher.swift` | 462 | `ModelAccumulator` ← Providers/OpenAI/OpenAIAPIUsageSnapshot.swift | FndNetworking |
| 182 | `Providers/OpenAI/OpenAIAPIUsageSnapshot.swift` | 305 | `OpenAIAPIUsageSnapshot` ← UsageFetcher.swift |  |
| 183 | `Providers/OpenAI/OpenAIAPIUsageResponses.swift` | 136 | `CostsResponse` ← Providers/OpenAI/OpenAIAPIUsageFetcher.swift |  |

### Providers/OpenCodeGo（1 文件 / 181 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 184 | `Providers/OpenCodeGo/OpenCodeGoUsageSnapshot.swift` | 181 | `OpenCodeGoUsageSnapshot` ← UsageFetcher.swift |  |

### Providers/Shared（1 文件 / 22 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 185 | `Providers/Shared/ProviderCookieSettings.swift` | 22 | `CookieProviderSettings` ← Providers/ProviderCredentialAdapter.swift |  |

### Providers/Windsurf（2 文件 / 983 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 186 | `Providers/Windsurf/WindsurfWebFetcher.swift` | 678 | `ProtoReader` ← Providers/Antigravity/AntigravityLocalReader.swift |  |
| 187 | `Providers/Windsurf/WindsurfDevinSessionImporter.swift` | 305 | `WindsurfDevinSessionImporter` ← Providers/Windsurf/WindsurfWebFetcher.swift |  |

### Vendored（14 文件 / 12,946 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 188 | `Vendored/CostUsage/CostUsageScanner.swift` | 6,699 | `CostUsageScanner` ← Vendored/CostUsage/CostUsagePricing.swift | CryptoKit Darwin Process |
| 189 | `Vendored/CostUsage/CostUsageStore+CodexCache.swift` | 1,539 | `CostUsageStoreLoad` ← Vendored/CostUsage/CostUsageScanner.swift |  |
| 190 | `Vendored/CostUsage/CostUsagePricing.swift` | 1,087 | `CostUsagePricing` ← UsageFormatter.swift |  |
| 191 | `Vendored/CostUsage/CostUsageStore.swift` | 991 | `CostUsageStore` ← Vendored/CostUsage/CostUsageScanner.swift | GCD SQLite actor |
| 192 | `Vendored/CostUsage/ModelsDevPricing.swift` | 779 | `ModelsDevPricingInfo` ← Vendored/CostUsage/CostUsagePricing.swift | Darwin FndNetworking actor |
| 193 | `Vendored/CostUsage/CostUsageJsonl.swift` | 473 | `CostUsageJsonl` ← Vendored/CostUsage/CostUsageScanner.swift | Darwin |
| 194 | `Vendored/CostUsage/CostUsageCacheModels.swift` | 428 | `CostUsageCache` ← Vendored/CostUsage/CostUsageScanner.swift |  |
| 195 | `Vendored/CostUsage/CostUsageStoreModels.swift` | 251 | `CostUsageStoreTotals` ← Vendored/CostUsage/CostUsageStore+CodexCache.swift |  |
| 196 | `Vendored/CostUsage/CostUsageCustomPricing.swift` | 193 | `CostUsageCustomPricing` ← Vendored/CostUsage/CostUsagePricing.swift | CryptoKit |
| 197 | `Vendored/CostUsage/CostUsageStore+ReadView.swift` | 191 | `CostUsageStoreReadView` ← CostUsageFetcher.swift |  |
| 198 | `Vendored/CostUsage/CostUsageStore+ReadWork.swift` | 125 | `CostUsageStoreReadWorkRecorder` ← Vendored/CostUsage/CostUsageStore+CodexCache.swift | SQLite |
| 199 | `Vendored/CostUsage/CostUsagePricingKey.swift` | 78 | `CostUsagePricingKey` ← Vendored/CostUsage/CostUsageScanner.swift | CryptoKit |
| 200 | `Vendored/OpenCodexUsage/OpenCodexRouteDispatcher.swift` | 58 | `OpenCodexRouteDispatcher` ← CostUsageFetcher.swift |  |
| 201 | `Vendored/CostUsage/ModelsDevPricingTargetResolver.swift` | 54 | `ModelsDevPricingTargetResolver` ← Vendored/CostUsage/CostUsagePricing.swift |  |

### OpenAIWeb（7 文件 / 4,036 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 202 | `OpenAIWeb/OpenAIDashboardFetcher.swift` | 1,328 | `OpenAIDashboardFetcher` ← Providers/Codex/CodexWebDashboardStrategy.swift | WebKit |
| 203 | `OpenAIWeb/OpenAIDashboardBrowserCookieImporter.swift` | 1,053 | `OpenAIDashboardBrowserCookieImporter` ← Providers/Codex/CodexWebDashboardStrategy.swift | WebKit |
| 204 | `OpenAIWeb/OpenAIDashboardWebViewCache.swift` | 713 | `OpenAIDashboardWebViewCache` ← OpenAIWeb/OpenAIDashboardBrowserCookieImporter.swift | GCD WebKit |
| 205 | `OpenAIWeb/OpenAIDashboardParser.swift` | 551 | `OpenAIDashboardParser` ← OpenAIWeb/OpenAIDashboardFetcher.swift |  |
| 206 | `OpenAIWeb/OpenAISubscriptionMetadata.swift` | 172 | `OpenAISubscription` ← OpenAIWeb/OpenAIDashboardFetcher.swift | WebKit |
| 207 | `OpenAIWeb/OpenAIDashboardWebsiteDataStore.swift` | 118 | `OpenAIDashboardWebsiteDataStore` ← OpenAIWeb/OpenAIDashboardBrowserCookieImporter.swift | CryptoKit WebKit |
| 208 | `OpenAIWeb/OpenAIDashboardNavigationDelegate.swift` | 101 | `NavigationDelegate` ← OpenAIWeb/OpenAIDashboardWebViewCache.swift | GCD WebKit |

### Host（6 文件 / 575 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 209 | `Host/Process/SubprocessRunner.swift` | 309 | `SubprocessRunner` ← Providers/Claude/ClaudeUsageFetcher.swift | Darwin GCD Process |
| 210 | `Host/Process/BoundedOutputBuffer.swift` | 73 | `BoundedLineBuffer` ← UsageFetcher.swift |  |
| 211 | `Host/Process/PosixSpawnFileActionsCloseFrom.swift` | 61 | `PosixSpawnFileActionsCloseFrom` ← Providers/Antigravity/AntigravityCLISession.swift | Darwin |
| 212 | `Host/PTY/StreamScanBuffer.swift` | 52 | `StreamScanBuffer` ← Host/PTY/TTYCommandRunner.swift |  |
| 213 | `Host/Process/PosixSpawnFileActionsCompatibility.swift` | 47 | `PosixSpawnFileActionsCompatibility` ← Providers/Antigravity/AntigravityCLISession.swift | Darwin |
| 214 | `Host/Process/RPCRequestTimeout.swift` | 33 | `RPCRequestTimeout` ← UsageFetcher.swift |  |

### Logging（7 文件 / 673 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 215 | `Logging/CodexBarLog.swift` | 229 | `CodexBarLog` ← Providers/Kimi/KimiUsageFetcher.swift |  |
| 216 | `Logging/FileLogHandler.swift` | 150 | `FileLogSink` ← Logging/CodexBarLog.swift | GCD |
| 217 | `Logging/OSLogLogHandler.swift` | 77 | `OSLogLogHandler` ← Logging/CodexBarLog.swift | os_log |
| 218 | `Logging/JSONStderrLogHandler.swift` | 72 | `JSONStderrLogHandler` ← Logging/CodexBarLog.swift | Darwin |
| 219 | `Logging/LogRedactor.swift` | 61 | `LogRedactor` ← Logging/CodexBarLog.swift |  |
| 220 | `Logging/LogCategories.swift` | 44 | `LogCategories` ← Providers/Kimi/KimiUsageFetcher.swift |  |
| 221 | `Logging/CompositeLogHandler.swift` | 40 | `CompositeLogHandler` ← Logging/CodexBarLog.swift |  |

### Plugins（8 文件 / 4,347 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 222 | `Plugins/QuickJSProviderPluginEngine.swift` | 1,139 | `QuickJSProviderPluginEngine` ← Plugins/UserProviderPlugins.swift | FndNetworking QuickJS |
| 223 | `Plugins/ProviderPluginRuntime.swift` | 983 | `ProviderPluginRuntime` ← Plugins/UserProviderPlugins.swift | FndNetworking GCD JSCore |
| 224 | `Plugins/ProviderPluginSnapshotMapper.swift` | 666 | `ProviderPluginSnapshotMapper` ← Plugins/ProviderPluginRuntime.swift |  |
| 225 | `Plugins/UserProviderPlugins.swift` | 604 | `UserProviderPluginRegistry` ← Config/CodexBarConfig.swift | Darwin FndNetworking JSCore QuickJS |
| 226 | `Plugins/ProviderPluginManifest.swift` | 553 | `ProviderPluginManifest` ← Plugins/UserProviderPlugins.swift |  |
| 227 | `Plugins/ProviderPluginEngine.swift` | 248 | `ProviderPluginEngine` ← Plugins/UserProviderPlugins.swift | JSCore QuickJS |
| 228 | `Plugins/QuickJSTypeScriptTranspiler.swift` | 126 | `QuickJSTypeScriptTranspiler` ← Plugins/QuickJSProviderPluginEngine.swift | QuickJS |
| 229 | `Plugins/ProviderPluginHTTPResponse.swift` | 28 | `ProviderPluginHTTPResponse` ← Plugins/ProviderPluginRuntime.swift |  |

### Config（5 文件 / 1,071 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 230 | `Config/CodexBarConfig.swift` | 387 | `ProviderConfig` ← Providers/Codex/CodexProviderDescriptor.swift | JSCore |
| 231 | `Config/CodexBarConfigValidation.swift` | 324 | `CodexBarConfigIssue` ← Providers/ProviderCredentialAdapter.swift |  |
| 232 | `Config/ProviderConfigCoding.swift` | 169 | `ProviderConfigExtensionValue` ← Config/CodexBarConfig.swift |  |
| 233 | `Config/CodexBarConfigStore.swift` | 132 | `CodexBarConfigStore` ← Providers/Cursor/CursorAppAuth.swift |  |
| 234 | `Config/CodexActiveSource.swift` | 59 | `CodexActiveSource` ← Providers/Codex/CodexAccountReconciliation.swift |  |

### WebKit（1 文件 / 108 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 235 | `WebKit/WebKitTeardown.swift` | 108 | `WebKitTeardown` ← OpenAIWeb/OpenAIDashboardWebViewCache.swift | WebKit |

### Generated（1 文件 / 5 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 236 | `Generated/CodexParserHash.generated.swift` | 5 | `CodexParserHash` ← PiSessionCostScanner.swift |  |

### Hooks（2 文件 / 265 行）

| # | 文件 | 行数 | 拉入依据 | 平台特征 |
|---|---|---|---|---|
| 237 | `Hooks/HookRule.swift` | 155 | `HooksConfig` ← Config/CodexBarConfig.swift |  |
| 238 | `Hooks/HookEvent.swift` | 110 | `HookEventType` ← Hooks/HookRule.swift |  |

## 7. 其余部分（未进入移植面）

### 7.1 仅因 ProviderManifest 注册被拉入（严格闭包 − 裁剪闭包 = 294 文件 / 58,966 行）

| 目录 | 文件数 | 行数 |
|---|---|---|
| Providers/Alibaba | 14 | 4,079 |
| Providers/Antigravity | 7 | 4,039 |
| Providers/Grok | 13 | 2,794 |
| Providers/Factory | 7 | 2,304 |
| Providers/OpenCodeGo | 5 | 1,958 |
| Providers/Kiro | 3 | 1,934 |
| Providers/Kilo | 8 | 1,585 |
| Providers/MiMo | 6 | 1,577 |
| Providers/Shared | 8 | 1,575 |
| Providers/MiniMax | 5 | 1,521 |
| Providers/ZoomMate | 7 | 1,509 |
| Providers/Doubao | 4 | 1,508 |
| Providers/Qoder | 6 | 1,465 |
| Providers/Copilot | 5 | 1,464 |
| Providers/OpenCode | 7 | 1,441 |
| Providers/Amp | 7 | 1,346 |
| Providers/Groq | 7 | 1,256 |
| Providers/StepFun | 4 | 1,185 |
| Providers/QwenCloud | 10 | 1,163 |
| Providers/Chutes | 3 | 1,162 |
| Providers/CommandCode | 9 | 1,099 |
| Providers/Augment | 4 | 1,034 |
| Providers/DeepSeek | 3 | 1,029 |
| Providers/Notion | 5 | 1,029 |
| Providers/Perplexity | 9 | 997 |
| Providers/LongCat | 9 | 953 |
| Providers/VertexAI | 5 | 900 |
| Providers/Manus | 6 | 780 |
| Providers/Abacus | 6 | 748 |
| CodexBarCore 根目录（核心模型与工具） | 4 | 735 |
| Providers/LiteLLM | 3 | 710 |
| Providers/Zed | 2 | 616 |
| Providers/T3Chat | 4 | 613 |
| Providers/JetBrains | 4 | 600 |
| Providers/Wayfinder | 3 | 598 |
| Providers/NeuralWatt | 3 | 596 |
| Providers/Fireworks | 4 | 595 |
| Providers/Zai | 4 | 581 |
| Providers/Sakana | 3 | 577 |
| Providers/Warp | 3 | 535 |
| Providers/Mistral | 3 | 470 |
| Providers/Windsurf | 4 | 461 |
| Providers/Moonshot | 5 | 446 |
| Providers/IBMBob | 3 | 445 |
| Providers/OpenAI | 3 | 437 |
| Providers/LLMProxy | 3 | 431 |
| Providers/AzureOpenAI | 3 | 424 |
| Providers/ElevenLabs | 3 | 421 |
| Providers/DeepInfra | 3 | 369 |
| Providers/ZenMux | 3 | 366 |
| Providers/AiAnd | 3 | 295 |
| Plugins | 2 | 255 |
| Providers/Cursor | 2 | 226 |
| Providers/OpenRouter | 2 | 207 |
| Providers/Devin | 2 | 183 |
| Providers/Deepgram | 2 | 159 |
| Providers/Sub2API | 2 | 158 |
| Providers/(共享) | 2 | 150 |
| Providers/Bedrock | 1 | 149 |
| Providers/XAI | 2 | 136 |
| Providers/ClawRouter | 2 | 125 |
| Providers/Crof | 2 | 105 |
| Providers/Synthetic | 2 | 93 |
| Providers/Venice | 2 | 92 |
| Providers/ClinePass | 2 | 91 |
| Providers/Poe | 2 | 82 |

结论：这些 provider（Abacus/AiAnd/Alibaba/Antigravity/AzureOpenAI/Bedrock/… 共 50+ 家）与 App 功能无关，裁剪 manifest 后无需移植。

### 7.2 SKIP（完全未引用：133 文件 / 27,408 行）

| 目录 | 文件数 | 行数 | 文件 |
|---|---|---|---|
| Vendored | 29 | 10,078 | `CodexSubagentRolloutShape.swift`, `CostUsageClaudeCache.swift`, `CostUsageClaudeJSON.swift`, `CostUsagePricing+CodexResolver.swift`, `CostUsagePricing+Overlay.swift`, `CostUsagePricing+Provider.swift`, `CostUsageScanner+CacheHelpers.swift`, `CostUsageScanner+Claude.swift`, `CostUsageScanner+CodexFastJSON.swift`, `CostUsageScanner+CodexPriority.swift`, `CostUsageScanner+CodexTruncatedPrefix.swift`, `CostUsageScanner+ForkCoverage.swift`, `CostUsageScanner+LogicalTarget.swift`, `CostUsageScanner+PricingRows.swift` …等 29 个 |
| CodexBarCore 根目录（核心模型与工具） | 29 | 5,379 | `AccountMenuLayoutPlanner.swift`, `AgentSession.swift`, `AutoreleasePoolCompat.swift`, `BoundedTaskJoin.swift`, `CheckedSum.swift`, `CodexBarCoreResourceSmoke.swift`, `CodexLocalProjectUsageProjection.swift`, `CodexModelsCSVExporter.swift`, `CodexPriorityDatabasePath.swift`, `CodexThreadMetadataReader.swift`, `CodexWorkspaceUsageFingerprint.swift`, `CookieHeaderCache+Fingerprint.swift`, `CookieHeaderCache+TestingOverrides.swift`, `Double+Clamped.swift` …等 29 个 |
| Providers/Claude | 13 | 2,435 | `ClaudeDesktopProjectsLocator.swift`, `ClaudeOAuthCredentials+Hashing.swift`, `ClaudeOAuthCredentials+SecurityCLIReader.swift`, `ClaudeOAuthCredentials+TestingOverrides.swift`, `ClaudeOAuthMutableKeychainOverrides.swift`, `ClaudeProviderConfig.swift`, `ClaudeSwapAccountList.swift`, `ClaudeSwapAccountProjection.swift`, `ClaudeSwapAccountReader.swift`, `ClaudeSwapAccountSwitch.swift`, `ClaudeSwapRetainedUsageStore.swift`, `ClaudeSwapUsageMeasurement.swift`, `ClaudeUsageSnapshot+WebExtras.swift` |
| OpenAIWeb | 6 | 1,831 | `OpenAIDashboardBrowserCookieImporter+Deadline.swift`, `OpenAIDashboardFetcher+PageScrape.swift`, `OpenAIDashboardFetcher+ReturnableData.swift`, `OpenAIDashboardFetcher+SessionAuthorization.swift`, `OpenAIDashboardReadinessScript.swift`, `OpenAIDashboardScrapeScript.swift` |
| Host | 4 | 1,735 | `ProcessPipeCapture.swift`, `ProcessTermination.swift`, `RPCChildProcessTeardown.swift`, `SpawnedProcessGroup.swift` |
| Providers/Antigravity | 11 | 1,647 | `AntigravityJSONLObject.swift`, `AntigravityLocalJSONL.swift`, `AntigravityLocalSQLite.swift`, `AntigravityLocalSQLiteSchema.swift`, `AntigravityLocalScan.swift`, `AntigravityLocalSnapshotSelection.swift`, `AntigravityProviderConfig.swift`, `AntigravityQuotaFamilyVisibility.swift`, `AntigravityStatusProbe+Deadline.swift`, `AntigravityStatusProbe+LocalEndpoints.swift`, `AntigravityUsageDataSource.swift` |
| Providers/Cursor | 5 | 678 | `CursorBrowserLoginModels.swift`, `CursorInteractiveLoginBrowser.swift`, `CursorStatusProbe+AppAuth.swift`, `CursorStatusProbe+SessionResolution.swift`, `CursorStatusProbe+UsageSummary.swift` |
| Providers/Codex | 5 | 643 | `CodexAdditionalRateLimitMapper.swift`, `CodexProviderConfig.swift`, `CodexProviderSettingsBuilder.swift`, `CodexSpendControlLimitMapping.swift`, `CodexVisibleAccountProjection.swift` |
| Hooks | 3 | 496 | `HookRateLimiter.swift`, `HookRunner.swift`, `HookTransitionDetector.swift` |
| Providers/Augment | 1 | 491 | `AugmentSessionKeepalive.swift` |
| Sync | 2 | 456 | `CanonicalSyncJSON.swift`, `SyncModels.swift` |
| Providers/MiniMax | 3 | 383 | `MiniMaxSubscriptionMetadata.swift`, `MiniMaxUsageFetcher+ModelMapping.swift`, `MiniMaxUsageSnapshot+Metadata.swift` |
| Providers/OpenCodeGo | 2 | 336 | `OpenCodeGoZenBalanceFetcher.swift`, `OpenCodeGoZenBalanceParser.swift` |
| Providers/(共享) | 4 | 210 | `CLIProbeSessionResetter.swift`, `ProviderAccentColors.swift`, `ProviderEnvironmentResolver.swift`, `ProviderInstanceIDAliases.generated.swift` |
| Providers/Gemini | 1 | 131 | `GeminiStatusProbe+DataLoader.swift` |
| Providers/Factory | 2 | 120 | `FactoryManualCredentials.swift`, `FactoryStatusProbe+APIKey.swift` |
| Providers/Shared | 1 | 107 | `OneConsoleTokenPlanSnapshot.swift` |
| Providers/XAI | 1 | 59 | `XAICostUsageMapping.swift` |
| Config | 2 | 40 | `ProviderConfigEnvironment.swift`, `SettingsValue.swift` |
| Providers/DeepSeek | 2 | 40 | `DeepSeekProviderConfig.swift`, `UsageSnapshot+DeepSeek.swift` |
| Logging | 2 | 37 | `LogMetadata.swift`, `ProviderLogging.swift` |
| Providers/Bedrock | 1 | 21 | `BedrockProviderConfig.swift` |
| Providers/Copilot | 1 | 15 | `CopilotCreditEntitlementParser.swift` |
| Providers/Fireworks | 1 | 14 | `FireworksProviderConfig.swift` |
| Providers/Kilo | 1 | 13 | `KiloProviderConfig.swift` |
| Providers/Moonshot | 1 | 13 | `MoonshotProviderConfig.swift` |

## 8. 二级裁剪建议（C# 侧再瘦身）

1. **UsageSnapshot 的 provider 专属字段**：`deepseekDetailedUsageState / deepseekPlatformProfiles / opencodegoUsage /` 等（UsageFetcher.swift L152-156）均为带默认值的可选字段 → C# 模型直接删除字段即可断开 DeepSeek/OpenCodeGo/MiniMax/Cursor/Ollama/Gemini/Bedrock/Antigravity/Codebuff… 共 **60 文件 / 20,707 行** 的拉入。`CostUsageFetcher.swift`（1,709 行，被 OpenCodeGoUsageSnapshot 拉入）同理可断。
2. **插件系统整体 stub**：链路 `CodexProviderDescriptor → ProviderConfig（Config/CodexBarConfig.swift）→ UserProviderPluginRegistry → Plugins/`（8 文件 / 4,347 行，含 QuickJS 引擎与 TypeScript 转译器）。App 不使用用户插件；C# 侧以空实现接口替代。
3. **CostUsage vendored（14 文件 / 12,946 行）**：仅因 `UsageFormatter` 调 `CostUsagePricing.codexDisplayLabel`（模型名美化）与 credits 链被拉入。6,700 行的 `CostUsageScanner`（本地 JSONL 扫描 + SQLite 缓存）与 App 展示弱相关，可先 stub 成静态定价表。
4. **Claude 链（35 文件 / 15,313 行）**：仅因 `CodexService` 持有 `ClaudeUsageFetcher` 并注入 `ProviderFetchContext.claudeFetcher`。若 Windows 版首期不做 Claude 配额，可用空协议实现替代，砍掉 ClaudeOAuth（Keychain 重镇）整块。

## 9. 平台守卫与 Windows 含义

裁剪闭包（263 文件）内的守卫/平台特征统计（文件数）：`os(macOS)` 47、`canImport(FoundationNetworking)` 32、`canImport(Darwin)` 20、`canImport(CryptoKit)` 10、`canImport(SQLite3)` 9、`canImport(JavaScriptCore)` 4、`canImport(os)` 3、`arch(arm64)` 3、GCD 10、Process 10、actor 7、os_log 7。

| 守卫/特征 | 出现位置（代表文件） | Windows 移植含义 |
|---|---|---|
| `os(macOS)`（47 文件） | KeychainCacheStore、TTYCommandRunner、OpenAIDashboard* | 取 macOS 分支语义移植；Linux 分支（FoundationNetworking）反而是更接近纯 HTTP 的参考实现 |
| `canImport(Darwin)`（20） | TTYCommandRunner、PosixSpawnFileActions*、PathEnvironment | posix_spawn/pid_t/进程组/信号 → `System.Diagnostics.Process`；需要 TTY 语义处用 Windows ConPTY |
| `canImport(FoundationNetworking)`（32） | 各 HTTP fetcher | Linux 分支用 FoundationNetworking 的 URLSession → C# 统一 `HttpClient`，此守卫天然消失 |
| `canImport(CryptoKit)`（10） | CostUsageScanner、CookieHeaderCache、CreditsModels、ClaudeOAuthCredentialModels | SHA256/HMAC/AES → `System.Security.Cryptography`；浏览器 cookie 解密的 AES-CBC+HMAC 见风险 5 |
| `canImport(SQLite3)`（9） | CostUsageStore、CodexWorkspaceUsageSidecar、KimiDesktopAuthToken（PORT） | C SQLite API → `Microsoft.Data.Sqlite` |
| Security.framework / SecItem*（4 文件，经 `os(macOS)` 守卫） | ClaudeOAuthCredentials(3,375 行)、KeychainCacheStore(961) | Keychain → DPAPI（`ProtectedData`）或 Windows 凭据管理器；App 本地 `KeychainService`（AIQuotaBar/Services/KeychainService.swift，应用侧）同样需要，需一并设计 |
| WebKit（7 文件） | OpenAIDashboardFetcher 等 OpenAIWeb/ | 无 WKWebView → WebView2 或改走 HTTP API + 手动 cookie；`WebsiteDataStore` cookie 读取无对应物 |
| `canImport(JavaScriptCore)`（4）+ QuickJS（4） | Plugins/*、CodexBarConfig | JS/TS 插件求值 → 建议 stub（§8.2） |
| `arch(arm64)`（3） | 二进制探测相关 | Windows 上对应 x64/arm64 exe 探测，语义重写 |
| `Bundle.module`（1） | CodexBarCoreResources | SPM 资源包 → C# 嵌入资源/内容文件 |

## 10. 移植风险 Top 10

1. **Codex 凭据与数据管线（核心价值，也最复杂）**：`Providers/Codex` 31 文件/6.4k 行 —— OAuth token 读取/刷新（`~/.codex/auth.json`）、PAT、`codex app-server` JSON-RPC 子进程（`UsageFetcher` 实为启动 `codex -s read-only -a never app-server` 并维持会话）、Web 仪表盘策略。路径需映射 `%USERPROFILE%\.codex`；RPC 需可靠进程管道管理。
2. **TTYCommandRunner（PORT，1,335 行）**：posix_spawn、进程组、信号、NSCondition 手写同步。Kimi CLI 探测（`kimi --status`）与 Codex/Claude CLI 会话共用。Windows 上重写为 Process(+ConPTY)，是发生率最高的单点重写。
3. **浏览器 Cookie/凭据导入（Kimi 自动发现的核心）**：BrowserDetection/BrowserCookieProfiles/ChromiumLocalStorageDiscovery 等 —— macOS 上解 Chrome `Safe Storage`（Keychain 里的密钥 + AES-128-CBC）。Windows 上 Chrome/Edge 改用 **DPAPI + AES-GCM**（app-bound encryption 还会更难），需单独 spike；`KimiCookieImporter`（PORT）直接踩这里。
4. **UsageSnapshot 共享模型的过度耦合**：公共字段内嵌 DeepSeek/OpenCodeGo 等其他 provider 的类型，是 60 文件/20.7k 行拖入的根因；C# 侧必须先裁字段再移植，否则面失控。
5. **OpenAIWeb/WebKit 仪表盘抓取（7 文件/4,036 行）**：`CodexWebDashboardStrategy` 依赖；无 WebKit 对应物，若 Codex 配额必须走 Web 仪表盘则需 WebView2 方案，工作量大、稳定性风险高。
6. **ClaudeOAuthCredentials（3,375 行，单文件最大 DEPENDS）**：Keychain 读写 + `security` CLI 解析 + 凭据比对。DPAPI 替代设计不当时会造成凭据迁移/兼容问题；若首期不做 Claude 建议直接断链（§8.4）。
7. **CostUsage vendored（14 文件/12,946 行）**：6,700 行扫描器 + SQLite 缓存 + models.dev 定价表。与 App 的 credits 显示只弱相关；全移植性价比低，建议静态定价表 stub，但 `UsageFormatter`/`CreditsSnapshot`（PORT）有真实调用点需保留接口。
8. **并发模型转换**：7 个 actor、83 文件含 async、10 文件用 DispatchQueue/NSCondition（如 TTYCommandRunnerActiveProcessRegistry 的关闭语义）。C# 需 async/await + SemaphoreSlim 重述，注意锁顺序与取消传播（`Task.checkCancellation` 语义）。
9. **KimiDesktopAuthToken（PORT，141 行，SQLite）**：读取 Kimi 桌面端本地 DB。Windows 上 Kimi 桌面版数据路径/加密方式未知，可能整条 desktop 数据源不可用，需产品决策降级为 Web/CLI 源。
10. **行为等价性回归**：`UsagePace/UsageFormatter/CodexPlanFormatting`（PORT）输出直接渲染到菜单栏，文本格式（重置时间、百分比、模型名美化）必须与 macOS 版对齐；建议以现有 Tests（6 个测试文件已在使用面内）翻成 C# 单测做金标准。

## 11. 建议移植顺序（自底向上）

1. **基础层**：Logging（7 文件/680 行，os_log→ILogger）、`TextParsing`、`CodexBarCoreResources`、`Double+Clamped` 等纯工具。
2. **纯模型层**：`UsageSnapshot`（先裁 provider 专属字段）、`RateWindow/NamedRateWindow`、`CreditsSnapshot`、`KimiModels`、`ProviderIdentitySnapshot`、`UsagePace`、`UsageFormatter`（pricing 先 stub）。
3. **进程基础设施**：`TTYCommandRunner` → Process/ConPTY 重写；`PathEnvironment`、`CodexExecutableResolver`（`which`→PATH 语义）、`SubprocessRunner`。
4. **Codex 管线**：`CodexHomeScope` → auth.json 读写 → `CodexOAuthUsageFetcher`（含 token 刷新、CryptoKit→System.Security.Cryptography）→ `CodexRPCClient`（app-server）→ `CodexProviderDescriptor`（manifest 裁剪后手工注册）。
5. **Kimi 管线**：`KimiSettingsReader`、`KimiUsageFetcher`/`KimiAPIError`（纯 HTTP，最顺）→ `KimiCLIStatusProbe`（依赖第 3 步）→ `KimiCookieImporter`/浏览器发现（DPAPI spike 后）→ `KimiDesktopAuthToken`（视产品决策）。
6. **（可选）Claude 管线**：`ClaudeUsageFetcher` + OAuth（凭据管理器方案定稿后）。
7. **组装与验证**：`ProviderDescriptor` 注册表（3 家）、`ProviderFetchContext`、错误映射；用移植的测试金标准跑通 CodexService/KimiService 等价输出。

---

附：分析可复现 —— `/tmp/cutlist/analyze4.py`（闭包+裁剪点）与 `/tmp/cutlist/gen_report.py`（本文件生成）；CodexBarCore 行数口径 wc -l（690 文件 / 180,494 行）。
