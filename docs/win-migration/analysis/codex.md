# Codex 提供方(配额获取) + 本地用量统计 + Codex 任务检测 — Windows 迁移规格

> 源码范围:
> - `AIQuotaBar/Services/Codex/`(全部 16 个文件)
> - `AIQuotaBar/Services/CodexWatch/`(注意:这是「关注他人账号额度」云功能,不是任务监视)
> - `AIQuotaBar/Services/CodexLocalUsage/CodexLocalUsageModel.swift`(本地用量 UI 编排层)
> - `Sources/CodexLocalUsageCore/`(全部 7 个文件:解析/存储/客户端核心)
> - `Sources/CodexUsageAudit/main.swift`(只读审计 CLI)
> - `AIQuotaBarHook/main.swift`(Codex 生命周期 hook 转发器)
> - 外部依赖:`CodexBarCore`(同级 `codexbar` 仓库,本仓库锁定基线 `b6e65a83dc471817b7ff7678e68e0204c9dd604f`;OAuth 抓取/刷新实现不在本仓库内,本文引用上游 codexbar main 分支对应源码并标注)
> - 测试:`Tests/CodexLocalUsageCoreTests/`(7 文件)、`AIQuotaBar/Tests/Codex/` 相关用例
> - 文档:`docs/codex-local-usage.md`、`docs/codex-watch-accounts.md`、`docs/task-detection-accuracy-plan.md`、`docs/superpowers/specs/2026-06-02-codex-subsystem-rewrite-design.md`

本模块由四条相互独立的数据链组成:

| 链路 | 驱动者 | 周期 | 数据落盘 |
|---|---|---|---|
| A. 配额(rate limit)抓取 | `CodexService` → CodexBarCore 策略(oauth/cli/web) | 默认 600s,周期结束 +15s 对齐刷新 | `account-quota.json`(每账号) |
| B. 本地用量统计 | `CodexLocalUsageModel` → `UsageStore.scan` | 60s(tolerance 5s) | `local-usage.sqlite`(WAL) |
| C. 任务检测(hook 源) | `CodexHookListener` ← `AIQuotaBarHook`(事件推送) | 事件驱动 | 无(内存) |
| D. 任务检测(本机源) | `CodexSleepProtectionCoordinator` → `CodexLocalActivityDetector` | 2s 轮询 | 无(内存,增量 offset) |

另有两个辅助链路:网络连通性监视(`CodexConnectivityMonitor`,8–12s)、关注账号云发布/拉取(`CodexWatchStore`,随配额刷新周期)。

---

## 1. Codex 凭据获取

### 1.1 `~/.codex/auth.json` 的确切 JSON 结构

Codex 根目录:环境变量 `CODEX_HOME` 优先,否则 `~/.codex`(所有读取点统一遵守,Windows 迁移必须保持一致,`%USERPROFILE%\.codex`)。

```json
{
  "OPENAI_API_KEY": "sk-...",          // 可选;存在且非空 → API Key 模式(优先级最高)
  "auth_mode": "chatgpt",              // 可选;缺失按 chatgpt 处理;非 "chatgpt" → 未登录
  "tokens": {
    "account_id": "org-xxxx",          // 必需且非空,否则视为未登录
    "access_token": "eyJhbGciOi...",   // JWT;camelCase 变体 accessToken 也被 CodexBarCore 接受
    "refresh_token": "rt_...",         // refreshToken 变体同样接受
    "id_token": "eyJ..."               // 可选 JWT;用于解出 email(payload base64url 解码后取 claims.email)
  },
  "last_refresh": "2026-10-17T12:00:00Z"  // CodexBarCore 刷新后写回(ISO8601 无毫秒)
}
```

分类判定(`Sources/CodexLocalUsageCore/AuthFileInspection.swift` → `CodexAuthFileReader.interpret`,顺序固定):

```
if OPENAI_API_KEY 非空           → .apiKeyMode        (即使 tokens 里还有残留 chatgpt token)
else if auth_mode 存在且 != "chatgpt" → .unauthenticated
else if tokens.account_id 缺失或为空   → .unauthenticated
else                              → .chatgptLogin(accountDigest, email)
```

- `email` = base64url 解码 `id_token` 的 payload 段,取 `email` claim(3 段式校验,签名不验证)。
- `accountDigest` = `SHA256("codex-account|" + account_id)` 的小写十六进制(64 字符)。**这是云端账本与本地账号池的关联键,Windows 版必须逐字节一致。**
- 读文件带撕裂读防护:读前后比对 mtime + fileSize 相同才接受;文件大小必须在 `(0, 262144)` 字节内;否则 `.unreadable`。不匹配任何形态返回 `.unreadable` 而非抛错。

### 1.2 OAuth token 刷新流程(CodexBarCore `CodexTokenRefresher`,上游源码核对)

- 端点:`POST https://auth.openai.com/oauth/token`
- Header:`Content-Type: application/json`
- Body(JSON):

```json
{
  "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
  "grant_type": "refresh_token",
  "refresh_token": "<auth.json tokens.refresh_token>",
  "scope": "openid profile email"
}
```

- 200 响应:`{ "access_token": "...", "refresh_token": "...", "id_token": "..." }`;缺失的字段回退保留旧值。
- 写回 `auth.json`(CodexBarCore `CodexOAuthCredentialsStore.save`):读取现有 JSON → 只替换 `tokens.{access_token, refresh_token, id_token?, account_id?}` 与根级 `last_refresh` → prettyPrinted + sortedKeys 序列化 → 以 owner-only 权限(macOS 0600)原子写。其他键原样保留。
- 失败分类(按响应体 `error.code` / `error` / `code`,再按状态码):`refresh_token_expired` 或 401 → expired;`refresh_token_reused` → reused;`invalid_grant` / `refresh_token_invalidated` → revoked;其余 → invalidResponse。ai-quota-bar 侧把 `.unauthorized` 映射为用户可见文案 `"Codex token expired — run `codex` to refresh"`。
- 刷新时机(`CodexOAuthCredentials.needsRefresh`):从 access_token JWT `exp` 解析过期时间;`codexHome` 来源在到期前 5 分钟内刷新,外部来源 60 秒;无 exp 时按 `last_refresh` 超过 8 天刷新。API Key 模式永不刷新。

### 1.3 多账号区分(两层,各自独立)

**(a) 本仓库的「免登录切换账号池」(`CodexAuthAccountStore`,全部为文件改名操作,不触碰 token 内容):**

- 账号池目录:`~/.codex/accounts/*.json`(文件名即显示名 label,过滤隐藏文件,按 label 不区分大小写排序)。
- 切换 = 原子改名接力:
  1. 守卫:ChatGPT/Codex 桌面版(bundle id 精确匹配 `com.openai.codex` / `com.openai.chatgpt.codex` / `com.openai.chat`,或 bundle id 含片段 `codex`,或进程名 `chatgpt`/`codex`,且只统计常规 GUI 应用)或 codex CLI(`/usr/bin/pgrep -x codex` 或 `pgrep -f @openai/codex` 任一命中)在运行 → 挂起请求,每 3s + 应用启停通知接力检查;自动模式先替用户执行一次「激活 + terminate()」正常退出。
  2. 当前 `auth.json` 若是 chatgptLogin → 改名入池(同指纹已有备份则替换,保留原 label;否则用 email 本地部分生成唯一 label,冲突追加 ` 2`/` 3`;label 清洗:禁止 `/:\\?%*|"<>`,空白折叠,截断 60 字符);若是未登录占位文件 → 直接删除;API Key/无法识别 → 中止不动。
  3. 目标备份改名上位为 `auth.json`。
  4. 随机延迟 1–2s 后拉起 ChatGPT.app;通知用户。写完后立即调用 `CodexLocalUsageModel.refreshCurrentAccount()` 让账号观测跟上。
