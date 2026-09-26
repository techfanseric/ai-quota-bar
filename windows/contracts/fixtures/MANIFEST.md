# windows/contracts/fixtures 采样清单（MANIFEST）

本目录是 Windows（C#）移植契约测试的 fixture 种子库。每个样本一行：文件、Provider、端点/场景、来源（仓库相对路径:行号，或 codexbar 资源路径）、来源标签、建议断言要点。

- 来源标签 `[test-synthesized]`：样本提取自 Swift 测试中的内嵌 JSON / fixture 文件，字段结构可信、数值为测试合成值。
- 来源标签 `[real-traffic-pending]`：尚无真实流量样本，等待 macOS 实机抓包录制（见 README.md）。
- 来源标签 `[synthesized-pending-capture]`：契约优先合成的全新端点形状——仓库内无任何 Swift / codexbar 来源，仅端点 URL 与鉴权方式来自线上观察（客户端日志），字段名与数值均为本仓库设计。真实抓包录制后必须逐字段校准或整体替换（见 README.md 政策 1）。
- 所有样本中的 token / 邮箱 / 账号 ID 均为测试占位值（如 `at-test-token`、`fixture-token`、`pat@example.com`），原样保留；本次未发现需要脱敏的真实凭据。

## codex/

| 文件 | Provider | 端点 / 场景 | 来源 | 标签 | 建议断言要点 |
| --- | --- | --- | --- | --- | --- |
| usage-response-pro-spark.json | Codex | `GET https://chatgpt.com/backend-api/wham/usage`（OAuth；PAT 走同路径，自定义 base 时为 `/api/codex/usage`） | .dependencies/codexbar/Tests/CodexBarTests/CodexAdditionalRateLimitsTests.swift:8-46 | [test-synthesized] | `rate_limit.primary_window`（5h，18000s）、`secondary_window`（weekly，604800s）、`additional_rate_limits[]` 的 `limit_name`/`metered_feature`/两层窗口；`reset_at` 为秒级 Unix 时间戳；`windowMinutes = limit_window_seconds/60`（300/10080） |
| usage-response-oauth-windows.json | Codex | 同上（仅主/周窗口的最小形态） | .dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift:170-186 | [test-synthesized] | 无 `plan_type` 时也能映射窗口；`used_percent` 22→primary、43→secondary；dataConfidence 为 exact |
| usage-response-free-weekly-only.json | Codex | 同上（free 计划仅周窗口） | .dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift:271-285 | [test-synthesized] | `primary_window` 含 604800s 时必须映射为 secondary(weekly)，primary 为空；`plan_type: "free"` |
| usage-response-unknown-window.json | Codex | 同上（非 5h/weekly 的未知窗口） | .dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift:326-338 | [test-synthesized] | `limit_window_seconds: 32400`（9h）保留为 primary 且 windowMinutes=540，不得丢弃或强行归为 5h |
| usage-response-pat-team-weekly.json | Codex | 同上（PAT / API key 模式，team 计划） | .dependencies/codexbar/Tests/CodexBarTests/CodexPATTests.swift:172-184, 208-219 | [test-synthesized] | PAT 来源 sourceLabel=pat；weekly-only 窗口进 secondary；账号邮箱/计划来自 whoami 而非该响应 |
| usage-response-credits-balance-string.json | Codex | 同上（credits 余量为字符串） | .dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift:117-129 | [test-synthesized] | `credits.balance` 可能为字符串 `"0"`，需容忍数字/字符串双形态；`has_credits:false`+`unlimited:false` |
| usage-response-business-workspace-credits.json | Codex | 同上（business 工作区 + 个人限额） | .dependencies/codexbar/Tests/CodexBarTests/CodexWorkspaceBalanceTests.swift:55-62 | [test-synthesized] | 根级 `individual_limit{limit,used}`（额度上限语义，remaining=limit-used=100）；`balance` 可为 null；`account_id` 用于工作区余额接口的账号匹配 |
| usage-response-additional-malformed-siblings.json | Codex | 同上（additional_rate_limits 混入畸形元素） | .dependencies/codexbar/Tests/CodexBarTests/CodexAdditionalRateLimitsTests.swift:77-95 | [test-synthesized] | 损失容忍解码：数组内非对象元素（字符串/数字）跳过，合法 Spark 条目保留；primary/weekly 不受影响 |
| whoami-response-pat.json | Codex | `GET https://chatgpt.com/backend-api/api/accounts/v1/user-auth-credential/whoami`（PAT 模式第一步） | .dependencies/codexbar/Tests/CodexBarTests/CodexPATTests.swift:153-159, 194-203 | [test-synthesized] | `chatgpt_account_id` 需回填到后续 usage 请求的 `ChatGPT-Account-Id` 头；`email`、`chatgpt_plan_type` 用于身份展示 |
| workspace-remaining-balance-response.json | Codex | `GET .../wham/.../remaining_balance`（工作区剩余积分，路径后缀 `/remaining_balance`） | .dependencies/codexbar/Tests/CodexBarTests/CodexWorkspaceBalanceTests.swift:171 | [test-synthesized] | 响应仅含 `balance`（数字，亦兼容字符串，见 CodexWorkspaceRemainingBalanceResponse）；账号不匹配时丢弃该结果 |
| rate-limit-reset-credits-response.json | Codex | `GET .../backend-api/wham/rate-limit-reset-credits`（OAuth 附带请求） | .dependencies/codexbar/Tests/CodexBarTests/CodexRateLimitResetCreditsTests.swift:29 | [test-synthesized] | `available_count`（负数必须拒绝）、`credits[]`；该接口失败不得影响主额度 |
| auth-json-oauth.json | Codex | 本地凭据文件 `~/.codex/auth.json`（OAuth 形态） | .dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift:31-43 | [test-synthesized] | `tokens.access_token/refresh_token/id_token/account_id`（snake_case，兼容 camelCase 变体）+ `last_refresh`；`OPENAI_API_KEY` 为 null |
| auth-json-pat.json | Codex | 本地凭据文件 `~/.codex/auth.json`（PAT 形态） | .dependencies/codexbar/Tests/CodexBarTests/CodexPATTests.swift:13-18 | [test-synthesized] | `personal_access_token`；纯 PAT 文件不得被当作 OAuth 解析（missingTokens 错误）；空白 PAT 视为缺失 |
| usage-snapshot-current.json | Codex | App 层 `UsageSnapshot` 序列化形态（跨 provider 的中间表示） | .dependencies/codexbar/Tests/CodexBarTests/Fixtures/usage-snapshot-current.json | [test-synthesized] | `primary{usedPercent,windowMinutes,resetsAt(ISO8601),resetDescription}`、`providerCost{used,limit,currencyCode,period}`、`identity{providerID,accountEmail,accountOrganization,loginMethod,accountID}`、`dataConfidence` |
| local-session-rollout.jsonl | Codex | 本地用量 `~/.codex/sessions/**.jsonl` 的 `session_meta` 行 | .dependencies/codexbar/Tests/CodexBarTests/Fixtures/agent-session-rollout.jsonl | [test-synthesized] | `session_meta.payload.session_id/cwd/originator/source`；解析器只读首行 session_meta，后续任意行不得使解析失败 |
| local-session-token-usage.jsonl | Codex | 本地用量 `~/.codex/sessions/**.jsonl` 的 turn_context / token_count 行（按 UsageTests 助手函数的具体值逐行序列化） | Tests/CodexLocalUsageCoreTests/UsageTests.swift:5-33（testRepeatedQuotaSnapshotsAndIdenticalRealRequests） | [test-synthesized] | `event_msg.payload.type=="token_count"`，`info.last_token_usage`（优先）与 `info.total_token_usage`（累计差值）字段 `input_tokens/cached_input_tokens/cache_write_input_tokens/output_tokens/reasoning_output_tokens`；`rate_limits.limit_id` 参与去重；相同时间戳不同 limit_id 不去重，相同则去重 |

