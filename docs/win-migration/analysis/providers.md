# Windows 迁移功能规格：Kimi / GLM / MiniMax 配额提供方

> 分析基准：master 工作区（版本 1.37.0, build 73）。
> 范围：`AIQuotaBar/Services/Kimi/`（8 文件）、`AIQuotaBar/Services/GLMCredential.swift`、`AIQuotaBar/Services/UsageService.swift`、`AIQuotaBar/Services/MiniMaxActivityDetector.swift`、`AIQuotaBar/Services/ZcodeActivityDetector.swift`、`AIQuotaBar/Services/KeychainService.swift`、`AIQuotaBar/Models/UsageData.swift`、`AIQuotaBar/Models/UsageProvider.swift`、`AIQuotaBar/Models/GLMResetAllowances.swift`、`AIQuotaBar/Tests/{Kimi,GLM,Providers}/`、`README.md`、`docs/api-field-mapping.md`、`docs/glm-api-field-mapping.md`。
> 注意：`TTYCommandRunner`、`KimiUsageFetcher`、`KimiSettingsReader`、`KimiCookieImporter`、`KimiDesktopAuthToken`、`RateWindow`、`UsageSnapshot`、`UsagePace`、`TextParsing` 定义在外部兄弟仓库 `codexbar`（SwiftPM 路径 `../codexbar` 或 `.dependencies/codexbar`，本机未签出）。本文基于本仓库的调用点、测试与文档记录其**可观察契约**；迁移时需另行核对 codexbar 源码（见 §9）。

---

## 0. 总体架构（三提供方共享）

- 每个提供方实现为「凭据 → 网络请求 → 解码为 `UsageData`」的纯函数式路径，入口统一在 `UsageService.fetchUsage(provider:)`：
  - `.kimi` → `KimiService.shared.fetchUsage(apiKey:)`（API key 之外的 4 种数据源）
  - `.glm` / `.miniMax` → `KeychainService.credential(for:)` 取凭据后走 `fetchGLMUsage` / `fetchMiniMaxUsage`
- `UsageData { provider, remains, total, timestamp, models: [ModelUsageData], subscribeTitle, subscribeEndTime, glmResetAllowances }`。
- `ModelUsageData` 关键语义（`AIQuotaBar/Models/UsageData.swift`）：
  - **`currentIntervalUsed` 字段名有误导性，存的是「剩余量」**（`currentIntervalRemaining` 直接返回它）；已用 = `currentIntervalTotal - currentIntervalUsed`。
  - `currentIntervalRemainingPercent`（0-100）存在时优先于按 count 计算；`valueSuffix == "%"` 表示百分比模式。
  - `remainsTime` 是「距重置的毫秒数」。
  - `sampledAt` = 抓取时刻（非窗口边界），决定本机/云端合并时选哪一行，所有提供方都必须写。
- 统一错误类型 `UsageError`：`invalidURL / networkError(Error) / invalidResponse / apiError(String) / keychainError / notConfigured`。
- 时间显示统一 `Asia/Shanghai` 时区、`en_US_POSIX` locale。
- 提供方枚举 `UsageProvider`：rawValue `minimax / glm / codex / kimi`；Keychain 旧账号名：miniMax→`apiKey`、glm→`glmCredential`、kimi→`kimiCodeAPIKey`、codex→`codexCredential`；只有 `.glm` 的 `usesCurlCredential == true`。左键菜单默认顺序 `[codex, kimi, glm, minimax]`。

---

## 1. Kimi

### 1.1 数据源模式与回退顺序（`Services/Kimi/KimiService.swift`）

模式存 UserDefaults key `kimiSourceMode`（`KimiDataSourceMode`: `auto/desktop/cli/web`，默认 `auto`）；最近成功来源存 `kimiLastSuccessfulSource`。

`fetchUsage(apiKey:)` 决策树（**必须精确保持**）：

1. `auto` 模式且 apiKey 非空（trim 后）→ 直接走 API key 模式，来源标签 `"Kimi Code API"`。
2. 显式模式 `desktop/web/cli` → 只走该来源（显式选择要暴露登录错误，不回退）。
3. `auto` 回退顺序：
   1. **桌面登录**：`KimiDesktopSessionReader().load().validated()` 成功 → 用它（来源 `"Kimi Desktop"`）；若 `desktopAvailable()`（token-store 文件存在）但加载失败，记录 localError。
   2. **已保存网页登录**：Keychain deviceCredential `kimi.web-session.v1` → 来源 `"Kimi Web"`；同时把存在性写入 UserDefaults `kimiSavedWebSessionAvailable`。
   3. **CLI**：`cliAvailable()`（见 §1.5）→ `KimiCLIStatusProbe`，来源 `"Kimi Code CLI /status"`；失败记入 localError（不覆盖已有）。
   4. **浏览器扫描**：`KimiBrowserSessionDiscovery.sessions()` → 若恰好 1 个唯一账号 → 来源 `"Kimi Web (auto)"`；多账号抛 `KimiSessionError.multipleBrowserAccounts`（不静默选择）。
   5. 全部失败 → `localError ?? UsageError.notConfigured`。
- **账号粘性规则**（测试锁定）：一旦选定有效登录（桌面/网页），后续网络/服务端错误直接抛出，**不**切换到其他账号/来源；只有「本地凭据不可用/过期」才继续回退。
- 取消语义：任何阶段检测到 `CancellationError` 或 `URLError.cancelled` 立即终止整个回退链（不启动下一来源）。
- 错误映射：`URLError→networkError`、`DecodingError→invalidResponse`、其他→`apiError(localizedDescription)`；`KimiSessionError` 子类型见 §1.2 错误表。
- `discoverAutomaticSources()`：在配置提供方过滤之前调用；仅 `auto` 且无桌面/CLI 时尝试读取已存网页会话，失败则触发一次浏览器扫描（供 `hasAutomaticSource` 判断）。
- `hasAutomaticSource`：`auto` = cliAvailable || desktopAvailable || 浏览器有缓存会话 || `kimiSavedWebSessionAvailable`；显式模式恒 true。

### 1.2 桌面会话发现（`Services/Kimi/KimiDesktopSessionReader.swift`）

读取 Kimi 桌面 App（bundle `com.moonshot.kimichat`）两类登录存储：