- 旧手工备份:`~/.codex/auth *.json`(前缀 `auth ` 后缀 `.json`)可一键收编入池。
- 删除备份:优先移入废纸篓,失败再直接删除。

**(b) CodexBarCore 的 `FileManagedCodexAccountStore`**(`CodexAccountCoordinator` 包装):`ManagedCodexAccountSet{version, accounts: [ManagedCodexAccount{id: UUID, email, workspaceLabel, managedHomePath, lastAuthenticatedAt: Unix秒}]}`,提供设置页账号列表/移除。Windows 版可先实现 (a),(b) 为设置页增强项。

### 1.4 抓取期间的账号观察(`CodexService.fetchUsage`)

```
before = UsageAccountObservation.read(root)      # 解析 auth.json → {at, accountDigest, email, generation}
result = descriptor.fetch(context)               # 抓取配额(可能耗时,期间账号可能被切换)
after  = UsageAccountObservation.read(root)
if before.accountID == after.accountID:          # 稳定才记账
    CodexAccountQuotaStore.record(digest, primary/secondary 的 usedPercent 与 resetsAt)
    # 用于账号切换面板展示每个池内账号「上次获取到的配额」
CodexSubscriptionStatus.receive(...)             # 仅 web 源的订阅续期/到期标记
```

`generation` = `"\(auth.json mtime unix秒):\(文件字节数)"`,用于时间线去重(见 §3.6)。

前置守卫:`CodexAppPresence.isRunning` 为假(Codex/ChatGPT 桌面版未运行)时直接抛 `apiError("Codex app is not running; usage refresh skipped.")`,不发请求。

---

## 2. 配额(rate limit)获取

### 2.1 数据源策略(CodexBarCore)

`CodexDataSourceMode`(UserDefaults key `codexSourceMode`,`auto|oauth|cli|web`,默认 `auto`)。`auto` 在 app 运行时下解析为策略序列 `[oauth, cli]`,失败逐级回退(cli 失败后可再回退 web);`shouldFallback` 决定是否继续。返回 `ProviderFetchResult{usage: UsageSnapshot, credits: CreditsSnapshot?, sourceLabel: "oauth"|"codex-cli"|"openai-web"}`。

### 2.2 OAuth 源:确切 API 调用(CodexBarCore `CodexOAuthUsageFetcher`,上游源码核对)

**用量主端点(GET):**

- 基础 URL:默认 `https://chatgpt.com/backend-api/`;可被 `~/.codex/config.toml` 中 `chatgpt_base_url = "..."` 覆盖(解析:按行拆 `#` 注释、`key = value`、剥引号)。URL 以 `https://chatgpt.com` 或 `https://chat.openai.com` 开头且不含 `/backend-api` 时自动补 `/backend-api`;去尾部 `/`。
- 路径规则(按本仓库锁定基线之后的上游 main;**迁移前需对照锁定 revision 验证,历史版本用过 `/codex/usage`**):
  - 规范化后含 `/backend-api` → GET `https://chatgpt.com/backend-api/wham/usage`
  - 否则(自定义代理) → GET `<base>/api/codex/usage`
- 请求 Headers:

```
Authorization: Bearer <access_token>
User-Agent: CodexBar            (Windows 版建议换成自己的 UA)
Accept: application/json
ChatGPT-Account-Id: <tokens.account_id>   (账号 id 存在且非空时携带)
```

- 超时 30s,`reloadIgnoringLocalCacheData`。HTTP 非 2xx/401 → `CodexOAuthFetchError`;401 触发 token 刷新后重试一次。

**辅助端点(同一 base,均为 GET + Bearer + ChatGPT-Account-Id):**

| 端点 | 用途 | 额外 Header |
|---|---|---|
| `/wham/rate-limit-reset-credits` | 5h 重置信用券(可用次数/状态) | `OpenAI-Beta: codex-1`、`originator: Codex Desktop` |
| `/accounts/{account_id}/spend-controls/current-user/monthly-usage` | 团队/企业月度消费控制 | — |
| `/accounts/{account_id}/remaining_balance` | workspace 剩余余额 | — |

(account_id 做路径百分编码,剔除 `/?#%`。)

### 2.3 响应 JSON 结构与 5h/Weekly 解析

```json
{
  "account_id": "org-xxxx",
  "plan_type": "pro",
  "rate_limit": {
    "primary_window":   { "used_percent": 35,  "reset_at": 1788832800, "limit_window_seconds": 18000 },
    "secondary_window": { "used_percent": 0,   "reset_at": 1789344000, "limit_window_seconds": 604800 },
    "individual_limit": { "limit": 100.0, "used": 12.5, "remaining_percent": 87.5, "resets_at": 1788832800 }
  },
  "credits": { "has_credits": true, "unlimited": false, "balance": 1234.0 },
  "individual_limit": { ... },
  "spend_control": { "individual_limit": { ... } },
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "spark",
      "rate_limit": { "primary_window": {...}, "secondary_window": {...} } }
  ]
}
```

解析规则(全部容错:单字段损坏只丢该字段,不丢整份响应;camelCase 变体同样接受;`credits.balance` 允许字符串数字):

- **窗口角色判定**(`CodexRateWindowNormalizer`):`windowMinutes = limit_window_seconds / 60`;`300` → session(5h),`10080` → weekly,其它 → unknown。primary 是 weekly 而 secondary 是 session/unknown 时**交换**,保证 primary=5h、secondary=Weekly。只有一个窗口时按角色放到对应槽位。
- **RateWindow 语义**:`usedPercent`(0–100,响应里的 `used_percent` 原样)、`resetsAt = Date(reset_at 秒)`、`windowMinutes`、可选 `resetDescription`、`nextRegenPercent`。
- `plan_type` 枚举:`guest/free/go/plus/pro/free_workspace/team/business/education/quorum/k12/enterprise/edu/未知字符串原样保留`。
- `credits` → `CreditsSnapshot(remaining: balance, events, updatedAt)`;UI 固定满刻度 1000,`percent = clamp(remaining/1000*100)`。
- `additional_rate_limits` → `NamedRateWindow(id: limit_name ?? metered_feature, title, window)`,逐元素 lossy 解码。
- 身份:`identity.accountEmail`(来自 id_token JWT)、`loginMethod = plan_type`。

### 2.4 剩余额度/重置时间计算公式(`CodexUsageDataMapper`)

```
remainingPercent = Int(round(100 - usedPercent))        # 每个窗口
startTime        = resetsAt - windowMinutes * 60        # 窗口起点由终点反推
remainsTime(ms)  = (resetsAt - now) * 1000
currentIntervalTotal = 100; currentIntervalUsed = remainingPercent   # UI 语义是"剩余量",单位 %
detailText       = "<Plan 显示名> · <OAuth|Codex CLI|OpenAI Web> · resets MM/dd HH:mm(Asia/Shanghai)"
```

模型行顺序:5h → Weekly → extras → Credits;全空时放占位行 `"Codex not configured — run `codex` to sign in"`。`UsageData.remains/total` = 有 `isCurrentIntervalAvailable` 的行数 / max(总行数,1)。**`sampledAt` 必须写抓取时刻 `snapshot.updatedAt`,不是 resetsAt**(周窗口的 resetsAt 在未来,曾被当作"更新于"显示成未来时间,是已修复的坑)。