Codex 端点/路径依据：`.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift:380-382`（`/wham/usage`、`/api/codex/usage`）、`:385`（`/remaining_balance` 后缀）。

## kimi/

| 文件 | Provider | 端点 / 场景 | 来源 | 标签 | 建议断言要点 |
| --- | --- | --- | --- | --- | --- |
| getusages-request.json | Kimi | `POST {origin}/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`（origin = `https://www.kimi.com` 或 `https://www.kimi.ai`）请求体 | AIQuotaBar/Services/Kimi/KimiWebUsageClient.swift:22-24 | [test-synthesized] | 请求体 `{"scope":["FEATURE_CODING"]}`；Content-Type: application/json，头 `connect-protocol-version: 1`、Bearer token、Origin/Referer |
| getusages-response-coding.json | Kimi | 同上响应（web 桌面双窗口完整形态） | AIQuotaBar/Tests/Kimi/KimiWebSourceTests.swift:6 | [test-synthesized] | `usages[].scope=="FEATURE_CODING"`；`detail.limit/remaining` 为**字符串**，resetTime 带微秒 ISO8601（weekly=7d）；`limits[].detail` 为**数字**，`window{duration,timeUnit}`（300×TIME_UNIT_MINUTE=5h）；detail 双形态（字符串/数字）都必须接受 |
| getusages-response-numeric-detail.json | Kimi | 同上响应（numeric detail 简化形态，URLProtocol 桩） | AIQuotaBar/Tests/Kimi/KimiWebUsageClientTests.swift:51 | [test-synthesized] | 顶层 detail 用数字类型（limit:100, remaining:60→40% used）；无 limits 数组时仅 weekly 窗口 |
| getusages-response-empty.json | Kimi | 同上响应（空 usages） | AIQuotaBar/Tests/Kimi/KimiWebSourceTests.swift:101 | [test-synthesized] | 空数组 → invalidResponse 错误（不得报“连接成功”） |
| getusages-response-zero-limit.json | Kimi | 同上响应（limit=0） | AIQuotaBar/Tests/Kimi/KimiWebSourceTests.swift:102 | [test-synthesized] | `limit:"0"` 无法构成有效窗口 → 解析失败；仅 `used` 无 `remaining` 且 limit=0 时拒绝 |
| getsubscriptionstats-response-omni.json | Kimi | `POST {origin}/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats`（请求体 `{}`）响应 | AIQuotaBar/Tests/Kimi/KimiWebSourceTests.swift:41 | [test-synthesized] | `subscriptionBalance{feature:"FEATURE_OMNI",type:"SUBSCRIPTION",amountUsedRatio,kimiCodeUsedRatio,expireTime}`；ratio 0.42→"Total usage" 58% 剩余；expireTime 推导月度展示窗口但不写 startTime |
| getsubscriptionstats-response-ratio-only.json | Kimi | 同上响应（仅 ratio，可选字段缺失） | AIQuotaBar/Tests/Kimi/KimiWebSourceTests.swift:54 | [test-synthesized] | feature/type/expireTime 可缺失；stats 失败/畸形不丢弃 code 配额（可选增强语义） |
| cli-status-output-session-none.txt | Kimi | `kimi` CLI `/status` 文本输出（无会话形态） | AIQuotaBar/Tests/Kimi/KimiUsageDataMapperTests.swift:53-58 | [test-synthesized] | 进度条文本解析：`Weekly limit ... 89% used ... resets in 1d 18h 35m`（剩余 11%）、`5h limit ... 0% used ... resets in 1h 35m`；`Session none` 行存在 |
| cli-status-output-percent-left.txt | Kimi | 同上（"percent left" 兼容变体） | AIQuotaBar/Tests/Kimi/KimiUsageDataMapperTests.swift:73-77 | [test-synthesized] | `11% left`/`100% remaining` 两种措辞都映射为剩余百分比；`Trust this folder?` 一类提示文本必须拒绝（workspaceTrustRequired） |
| desktop-token-store.json | Kimi | Kimi Desktop 本地 `bridge-store/token-store.json`（macOS: `~/Library/Application Support/kimi-desktop/bridge-store/`） | AIQuotaBar/Tests/Kimi/KimiWebSourceTests.swift:264 | [test-synthesized] | `encryption:"safeStorage.v1"` + base64 `data`（Electron safeStorage v10 密文，密钥来自 Kimi 的 Keychain 条目）；内为测试合成密文（解出 `fixture-token`，密码 `test-password`） |
| desktop-conversation-context-usage.json | Kimi | 本地活动检测 `kimi-agent/conversation-context-usage.json`（按测试具体值序列化；时间戳对应测试基准 epoch 1000000） | AIQuotaBar/Tests/Kimi/KimiLocalActivityDetectorTests.swift:8-15, 143-153 | [test-synthesized] | 键格式 `agent:main:main:conversation:{id}`；值 `contextUsage/contextTokens/maxContextTokens/model(k3-agent)/updatedAt`（毫秒精度 ISO8601）；10 分钟内=活跃 |
| cli-wire.jsonl | Kimi | 本地活动检测 `.kimi-code/sessions/{workspace}/{session}/agents/{agent}/wire.jsonl`（按测试具体值序列化） | AIQuotaBar/Tests/Kimi/KimiLocalActivityDetectorTests.swift:28-39, 172-175 | [test-synthesized] | 行格式 `{"type":"turn.prompt","time":<毫秒>}`；`turn.ended` 结束会话；同 session 多 agent 合并为一个活跃任务 |