**(a) 新版加密 token store（优先）**
- 文件：`~/Library/Application Support/kimi-desktop/bridge-store/token-store.json`
- 外层 JSON：`{"encryption":"safeStorage.v1","data":"<base64>"}`；`encryption` 必须为 `"safeStorage.v1"`，否则 `invalidStore`。
- base64 解出的密文是 **Electron macOS safeStorage v10** 格式：
  - 前 3 字节 ASCII `v10` 前缀；其余长度必须是 16 的倍数。
  - 密钥派生：PBKDF2-HMAC-SHA1，盐 = ASCII `"saltysalt"`，迭代 **1003** 次，输出 16 字节（AES-128）。
  - 解密：AES-128-**CBC**，IV = 16 字节 `0x20`，PKCS7 padding。
  - 密钥来源 = Keychain 条目 **service=`kimi-desktop Safe Storage`**（kSecClassGenericPassword，无 account 条件，kSecMatchLimitOne 取数据）。
- 解密后明文 JSON：`{"origin": String, "tokens": {"access_token": String?}}`；只取 `access_token`（**忽略 refresh_token**），`origin` 保留；`access_token` 缺失/为空 → `invalidStore`。

**(b) 旧版 Cookie/token 存储（回退）**：`KimiDesktopAuthToken.load(homeDirectory:)`（codexbar 提供，本仓库无源码；行为上是读取旧版 kimi-desktop 的本地 token），命中则构造 `KimiWebSession(token:, origin: "https://www.kimi.com")`。

- `isPresent`（presence 探测，不碰 Keychain、不弹窗）= token-store.json 文件存在 || KimiDesktopAuthToken 可加载。
- **密钥缓存协议**（迁移必须保持的授权模型）：
  - 解密密钥首次经用户授权读取后，缓存进**自家**凭据库（vault 字段 `kimiDesktopSafeStorageKey`，base64）；此后启动只读自家条目，避免每次启动都弹 Kimi 条目的 macOS 授权框。
  - 缓存命中判定：缓存密钥解密 + 解码 + `validated()` 全部成功才算命中（错误密钥可能通过 AES padding）。
  - 后台刷新（`allowInteraction=false`）：无缓存或缓存失效 → 抛 `KimiSessionError.keychain(errSecInteractionNotAllowed)`，**绝不**读 Kimi 的 Keychain 条目、**绝不**写 vault（写也会触发弹窗）。
  - 交互读取（Settings「Allow Desktop Access」按钮，`allowInteraction=true`）：缓存失效则先 `clear()`，再做一次授权读取并 `write()` 新密钥；密钥错误且已交互过一次 → 直接失败（`freshCalls == 1`，不无限重试）。

### 1.3 网页会话模型与校验（`Services/Kimi/KimiWebSession.swift`）

`KimiWebSession: Codable { token: String, origin: String }`：
- token 是 JWT：手动 base64url 解 payload（`-`→`+`、`_`→`/`、补 `=`），取 `exp`（过期时间，unix 秒）与 `sub`（账号 ID）。`accountLabel = "Kimi · <sub>"`，无 sub 则 `"Kimi"`。
- `validated()`：
  - `origin` 必须**全等** `https://www.kimi.com` 或 `https://www.kimi.ai`（`http://`、子域后缀、`@`、带 path 一律拒绝 → `unsupportedOrigin`）。
  - token 非空且不含任何空白字符，否则 `invalidStore`。
  - `exp <= now` → `expired`。
- 错误枚举 `KimiSessionError`：`missing / invalidStore / expired / unsupportedOrigin / keychain(OSStatus) / noBrowserSession / multipleBrowserAccounts`（中英文案见源码，Windows 版需保留双语）。

### 1.4 浏览器会话发现（`Services/Kimi/KimiBrowserSessionDiscovery.swift` + Settings/KimiSourceSection）

- 扫描实现 `KimiCookieImporter.importSessions()`（codexbar）：枚举本机浏览器 Cookie 存储，取 **cookie 名 `kimi-auth`** 的值；`expiresDate` 已过期（或存在且 ≤ now）的丢弃；构造 `KimiWebSession(token: cookie.value, origin: "https://www.kimi.com")` 并 `validated()`。支持的浏览器（手动导入 UI）：Chrome、Safari、Edge、Arc、Brave。
- 后台扫描永不触发浏览器 Keychain 授权 UI（codexbar 侧 `ProviderInteractionContext.background` 门控）；正/负结果缓存 **TTL 300 秒**；并发刷新共享同一次扫描（单飞行）；缓存读不延长 TTL。
- `uniqueSession(_:)`：按 `origin + "|" + (accountID ?? token)` 去重；同账号多 profile 取 `exp` 最新者；**>1 个账号 → 抛 `multipleBrowserAccounts`**；0 个 → nil。
- 手动保存网页登录：先 `KimiWebUsageClient().fetch()` 验证可用，再把 session JSON 存为 deviceCredential 绑定 `Kimi.webSessionBinding = "kimi.web-session.v1"`；移除 = 保存空串。手动连接支持手填 kimi-auth cookie 值 + 站点选择（kimi.com / kimi.ai）。

### 1.5 CLI PTY 探测（`Services/Kimi/KimiCLIStatusProbe.swift`）

目的：在**真 PTY** 中运行官方 `kimi` CLI 并发送 `/status` 斜杠命令。`/status` 由 CLI 本地处理，不产生模型回合、不消耗上下文 token；OAuth 刷新留在官方 CLI 内（避免与短期 access/refresh token 轮换竞态）。

- `cliAvailable()` = `KimiSettingsReader.hasKimiCodeCredential()`（codexbar；检查 `~/.kimi-code` 下存在 CLI 登录凭据）。
- 二进制定位：`$KIMI_CODE_HOME/bin/kimi`（可执行）→ 否则 `TTYCommandRunner.which("kimi")`（等价 `which kimi`）→ 都没有抛 `cliNotInstalled`。
- 工作目录（专用探测目录，需先 mkdir -p）：`~/Library/Application Support/com.techfanseric.aiquotabar/KimiStatusProbe`。
- PTY 运行参数（`TTYCommandRunner.run`，codexbar）：
  - 终端尺寸 rows=60, cols=180；总超时 **10s**；空闲超时 **1.2s**；启动初始延迟 0.2s；启动时不发送任何初始文本（`send: ""`）。
  - **`sendOnSubstrings` 触发式输入**：输出中出现 `"Trust this folder?"` → 发送 `ESC[A` + `\r`（上箭头+回车，选择非默认项以跳过工作区信任提示）；出现 `"context:"` → 发送 `/status\r`。
  - **`stopOnSubstrings`**：输出出现 `"5h limit"` 或 `"5-hour limit"` 即认为状态已渲染，再等 0.6s（`settleAfterStop`）收割输出。