### 2.5 每账号配额快照落盘(`CodexAccountQuotaStore`)

- 路径:`~/Library/Application Support/com.techfanseric.aiquotabar/account-quota.json`(Windows 建议 `%APPDATA%\AIQuotaBar\account-quota.json`)。
- 结构:`{ "<accountDigest>": { shortRemainingPercent, shortResetsAt, longRemainingPercent, longResetsAt, capturedAt } }`,ISO8601 日期,sortedKeys,原子写。
- 规则:primary 缺失 → 整条不记;`remaining = clamp(0, round(100-usedPercent))`;上限 32 个账号,超出按 capturedAt 淘汰最旧。

### 2.6 周边数据源

- **codex-resets.com**(`CodexResetHistory`):GET `https://codex-resets.com/api/v1/resets?limit=100`,UA `AIQuotaBar`,超时 10s;成功后 6h 内不重拉,失败 10s 后重试。响应 `{data: [{announced_at: ISO8601(可带毫秒), reset_type: "regular"|"banked", ...}]}`;取本地日(本地时区 startOfDay)标记,同日取列表第一条(最新);`reset_type=="banked"` → banked 标记。只读富化,失败不影响主数据。
- **订阅状态**(`CodexSubscriptionStatus`):仅当 source == `openai-web`、前后账号观察 digest+generation 一致、auth.json email 与快照 email 相等时,记录 `subscriptionRenewsAt`/`subscriptionExpiresAt` 标记;24 小时过期;纯内存。

---

## 3. 本地用量统计(Sources/CodexLocalUsageCore + CodexLocalUsageModel)

### 3.1 输入文件

- 根目录:`CODEX_HOME` env 或 `~/.codex`;扫描 `<root>/sessions/` 与 `<root>/archived_sessions/` 两个目录(**递归**枚举所有 `.jsonl`,跳过隐藏文件)。目录不存在 → 空结果非错误;目录位置被普通文件占据 → 计 1 个 issue。
- 源文件只读。Codex rollout 文件为每会话一个 JSONL,行结构(顶层 `{timestamp, type, payload}`):

```
{"timestamp":"2026-09-01T00:00:00Z","type":"session_meta","payload":{"id":"<会话id>","forked_from_id":"<父id>?", "source":{"subagent":{"thread_spawn":{"parent_thread_id":"..."}}}?}}
{"timestamp":"...","type":"turn_context","payload":{"model":"gpt-5.3-codex","chatgpt_account_id":"org-..."}}
{"timestamp":"...","type":"event_msg","payload":{"type":"token_count","info":{
    "model":"gpt-5.3-codex",
    "total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"cache_write_input_tokens":10,"output_tokens":10,"reasoning_output_tokens":0},
    "last_token_usage":{...同构...},
    "chatgpt_account_id":"org-..."},
    "rate_limits":{"limit_id":"default"}}}
```

- 解析性能门槛(必须保持):首字节不是 `{`(0x7B)或空格(0x20) → 直接计 issue 跳过;行内不含字节串 `"session_meta"` / `"turn_context"` / `"token_count"` → 不做 JSON 解码(绝大多数行是对话/工具正文);64KB 分块流式读;结尾半行若不是合法 JSON → `incomplete = true`(下轮文件变化后重扫)。

### 3.2 单文件解析算法(`UsageParser.parse`,伪代码)

```
state = {sessionID, parentID, startedAt, model="unknown", turnAccountID,
         previousTotal=null, signatures{}, previousSignature=null, occurrences{}, records[], issues=0}

for line:
  快速过滤(见上) → JSON 解码 {type, payload, timestamp}
  case type == "session_meta" (仅首个):
      sessionID = payload.id ?? payload.thread_id ?? payload.threadId
      parentID  = payload.forked_from_id ?? payload.source.subagent.thread_spawn.parent_thread_id
      两者冲突 / 相同 → sessionID 置空 + issue
  case type == "turn_context":
      turnAccountID = payload.chatgpt_account_id ?? payload.account_id
      model = payload.model
  case type == "event_msg" && payload.type == "token_count":
      info = payload.info
      model = info.model ?? info.model_name ?? payload.model
      total = counters(info.total_token_usage); last = counters(info.last_token_usage)
      # counters 校验:必须同时含 input_tokens 与 output_tokens;每个数值为非布尔、有限、
      # 整数、0 ≤ v ≤ 1e12;否则整体视为 null 并 issues += 1
      signature = "in:cached:write:out:reason(in:...)"(total 与 last 各一段,缺侧为 "-")
      source = payload.rate_limits?.limit_id ?? "default"
      duplicate = (total 存在) && (signatures[source] == signature || previousSignature == signature)
      if total 存在: signatures[source] = signature
      startsBaseline = (previousTotal == null)
      if last 存在:            tokens = last;  quality = "exact"
      elif total 存在:         quality = "cumulative-delta"
          if previousTotal 存在:
              任一分量回退(total.x < prev.x) → issue,本轮跳过(不确定段不猜)
              否则 tokens = total - previousTotal(逐分量差)
          else:               tokens = total(首条累计值直接入账)
      if total 存在: previousTotal = total
      skip if duplicate 或 tokens.total <= 0 或 tokens 无效
      accountID = SHA256("codex-account|" + (info.chatgpt_account_id ?? payload.chatgpt_account_id ?? turnAccountID))   # accountSource = "log";无 → null
      id  = SHA256("{sessionID}|{ISO8601(timestamp, 毫秒)}|{signature}|{同 base 第几次出现}")   # 事件幂等键
      records += {event, signature, cumulative: total, startsBaseline}
```

`UsageTokens` 不变量:`input/cached/cacheWrite/output/reasoning` 均 `0 ≤ v ≤ 1e12`,`cached + cacheWrite ≤ input`,`reasoning ≤ output`,`total = input + output`(**输入已含缓存读、输出已含推理,总量 = input+output,不得再相加**)。

### 3.3 跨文件解析/去重(`UsageParser.resolve`)

- 按 `sessionID` 分组(含 sessions/ 与 archived_sessions/ 的同名会话、分页、归档副本)。
- **fork/续页处理**:子会话带 `parentID` 时,取父会话(含父自己继承的前缀)在 fork 起点 `startedAt` 之前、按 signature 顺序匹配子文件开头记录,匹配到的前缀条数 `prefix` 从子记录中剔除(不重复计费)。父不可达 → 整个会话 **deferred(暂缓)**,绝不猜;父文件之后出现时自动重算。
- 纯累计(无 last)的续页首条:用上一页的 cumulative 基线做差(逐分量必须单调不减,否则该条丢弃并记 unresolved)。
- 嵌套 fork 递归 memo 化,带环检测;输出按 `occurredAt` 排序 + 全局 id 去重。
- 返回 `(events, deferred 个数, issues 总数, deferredSessionIDs)`。

### 3.4 扫描调度与持久化(`UsageStore`)

- 数据库:`~/Library/Application Support/AIQuotaBar/local-usage.sqlite`(Windows 建议 `%APPDATA%\AIQuotaBar\local-usage.sqlite`),SQLite WAL,`busy_timeout=5000`。
- Schema:

```sql
usage_events(id TEXT PRIMARY KEY, occurred_at TEXT NOT NULL, body TEXT NOT NULL,   -- body = LocalUsageEvent JSON
             binding TEXT, delivery TEXT NOT NULL DEFAULT 'pending', delivery_error TEXT)
CREATE INDEX usage_delivery ON usage_events(binding, delivery, occurred_at);
CREATE INDEX usage_chronological ON usage_events(occurred_at, id);
parsed_files(path TEXT PRIMARY KEY, stamp TEXT, body TEXT);       -- 完整解析结果缓存(JSON)
parsed_file_headers(path TEXT PRIMARY KEY, stamp TEXT, session TEXT, parent TEXT, issues INTEGER, incomplete INTEGER);
metadata(key TEXT PRIMARY KEY, value TEXT);                       -- account-timeline-v1 / deferred-sessions-v1 / ...
```

- **增量扫描**:`stamp = "v2:{fileSize}:{mtimeSeconds}"`;stamp 未变不重读。变化文件重新解析后,把受影响会话**家族**(变更文件的 session + 旧 session + 删除文件的 session,再沿 parent 邻接图 BFS 扩到祖先+后代)全部重解析。目录读错误 > 0 时不把消失的文件从目录里除名(不可访问 ≠ 历史消失)。
- 解析结果与事件插入在同一 `BEGIN IMMEDIATE` 事务提交;崩溃安全重放。
- 账号时间线观察(`UsageAccountTimeline`):每次扫描读一次 `auth.json`(`UsageAccountObservation`,§1.4);相邻两次观察满足:同 accountID、同 generation(mtime:size)、间隔 ≤ 90 秒 → 延长/新建区间 `[start,end)`;否则(切换、重启、休眠、auth 重写)留空隙 = 未知。事件时间落在区间内且原本无账号 → 归属该账号,`accountSource = "login-observation"`;**已入账事件永不重写归属**(测试断言)。
- 可见窗口:模型层只加载最近 35 天(`eventsSince`),磁盘上更旧记录保留。
- 每 60s 定时扫描(Timer tolerance 5s),与配额轮询/OAuth/Codex App 是否运行完全解耦。

### 3.5 聚合、缓存命中率与成本(`UsageSummary` / `UsagePrice`)

- 事件筛选区间为**字符串比较** ISO8601(UTC 固定格式带毫秒,字典序=时间序,Windows 实现必须用完全一致的 `yyyy-MM-dd'T'HH:mm:ss.fffZ` 输出)。
- `cacheHitRate = Σcached / Σinput`(仅 `Σinput > 0`;否则 nil,UI 显示"—")。**按 token 加权**,不是记录数平均。
- 成本(USD,`decimal` 精确计算,不做浮点):

```
cost = ( (input - cached - cacheWrite) * P.input + cached * P.cached
       + cacheWrite * (P.cacheWrite ?? 0) + output * P.output ) / 1_000_000
```

  单位 = USD/百万 token。**模型名精确匹配,不做模糊、不回退到相近型号、不按 0 成本处理**;事件含 `cacheWrite > 0` 而价格 `cacheWrite == null` → 该事件保持未定价(不计入 pricedRecords);价格按事件时间落在 `[effectiveFrom, effectiveTo)` 区间选择。`quality != "exact"` 的事件计入 `estimatedRecords`。

- 价格表默认值:**空**(未配置时本地与团队 token 统计仍可用,成本显示"未定价");来源:界面导入 JSON 或服务器 `/v1/usage/identity` 下发(连接/同步时团队价格表覆盖本地,UserDefaults key `localUsage.prices`)。格式:

```json
[ { "model": "gpt-5.3-codex", "version": "approved-rate-v1", "source": "https://...",
    "effectiveFrom": "2026-01-01T00:00:00Z", "effectiveTo": null,
    "input": 2, "cached": 0.2, "cacheWrite": null, "output": 10 } ]
```

  校验(`UsagePrice.validate`):model/version/source 非空;日期可解析且 to > from;费率有限、`0 ≤ v ≤ 1e6`;同模型区间不得重叠;最多 20 条(服务器侧)。

- 历史分桶(`UsageHistory`):本地日历日边界(天然正确处理 DST 23/25 小时日);`days==1` → 小时桶,否则日桶(1–365 钳制);`month` → 当月自然日;`last24Hours` → 严格 24×3600s 均分 288 个 300s 桶。空桶为零用量,未定价桶成本为 nil(≠ 0)。

### 3.6 团队上报(`UsageClient`,设备凭据体系)

- 端点约束:仅 HTTPS(例外:回环 `http://localhost|127.0.0.1|::1`),禁止 userinfo/query/fragment/路径;凭据只进 `Authorization: Bearer`;禁跟随重定向;ephemeral 会话、无 cookie/缓存。
- 生产入口:`https://ai-quota-bar.pages.dev`(旧 `https://ai-quota-bar-sync.techfanseric.workers.dev`、`https://quota.talktrace.app` 自动验证同身份后迁移 binding)。
- 接口:`POST /v1/team/create`、`POST /v1/usage/join {inviteCode, memberName, deviceID, memberPassphrase?}`(邀请码归一:去空白→大写→仅保留字母数字)、`GET /v1/usage/identity`(返回身份+价格表)、`POST /v1/usage/events/batch`(≤50 条,回执 accepted/rejected 必须与发送集合完全一致否则视为失败)、`GET /v1/usage/summary?from&to&group_by=member|device|model|account`、`GET /v1/usage/timeline?from&to&bucket_seconds=300|86400&member_id&device_id&account_id`、`POST /v1/usage/leave`、`POST /v1/usage/member/passphrase`、`POST /v1/team/handoff`(一次性 64 位十六进制票据,仅进 URL fragment)。
- `binding = SHA256(endpoint + "|" + SHA256(team_id + "|" + member_id + "|" + device_id))`;设备 token 存 macOS Keychain(Windows → DPAPI,见 §6)。join 时校验响应 `identity.device_id == 本机 deviceID`。
- 上报循环:每 60s 扫描后,若 `reportingEnabled` 且到期;每轮最多 20 批 × 50 条;失败退避 `min(3600, 60 × 2^(min(failures-1,6)))` 秒;错误文本含 `401` → 停止自动重试(需重新绑定),client 置空。
- 保留策略:`pruneExpendable` 只删 `delivery='sent'` 或 `binding IS NULL` 且早于 40 天的行;**绑定但 pending/rejected 的行永不删**;每日一次;空闲页 ≥ 64MB 才 VACUUM。
- 云端核验(`--verify-usage-delivery` 或界面按钮):对已确认事件按 365 天分段拉 timeline 聚合,比对记录数与全部分量 token,报告写 `App Support/AIQuotaBar/Diagnostics/usage-delivery-audit.json`。
- 隐私边界:事件 ID 是摘要;上传内容只有 model/时间/tokens/quality/accountID 摘要;原始会话 ID、路径、提示词、OAuth token、账号邮箱一律不上传。

---

## 4. Codex 任务检测

### 4.1 双源架构与合并

`CodexSleepProtectionCoordinator`(主线程)合并两个 Codex 源,`mergedCodexActiveSessionIDs = hookTracker.activeSessionIDs ∪ localDetector.activeSessionIDs`,每 **2 秒**轮询一次(本地探测器 + 各 provider 探测器共用一个 2s 循环);每次合并前先 `pruneStaleTurns`。任务计数即合并后 session 数(上限 99)。这个模块同时驱动防睡眠(见 `power.md`),本文只记录检测语义:最后一个 turn 结束后有 **5 分钟 grace**(`defaultTurnEndGracePeriod`)保持保护不抖动。