## glm/

| 文件 | Provider | 端点 / 场景 | 来源 | 标签 | 建议断言要点 |
| --- | --- | --- | --- | --- | --- |
| quota-limit-response-credit-windows-observed.json | GLM | `GET https://bigmodel.cn/api/monitor/usage/quota/limit`（web 会话）／`https://open.bigmodel.cn/...`（API Key Bearer） | AIQuotaBar/Tests/GLM/GLMUsageTests.swift:54（测试注释：结构来自 2026-09-11 个人用量页实测核对，数值已替换；docs/glm-api-field-mapping.md:20-41 佐证） | [test-synthesized] | `code/success` 包裹；`data.level`；`limits[]`：`type:"CREDIT_LIMIT"`，`unit/number` 决定周期（3/5=5h，6/1=weekly），`usage`=总额度、`currentValue`=已用、`remaining`=服务端剩余（独立取整，≠usage-currentValue）、`nextResetTime`=毫秒时间戳可缺失；5h 窗口无 reset 时不伪造起止时间 |
| quota-limit-response-credit-single-window.json | GLM | 同上（仅 5h 窗口） | AIQuotaBar/Tests/GLM/GLMResetAllowanceTests.swift:39 | [test-synthesized] | 单 CREDIT_LIMIT 也能出一条模型；无 nextResetTime 时窗口起点为空 |
| quota-limit-response-legacy-tokens-time.json | GLM | 同上（旧版 TOKENS_LIMIT/TIME_LIMIT，字段为字符串） | AIQuotaBar/Tests/GLM/GLMUsageTests.swift:80 | [test-synthesized] | `percentage:"12.5"`（字符串百分比→87% 剩余，值后缀 %）；`TIME_LIMIT usage/currentValue` 字符串数字；缺周期字段按旧版 5h 窗口处理（见 docs/glm-api-field-mapping.md:57-61） |
| quota-limit-response-error-401.json | GLM | 同上（会话过期错误体） | AIQuotaBar/Tests/GLM/GLMUsageTests.swift:93 | [test-synthesized] | `code:401, success:false, msg` → 解码失败，不得报告连接成功 |
| quota-limit-response-empty-limits.json | GLM | 同上（空 limits） | AIQuotaBar/Tests/GLM/GLMUsageTests.swift:94 | [test-synthesized] | `limits:[]` → 错误（避免“连接成功但没有数据”） |
| quota-limit-response-credit-missing-fields.json | GLM | 同上（条目缺数值字段） | AIQuotaBar/Tests/GLM/GLMUsageTests.swift:95 | [test-synthesized] | 仅 `type:"CREDIT_LIMIT"` 无数值 → 错误 |
| quota-limit-response-out-of-range.json | GLM | 同上（remaining 越界） | AIQuotaBar/Tests/GLM/GLMUsageTests.swift:102 | [test-synthesized] | `remaining:-20`/`currentValue:120` → 剩余量钳制到 0，不抛错 |
| reset-allowances-response-personal.json | GLM | `GET https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL`（仅 web 会话凭据、无组织） | AIQuotaBar/Tests/GLM/GLMResetAllowanceTests.swift:6-16 | [test-synthesized] | `data.targetType=="PERSONAL"`（TEAM 拒绝）；`fiveHourResets[]/weekResets[]{available,expireTime}`，expireTime 格式 `"yyyy-MM-dd HH:mm:ss"`（按 UTC+8 解析）；只统计 available=true |
| reset-allowances-response-error-401.json | GLM | 同上（错误体） | AIQuotaBar/Tests/GLM/GLMResetAllowanceTests.swift:14 | [test-synthesized] | `{"code":401,"success":false}` 与缺 resets 数组都拒绝 |
| coding-plan-balance.synthetic.json | GLM | `GET https://zcode.z.ai/api/v1/zcode-plan/billing/balance`（ZCode 桌面客户端 coding-plan 余额；`Authorization: Bearer {JWT}`，凭据存 `~/.zcode/v2/credentials.json`） | 无仓库来源——契约优先合成（端点 URL 来自 ZCode 桌面客户端日志，响应形状未录制，字段为 Windows 端设计） | [synthesized-pending-capture] | `code/msg` 信封（无 `success` 字段，与大 model.cn 端点不同）；`data.total/remaining` 为**计数**（正值，数字形态）；`data.startTime`（可选）、`data.resetTime`（必填）为 ISO8601 文本；归一为百分比制单行 "Coding Plan"（GlmCodingPlanParser）。校准点：信封字段、数字/字符串形态、时间戳精度与时区（Z 或 +08:00）——待 Windows 实机登录 ZCode 抓包后以真实样本替换 |