- 输出解析（`parse(text:now:)`）：
  1. 清洗：剥 ANSI/CSI 转义、OSC 超链接/标题序列（`\u001B]...\u0007` 或 `\u001B\`）、控制字符（保留 `\t \r` 语义之外全删）。
  2. 正则取行：`Weekly\s+limit[^\n]*` → 周窗口（10080 分钟）；`(?:5h|5-hour)\s+limit[^\n]*` → 5h 窗口（300 分钟）。
  3. 每行取百分比：`([0-9]{1,3})%\s*used` → used；否则 `([0-9]{1,3})%\s*(?:left|remaining)` → used = 100 - left。clamp 0...100。
  4. 重置时间：行内 reset 串以 `"in "` 开头时，按 `([0-9]+)\s*([dhms])` 累加（d=86400/h=3600/m=60/s=1 秒），`resetsAt = now + seconds`。
  5. 两窗口都缺失：输出含 `"Trust this folder?"` → `workspaceTrustRequired`；否则 `statusUnavailable`（"Kimi Code CLI /status did not return quota data."）。
- 结果 `UsageSnapshot(primary: 周窗口, secondary: 5h窗口, updatedAt: now)`，由 `KimiUsageDataMapper` 映射。

### 1.6 API key 模式（`KimiService.fetchAPIUsage`，fetcher 在 codexbar）

- `baseURL = KimiSettingsReader.codeAPIBaseURL()`（codexbar；从 `~/.kimi-code` 设置解析 Kimi Code API 的 base URL），调用 `KimiUsageFetcher.fetchCodeAPIUsage(apiKey:baseURL:)`，返回值经 `.toUsageSnapshot()` 转换后走同一 mapper，来源标签 `"Kimi Code API"`。
- API key 可带或不带 `Bearer ` 前缀语义（服务端处理），本侧只 trim。错误映射：`KimiAPIError → apiError`。
- **迁移注意**：确切端点/响应 JSON 在 codexbar 仓库，本仓库无引用（见 §9 待办）。

### 1.7 网页/桌面配额 API（`Services/Kimi/KimiWebUsageClient.swift`）——本仓库内、必须逐字段保持

两个 POST JSON（Connect 协议风格）请求，base = `session.origin`（`https://www.kimi.com` 或 `https://www.kimi.ai`）：

**(1) 主接口** `POST {origin}/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
- Body：`{"scope":["FEATURE_CODING"]}`
- Headers：`Content-Type: application/json`；`Authorization: Bearer <token>`；**`Cookie: kimi-auth=<token>`**；`Origin: <origin>`；`Referer: <origin>/code/console`；`connect-protocol-version: 1`。超时 20s。
- URLSession 为 ephemeral 且**禁用重定向**（`NoRedirects` delegate 返回 nil —— 防止 30x 把凭据带去别的域）。

**(2) 可选会员接口**（3s 超时，失败被吞、绝不影响主接口）：`POST {origin}/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats`，Body `{}`。

状态码处理：401/403 → `KimiSessionError.expired`（**错误消息不得包含响应体或认证头**，测试锁定）；非 200 → `UsageError.apiError("Kimi HTTP <code>")`（同样不泄露响应体）。

**响应解析（`parse(data:stats:)`）**：
```jsonc
// GetUsages 响应
{ "usages": [ {
    "scope": "FEATURE_CODING",
    "detail": { "limit": "100"|100, "used": "71"|71?, "remaining": "71"|71?, "resetTime": "2026-09-29T11:22:56.007158Z" },
    "limits": [ { "detail": {…同上…}, "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" } } ]
} ] }
```
- 取 `scope == "FEATURE_CODING"` 的条目；数值字段兼容字符串/数字。
- **周窗口**（primary）：直接用 `detail`（10080 分钟固定）；**短窗口**（secondary）：取 `limits` 中 `window.minutes == 300` 的第一条（否则第一条）；`minutes` 换算：`TIME_UNIT_MINUTE=1、TIME_UNIT_HOUR=60、TIME_UNIT_DAY=1440`，其他单位 → nil（模型名降级为 `"Rate limit"`，不标 5h）。
- 单窗口换算：`total = Double(detail.limit)`（必须 finite 且 >0）；`used = detail.used`（finite ≥0），否则 `used = total - detail.remaining`（remaining 需在 0...total）；`usedPercent = min(100, used/total*100)`；`resetsAt = ISO8601（兼容带/不带毫秒）解析 resetTime`。
- **月度 Total usage（extraRateWindow）**：来自 GetSubscriptionStats 的 `subscriptionBalance`，需同时满足：`feature == null 或 "FEATURE_OMNI"`、`type == null 或 "SUBSCRIPTION"`、`amountUsedRatio` finite ≥0；生成 `NamedRateWindow(id:"kimi-monthly", title:"Total usage", window: RateWindow(usedPercent: min(1,ratio)*100, windowMinutes: nil, resetsAt: 解析 expireTime))`。
- 三者全无 → `invalidResponse`；stats 解析失败不影响主配额（测试锁定）。

### 1.8 数据映射（`Services/Kimi/KimiUsageDataMapper.swift`）

模型行顺序（先短窗后周窗，再 extras）：
1. secondary → 模型名 `windowMinutes % 60 == 0 ? "\(m/60)h" : "\(m)m"`（300→`"5h"`；无 minutes → `"Rate limit"`）。
2. primary → `"7d"`。
3. extras → `"Total usage"`（kimi-monthly）或 `extra.title`。
- 每行：`currentIntervalTotal = 100`，`currentIntervalUsed = round(remainingPercent)`（0-100），`valueSuffix = "%"`，`detailText = "<source> · <origin>"`（如 `Kimi Desktop · https://www.kimi.com`），`startTime = inferStart ? resetsAt - windowMinutes*60 : nil`（**kimi-monthly 不推算起点**），`remainsTime = max(0, (resetsAt-now)*1000)` 毫秒。
- `accountName` 统一填 `session.accountLabel`（"Kimi · <sub>"）。
- `remains` = `isCurrentIntervalAvailable` 的行数。

### 1.9 月度按天分段 + pace（reserve/deficit）算法（`Models/UsageData.swift`）