### 4.2 Hook 源:AIQuotaBarHook 的安装、调用与协议

**(a) 安装(`CodexHookInstaller`)**:写 `~/.codex/hooks.json`(同样遵循 `CODEX_HOME`)。8 个事件全量注册:`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`SubagentStart`、`SubagentStop`、`Stop`、`SessionEnd`。结构:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "'/path/to/AIQuotaBarHook'", "timeout": 5 } ] }
    ],
    "Stop": [ ...同上... ]
  }
}
```

- 幂等:先删除自己拥有的组(command 含 `/AIQuotaBarHook` 判定),再追加;内容无变化不写盘;已存在配置首次修改前备份为 `hooks.json.ai-quota-bar.backup`(只备份一次);顶层其他键(如用户自定义设置)原样保留;写后 chmod 0600;helper 不可执行 → 返回 `.helperMissing` 且不动文件。helper 路径:app bundle 内 `Contents/Helpers/AIQuotaBarHook`。

**(b) 被调方式(`AIQuotaBarHook/main.swift`)**:Codex CLI 在生命周期事件发生时以子进程执行 hook,**stdin 传入一段 JSON**。hook 读取 stdin,要求含非空 `hook_event_name` 与 `session_id`(可选 `turn_id`、`agent_id`,空串丢弃),否则静默退出 0。随后通过 `DistributedNotificationCenter` 发通知:

```
name     = "com.techfanseric.aiquotabar.codex-hook"
userInfo = { hook_event_name, session_id, turn_id?, agent_id? }
```

**(c) 接收(`CodexHookListener` → `CodexActivityTracker` 状态机)**,以 `TurnKey(sessionID, turnID)` 为单位:

| 事件 | 状态转移 |
|---|---|
| UserPromptSubmit | turn 不存在则创建;`startedAt` 取最早;rootStopped=false |
| PreToolUse / PermissionRequest / PostToolUse | 带 agentID → activeSubagents.insert;否则 rootStopped=false |
| SubagentStart | 带 agentID → activeSubagents.insert |
| SubagentStop | 带 agentID → activeSubagents.remove |
| Stop | 带 agentID → 移除该 subagent;不带 → rootStopped=true |
| (任意时刻) | `rootStopped && activeSubagents.isEmpty` → 删除 turn(**根 Stop 等待所有 subagent Stop**) |
| SessionEnd | 清空该 session 的全部 turn |
| 孤儿 Stop/SubagentStop(turn 不存在) | 忽略,不创建 |
| 无 turnID 的事件 | 只更新安全事件流,不动 turn |

- **TTL(心跳替代)**:hook 无心跳;`defaultTurnTTL = 10 分钟`,合并循环每次调用 `pruneStaleTurns(now)` 回收 `lastEventAt` 超过 TTL 的 turn(kill -9 / Stop hook 丢失 / Esc 中断路径的幽灵任务自愈;权限等待等合法长停顿被误回收后,用户响应产生的新事件会重建 turn)。
- `reliableOldestStartedAt`:仅当每个活跃 session 的所有 turn 都有真实 UserPromptSubmit 时返回最早 startedAt,否则 nil(不制造假的开始时间)。
- 安全事件投影(`CodexSafeActivityEvent`):只保留 kind(taskStarted/toolStarted/permissionRequested/toolFinished/subtaskStarted/subtaskFinished/taskFinished/sessionEnded)+ 时间,内存上限 32 条;任何 hook 标识与 payload 文本永不进入(会跨到 LAN dashboard)。

### 4.3 本机源:`CodexLocalActivityDetector`(状态库 + rollout 尾部增量解析)

**(a) 候选发现**:只读打开 `~/.codex/state_5.sqlite`(Codex CLI 自己维护;遵循 `CODEX_HOME`),`busy_timeout 250ms`,查询:

```sql
SELECT id, rollout_path, updated_at, source, <created_at 或 created_at_ms>,
       title, cwd, model, reasoning_effort, model_provider, sandbox_policy,
       approval_mode, tokens_used, git_branch, cli_version, agent_nickname, thread_source
FROM threads
WHERE archived = 0 AND updated_at >= ?   -- now - 12h(recentActivityWindow)
ORDER BY updated_at DESC LIMIT ?         -- 256(candidateLimit)
```

所有列都用 `PRAGMA table_info(threads)` 探测,缺列 → NULL(schema 漂移防御;`id/rollout_path/updated_at/archived` 缺失则整体放弃返回空)。`created_at` 秒 → ×1000;`created_at_ms` 优先,`COALESCE(created_at_ms, created_at*1000)`。父子关系:`source` 列若为 JSON,取 `subagent.thread_spawn.parent_thread_id`。根会话归并:沿 parent 链上溯(最多 32 跳 + 环检测);`session_meta` 里 `payload.id != threadID && payload.session_id` 存在时以 `session_id` 为根。元数据(标题/分支/模型等)全部过 sanitizer(§4.4)后才保留。

**(b) rollout 尾部增量解析**(每线程一个 `ParserState`):

- 文件身份 = `(device, inode)`(Windows 等价:`(volumeSerial, fileIndex)`,见 §6);身份变化或 `fileSize < offset`(截断)→ 全量重置状态。
- 未读字节 > `maximumRolloutScanBytes`(默认 16MB)→ 重置,从 `fileSize - 16MB` 开始,**丢弃首行碎片**,并触发 **lifecycle bootstrap**:从头重放但只解析 `session_meta` 与 `task_started/task_complete/turn_aborted/task_aborted` 四类行(恢复窗口前就开始的活跃 turn);单行超过 16MB 直接丢弃不驻留内存。
- 追加读:256KB 分块;最后一行不完整 → 存 `partialLine` 等下轮拼齐(测试断言:半行期间活跃状态已可见,拼齐后进度行出现)。
- **turn 判定**:
  - `event_msg.task_started`:`turn_id`(缺省 `"legacy"`);子代理线程做归属校验 `isOwnedTurn` — turn_id 是 UUIDv7 时取前 12 位十六进制毫秒时间,要求 `turnDate ≥ thread.createdAt - 0.25s`(毫秒精度优先于秒精度的 `started_at`);非 UUIDv7 用 `started_at` 字段,容差 1s。首个自有 turn 出现时清空之前从父会话继承的杂散状态。
  - `task_complete` / `turn_aborted` / `task_aborted`:移除 turn(`legacy` → 清空全部)。
  - `compacted` / `context_compacted` / `thread_rolled_back`:清进度行/事件/工具表,**保留 turn 生命周期**,语义置 unknown/thinking。
  - 语义映射(最新一条生效,10 分钟过期):`agent_reasoning→thinking`;`agent_message(phase=commentary)→进度行`;`patch_apply_begin/end→editing/fileEdit`;`mcp_tool_call_begin/end→usingTool/mcp`;`web_search_begin/end→usingTool/web`;`subagent_start|subagent_stop→delegating/subagent`;`response_item.function_call/custom_tool_call/tool_search_call(+output)→按工具名分类`;`response_item.message(role=assistant, phase=commentary, content[].type=output_text)→进度行`。
  - 工具名分类(小写包含):`apply_patch`/`file_edit`→fileEdit;`exec_command`/`write_stdin`/`shell`/`terminal`→shell;`web`/`search_query`/`browser`→web;前缀 `mcp__`/`connector`/`codex_apps`→mcp;`spawn_agent`/`subagent`/`followup_task`/`send_message`/`wait_agent`→subagent;其余 other。完成状态:`success`/`is_error` 布尔优先,`status` 字符串映射 completed/failed/declined/inProgress,缺省 completed。