GLM 端点依据：`AIQuotaBar/Tests/GLM/GLMUsageTests.swift:110,121`、`AIQuotaBar/Models/GLMResetAllowances.swift:55`、`AIQuotaBar/Services/UsageService.swift:429`（旧版辅助 `/api/biz/subscription/list`，无样本）。coding-plan 端点无 Swift 依据（ZCode 桌面客户端为 Electron 应用，Windows 端新增），URL 见上表。

## minimax/

| 文件 | Provider | 端点 / 场景 | 来源 | 标签 | 建议断言要点 |
| --- | --- | --- | --- | --- | --- |
| token-plan-remains-normal.json | MiniMax | `GET https://platform.minimax.io/v1/token_plan/remains`（Global；CN 为 platform.minimaxi.com；备选 `v1/api/openplatform/coding_plan/remains`；Cookie 头鉴权，可带 group_id 查询参数） | .dependencies/codexbar/Tests/CodexBarTests/Fixtures/Providers/MiniMax/token-plan-normal.json（断言依据 ProviderQuotaFixtureContractTests.swift:8-22） | [test-synthesized] | `base_resp.status_code==0`；`data.current_subscribe_title`；`model_remains[]`：**`_usage_count` 字段=剩余数量而非已用**（docs/api-field-mapping.md 核心约定）；`current_interval_remaining_percent:"96"`（字符串）、weekly 同理；`start_time/end_time/weekly_*` 毫秒时间戳；5h=18000s、weekly=604800s |
| token-plan-remains-missing-reset.json | MiniMax | 同上（缺重置时间戳） | .dependencies/codexbar/Tests/CodexBarTests/Fixtures/Providers/MiniMax/token-plan-missing-reset.json（断言依据 ProviderQuotaFixtureContractTests.swift:25-41） | [test-synthesized] | 无 `start_time/end_time` 时窗口仍保留（windowMinutes 300/10080），resetsAt 为 null；此时 percent 为数字类型（非字符串）——双形态都要兼容；`points_balance` 可缺失 |