- `isKimiMonthlyTotalWindow`：`provider == .kimi && modelName == "Total usage" && startTime == nil && endTime != nil`。
- **展示窗口（按天分段的柱图基础）**：`quotaChartWindow()` = `(endTime - 1 个自然月, endTime)`（`Calendar.date(byAdding:.month, value:-1)`）；**不写回 `startTime`**（不参与节奏的字段级污染），历史柱图标签用 "Monthly cycles"。
- **pace 窗口** `currentIntervalPaceWindow`：有真实 start/end 用之；否则 kimi-monthly 用上面的推导窗口（**GLM 5h 滚动窗口永不参与 pace**）。
- `currentIntervalElapsedRatio = clamp(elapsed/duration, 0, 1)`；`paceUsedPercent = ratio*100`；`paceDeltaPercent = paceUsed - actualUsed`（**正数=省/reserve（绿），负数=亏/deficit（红）**）。
- `currentIntervalPace`（复用 codexbar `UsagePace.historical`）：`expected = elapsed/duration*100`，`actual = currentIntervalPercentageUsed`；`elapsed==0 && actual>0` → nil（脏数据 guard）；Stage 分桶按 **|delta|**：≤2 onTrack、≤6 slightly、≤12 ahead/behind、>12 far；`isAhead`：onTrack/slightlyBehind/behind/farBehind → true（剩余比应有多）。
- 其余：`currentIntervalPaceRemaining = yAxisMax * (1-ratio)`（5h 面积图参考线）；progressBarPercentOverride 非 nil 时 pace 全部禁用。

### 1.10 Kimi 本地活动检测（`Services/Kimi/KimiLocalActivityDetector.swift`，供睡眠保护/跟随运行应用）

三个运行时，只读，绝不保留消息体/模型输出/命令输出：
- **桌面 agent**：`~/Library/Application Support/kimi-desktop/kimi-agent/`：
  - `conversation-statuses.json`：`{conversationKey: status}`，key 形如 `agent:main:main:conversation:<id>`，取 `:` 最后一段为 ID。终态集合（authoritative，立即退出活跃集）：`completed/stopped/error/failed/cancelled/canceled/interrupted/aborted`；进行中集合：`running/generating/streaming/pending/queued`（需心跳守卫）；未知值 → 按 freshness 兜底。
  - `conversation-context-usage.json`：`{conversationKey: {updatedAt: ISO8601(可带毫秒), …}}` 提供 `updatedAt` 心跳。
  - 规则：终态 → 非活跃（即便心跳新鲜）；running 态且心跳静默超 10 分钟 → 崩溃守卫判非活跃；无 ledger/未知状态 → 心跳在 120s（`freshnessWindow`）内即活跃。会话 ID 前缀 `kimi:desktop:`。
- **CLI**：`$KIMI_CODE_HOME`（默认 `~/.kimi-code`）/`sessions/<workspace>/session_*/agents/*/wire.jsonl`；turn 生命周期记录：`{"type":"turn.prompt"}` 开启、`{"type":"turn.ended"}` 关闭；活跃 = turn 开启 **且** 文件 mtime 在 10 分钟静默窗口（`openTurnSilenceWindow`）内且 ≤ now；**增量解析**（按 size + 已消费换行偏移续读，尾部不完整行重复解析无害；文件缩小则全文重读；offset 缓存按磁盘现存 wire 修剪）。前缀 `kimi:cli:`。
- **Kimi Work（daimon）桌面托管运行时**：`~/Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/`，目录名 `conv-*`/`ctitle-*`，同样 wire 生命周期，前缀 `kimi:work:`；与 CLI root 相同时不重复计数。
- 同一 session 多 agent 折叠为一个任务（ID 取 session 目录名）。

---

## 2. GLM

### 2.1 凭据（`Services/GLMCredential.swift`）

两种输入，统一解析为 `GLMCredential { apiURL, authorization, organization?, project?, cookie?, headers:[String:String] }`：

**(a) API Key 模式（个人 Coding Plan）**：输入裸 key 或 `Bearer <key>` →
- `apiURL = "https://open.bigmodel.cn/api/monitor/usage/quota/limit"`
- `authorization = "Bearer <key>"`（已带前缀则原样，**只加一次** Bearer）
- organization/project/cookie/headers 全空。

**(b) Web 会话 cURL 粘贴模式**：输入含 `curl` 时走 shell 分词解析（支持单/双引号、反斜杠续行与转义、`\\\n` 折行）：
- URL：第一个 `http(s)://` token；缺省 `https://bigmodel.cn/api/monitor/usage/quota/limit`。
- `-H/--header`（含粘附形式 `-Hxxx`）：header 名转小写；`cookie` 头单独存入 `cookie`，其余进 `headers`。
- `-b/--cookie`：cookie 值。
- `authorization` = headers 里的 `authorization`，缺失时从 Cookie 提取 **`bigmodel_token_production`** cookie 值；两者皆无 → `apiError("Missing GLM authorization header in curl command.")`。
- 提取 `bigmodel-organization` / `bigmodel-project` 专用字段。
- **只解析不执行** cURL；网页会话过期需用户重新复制。

存储（Keychain 里）为 credential 的 JSON（`storageString`）；编辑框回显 `editableString`：纯 API key 模式只回显 key（剥掉 Bearer）；web 模式重建成 `curl '<url>' -H 'name: value' … -b '<cookie>'` 形式（header 按名排序，authorization/org/project 并入 -H），单引号内 `'` 转义为 `'\''`，解析可无损往返（round-trip 测试锁定）。

### 2.2 请求构造（`UsageService.fetchGLMUsage`）

`GET {apiURL}`，超时 30s。Header 应用顺序（`applyGLMHeaders`）：
1. 先应用用户 headers（curl 带来的全部）；
2. 缺省补：`Accept: application/json, text/plain, */*`、`Content-Type: application/json`、`Authorization: <credential.authorization>`（若 headers 已含 authorization 则不覆盖）、`Accept-Language: zh`、`Set-Language: zh`；
3. `bigmodel-organization` / `bigmodel-project`（非空时）；
4. `Cookie: <cookie>`（非空时）。

### 2.3 配额响应结构与解析（`decodeGLMUsageData` + `docs/glm-api-field-mapping.md`）