- 活跃 = `activeTurnIDs` 非空;同根会话的多个线程聚合为一个 `CodexLocalSessionActivity`(代表线程取根,startedAt 仅当所有 turn 有可靠起点,进度行取最近 2 条去重,recentEvents 16 条/10 分钟窗口,tokensUsed 求和,subtask 名单去重取 5 个)。

**(c) 安全过滤器(必须完整移植)**:

- `CodexTaskProgressSanitizer.sanitize`:NFC 规范化 → 去 ANSI 转义序列 → 过滤控制字符(保留 `\t\n\r`)、C0/C1、双向控制符、私有区 → 空白折叠为单空格 → trim;命中 18 条敌对正则之一(Bearer、`sk-`、api key/token/password 赋值、邮箱、带 query 的 URL、`~/`、绝对 POSIX 路径、Windows 路径、workspace/、`?token=` 等、session/turn/agent id 赋值、UUID、26 位 ULID 风格、ghp_/xox/AKIA、JWT、PRIVATE KEY 块)→ **整行丢弃**(不做部分脱敏);截断 120 字符 / 512 UTF-8 字节。
- `CodexTaskMetadataSanitizer.sanitize`:在其上再加白名单字符集(字母数字 + `._:+-/()[] `),≤64 字符,不满足 → nil。

### 4.4 关注账号(CodexWatch,注意不是任务监视)

命名澄清:`Services/CodexWatch/` 是「用邮箱关注他人共享的 Codex 额度」的云功能,走 app 内置公共端点(`/v1/watch/*`,内置 `SYNC_TOKEN` Bearer,`User-Agent: AIQuotaBar`):

- 发布:`POST /v1/watch/publish`,body `{publisher: <deviceID>, accounts: [{account: 归一邮箱, plan?, windows: [{name, remainingPercent, resetsAt?, sampledAt?, startsAt?}]}]}`;**整体替换语义**(空数组=全部取消);本机无 Codex 数据(usageData nil)时**不发布**(防止瞬时故障清空分享);窗口同名取 `sampledAt` 最新;`sampledAt` 只能来自真实采样时刻。
- 拉取:`GET /v1/watch/quota?email=<归一邮箱>`(超时 8s):200 → available;404 → notShared(没人分享);410 → stale(保留缓存行并标过期,行不消失);其他/异常 → unreachable(保留原因给 UI)。
- 被读计数:`GET /v1/watch/reads?publisher=<deviceID>` → `{accounts: [{account_key, read_count, last_read_at, stale}]}`;`account_key = SHA256(trim+lowercase(email))` 十六进制,本地反向匹配已知邮箱。
- 读侧防御:未来时间的 `sampledAt` 不可信 → 回退 `publishedAt`;缺 `startsAt` 且窗口名含 "weekly" 或 =="7d" → 用 `resetsAt - 7天` 反推(未来则丢弃);「这一轮真的拉到了」(`freshlyFetched`)与「缓存里有」严格区分,防止把旧数字当新读数采样出假曲线。
- 本地存储:UserDefaults `codexWatch.isSharing`(迁移自 v1.32 `codexWatch.isServing`)、`codexWatch.shared.v1`、`codexWatch.watched.v1`(换行分隔);邮箱校验:≤254 字符、无前后导 `.`、无 `..`、单一 `@`、local ≤64、domain 含点且边界合法、拒绝 `/?#:\"<>()[],;`、字符集限 RFC5322 atext。

---

## 5. 节流 / 重试 / 缓存 / 轮询参数汇总

| 项 | 值 | 位置 |
|---|---|---|
| 配额刷新间隔 | 默认 600s;服务端周期结束 +15s 对齐刷新;并发刷新去重(当前请求结束后补跑一次) | SPEC.md / UsageViewModel |
| OAuth 用量请求 | 超时 30s,禁缓存;辅助端点 4s | CodexBarCore |
| OAuth token 刷新 | 超时 30s;exp 前 5min(外部源 60s)/ last_refresh 8 天触发 | CodexBarCore |
| 本地用量扫描 | 60s(tolerance 5s);增量;25/35 天可见窗口;首次导入大历史可能数分钟 | CodexLocalUsageModel |
| 团队上报 | 扫描后触发;≤20 批×50 条/轮;退避 `60×2^(n-1), n≤6, 上限 3600s`;401 → 停止 | CodexLocalUsageModel.sync |
| 保留/回收 | sent/unbound > 40 天删除;每日一次;freelist ≥ 64MB 才 VACUUM | UsageStore |
| 任务检测轮询 | 2s(hook 源事件驱动 + 本机源轮询) | CodexSleepProtectionCoordinator |
| hook turn TTL | 10 分钟 | CodexActivityTracker |
| 任务结束 grace | 5 分钟 | coordinator |
| 连通性探测 | HEAD `https://chatgpt.com/` + `https://openai.com/`,超时 3s,间隔 `8 + rand*4` 秒;两者都失败才算 unreachable;切 Clash 路由后用新会话立即重测 | CodexConnectivityMonitor |
| codex-resets.com | 成功 6h / 失败 10min;超时 10s | CodexResetHistory |
| 订阅标记有效期 | 24h | CodexSubscriptionStatus |
| 账号切换接力检查 | 3s 定时器 + 应用启停通知;面板展示期 5s 轮询刷新账号池 | CodexAuthAccountStore |
| 账号池配额快照 | ≤32 账号 | CodexAccountQuotaStore |
| 桌面版在运行判定 | bundle id 匹配 + 常规 GUI 应用;CLI 用 pgrep -x codex / -f @openai/codex | ProviderAppPresence / CodexAuthAccountStore |

**落盘数据一览:**

| 数据 | 路径/键 | 格式 |
|---|---|---|
| 本地用量事件库 | `~/Library/Application Support/AIQuotaBar/local-usage.sqlite`(+`-wal`/`-shm`) | SQLite WAL |
| 每账号配额快照 | `~/Library/Application Support/com.techfanseric.aiquotabar/account-quota.json` | JSON, ISO8601 日期 |
| 云端核验报告 | `~/Library/Application Support/AIQuotaBar/Diagnostics/usage-delivery-audit.json` | JSON |
| 数据源模式 | UserDefaults `codexSourceMode` | String |
| 本地用量开关/连接/价格 | UserDefaults `localUsage.reporting` / `localUsage.connection`(LocalUsageConnection JSON)/ `localUsage.prices` / `localUsage.lastUploadConfirmedAt` | — |
| 关注账号 | UserDefaults `codexWatch.isSharing|shared.v1|watched.v1` | 换行分隔 |
| hook 配置 | `~/.codex/hooks.json`(+ `.ai-quota-bar.backup`) | JSON |
| 设备凭据/管理密码 | macOS Keychain(binding 为账号) | — |
| 源数据(只读) | `~/.codex/auth.json`、`accounts/*.json`、`sessions/`、`archived_sessions/`、`state_5.sqlite`、`config.toml` | — |

---

## 6. macOS 专有依赖清单与 Windows 等价物