MiniMax 端点依据：`.dependencies/codexbar/Sources/CodexBarCore/Providers/MiniMax/MiniMaxAPIRegion.swift`、`MiniMaxUsageFetcher.swift:10-11`。注意：AIQuotaBar 本体当前未实现 MiniMax 用量拉取（仅本地活动检测，读 `manifest.json`/`messages.jsonl`），Windows 端如实现拉取需以 codexbar 实现为准。

## clash/

| 文件 | Provider | 端点 / 场景 | 来源 | 标签 | 建议断言要点 |
| --- | --- | --- | --- | --- | --- |
| connections-response-mihomo.json | Clash | `GET http://127.0.0.1:9097/connections`（mihomo/Clash RESTful API，`Authorization: Bearer {secret}`；亦用于 WebSocket `/connections` 流式帧） | AIQuotaBar/Tests/Clash/ClashConnectionTests.swift:170-197 | [test-synthesized] | `downloadTotal/uploadTotal/memory`；`connections[]{id,download,upload,chains[],rule,rulePayload,start(微秒精度ISO8601),metadata{network,type,destinationIP,host,process,processPath,remoteDestination,sniffHost}}`；OpenAI 过滤匹配 host/sniffHost/rulePayload 的 openai.com|chatgpt.com 后缀 |
| clash-verge-config.yaml | Clash | 本地配置发现 `clash-verge.yaml`（macOS: `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/`；Windows 端需替换为 Verge Rev 的 Windows 数据目录） | AIQuotaBar/Tests/Clash/ClashConfigurationDiscoveryTests.swift:51-54 | [test-synthesized] | 只读**顶层** `external-controller`（`0.0.0.0` 归一化为 `127.0.0.1`，拒绝非回环远端主机）与 `secret`（带注释的引号值）；忽略嵌套键（如 dns.secret） |

Clash 端点依据：`AIQuotaBar/Services/Clash/ClashAPIClient.swift:40,45,114,117,164`（`/version`、`/connections`、`/proxies`、`/rules`）。`/version`、`/proxies`、`/rules` 三个端点在现有资产中无 JSON 响应样本（相关测试用 Swift 结构体直接构造），见 README 缺口清单。

## 敏感值核查记录（2026-09-24 采录时）

- 逐一核对了全部来源样本，未发现真实 token、真实邮箱或真实会话 ID：测试内嵌 JSON 的凭据均为占位值（`at-test-token`、`fixture-token`、`access-token`、`sk-test` 等），邮箱均为 `*@example.com` 或测试账户名。
- `desktop-token-store.json` 的 base64 密文为测试合成（用 `test-password` 加密 `fixture-token` 生成），非真实会话。
- codexbar 的 `codex-plan-utilization-real-migration.json` 含真实本机用量历史（SHA-256 哈希与账号键），因其属于本地历史存储格式而非 API 契约，未纳入本库，避免引入真实遥测数据。
- 因此本库未执行任何 `<REDACTED-*>` 替换；后续录制真实流量时必须执行（政策见 README.md）。