```jsonc
{ "code": 200, "success": true, "msg": null,
  "data": { "level": "lite",
    "limits": [
      { "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
        "usage": 2000, "currentValue": 0, "remaining": 2000, "percentage": 0 },           // 5h 窗口
      { "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
        "usage": 10000, "currentValue": 514, "remaining": 9485, "percentage": 5,
        "nextResetTime": 1789647732997 } ] } }                                            // weekly 窗口
```
- 字段兼容解码（**flexible decode**，数字/字符串/浮点互转，失败给 0/空）：`type,currentValue,usage,percentage?,nextResetTime?(Int64),remaining?,unit?,number?,usageDetails[{modelCode,usage}]`。
- 门槛：`success == true && code == 200`，否则 `apiError(msg ?? unknownError)`；`limits` 映射后为空（含 `usage<=0` 且无 percentage 的条目）→ `invalidResponse`。
- **归一化**（每条 limit）：
  - count 模式（`usage` finite>0 且 < Int.max）：`total = round(usage)`；`remaining = limit.remaining ?? max(0, usage-currentValue)`，再 clamp 到 `0...total`；`used(展示) = clamp(currentValue, 0...total)`。注意服务端对 currentValue/remaining 独立取整，remaining 可不等于 usage-currentValue，**以服务端 remaining 为准**。
  - percentage 模式（count 不可用且 `percentage` finite）：`used = clamp(percentage,0,100)`，total=100，`valueSuffix="%"`。
  - 都不行 → 该条丢弃（total=0）。
- **窗口**：`unit` 枚举（与 CodexBar 一致）：`1=天(86400)、3=小时(3600)、5=分钟(60)、6=周(604800)`；`duration = number * multiplier`。缺 unit/number 时：`TOKENS_LIMIT` 按 5h（18000s）兜底，其他 nil。
- **endTime**：`nextResetTime`（毫秒时间戳）解析；缺失且 `type == "TIME_LIMIT"` → 用订阅重置时间兜底；**缺失时不伪造起止时间**（startTime/endTime = nil，测试锁定）。
- **startTime**：`endTime - duration`（仅在两者都可得时）。
- **模型命名**：`CREDIT_LIMIT` → `GLM Credits (5h)` / `GLM Credits (weekly)`（period 文本：unit1→`Nd`、unit3→`Nh`、unit5→`Nm`、unit6→`1→weekly / Nw`，unit/number 缺失用 fallback：Credits→`unknown`、Tokens→`5h`、Time→`month`）；`TOKENS_LIMIT` → `GLM Tokens (…)`；`TIME_LIMIT` → `GLM MCP/Search (…)`；未知 type → `GLM <type>`。
- `subscribeTitle = data.level`（如 "lite"）；detailText = `"X.X% used"`（有 percentage）或 `"N used"`，加 usageDetails 前 3 名 `"modelCode: N"`（usage>0，降序）以 ` · ` 连接。
- 两行 Credits 有独立 ID、独立历史与菜单栏选择；`isGLMFiveHourWindow`（名字含 "5h"）的展示窗口是 `quotaChartWindow = (now-5h, now)` 滚动窗，**不参与 pace**（`currentIntervalPaceDeltaPercent == nil`，测试锁定）。

### 2.4 订阅重置兜底（仅旧网页凭据）

触发条件：quota 响应 success 且存在 `type=="TIME_LIMIT" && nextResetTime==nil` 的条目，**且** `apiURL.host == "bigmodel.cn"`。请求 `GET {scheme}://bigmodel.cn/api/biz/subscription/list`（由 quota URL 改 path、去 query；同 headers；15s 超时）。
响应 `{code, success, data: [{productName?, valid?, nextRenewTime?, inCurrentPeriod?}]}`；每个条目取 `nextRenewTime`（优先）或 `valid` 的后半段（`valid` 形如 `yyyy-MM-dd HH:mm:ss-yyyy-MM-dd HH:mm:ss`，取后 3 段）；日期解析（`Asia/Shanghai`）：`yyyy-MM-dd HH:mm:ss` / `yyyy-MM-dd HH:mm` / `yyyy-MM-dd` / 纯毫秒数；取**最小的未来日期**（都在过去则取最大者）。API Key 与新版 Credits 不调用该接口。

### 2.5 重置额度（Reset Allowances，`Models/GLMResetAllowances.swift`）

个人 Coding Plan 的**重置券**（不是配额积分）：
- 端点：`GET https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL`，超时 **2s**，`httpShouldHandleCookies=false`，只带 `Authorization`（**不带 Cookie/org/project**）。
- **严格的发送门槛**（防止凭据发给未验证主机）：apiURL 必须 `https`、host 恰为 `bigmodel.cn`、无端口、path 恰为 `/api/monitor/usage/quota/limit`、query 不含 `type != 1` 的 `type` 项、organization/project 为空（字段与 header 双重检查）。不满足则不发。
- 响应 `{code:200, success:true, data:{targetType:"PERSONAL", fiveHourResets:[{available:Bool, expireTime:"yyyy-MM-dd HH:mm:ss"}], weekResets:[…]}}`；`targetType != "PERSONAL"` 或 code/success 不对 → invalidResponse；日期用 Asia/Shanghai 严格解析（解析后再格式化必须与原文一致，防止静默容错）；只保留 `available==true`，排序。
- 结果挂在 `UsageData.glmResetAllowances`（随 Codable 持久化），UI 显示可用张数与最近到期；请求失败完全静默，不影响配额。

### 2.6 错误处理 / 速率限制

- 非 2xx：`apiError("状态码 N：<body 文本>")`（英文 `Status N: <body>`），body 解码失败用 unknown 文案。**没有专门的 429 退避**：错误按通用失败处理（保留旧数据，下轮重试）。
- 网络异常 → `networkError`；JSON 解不开 → `invalidResponse`。
- `testConnection` = 完整跑一次 `fetchGLMUsage`（不额外调用重置券接口）。

---

## 3. MiniMax

### 3.1 配额接口（`UsageService.fetchMiniMaxUsage`）