| macOS 依赖 | 用途 | Windows 建议 |
|---|---|---|
| `DistributedNotificationCenter` | hook → app 进程间事件 | 命名管道(`NamedPipeServerStream` 多实例)或本机 UDP 广播;hook exe 写一行 JSON,app 常驻读。保持「hook 无状态、崩溃无影响」的设计 |
| `NSWorkspace.runningApplications` / bundle id | 桌面版在运行检测 | 枚举进程 + 窗口(`EnumWindows`/`GetWindowText`)排除后台进程;匹配可执行名 `ChatGPT.exe`/`Codex.exe` |
| `/usr/bin/pgrep -x codex` / `-f @openai/codex` | codex CLI 在运行检测 | `System.Diagnostics.Process.GetProcesses()` 名匹配 + WMI/CIM `CommandLine` 包含 `codex.js`/`@openai/codex` |
| Keychain(`KeychainService.deviceCredential`) | 团队设备 token / 管理密码 | DPAPI(`ProtectedData.Protect`,CurrentUser 作用域)存 `%APPDATA%`;或 Windows 凭据管理器 |
| `UNUserNotificationCenter` | 账号切换通知 | Toast 通知(`ToastNotificationManager`)或托盘气泡 |
| 文件 `chmod 0600` / `trashItem` | 私有权限 / 删除进废纸篓 | ACL 收紧或 DPAPI 加密;回收站用 `Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(..., RecycleBin)` 或 SHFileOperation |
| `(st_dev, st_ino)` 文件身份 | rollout 增量解析防截断/替换 | `GetFileInformationByHandle` → `(dwVolumeSerialNumber, nFileIndexHigh/Low)`;.NET 可用 `FileStream.Handle` P/Invoke;退路:length+mtime |
| `NSCocoaError` mtime+size 撕裂读防护 | auth.json 读一致性 | 同模式直接移植(`FileInfo.LastWriteTimeUtc`/`Length` 前后比对) |
| `IOPMAssertionCreateWithName` 等 | 任务期防睡眠 | `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED)`(详见 power.md) |
| `Timer` + tolerance | 轻量定时器 | `System.Threading.Timer` 或 `PeriodicTimer`(tolerance 语义可忽略) |
| `URLProtocol` 测试桩 | HTTP 单测 | `HttpMessageHandler` mock / `WebApplicationFactory` |
| `ISO8601DateFormatter`(两种格式) | 时间解析/序列化 | `DateTimeOffset.ParseExact`;**输出必须固定 `yyyy-MM-dd'T'HH:mm:ss.fffZ`**(见 §7 坑) |
| SQLite3 C API | 用量库/读 state_5.sqlite | `Microsoft.Data.Sqlite`(同文件格式,只读打开 state_5.sqlite 用 `Mode=ReadOnly`) |
| CryptoKit `SHA256` | 摘要 | `System.Security.Cryptography.SHA256.HashData`,十六进制小写 |
| Swift `Decimal` | 成本 | `System.Decimal` |
| App bundle `Contents/Helpers/AIQuotaBarHook` | hook helper 路径 | 安装目录旁 `AIQuotaBarHook.exe`;hooks.json 中命令行用引号包裹整个路径 |
| DistributedNotification 的 `deliverImmediately` | 睡眠时也能收到 | 命名管道天然如此 |

---

## 7. 测试行为清单(迁移后必须保持一致)

来自 `Tests/CodexLocalUsageCoreTests/` 与 `AIQuotaBar/Tests/Codex/` 的精确断言:

**凭据识别(AuthFileReaderTests)**
1. `OPENAI_API_KEY` 非空 → apiKeyMode,优先于残留 tokens;`auth_mode: "apikey"` + stale tokens → 无账号归属。
2. 无 `auth_mode` 但 tokens.account_id 存在 → 仍识别为 chatgptLogin(legacy 形态);`{"auth_mode":"chatgpt"}` 无 tokens → unauthenticated;垃圾/缺失文件 → unreadable。
3. accountDigest:同账号不同 token 内容(有无 id_token)指纹一致;不同账号不同;64 字符;不包含原始 account_id;观测持久化 JSON 不含任何 token/原始 ID。

**账号时间线(UsageAccountTests)**
4. 区间仅当相邻观察同账号+同 generation+间隔 ≤90s;A→B→A 是新区间不是改写;auth 重写(generation 变)即使同账号也留未知空隙;休眠/重启空隙保持未知;已入账事件(含后来才知的账号)不可变。

**解析与去重(UsageTests)**
5. 同一 total/last 快照重复(含不同 `rate_limits.limit_id` 的重复配额快照)只计一次;`last` 相等事件的两次出现**不去重**(id 含出现序号,不同 id);测试值:2 条事件、total=220、cacheHitRate=0.5。
6. 累计差值回退:模型切换场景 `[100,150,10,30]` → records input `[100,50,20]`,issues=1(回退段跳过)。
7. 非法计数不回退到膨胀总量:bool 值/非法字段 → 整条丢弃并 issues(测试:0 条记录、3 issues)。
8. fork/嵌套 fork:父+子+孙去重后 3 条、input 合计 160;缺父 → deferred=1 且 events 为空;父到达后 deferred=0、2 条、input 合计 150。fork 之后与父签名相同但时间在 fork 后的真实新用量**不**被误删(2 条)。
9. 归档副本/分页重叠 page1⊂page2+重复 → 2 条。
10. 价格与加权缓存:事件 (in=100,cached=90,write=10)+(in=900),价格 in=2,cached=1,write=3,out=10 → cacheHitRate=0.09,cost=0.00212(Decimal 精确),pricedRecords=2;无价格 → pricedRecords=0;区间 `[from,to)` 左闭右开;空汇总 cacheHitRate=nil;重复价格区间 → validate 抛错。
11. outbox 所有权:同批事件先绑 alice 再绑 bob,bob 无 pending(alice 的事件不带 alice 的 binding);重启后 pending 恢复;acknowledge 按 binding 匹配;已发送事件重复 insert 不再 pending。
12. 半行/归档/重启:截断尾行 → incomplete=1 但已有事件可见;补全后 2 条;文件移入 archived_sessions 改名 → 仍 2 条;重复扫描结果稳定。
13. 纯累计续页用上一页基线:100 与 150 两页 → 合计 150;纯累计 fork 无复制前缀 → 减父基线,合计 150。
14. 拒绝原因重启后保留(`ownership_conflict: 1`),被拒事件不再 pending。
15. 10 万事件定价汇总 cost=25(Decimal 精确聚合,先按价格段聚合 token 再算钱)。
16. 增量扫描:无变化 → parsedFileCount=0/resolvedFileCount=0/revision 不变;重启后 warm 同样为 0;child 变化 → 只重解析 child(1)+家族(2)。
17. 可见窗口不删数据:eventsSince 过滤后旧事件仍在全量 events() 与 pending 中;storageStats 分类计数(sent/pending/rejected/localOnly)。
18. 端点安全:`http://example.com`、`https://user:pass@...`、带 query → 拒绝;`http://127.0.0.1:8787` 允许。
19. HTTP 幂等:超时后 outbox 保留,重试携带 `Authorization: Bearer ...` 打 `/v1/usage/events/batch`,回执 accepted 与发送集合不完整匹配 → 视为失败(不能丢事件)。
20. join:body 携带归一邀请码( `" abcd-2345-efgh "` → `ABCD2345EFGH`)、trim 后的名字/设备号、无凭据 header;响应 device 不符 → 拒绝;409 → "Name taken";票据必须 64 位十六进制且 role 匹配,URL 只含 fragment 票据。
21. 修剪:sent/unbound >40 天删,pending/bound 永不删(90 天 pending 仍保留);新库 reclaim 是 no-op。
22. 首跑:日志目录不存在 → files=0/issues=0/空事件;目录位置是文件 → issues=1。