- 端点：`GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`
- Headers：`Authorization: Bearer <token>`（自动补 Bearer 前缀）、`Content-Type: application/json`；超时 **30s**。
- 响应（`MiniMaxUsageAPIResponse`）：
```jsonc
{ "base_resp": { "status_code": 0, "status_msg": "" },
  "model_remains": [ {
    "model_name": "MiniMax-M2",
    "start_time": 1775649600000, "end_time": 1775667600000,   // 当前周期起止，毫秒
    "remains_time": 1618725,                                   // 距重置毫秒
    "current_interval_total_count": 4500,
    "current_interval_usage_count": 3734,                      // ★ 剩余，不是已用
    "current_weekly_total_count": 133000,
    "current_weekly_usage_count": 133000,                      // ★ 周剩余
    "weekly_start_time": …, "weekly_end_time": …,
    "weekly_remains_time": ?, "current_interval_status": ?,
    "current_interval_remaining_percent": ?, "current_weekly_status": ?,
    "current_weekly_remaining_percent": ?,
    "interval_boost_permille": ?, "weekly_boost_permille": ? } ] }
```
- `base_resp.status_code != 0` → `apiError(status_msg)`。
- **核心语义（docs/api-field-mapping.md 反复强调）：所有 `_usage_count` 字段 = 剩余数量**；已用 = total - usage_count；两个接口都不带服务端时间戳，`sampledAt = 解码时刻`（两处共用同一时刻）。
- 每个模型映射为一行 `ModelUsageData`：`currentIntervalTotal/Used ← total/usage_count`（Used 存剩余，见 §0），weekly 同理；起止时间毫秒→Date；percent 字段直通；boost_permille 仅解码不使用。
- 周额度特殊态：`isWeeklyUnlimited` = `weeklyRemainingPercent >= 100 && weeklyTotal <= 0`（API 用 status=3 或 total=0+percent=100 表达无周限）。

### 3.2 订阅信息（`fetchMiniMaxSubscribe`，可选、失败静默）

- 端点：`GET https://www.minimaxi.com/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7`
- 同样 Bearer 认证，超时 **15s**；非 2xx/解码失败 → nil（不影响主接口；主请求失败也要 await 该任务避免泄漏）。
- 响应 `{"current_subscribe": {"current_subscribe_title": "TokenPlanMax-年度会员", "current_subscribe_end_time_ts": 1790000000000, "curr_subscribe_combo_id", "current_subscribe_combo_type", "current_subscribe_cycle_type", "renewal_state", "refundable"}}`。
- **过期日期解析**：`current_subscribe_end_time_ts` 为毫秒时间戳，`> 0` 才生成 Date（0 = 无有效订阅 → nil）；title trim 后空 → nil。UI 副标题取 title 按 `-` 切分的前段（"TokenPlanMax"）。
- `UsageData.subscribeTitle / subscribeEndTime` 仅 MiniMax 填充。

### 3.3 MiniMax 本地活动检测（`Services/MiniMaxActivityDetector.swift`）

只读、绝不读消息体/工具输出；freshness 窗口 120s：
- **CLI 会话**：`$MINIMAX_HOME`（默认 `~/.minimax`）/`v2/sessions/<年>/<月>/<日>/​*-session_<id>/`；每次只扫**最新 2 个**日目录（目录名字典序=时间序，跨午夜也覆盖）；活跃 = 会话目录内**直接子文件最大 mtime** 在窗口内（`manifest.json` 只用于读 `sessionId`——实测可滞后数分钟，不能作活动信号；manifest 损坏回退目录名）。ID 前缀 `minimax:cli:`。
- **后台任务**（MiniMax Code 桌面 App）：`~/.minimax/background-tasks/bg_<uuid>/`；活跃 = max(目录 mtime, `output.log` mtime, `summary.txt` mtime) 在窗口内；ID 前缀 `minimax:bg:`。海量历史 `bg_*` 目录优化：已知过期且目录 mtime 也过期的目录跳过 stat；每 **300s** 一次全量 sweep 兜底「原地续写但目录 mtime 不变」的漏检（测试锁定该 300s 窗口语义）。
- 应用在线检测（跟随运行应用）：bundle ID `com.minimax.agent.cn` / `com.minimax.agent`，进程名 `minimax code` / `minimax`。

---

## 4. GLM(ZCode) 本地活动检测（附带，`Services/ZcodeActivityDetector.swift`）

- 数据源：`$ZCODE_HOME`（默认 `~/.zcode`）/`cli/db/db.sqlite`（SQLite，只读打开）。
- 混合生命周期：交互会话活跃 = `time_updated` 在 120s 窗口内；`turn_usage` 行只在 turn 到达终态（completed/error/cancelled）时 INSERT（带回填时间戳），**新出现的终态行 = 立即结束信号**（不必等满窗口）；`time_updated` 比最近终态行更新 → 仍有后续写入，保持活跃。游标 `lastSeenTurnRowID` 增量消费。
- 会话 ID 前缀 `glm:zcode:`。应用在线：ZCode IDE（见 ProviderAppPresence）。

---

## 5. 凭据存储与 Windows DPAPI 映射建议

### 5.1 现状（macOS Keychain）

**单一 vault 条目**（`CredentialVaultStore`）：
- class `kSecClassGenericPassword`，service **`com.techfanseric.aiquotabar`**，account **`providerCredentials`**，accessible=WhenUnlocked。
- 值为 JSON `CredentialVaultV1`：
```jsonc
{ "version": 1,
  "providers": { "minimax": "<bearer token>", "glm": "<GLMCredential JSON>", "kimi": "<可选 API key>" },
  "deviceCredentials": { "kimi.web-session.v1": "<KimiWebSession JSON {token,origin}>" },
  "cloudSyncToken": null, "mobileDashboardAccessToken": null,
  "mobileDashboardTokenMigration": null,
  "kimiDesktopSafeStorageKey": "<base64 的 Kimi safeStorage 解密密钥副本>" }
```
- 读改写在 actor 内同步串行化（防覆盖竞态）；解码失败**不覆盖原条目**并广播 `didFailToDecodeCredentials`；权限失败静默直至用户重试（`retryFailedAccess`）。
- 旧格式迁移（一次性）：vault 不存在时探测旧 per-key 条目（service `com.techfanseric.aiquotabar`，accounts：`apiKey`/`glmCredential`/`kimiCodeAPIKey`/`codexCredential`；MiniMax 还查旧应用 service `com.minimax.usagemonitor`；device credential 查 `com.techfanseric.aiquotabar.local-usage`），迁入 vault 后删除旧条目。vault 存在则不再探测（避免多余授权弹窗）。
- UserDefaults 辅助缓存 `keychainConfiguredProviderKeys`（已配置提供方集合，启动时先显示后校正）。

**第三方条目（只读）**：
- Kimi 桌面：service **`kimi-desktop Safe Storage`**（无 account），值 = safeStorage 解密密钥（§1.2）。

### 5.2 Windows 映射建议（C# .NET 8）

| macOS | Windows 建议 |
| --- | --- |
| Keychain vault 条目（service `com.techfanseric.aiquotabar`, account `providerCredentials`） | 单文件 `%LOCALAPPDATA%\AIQuotaBar\credential-vault.json`，内容 = 同一 `CredentialVaultV1` JSON，整体 `ProtectedData.Protact(..., DataProtectionScope.CurrentUser)`（DPAPI，System.Security.Cryptography.ProtectedData 包）。保持字段名/version 不变以便跨平台云同步语义一致 |
| 旧 per-key 条目迁移 | 同目录遗留 `%APPDATA%` 旧版文件或旧注册表值的迁移逻辑（Windows 版无 Keychain 历史，可省略；若做 Win→Win 升级则保留迁移路径） |
| `kimi.web-session.v1` deviceCredential | vault JSON 内 `deviceCredentials` 字段原样保留 |
| Kimi `kimi-desktop Safe Storage` | Windows 上 Electron safeStorage 走 **DPAPI**（`CryptProtectData`），存储在 `%APPDATA%\kimi-desktop\...`；Windows 版应直接 `ProtectedData.Unprotect` 对应 blob，**无需** v10/saltysalt/PBKDF2 解密路径（该算法仅 macOS 实现）；「授权一次后缓存密钥副本」的 vault 缓存机制可整体省略（DPAPI 无 per-item ACL 弹窗），但若 Kimi Windows 版仍带加密 token-store，须按其 envelope 版本字段分派 |
| `kSecAttrAccessibleWhenUnlocked` | DPAPI CurrentUser 默认随用户 profile，等价满足；无需额外动作 |
| 解码失败不覆盖 + 通知 | 保持同语义：损坏文件改名备份（如 `.corrupt`）后重建，绝不静默覆盖 |

安全不变量（迁移必须保留）：错误与日志中不出现 token/cookie/响应体；`KimiWebUsageClient` 禁重定向；GLM 重置券只发给已验证 host；浏览器/桌面凭据只读。

---

## 6. 轮询、错误处理与多账号

### 6.1 轮询调度（`UsageViewModel`）

- 全局 Timer：`refreshInterval`（UserDefaults，**默认 600s = 10 分钟**，用户可调；改动即重启 Timer）；`autoRefreshOnLaunch` 默认 true。
- 周期末刷新：`cycleEndTimer` 在某模型窗口到期时触发刷新并重启主 Timer。
- 并发：所有已配置提供方在 TaskGroup 中**并行** fetch（3 提供方 ~30s→~10s）；每轮先 `KimiService.discoverAutomaticSources()`（仅 kimi 未配置 API key 时）。
- 提供方过滤 `shouldFetchProvider`：`codex` 仅 ChatGPT 运行时；**`minimax`/`glm`/`kimi` 恒 true**（后台刷新不因 app 未运行而停）；用户可 pause（`pausedUsageProviders`）。
- 各请求超时：Kimi web 20s（membership 3s）、Kimi CLI 10s、GLM 30s（订阅 15s、重置券 2s）、MiniMax 30s（订阅 15s）。

### 6.2 错误处理

- 单提供方失败：保留上一轮 `providerUsageData[provider]`，错误进 `providerErrors[provider]`（菜单逐提供方显示）；只有**全部无数据**才置全局 error。
- Kimi 专属：401/403 → `expired`（提示重新登录/重导入）；多浏览器账号 → 显式错误不猜测；账号粘性（§1.1）。
- 无 429 专用退避；网络错误下轮重试。
- Kimi 来源切换期间数据丢弃防护：fetch 期间来源 revision 变化则丢弃该轮 kimi 结果。

### 6.3 多账号

- **只有 Codex 支持多账号**（CodexAccountCoordinator，不在本文范围）。
- Kimi：单账号语义，但行上带 `accountLabel`（JWT sub）；多网页账号需用户手动选择，不自动。
- GLM / MiniMax：vault `providers[rawValue]` 单字符串，**单凭据单账号**；GLM 团队上下文（org/project）只随 curl 凭据携带。

---

## 7. 测试锁定的精确行为（迁移验收清单）

**KimiWebSourceTests**（Tests/Kimi）：
1. Electron v10 解密 fixture（base64 blob + "test-password"）；错密钥/非 v10/只有 refresh_token 均拒绝。
2. `validated()`：exp 边界（`exp<=now` 拒绝）；origin 全等白名单（http、`.evil.test` 后缀、`@`、带 path 全拒）；含空白 token 拒绝且错误不泄露 token。
3. Web schema 映射：`limit:"100", remaining:"71"`（字符串数字）→ 5h=84%、7d=71%；membership `amountUsedRatio:0.42` → Total usage 58%；模型顺序 `["5h","7d","Total usage"]`；kimi-monthly `startTime == nil`、`endTime != nil`；derived 窗口 = endTime-1 自然月；pace：到期 7 天后、已用 58% → `stage.isAhead == true`。
4. 只有 membership（usages 空）也出一行 Total usage；stats 畸形不影响 Code 配额；usages 空 + stats 空 → invalidResponse；`limit:"0"` → invalidResponse。
5. 未知 timeUnit → 模型名 `"Rate limit"`、startTime nil。
6. 桌面密钥缓存协议 4 场景：命中不碰 Keychain；交互后缓存；后台无缓存抛 `keychain(errSecInteractionNotAllowed)` 且零写入；后台遇陈旧缓存静默失败（不 clear、不写），交互时 clear+重取+写；不可恢复密钥只试一次。
7. 来源选择：desktop 模式忽略 API key 与 CLI；auto 无桌面时用 CLI；web 模式不读桌面且保留取消传播；空 home 的 `isPresent == false`。
8. live 测试（环境变量门控）：`AIQUOTABAR_LIVE_KIMI_DESKTOP_TEST=1`（桌面真实请求，含 5h/7d 行）、`AIQUOTABAR_LIVE_KIMI_TEST=1`（真实 CLI /status，模型 `["5h","7d"]`）。

**KimiAutomaticSourceTests**：fresh install 桌面优先于 CLI；桌面过期 → 已存 web → CLI；浏览器唯一账号在配置过滤前被发现；CLI 失败回退唯一浏览器；只存 web 时不扫浏览器；**桌面网络失败不跳账号**；检测中取消不启动回退；多浏览器账号抛错、同账号去重、空集 nil；扫描缓存正负结果 + TTL 过期感知登出。

**KimiUsageDataMapperTests**：CLI /status 文本解析 fixture（`89% used resets in 1d 18h 35m` → 剩 11%、resetsAt=now+1d18h35m；`0% used` → 100%）；`11% left`/`100% remaining` 兼容；`Trust this folder?` → `workspaceTrustRequired`；空 snapshot → invalidResponse；映射顺序 `["5h","7d"]`、remaining=100-used、startTime=reset-5h。