**历史分桶(UsageHistoryTests)**
23. 本地午夜边界(UTC+8):15:59:59Z 与 16:00:00Z 分属两日;days=3 → 3 桶 input `[900,1000,200]`,桶内 cacheHitRate=0.1;days=1 → 小时桶 13 个,空桶 cacheHitRate=nil。
24. DST 日 23 个小时桶,版本化价格 cost=2;月历 28/29/30/31 天;未来时段 0 记录;last24Hours 恒 288×300s,边界 `-1/0/299.999/300/86399/86400/86401` 落桶正确,首桶 cacheHitRate=0.2。

**配额映射(CodexUsageDataMapperTests)**
25. primary→"5h"(remaining 65)、secondary→"Weekly"(100)、extras→NamedRateWindow title;credits→"Credits"(currentIntervalRemaining=1234);四段同现顺序 5h→Weekly→extra→Credits;空快照 → "Codex not configured" 占位;`usedPercent` 0/100 边界 clamp。
26. `Codex Spark 5-hour` 命名的 extra 窗口使用独立 historyID 且算 5h 类窗口(canonical id `codex:user@x:Codex Spark 5-hour`)。

**配额快照(CodexAccountQuotaStoreTests)**
27. `record(primary 32.4, secondary 59)` → short=68/long=41(四舍五入),iso8601 往返一致;primary nil → no-op 且不落盘;重复 record 覆盖为最新;41 账号时保留最近 32 个(digest-0..7 删,digest-8 留)。

**重置历史/订阅(CodexResetHistoryTests / CodexSubscriptionStatusTests)**
28. `reset_type=="banked"` → banked=true;日期非法条目跳过;同日取列表第一条;announced_at 映射到本地日。
29. 订阅标记:仅 openai-web + 前后观察一致 + email 匹配才记录;oauth 源/账号变化/email 不符 → nil;24h+1s 过期;renews 标志随最近一次有效快照翻转。

**任务检测(CodexActivityTrackerTests / CodexLocalActivityDetectorTests)**
30. Prompt→working,Stop→结束;PermissionRequest 单独维持活跃;根 Stop 等待全部 subagent Stop;SessionEnd 只清本 session;孤儿终态事件不产生工作;并发 turn 独立计数。
31. 安全事件流:窗口 600s、上限 5 条、kind 白名单;11 分钟前的 taskStarted 已过期不出现。
32. `reliableOldestStartedAt`:任一活跃 session 缺真实 Prompt 起点 → nil。
33. TTL:10 分钟前无事件的 ghost turn 被 prune(返回 true),活跃 turn 保留,再次 prune 返回 false。
34. 检测器:task_started 后中间夹任意行仍活跃;task_complete 排除;12h 窗口外的 stale 线程排除;`state_5.sqlite` 路径遵循 `CODEX_HOME`。
35. 元数据全量采集且脱敏:title/cwd(取最后一段)/branch/model 等与 sanitizer 拒绝 `sk-`、绝对路径。
36. 半行保留:进度行只在行完整后出现;超 16MB 工具输出后 bootstrap 恢复窗口前的活跃 turn;同 inode 截断 → 状态全弃(不再活跃);原子替换(inode 变)→ 当新流处理。
37. compaction:进度行/事件清空但 turn 生命周期保留;compacted payload 里的密文哨兵不出现在任何输出。
38. 子代理线程归并到根会话不重复计数;已完成的子代理忽略从父继承的活跃 turn(UUIDv7 毫秒时间优先于秒精度 started_at,容差 0.25s/1s)。
39. 38 个 CLI 版本家族的代表性 rollout 兼容;未知事件类型 fail-closed 不清除已知生命周期。
40. 敌意文本整行丢弃(11 类哨兵 + 终端原始输出),只留安全行;行 ≤120 字符/≤512 UTF-8 字节;进度行最多 2 条。
41. 工具语义:apply_patch → editing/fileEdit/inProgress;调用输出到达 → completed;参数与输出内容永不保留。

**Hook 安装(CodexHookInstallerTests)**
42. 保留用户既有配置与钩子组(自己组去重后追加,Stop 变 2 组);重复安装幂等(字节相同);helper 缺失不动文件;`CODEX_HOME` 生效。

---

## 8. 迁移注意与坑

1. **时间字符串字典序**:`occurred_at`、bucket key、区间过滤全部按字符串比较。Swift 侧输出恒为 `yyyy-MM-ddTHH:mm:ss.SSSZ`(UTC);.NET 若用不同精度(如 7 位 tick)会破坏字典序与相等性。务必固定毫秒 3 位。
2. **摘要算法逐字节兼容**:`usageDigest = SHA256(UTF8)` 小写 hex;账号摘要前缀 `"codex-account|"`;binding 组合串 `"team|member|device"` 与 `"endpoint|bindingID"` 的拼接顺序、事件 ID 的 `"{session}|{timestamp}|{signature}|{occurrence}"` 格式都不能变,否则云端幂等键断裂、历史重复入账。
3. **配额端点确认**:本仓库锁定的 codexbar 基线较旧;上游已从 `chatgpt.com/backend-api/codex/usage` 迁到 `wham/usage` 并新增 spend-controls / remaining_balance / rate-limit-reset-credits。Windows 实现前应对照锁定 revision `b6e65a83…` 复核路径,或按上游 main 实现 `/wham/usage` 并保留 `chatgpt_base_url` 覆盖。
4. **UI 语义反转**:`currentIntervalUsed` 在 Codex 行存的是"剩余百分比";MiniMax 等其他 provider 是"剩余数量";credits 固定满刻度 1000。不要统一。
5. **sampledAt 坑**:采样时间只能用抓取时刻;`endTime`(= resetsAt)兜底会产生"未来时间",CodexWatch 读侧已有防御(`coherentSampleTime`),Windows 版保持。
6. **输入含缓存、输出含推理**:任何求和、显示、上传都不得把 cached/reasoning 再加一遍;`total = input + output`。
7. **只读原则**:源日志、`state_5.sqlite`、`auth.json` 的 token 内容永不修改;本应用写盘只有自己的 App Support/UserDefaults/凭据保护存储;hook 安装是唯一改 Codex 目录的行为。
8. **`pgrep` 语义**:CLI 检测两种形态(node 脚本 `@openai/codex/bin/codex.js` 与原生 `codex` 二进制);Windows 命令行匹配要同时覆盖。
9. **auth.json 撕裂读**:Codex 会原子替换 auth.json;读前后 mtime+size 校验是必须的,否则会把半截 JSON 当 unauthenticated 触发误判账号切换。
10. **事件不可变性**:账号归属一旦写入不重写;云端冲突隔离、拒绝原因持久化;「回执不完整匹配 = 失败」必须移植,否则可能丢事件。
11. **grace 与 TTL 的配合**:turn 结束 5 分钟 grace(防睡眠不抖动)、hook turn 10 分钟 TTL(幽灵任务回收)、进度/事件 10 分钟新鲜窗、recentEvents 上限 32/展示 16/5,这些常量来自实测调优,不要随意改。
12. **移动端/LAN 泄漏面**:跨网发送的只有安全投影(kind+时间+脱敏文本);hook 的 session/turn/agent id 不得进入投影;敌意正则清单必须完整移植。