**KimiWebUsageClientTests**：membership 失败保留配额与 origin；401/429 错误消息不含响应体 "sensitive-response"；请求方法 POST、host、`Authorization: Bearer`、`Origin` 头。

**GLMUsageTests**：真实 2026-09-11 响应 shape（5h `usage:2000,currentValue:0,remaining:2000` 无 nextResetTime → endTime/startTime nil、`isShortCurrentInterval`、5h 滚动展示窗、paceDelta nil；weekly nextResetTime=1789647732997 → endTime 毫秒精度、startTime=endTime-7d）；菜单栏 ring 跟随 weekly/current 选择，无 weekly 数据时不虚构 pace；旧版 percentage-only TOKENS_LIMIT（`percentage:"12.5"` 字符串）→ 87% 剩、valueSuffix `%`、start=reset-5h；TIME_LIMIT 用订阅 reset 兜底、startTime nil；`code:401/success:false`、空 limits、缺 usage 的条目全部报错不报成功；remaining 越界 clamp 到 0；API key 输入裸/Bearer 两种均 → `open.bigmodel.cn` 端点 + 恰一个 Bearer；curl 解析保留 authorization/org/project/cookie 且 storageString 往返；无 authorization 的 curl 报错；editableString round-trip（含 `'` 转义）；`UsageProvider.glm.keychainAccount == "glmCredential"`。

**GLMResetAllowanceTests**：decode 只认 PERSONAL、available=false 过滤、时间戳精确（`2026-10-18 17:48:12` 上海时区 = `09:48:12Z`）、过期后 available 空；`code:401`、缺 fiveHourResets/weekResets 字段 → invalidResponse；request 门槛：apiKeyURL（open.bigmodel.cn）、代理 host、http、`?type=2`、带 organization 一律不发；`UsageData.withModels` 保留 allowances 且 JSON 编解码往返。

**MiniMaxActivityDetectorTests**：新 transcript 活动 + 陈旧 manifest 仍活跃（manifest 滞后回归）；静默会话忽略；新鲜 bg 任务活跃、陈旧忽略；manifest 损坏回退目录名；超出最新 2 个日目录的会话被排除；根目录缺失 → 空快照；陈旧 bg 目录在全量 sweep（60s 配置）前不重 stat、sweep 后发现原地续写。

**KimiLocalActivityDetectorTests**：running 活跃；completed 即便心跳新鲜也立即非活跃；running 但心跳静默 15 分钟 → 崩溃守卫非活跃；未知状态按 freshness 兜底（新鲜活跃/陈旧不活跃）；无 ledger 时 freshness-only；开 turn 且 30s 内写盘活跃；静默 5 分钟（<10 分钟窗）仍活跃；turn.ended 或静默 15 分钟非活跃；同 session 多 agent 折叠单任务；work 运行时 `conv-*`/`ctitle-*` 带前缀识别。

---

## 8. 关键常量速查

| 常量 | 值 |
| --- | --- |
| Kimi 桌面 token store | `~/Library/Application Support/kimi-desktop/bridge-store/token-store.json`（encryption `safeStorage.v1`） |
| Kimi Keychain 条目 | service `kimi-desktop Safe Storage` |
| Kimi cookie | `kimi-auth`（域 www.kimi.com / www.kimi.ai） |
| Kimi web session 绑定 | `kimi.web-session.v1`（vault deviceCredentials） |
| Kimi 配额 API | `POST {origin}/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`（body `{"scope":["FEATURE_CODING"]}`） |
| Kimi 会员 API | `POST {origin}/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats`（body `{}`） |
| Kimi CLI | `$KIMI_CODE_HOME/bin/kimi` 或 PATH `kimi`；PTY 60x180、超时 10s、idle 1.2s、`/status\r` |
| Kimi 浏览器扫描 TTL | 300s |
| GLM API key 端点 | `GET https://open.bigmodel.cn/api/monitor/usage/quota/limit` |
| GLM web 端点 | `GET https://bigmodel.cn/api/monitor/usage/quota/limit`（默认） |
| GLM 订阅列表兜底 | `GET {origin}/api/biz/subscription/list` |
| GLM 重置券 | `GET https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL`（2s） |
| GLM header 缺省 | Accept/Content-Type/Authorization/Accept-Language:zh/Set-Language:zh |
| MiniMax 配额 | `GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains` |
| MiniMax 订阅 | `GET https://www.minimaxi.com/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7` |
| Vault | service `com.techfanseric.aiquotabar` / account `providerCredentials`（旧 accounts：`apiKey`/`glmCredential`/`kimiCodeAPIKey`；旧 MiniMax service `com.minimax.usagemonitor`） |
| 全局刷新 | 默认 600s，autoRefreshOnLaunch=true |

## 9. 迁移待办（本仓库无法核实的 codexbar 细节）

以下符号定义在兄弟仓库 `codexbar`（本机未签出），迁移前须核对其源码补齐端点/协议细节：
1. `KimiUsageFetcher.fetchCodeAPIUsage(apiKey:baseURL:)` —— Kimi Code API key 模式的确切端点、请求头与响应 JSON（本仓库只有调用点与来源标签 "Kimi Code API"）。
2. `KimiSettingsReader.codeAPIBaseURL()` / `hasKimiCodeCredential()` —— `~/.kimi-code` 设置文件格式与登录凭据检测逻辑。
3. `TTYCommandRunner`（PTY 协议细节：fork/pty 对、环境传递、`which` 实现）与 `TextParsing`（ANSI/OSC 剥离正则的完整集合）。
4. `KimiCookieImporter.importSessions(from:)` —— 各浏览器 Cookie 存储路径/加密（Chrome Keychain 加密 Cookie 等）；Windows 上需改读各浏览器 DPAPI 加密的 Cookie 库。
5. `KimiDesktopAuthToken` —— 旧版 kimi-desktop token 的存储位置与格式。
6. `RateWindow`/`UsageSnapshot`/`UsagePace.historical` —— pace stage 分桶常量（本文按注释记录为 |delta|≤2/≤6/≤12/>12）。
7. Windows 上 Kimi/GLM/MiniMax 桌面应用的数据目录与加密方式（Electron DPAPI、浏览器 Cookie 存储）需现场勘查后替换 §1.2/§1.4 的 macOS 路径。
