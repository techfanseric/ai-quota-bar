# Windows 迁移规格 — Cloudflare Worker 后端 API 与团队/云同步客户端

> 模块归属:Cloudflare Worker(`cloudflare/src/` 10 个文件 + `cloudflare/migrations/` D1 schema)与 Mac 端团队/云同步客户端行为。
> 结论先行:**Worker 是跨平台 JS,Windows 版直接复用同一个部署(`https://ai-quota-bar.pages.dev`),无需重写后端**;Windows 只需按本文实现一个等价的 HTTP 客户端 + 本地凭据/队列存储。
> 源码依据:`cloudflare/src/{worker,team,team-handoff,team-quota,local-usage,usage-team-core,legacy-quota,operations,feedback,codex-watch}.js`、`cloudflare/migrations/0001-0009`、`cloudflare/schema.sql`、`AIQuotaBar/Services/{CloudSyncService,CloudSyncQueue,CloudDiagnosticLog,CodexLocalUsage/CodexLocalUsageModel}.swift`、`Sources/CodexLocalUsageCore/UsageClient.swift`、`AIQuotaBar/Services/CodexWatch/CodexWatchCloudClient.swift` 等。

---

## 1. 认证体系总览(必读)

Worker 上共有 6 类凭据/密钥,Windows 版必须逐字复刻其派生与哈希算法(均为 SHA-256 小写 hex):

| 凭据 | 派生/哈希算法 | 存储位置 | 用途 |
|---|---|---|---|
| 设备凭据(device token) | 明文形如 `aqu_` + 64 个 hex 字符(两个去连字符 UUID 拼接);服务端只存 `SHA-256(token)` 于 `usage_devices.token_hash` | Mac:Keychain vault 按 binding 键存储 | 所有 `/v1/usage/*`、`/v1/quota-samples`、`/v1/team/handoff` 的 `Authorization: Bearer` |
| 邀请码(invite code) | 3 组 4 字符 `XXXX-XXXX-XXXX`,字母表 `ABCDEFGHJKMNPQRSTUVWXYZ23456789`(无 I/L/O/0/1,便于手抄);服务端存 `SHA-256("aqb-invite|" + 去掉连字符的大写码)` 于 `usage_teams.invite_hash` | 服务端仅哈希 | 加入团队(`POST /v1/usage/join`),唯一入队凭据 |
| 团队管理密码(login password) | 3 组 5 字符 `XXXXX-XXXXX-XXXXX`,同字母表;服务端存 `SHA-256("aqb-team-login|" + password)` 于 `usage_teams.login_hash` | 服务端仅哈希;Mac 端创建成功后明文存入本机 Keychain(`team-manager:<digest>` binding) | `/v1/team/login`、manager 会话签名密钥、handoff 升级 manager |
| 成员口令(member passphrase) | 4-64 字符;服务端存 `SHA-256("aqb-member|" + teamID + "|" + memberID + "|" + passphrase)` 于 `usage_member_secrets.pass_hash` | 服务端仅哈希 | 同名成员的第二台设备加入/轮换设备凭据 |
| 平台管理密钥 `OPS_ADMIN_SECRET` | secret,≥40 字符且 ≠ `SYNC_TOKEN`;Cookie `__Host-aqb_ops = expiry.nonce.HMAC-SHA-256(expiry.nonce, secret)` | Worker secret(wrangler) | `/admin` 控制台、`/v1/admin/*` |
| 设备供应密钥 `USAGE_ADMIN_TOKEN` | secret,≥32 字符且 ≠ `SYNC_TOKEN`,`Bearer` 全等比较 | Worker secret | `POST /v1/usage/devices[/revoke]`(管理员手工供应设备) |
| App 内置公共 key `SYNC_TOKEN` | 固定字符串,硬编码进客户端二进制(Mac 端默认值 `d7dac44143ffaa6e1fe1237add43723dcc10ce72330410483a49de8c8d62c038`) | Worker secret + 客户端硬编码 | **仅作 ingestion gate**:telemetry、feedback(app 端)、codex watch。明确不是鉴权,永不授予读/删团队数据能力 |

### 1.1 Cookie 会话(三种,签名密钥不同)

- **manager 会话**(team.js):Cookie `__Host-aqb_team`,值 `teamID.expiry.nonce.signature`,8h(28800s)有效;`signature = HMAC-SHA-256(teamID.expiry.nonce, login_hash)`。teamID 须匹配 `^t[a-f0-9]{16}$`,nonce 为 36 位 UUID。签名验证用常数时间比较。
- **member 会话**(team-handoff.js):Cookie `__Host-aqb_team`,值 `member.<base64url(JSON)>.signature`,JSON 为 `{teamID,deviceID,tokenHash,expiry,nonce}`,8h 有效;签名密钥同样是该团队的 `login_hash`,且每次请求还要回查 `usage_devices` 确认 token 未被吊销。member 会话只能 GET。
- **平台管理员代铸 manager 会话**(operations.js `/v1/admin/team-session`):值 `admin.teamID.expiry.nonce.HMAC(..., OPS_ADMIN_SECRET)`,team.js 的 `adminSession()` 接受,使 `/admin` 控制台可无密码打开任意团队(包括早于 `usage_teams` 表的 device-only 团队)。
- 所有 Cookie 属性:`Path=/; Secure; HttpOnly; SameSite=Strict`。

### 1.2 限速(固定窗口计数器,表 `usage_team_limits` / `ops_login_limits`)

| 动作 | 桶 | 上限/窗口 |
|---|---|---|
| 建团 | `create-ip|<ip>` | 3 次/小时 → 429(retry-after 3600) |
| 团队登录 | `login|<teamID>|<ip>` | 10 次/15min |
| 加入团队 | `join-ip|<ip>` / `join-code|<hash 前 16>` | 20 / 30 次/15min |
| handoff 验证管理密码 | `handoff|<teamID>|<ip>` | 10 次/15min |
| 反馈提交 | `feedback-ip|<ip>` | 5 次/小时 |
| watch 读写 | `watch-pub|<publisher>` / `watch-read|<ip>` / `watch-reads|<ip>` | 120 / 120 / 60 次每小时 |
| admin 登录 | hash(secret+ip+15min 桶) | 10 次/15min |

### 1.3 全局行为

- `MIGRATION_READ_ONLY=true` 时所有 POST/PUT/DELETE → 503 `migration_in_progress`(retry-after 60)。
- 所有 JSON 响应 `cache-control: no-store` + CORS `*`(GET/POST/DELETE/OPTIONS,allow-headers `authorization,content-type`)。
- 带 origin 的浏览器写请求做 same-origin 校验(`invalid_origin` 403);原生 App 请求不带 origin,天然通过。
- D1 错误分类(worker.js `d1ErrorResponse`):消息含 "d1" → 若匹配每日行配额特征返回 503 `{error:"d1_daily_limit_exceeded", hint:"...resets at 00:00 UTC"}`,否则 503 `{error:"d1_error"}`。客户端据此判定不可重试。Windows 端须实现相同的 `isD1DailyLimitExceeded`/`isD1Error` 文本匹配(见 §6.3)。

---

## 2. Worker 完整 REST API 清单

默认端点 `https://ai-quota-bar.pages.dev`。请求体全部为 `application/json`;除特别说明,响应均为 `{ok:true,...}` 或 `{error:"<code>"}` + 对应 HTTP 状态码。

### 2.1 公开端点(worker.js)

| 方法+路径 | 请求 | 响应 | 说明 |
|---|---|---|---|
| GET `/healthz` | — | `{ok:true, service:"ai-quota-bar-sync"}` | 健康检查 |
| GET `/v1/app-update` | — | `{ok, source:"github-proxy"\|"worker-fallback", version, tag, release_url, download_url, published_at}` | 代理 GitHub latest release(优先 `AIQuotaBar.pkg` 资产,回退 `.dmg`),cf 缓存 300s;失败时用 `APP_LATEST_VERSION`(默认 1.19.0)等 vars 回退。Windows 版可复用取版本号,或新增资产名 |
| OPTIONS 任意 | — | 204 | CORS 预检 |

### 2.2 自助团队(team.js)

| 方法+路径 | 认证 | 请求 | 成功响应 | 备注 |
|---|---|---|---|---|
| POST `/v1/team/create` | 公开(same-origin) | `{teamName}`(≤60 字符,无控制字符) | `{ok, teamID, teamName, inviteCode, loginPassword}` | 明文凭据**仅返回一次**;限速 3/h/IP;需 `USAGE_TEAMS_ENABLED=true`(否则 503 `teams_not_configured`);teamID 冲突重试 3 次后 503 `team_service_unavailable` |
| POST `/v1/team/login` | 公开 | `{teamID, password}` | `{ok}` + Set-Cookie(manager 会话) | teamID 须 `^t[a-f0-9]{16}$`;限速 10/15min;失败统一 401 `invalid_credentials` |
| POST `/v1/team/logout` | 任意 | — | `{ok}` + 清 Cookie | — |
| GET `/v1/team/overview?days=7\|30\|90` | team cookie(member 或 manager) | — | `{ok, access:{role,canManage,memberID}, generatedAt, timezone:"UTC", days, from, to, team:{teamID,teamName,createdAt,inviteRotatedAt,memberLimit:20}, members:[{memberID,memberName,devices:[{deviceID,revoked,createdAt,lastEventAt}]}], usage:{member[],device[],account[]}}` | device-only 团队(无 usage_teams 行)合成占位 team 对象;usage 行结构见 §2.4 summary |
| GET `/v1/team/timeline` | team cookie | `from,to,bucket_seconds=300\|86400,&member_id,&device_id,&account_id` | `{ok, from, to, bucketSeconds, groups:[TeamUsageRow]}` | 校验同 `/v1/usage/timeline`;300s 桶跨度 ≤24h,86400 桶 ≤366 天 |
| GET `/v1/team/accounts` | team cookie(member 可) | — | `{ok, accounts:[{provider,account_name,sample_count,model_count,earliest_sampled_at,latest_sampled_at}]}` | 团队 quota 账号清单 |
| DELETE `/v1/team/accounts?provider=&account_name=` | manager cookie | — | `{ok, deleted_quota_samples, deleted_devices:0, deleted_settings:0}` | 删该团队该账号全部 quota 历史 + 写审计(`delete_quota_account`) |
| POST `/v1/team/invite/rotate` | manager cookie | — | `{ok, inviteCode}` | 旧 invite 立即失效;device-only 团队无行 → 404 |
| POST `/v1/team/devices/revoke` | manager cookie | `{deviceID}` | `{ok}` | `usage_devices.revoked=1` |
| POST `/v1/team/members/revoke` | manager cookie | `{memberID}` | `{ok}` | 吊销该成员**所有**设备 + 审计(`revoke_member`) |

member 会话发非 GET → 403 `team_manager_required`;请求头 `x-aqb-team` 与会话团队不符 → 409 `team_session_changed`。

### 2.3 浏览器 handoff(team-handoff.js)

| 方法+路径 | 认证 | 请求 | 响应 | 备注 |
|---|---|---|---|---|
| POST `/v1/team/handoff` | Bearer 设备凭据 | `{}`(member)或 `{"managementPassword":"..."}`(升级 manager) | `{ok, ticket, role:"member"\|"manager", expiresIn:120}` | ticket = 64 hex(两个 UUID),有效期 120s、单次;管理密码验证限速 10/15min;团队无 usage_teams 行 → 409 `team_console_unavailable` |
| POST `/v1/team/redeem` | 浏览器 same-origin | `{ticket}` | `{ok, role, teamID}` + Set-Cookie(member 或 manager 会话) | `DELETE ... RETURNING *` 保证单次(失败兑换也消耗);再校验 login_hash 未变、设备 token 未吊销,否则 401 `revoked_ticket` |

Mac 端流程:`teamBrowserURL()` 取 ticket 后拼 `https://<endpoint>/team#handoff=<ticket>` 交给系统浏览器打开。

### 2.4 本机用量与设备供应(local-usage.js)

事件结构(`POST /v1/usage/events/batch` 的 `events[i]`,服务端 `validEvent` 强校验):

```
{
  "id": "64位hex",                  // 事件指纹
  "occurredAt": "ISO8601",           // 不得晚于服务器时间 +300s
  "model": "≤200字符",
  "quality": "exact" | "cumulative-delta",
  "parserVersion": 1,                // 必须恰为 1
  "accountID": "64hex 或省略",       // 省略时 accountSource 也必须省略
  "accountSource": "log" | "login-observation",
  "tokens": { "input":≥0, "cached":≥0, "cacheWrite":≥0, "output":≥0, "reasoning":≥0 }  // 全部安全整数 ≤1e12
  // 不变式: cached+cacheWrite ≤ input; reasoning ≤ output; input+output > 0
}
```

| 方法+路径 | 认证 | 请求 | 成功响应 | 备注 |
|---|---|---|---|---|
| POST `/v1/usage/join` | 公开(无 Authorization) | `{inviteCode, memberName(≤60), deviceID(≤120), memberPassphrase?}` | `{ok, token, identity:{team_id,device_id,member_id,member_name}}` | 服务端先归一化 invite(大写、剔除非 `A-Z2-9`);已有同名成员必须持 passphrase 或当前设备凭据(否则 409 `name_taken` / 401 `invalid_passphrase`);新成员满 20 → 403 `team_full`;设备已绑定他人 → 409 `device_already_bound` |
| GET `/v1/usage/identity` | Bearer | — | `{ok, identity:{team_name?,team_id,member_id,member_name,device_id}, prices:[UsagePrice]}` | 每轮上报前调用,顺带刷新价格表 |
| POST `/v1/usage/leave` | Bearer | — | `{ok}` | 吊销当前设备(revoked=1);团队历史保留 |
| POST `/v1/usage/member/passphrase` | Bearer | `{passphrase(4-64)}` | `{ok}` | upsert 成员口令哈希 |
| POST `/v1/usage/events/batch` | Bearer | `{events:[1..50]}` | `{ok, accepted:[id...], rejected:[{id, reason:"invalid_event"\|"ownership_conflict"\|"content_conflict"}]}` | 服务端为每条事件算 `fingerprint = SHA-256(JSON(规范化事件))`;`INSERT OR IGNORE` 幂等;回读对比 member_id(所有权)与 fingerprint(内容);批内重复 id → 400 `duplicate_id_in_batch` |
| GET `/v1/usage/summary?from&to&group_by=member\|device\|model\|account&member_id` | Bearer | — | `{ok, groups:[TeamUsageRow], from, to}` | 跨度 ≤366 天 |
| GET `/v1/usage/timeline?from&to&bucket_seconds&member_id&device_id&account_id` | Bearer | — | 同 2.2 timeline | bucket 只允许 300 或 86400;300 限 24h、86400 限 366 天 |
| POST `/v1/usage/devices` | `USAGE_ADMIN_TOKEN` | `{teamID,deviceID,memberID,memberName,reassign?}` | `{ok, token, identity}` | 管理员供应;同设备换 member 需 `reassign:true`,否则 409 |
| POST `/v1/usage/devices/revoke` | `USAGE_ADMIN_TOKEN` | `{teamID,deviceID}` | `{ok}` | 管理员吊销 |

`TeamUsageRow`(summary/timeline/overview 共用,按价格区间分桶聚合,原始事件永不离开服务端):

```
{ "id":"分组键", "name":"成员名或id", "memberID":"m..|null",
  "records":n, "input":n, "cached":n, "cacheWrite":n, "output":n, "reasoning":n,
  "estimatedRecords":n,          // quality != exact 的条数
  "pricedRecords":n, "costUSD":x, // 按 USAGE_MODEL_PRICES 价格表分段计价(微美元取整后/1e6)
  "cacheHitRate":0..1|null }
```

### 2.5 团队 quota 读写(team-quota.js,经 worker.js 路由,全部 Bearer 设备凭据)

| 方法+路径 | 请求 | 成功响应 | 备注 |
|---|---|---|---|
| GET `/v1/health` | — | `{ok:true}` | 凭据有效性探测 |
| POST `/v1/quota-samples` | 上传快照,见 §4.1(体 ≤256 KiB,否则 413 `body_too_large`) | `{ok, inserted:n, retention_days:90}` | 服务端 allowlist 重序列化(`detail_text` 强制 null);percent 模式折叠 total=100;90 天服务端保留(每次上传顺带按服务器时间裁剪本团队) |
| GET `/v1/quota-samples?limit=1..500&history=1?&device_id?` | — | `{ok, samples:[payload...]}` | 默认 heads:每个 (provider,account,model) 只取最新一条(跨设备去重,共享额度不求和);`history=1` 返回 `team_quota_samples` 原始历史(按 sampled_at 降序) |
| GET `/v1/account-summaries` | — | `{ok, accounts:[...]}` | 同 2.2 accounts |
| GET `/v1/devices?device_id?` | — | `{ok, devices:[{id,name,created_at,last_seen_at}]}` | last_seen_at 取 quota_heads 最新采样,回退 created_at |
| DELETE `/v1/data`(及一切 DELETE) | — | 403 `{error:"team_manager_required"}` | **设备凭据永远不能删除数据**(含自己团队);清理必须走 manager 会话的 `/v1/team/accounts`。Mac 端 `deleteRemoteData()` 仍保留旧调用,实际会得到 403 — Windows 版不必实现 |

### 2.6 遥测与运营(operations.js)

| 方法+路径 | 认证 | 请求 | 响应 | 备注 |
|---|---|---|---|---|
| POST `/v1/telemetry/pulse` | `SYNC_TOKEN` | `{installationToken(64hex), event:"active"\|"heartbeat", appVersion, appBuild, osVersion}` | `{ok}` | 服务端 id = SHA-256("aqb-telemetry|"+token);版本/os 有正则校验;90 天日表保留 |
| POST `/v1/telemetry/forget` | `SYNC_TOKEN` | `{installationToken}` | `{ok}` | 删除记录 + 留撤销哈希拒绝在途重试(410 `installation_deleted`) |
| POST `/v1/admin/login` | 公开(same-origin) | `{password}` | `{ok}` + `__Host-aqb_ops` cookie | 密码与 `OPS_ADMIN_SECRET` 双重哈希后常数时间比较;限速 10/15min |
| POST `/v1/admin/logout` | ops cookie | — | `{ok}` | — |
| POST `/v1/admin/team-session` | ops cookie | `{teamID}` | `{ok,teamID}` + admin 代铸 `__Host-aqb_team` cookie | `/admin` 控制台"打开面板"按钮用 |
| GET `/v1/admin/overview?days=7\|30\|90` | ops cookie | — | `{ok, generatedAt, timezone:"UTC", days, coverageSince, metrics:{total,new_today,reporting_recently,reporting_month,dau,wau,mau}, trend:[{day,active,newInstalls}], versions[], systems[], legacy:{syncedDevices,configuredMembers}}` | 匿名安装统计 |
| GET `/v1/admin/feedback?limit=1..200` | ops cookie | — | `{ok, counts:{published,hidden}, items:[含 contact 的完整留言]}` | contact 仅此处可见 |
| POST `/v1/admin/feedback/status` | ops cookie | `{id:"f"+16hex, status:"published"\|"hidden"}` | `{ok}` | — |
| DELETE `/v1/admin/feedback?id=` | ops cookie | — | `{ok}` | — |
| GET `/v1/admin/d1-usage` | ops cookie | — | `{ok, rowsRead, rowsWritten, scope:"account", databaseRowsRead, databaseRowsWritten, remaining, limit:5000000, pct, observedAt, windowStart, resetsAt}` | 走 Cloudflare GraphQL Analytics(不耗 D1 读配额),5min 边缘缓存;未配 `CF_API_TOKEN` → 503 `missing_token`。**旧的 `/v1/d1-usage` 已关闭 → 403 `platform_admin_required`**(Mac 客户端 `fetchD1UsageState()` 仍在代码里但已无入口,Windows 版可不实现) |
| GET `/v1/admin/data/teams` | ops cookie | — | `{ok, teams:[{team_id,team_name,created_at,members,devices,events}]}`(≤1000) | 团队清单(usage_teams ∪ usage_devices) |
| GET `/v1/admin/data/quota?team_id?` | ops cookie | — | `{ok, items:[payload+team_id+team_name], truncated, row_budget:2000}` | 全团队(或指定团队)每个 (provider,account,model) 的最新快照 |
| GET `/v1/admin/data/quota-history?team_id&provider&account&hours=1..2160&model?` | ops cookie | — | `{ok, samples[](升序), truncated, row_budget:5000, hours, model}` | 行预算 5000,超预算保留**最新**部分并置 truncated;未知查询参数直接 400 `invalid_parameter`(fail-closed) |
| GET `/v1/admin/data/accounts?team_id` | ops cookie | — | `{ok, accounts:[...]}` | 同团队 accounts |
| DELETE `/v1/admin/data/accounts?team_id&provider&account_name` | ops cookie | — | 同 `/v1/team/accounts` 删除 | actor 记为 `platform-admin`,写审计 |
| GET `/v1/admin/data/audit` | ops cookie | — | `{ok, items:[team_data_audit 行]}`(≤100) | 删除/吊销审计 |
| GET `/v1/admin/data/legacy/{accounts,samples,devices}` | ops cookie | query 同 legacy | 各自列表 | 旧共享表只读隔离展示 |

### 2.7 反馈墙(feedback.js)

| 方法+路径 | 认证 | 请求 | 响应 | 备注 |
|---|---|---|---|---|
| POST `/v1/feedback` | 浏览器 same-origin 或 App `SYNC_TOKEN` | `{nickname≤30, message≤1000, contact≤120, appVersion, osVersion}` | `{ok, id:"f"+16hex}` | message 允许换行/Tab;单行字段拒绝一切控制字符;限速 5/h/IP;体 ≤4 KiB |
| GET `/v1/feedback?limit=1..50&offset` | 公开 | — | `{ok, total, items:[{id,nickname,message,source,appVersion,createdAt}]}` | **不含 contact**;只列 published |

### 2.8 Codex 关注通道(codex-watch.js,刻意独立于团队)

授权 = `SYNC_TOKEN`(内置 key,仅证明"是本 App 的一个安装")。地址本身是公开查找键:`account_key = SHA-256(小写归一化邮箱)`。

| 方法+路径 | 请求 | 响应 | 备注 |
|---|---|---|---|
| POST `/v1/watch/publish` | `{publisher, accounts:[≤20 {account, plan?, windows:[≤8 {name, remainingPercent:0..100, resetsAt, sampledAt, startsAt?}]}]}` | `{ok, published:n, updated_at}` | **整体替换语义**:空数组 = 全部取消分享(撤销无需独立端点);跨发布者撞地址 → 409 `account_published_elsewhere`;`sampledAt` 超过当前时间会被钳制到 now;体 ≤128 KiB |
| GET `/v1/watch/quota?email=` | — | 200 `{ok, account, plan, windows[], updated_at, stale_after_ms:10800000}` / 404 `{error:"not_shared"}` / 410 `{error:"stale"}` | 无人分享(最常见)是 404 实义答案;发布者 3h 未更新 → 410;成功读取会累计 `watch_reads` |
| GET `/v1/watch/reads?publisher=` | — | `{ok, accounts:[{account_key, plan, updated_at, read_count, last_read_at, stale}]}` | 发布者查看自己每个账号被读计数(只计数与时间,无读取者身份) |

邮箱校验规则(客户端与服务端逐字一致):trim+小写,3-254 字符,单个 `@`,local ≤64 且匹配 `[a-z0-9.!#$%&'*+/=?^_\`{|}~-]+`,domain 含点、标签不以 `-` 开头/结尾。

### 2.9 静态资产路由(worker.js)

`/team`、`/admin`、`/feedback`、官网首页及语言/图表 JS、`/mobile-preview` 等显式白名单经 `env.ASSETS` 输出,统一附加严格 CSP(`default-src 'self'`,admin/team 再加 `x-robots-tag: noindex`)。**所有 API 响应 no-store;只有官网静态资源可缓存**。

---

## 3. D1 数据库完整 schema

基础表(`cloudflare/schema.sql`,遗留共享区,现已对新客户端只读隔离)+ 9 个 migration(全部幂等 `IF NOT EXISTS`)。

### 3.1 遗留表(仅 /admin 只读 + 迁移测试可写)

```
devices(id TEXT PK, name TEXT, created_at TEXT DEFAULT now, last_seen_at TEXT DEFAULT now)
quota_samples(id TEXT PK, device_id→devices.id, provider TEXT, account_name TEXT NULL,
  model_id TEXT, model_name TEXT, current_interval_total/remaining INT,
  weekly_total/remaining INT, reset_start/end_time TEXT, weekly_start/end_time TEXT,
  value_suffix TEXT, detail_text TEXT, sampled_at TEXT, created_at TEXT DEFAULT now)
  -- 索引: idx_quota_samples_device_sampled_at(device_id, sampled_at DESC)
  --       idx_quota_samples_model_sampled_at(device_id, provider, model_id, sampled_at DESC)
settings(device_id, key, value, updated_at, PK(device_id,key))
```

**0001_latest_heads.sql**:`quota_sample_heads(sample_id→quota_samples.id ON DELETE CASCADE, device_id, provider, account_key, model_id, sampled_at)` + 分组索引 + INSERT/DELETE/UPDATE 三个维护触发器(把"每组最新一条"维护进小表,latest 查询免全表扫;由 `LATEST_INDEX_ENABLED=true` 启用读路径)+ 一次性回fill。

### 3.2 团队用量表(0002 + 0003)

```
usage_members(team_id, member_id, member_name, PK(team_id,member_id))
usage_devices(team_id, device_id, member_id, member_name,
  token_hash TEXT NOT NULL UNIQUE, revoked INTEGER DEFAULT 0, created_at TEXT,
  PK(team_id,device_id))
usage_events(team_id, event_id, device_id, member_id, occurred_at TEXT, model TEXT,
  input_tokens, cached_tokens, cache_write_tokens, output_tokens, reasoning_tokens,
  quality TEXT, parser_version INT, fingerprint TEXT, account_id TEXT NULL,
  account_source TEXT NULL,          -- 0003 追加,账号维度隔离
  PK(team_id,event_id), FOREIGN KEY(team_id,device_id)→usage_devices(team_id,device_id))
  -- 索引: usage_events_team_time(team_id,occurred_at)
  --       usage_events_member_time(team_id,member_id,occurred_at)
  --       usage_events_account_time(team_id,account_id,occurred_at)
  -- 事件身份永久保留(无自动清理):防止离线设备复活已计数事件
```

### 3.3 运营表(0004)

```
telemetry_installs(id PK, first_seen_at, last_seen_at, app_version, app_build, os_version)
  -- 索引 telemetry_installs_last_seen(last_seen_at)
telemetry_days(day, install_id→telemetry_installs.id ON DELETE CASCADE, active 0|1,
  PK(day,install_id))  -- 索引 telemetry_days_install(install_id,day)
ops_login_limits(bucket PK, attempts, expires_at INTEGER)
telemetry_revocations(id PK)   -- 只留撤销哈希
```

### 3.4 自助团队(0005)

```
usage_teams(team_id PK, team_name, invite_hash, login_hash, invite_rotated_at, created_at)
usage_member_secrets(team_id, member_id, pass_hash, PK(team_id,member_id))
usage_team_limits(bucket PK, attempts, expires_at INTEGER)  -- 固定窗口限速器
```

### 3.5 反馈墙(0006)

```
feedback_messages(id PK "f"+16hex, nickname, message, contact, source 'app'|'web',
  app_version, os_version, status 'published'|'hidden', created_at)
  -- 索引 feedback_by_status(status, created_at DESC)
```

### 3.6 团队 quota(0007)

```
team_quota_samples(team_id, device_id, provider, account_key, model_id, sampled_at,
  payload TEXT,  -- 服务端 allowlist 重序列化后的 JSON 快照
  PK(team_id,device_id,provider,account_key,model_id,sampled_at))
  -- 索引 team_quota_time(team_id,sampled_at DESC), team_quota_device_time(team_id,device_id,sampled_at DESC)
team_quota_heads(team_id, device_id, provider, account_key, model_id, sampled_at, payload,
  PK(team_id,device_id,provider,account_key,model_id))   -- UPSERT 仅接受更新的 sampled_at
team_data_audit(id PK uuid, team_id, actor, action, target, created_at)
  -- 索引 team_audit_time(team_id,created_at DESC)
```

### 3.7 浏览器 handoff(0008)

```
team_browser_handoffs(token_hash PK, team_id, role 'manager'|'member', device_id,
  device_token_hash, login_hash, expires_at INTEGER)  -- 索引 (expires_at);2 分钟过期
```

### 3.8 Codex 关注(0009)

```
watch_shared_quota(account_key PK, publisher_id, payload TEXT, updated_at)
  -- 索引 watch_shared_quota_publisher(publisher_id)
watch_reads(account_key PK, read_count DEFAULT 0, last_read_at)
```

---

## 4. 团队生命周期与 quota 共享

### 4.1 创建(Mac 端 `CodexLocalUsageModel.createTeam` → `UsageClient.createTeam`)

1. `POST /v1/team/create {teamName}`;服务器生成 `teamID = "t" + uuid去连字符前16位`、inviteCode、loginPassword(§1 算法),持久化两个 SHA-256 哈希。
2. 明文凭据只在响应里出现一次;Mac 端把 `loginPassword` 以 `team-manager:<SHA-256(endpoint|teamID)>` 为 binding 存入 Keychain,并在 UI 展示"团队信息"卡片供用户抄写备份(ID/邀请码/管理密码 + 一键复制)。**重试不会重复建团**:创建结果缓存在 `createdTeam`,失败重试直接复用。
3. 紧接着用返回的 inviteCode 走一次普通 join(见下),创建者自动成为第一个成员/设备。

### 4.2 加入(`UsageClient.join`,无 Authorization 头)

1. `POST /v1/usage/join {inviteCode, memberName, deviceID, memberPassphrase?}`。客户端先把 invite 归一化(大写、只留字母数字),与服务端 `normalizeInvite` 对齐,粘贴小写/带空格也能匹配。
2. 服务端分支:
   - **新成员名**:成员上限 20;`memberID = "m"+uuid16hex`;若带 passphrase 则写 `usage_member_secrets`;签发新 token。
   - **已存在成员名**:必须(当前请求本身持有该成员该设备的有效凭据)或(passphrase 哈希匹配)。仅知道 deviceID 不能轮换凭据。
3. 响应 `{token, identity}`;Mac 端校验 `identity.device_id == 本机 deviceID` 后立即走 `connect()`:`GET /v1/usage/identity` 换取 identity+prices,把 token 存 Keychain(binding = `SHA-256(endpoint|SHA-256(team_id|member_id|device_id))`),连接对象 `LocalUsageConnection{endpoint, identity, since}` 存 UserDefaults(`localUsage.connection`)。`since` 决定历史回填起点:勾选"同时上报尚未归属团队的本机历史"则 since=1970,否则=加入时刻。
4. 切换团队:成功后本机 binding 变化,旧团队 outbox/队列文件按 binding 隔离永不迁移,已归属旧团队的用量不转移。

### 4.3 设备凭据的生成与吊销

- 生成:join(自助)或 `/v1/usage/devices`(管理员手工,`USAGE_ADMIN_TOKEN`)。token 明文 `aqu_` + 64hex 只在响应出现一次;服务端存 `SHA-256(token)`。同设备重复 provision = upsert 轮换 token 并复活 revoked=0(join 路径无 reassign 限制,admin 路径换 member 需 `reassign:true`)。
- 吊销(全部置 `usage_devices.revoked=1`,之后所有 Bearer 请求 401):
  - 自助:`POST /v1/usage/leave`(Mac 端 leaveTeam:先 leave 再清本地连接/Keychain/队列状态);
  - manager:`POST /v1/team/devices/revoke {deviceID}` 或 `/v1/team/members/revoke {memberID}`(连带审计);
  - 平台管理员:`POST /v1/usage/devices/revoke` 或 admin 数据面删除。
- Mac 客户端遇 401 的处理:停用同步循环(`nextAttempt = distantFuture`、丢弃 client),提示"凭据已过期或被吊销,请重新加入"。

### 4.4 usage 事件上报(payload 结构与节奏)

- **本地源**:扫描 `~/.codex`(可用 `CODEX_HOME` 覆盖)会话日志,解析为 `LocalUsageEvent`(§2.4 结构);持久化在本地 SQLite outbox(`AIQuotaBar/local-usage.sqlite`),状态机 pending/sent/rejected 按 binding 隔离。
- **节奏**:`Timer` 每 **60 秒**触发一轮 refresh → 扫描 + (到点则)sync。每轮 sync:
  1. `GET /v1/usage/identity`(校验 bindingID 未变、刷新价格表);
  2. 循环最多 **20 批**,每批 `POST /v1/usage/events/batch` 携带 ≤50 条 pending 事件;按回执 `accepted` 标记 sent、`rejected` 记录原因(ownership_conflict/content_conflict 等);
  3. 全部批次完成或遇到失败为止;失败后指数退避 `min(3600, 60 × 2^min(failures-1,6))` 秒;401 直接停摆。
- **核验工具**:`verifyCloudDelivery()`(--verify-usage-delivery 启动参数)用 `GET /v1/usage/timeline` 按天分页拉服务端聚合,与本地已确认记录逐 token 对账,报告写入 `usage-delivery-audit.json`。Windows 版建议保留此诊断能力。

### 4.5 quota 共享语义(关键)

- 每台设备各自上报自己看到的账号快照(POST /v1/quota-samples);服务端 `team_quota_heads` 按 `(team_id,device_id,provider,account_key,model_id)` UPSERT(仅更新的 sampled_at 覆盖),`team_quota_samples` 保留 90 天历史。
- **读取**(GET /v1/quota-samples,无 device_id)按 `(provider,account_key,model_id)` 跨设备取最新一条(ROW_NUMBER 窗口)——**共享额度不被多设备求和**,成员消耗(usage_events)才按成员/设备分别统计。
- 菜单/设置里云端数据与本地数据合并展示:本地 provider 数据缺失时回落云端(Cloud 源);`CloudDataVisibilityLimit`(1h/5h/1d/1w/never)控制"最后一次远端报告多久后隐藏纯云端视觉"。

---

## 5. 云同步(quota metadata)

### 5.1 上传内容与时机

- 触发:每轮 provider 刷新(用户可配 `refreshInterval`,**默认 600 秒**)拿到**本轮新抓到的**用量后 `syncUsageDataToCloud`(仅当采样时的团队 binding 仍等于当前 binding)。开关 `cloudSyncEnabled`(UI 文案"共享账号额度")默认关;已加入团队时与"共享本机用量"(reportingEnabled)是两个独立开关。
- Payload(`CloudUsageSnapshotPayload`):

```json
{
  "deviceID": "UUID(本机持久化,UserDefaults cloudSyncDeviceID)",
  "sampledAt": "ISO8601(本帧采样时间)",
  "retentionDays": 90,            // 上传携带,但服务端忽略,固定 90
  "models": [{
    "provider": "codex|kimi|glm|minimax",
    "accountName": "账号标签(可能含邮箱,视为个人数据)",
    "modelID": "...", "modelName": "...",
    "currentIntervalTotal": 100, "currentIntervalRemaining": 42,
    "currentIntervalRemainingPercent": 42,   // percent-only 提供商:total 折叠为 100
    "weeklyTotal": n, "weeklyRemaining": n, "weeklyRemainingPercent": null,
    "resetStartTime": "...", "resetEndTime": "...",
    "weeklyStartTime": "...", "weeklyEndTime": "...",
    "valueSuffix": "%"|"次"|null, "detailText": null   // 服务端永不落盘 detailText
  }]
}
```

- **永不**上传:任何提供商凭据(Codex/Kimi/GLM/MiniMax OAuth、Clash key)、对话内容、跨周期 utilization 历史(旧版曾整包附带,超过 256 KiB 上限后已移除;`utilizationHistories` 字段仅为解码旧队列文件保留)。

### 5.2 413 与体积限制

| 端点 | 请求体上限 | 超限响应 |
|---|---|---|
| POST /v1/quota-samples | 262,144 B(256 KiB) | 413 `{error:"body_too_large"}` |
| POST /v1/usage/events/batch | 524,288 B(512 KiB) | 413 |
| POST /v1/watch/publish | 131,072 B | 413 |
| POST /v1/feedback | 4,096 B | 413 |
| team console 各 POST(readBody) | 2,048 B | 413 |

客户端配合:入队前把旧 payload 归一化为 `teamSnapshot`(剥掉 utilizationHistories),避免 700 KiB 旧文件反复打 413 导致队列永不清空。

### 5.3 本地缓存与重试队列

- **CloudSyncQueue**(`~/Library/Application Support/com.techfanseric.aiquotabar/sync-queue/`):POST 失败(重试用尽)后 payload 落盘为 UUID.json,**按团队 binding 分子目录**;容量 `maxQueueSize = 50` 条/团队(按修改时间丢最旧);无 binding 的遗留文件隔离不再发送;flush 按写入时间顺序逐条重发,一条失败即停(余下多半同因);解码失败文件直接清除。Windows 对应:`%APPDATA%` 下同等目录 + 相同 per-team 隔离与容量语义(TeamSyncIsolationTests 固化了这些不变式)。
- **重试策略(写入路径 `sendWithRetry`)**:1s → 4s → 16s 共 3 次退避(共 4 次尝试);`CancellationError`(关同步/换团队/换 endpoint)立即退出不入队;**非重试错误**:4xx 全部、以及 `d1_daily_limit_exceeded`/D1 日配额特征(日配额 UTC 0 点才重置,秒级重试无意义)——直接入队等下轮。
- **读取路径 `data(for:)`**:同样 1/4/16 退避,但仅对瞬态网络错误(URLError)重试;HTTP 4xx/5xx 立即抛出。
- 请求超时 15s(CloudSyncService)/30s(UsageClient);`URLSession` ephemeral + 禁 Cookie/缓存 + **禁 HTTP 重定向**(CloudSyncRedirectBlocker,防凭据被 3xx 引走)。
- **状态持久化**:`lastSyncStatus`(idle/success/failure+reason)快照存 UserDefaults `cloudSync.lastStatusSnapshot.v1`(Error 不序列化,重启后仅显示 reason);UI 显示 "Last sync: 2m ago"/"Failed: 5m ago"。
- **下载**:每轮刷新末尾 `refreshCloudUsageData()`:GET `/v1/quota-samples?limit=500`(最新)+ `?history=1&limit=500`(历史曲线),重建 `cloudProviderUsageData` 与 `cloudModelQuotaSamples`(内存),失败清空并记 `cloudUsageLoadError`。注意读路径会在 `data(for:)` 里用当前团队 context 重写 URL 与 Authorization 头(旧 token 失效即取消)。

### 5.4 Sync 诊断

- **CloudDiagnosticLog**(UserDefaults `cloud.diagnostics.v1`,≤200 条):上传/下载各记一条,只存错误码("HTTP 503"、"URL loading error (‑1009)"),**永不**存服务器响应体、凭据或 URL;相同 operation+message 折叠 `occurrences` 并置顶。设置页"同步状态与日志"展示前 10 条。
- **数据报告**:`makeDataReport/`makeRemoteDataReport` 拉 devices + samples(history)+ account-summaries 生成自包含 HTML(本地 vs 云端逐 model 对照、过滤)。Windows 版建议保留(纯客户端功能)。
- **D1 用量面板**:Mac 端 `fetchD1UsageState()`(GET `/v1/d1-usage`)已因服务端关闭该端点而失效(403);Windows 版无需实现,除非将来给 `/v1/admin/d1-usage` 开非 admin 视图。

---

## 6. /team 与 /admin 仪表板功能边界

### 6.1 `/team`(团队自服务面板,member 只读 / manager 全权)

- 进入方式:App 内"查看团队"(member handoff ticket)或"管理团队"(manager ticket,管理密码已在 Keychain 则免输);或浏览器 `POST /v1/team/login` 输 teamID+管理密码。均落到同一 Cookie。
- **member 会话(只读)**:overview、timeline、accounts 三个 GET;一切写操作 403。
- **manager 会话可做**:overview 查看(成员/设备/账号/最近事件)、`invite/rotate`(展示一次性新邀请码)、`devices/revoke`、`members/revoke`、`DELETE /v1/team/accounts?provider&account_name`(清理本团队某账号 quota 历史,带确认弹窗与审计)。
- UI(public/team.js + team-charts.js):用量条形图/月历/24h 五分钟矩阵,按成员/设备/账号筛选,切 Tokens/记录数/缓存命中/成本;团队信息、邀请码轮换、成员设备吊销、quota 账号表。
- 边界:只能看到**本团队**;请求里的 teamID 永不是权限来源(全部来自服务端会话);账号删除只删 quota 快照,不动消费事件。

### 6.2 `/admin`(平台运营台,`OPS_ADMIN_SECRET` 独立登录)

- 匿名安装统计(7/30/90 天 DAU/WAU/MAU、新增、版本与系统分布、90 天趋势);
- 反馈留言审核(完整含 contact、隐藏/恢复/删除);
- 团队清单(名称/成员/设备/事件数)与"打开面板"按钮(经 `/v1/admin/team-session` 代铸 manager cookie 进任意团队);
- 团队数据面:`data/quota`(全团队最新快照,可按 team_id 过滤)、`data/quota-history`(账号展开时懒加载原始历史,行预算 5000 + truncated 提示)、`data/accounts`、`data/audit`、`data/legacy/*`(旧共享数据只读隔离);
- 平台管理员可跨团队删除 quota 账号(`DELETE /v1/admin/data/accounts`,actor=platform-admin,写审计);
- D1 用量监控(`/v1/admin/d1-usage`)。
- 边界:**不含**团队管理密码、设备 token、消费事件原始行(只有聚合);legacy 数据在所有权明确解决前只读。

---

## 7. Windows 客户端(C#/.NET 8)HTTP 客户端清单

统一约束:base URL `https://ai-quota-bar.pages.dev`(硬编码,不暴露自定义端点设置);`HttpClient` 禁自动重定向(AutomaticDecompression 可开);timeout 15s(quota 路径)/30s(usage 路径)/8s(watch 读);设备凭据存 Windows Credential Manager / DPAPI(对应 Keychain vault 的 `deviceCredentials[binding]` 字典语义)。

### 7.1 端点 × 时机 × 重试总表

| # | 端点 | 时机 | 认证 | 重试策略 |
|---|---|---|---|---|
| 1 | POST `/v1/team/create` | 用户点"创建并加入" | 无 | 4xx/429 不重试;网络错误 1/4/16;结果缓存防重复建团 |
| 2 | POST `/v1/usage/join` | 创建后 / 用户点"加入团队" | 无(不带 Authorization) | 同上;401/403/409 映射为"邀请码或口令错误/团队已满/名字被占" |
| 3 | GET `/v1/usage/identity` | connect 时 1 次 + 每 60s 同步轮首 | Bearer 设备凭据 | 网络错 1/4/16;401 → 判定凭据失效,停止轮询要求重新加入 |
| 4 | POST `/v1/usage/events/batch` | 60s 轮询,≤50 条/批 × ≤20 批/轮 | Bearer | 批级失败指数退避 60×2^n(上限 3600s);数据不丢(SQLite outbox),rejected 按回执落账 |
| 5 | POST `/v1/quota-samples` | 每 refreshInterval(默认 600s)拿到新 provider 数据后 | Bearer | 1/4/16 三次;4xx 与 D1 日配额立即放弃并入本地队列(≤50 条/团队) |
| 6 | (队列 flush = 再次 POST /v1/quota-samples) | 启动时、每次上传成功后 | Bearer | 逐条顺序重发,一条失败即停 |
| 7 | GET `/v1/quota-samples?limit=500` + `?history=1&limit=500` | 每轮刷新末尾(下载合并);"立即同步"按钮 | Bearer | 网络错 1/4/16;HTTP 错误立即失败并清云端缓存 |
| 8 | GET `/v1/account-summaries`、GET `/v1/devices` | 数据报告生成时 | Bearer | 同 7 |
| 9 | GET `/v1/usage/summary`(×3: member/device/account) | 打开团队用量面板、切天数 | Bearer | 网络错 1/4/16 |
| 10 | GET `/v1/usage/timeline`(daily 86400 + hourly 300) | 打开菜单面板(结果缓存 5 分钟)、点日期看当天、核验工具 | Bearer | 同上;300 桶限 24h 窗口 |
| 11 | POST `/v1/usage/member/passphrase` | 用户保存成员口令 | Bearer | 不重试(用户可重点) |
| 12 | POST `/v1/usage/leave` | 用户确认退出团队 | Bearer | 不重试;成功后清本地连接/凭据/状态 |
| 13 | POST `/v1/team/handoff` | 用户点"查看团队/管理团队" | Bearer(+可选 managementPassword) | 不重试;401 时清除已存管理凭据 |
| 14 | (浏览器)GET `/team#handoff=<ticket>` → 页面内 POST `/v1/team/redeem` | 打开面板 | ticket | 由网页完成,客户端只拼 URL 并调系统浏览器 |
| 15 | POST `/v1/telemetry/pulse` | 活跃时(≥15min 节流 + 每日一次)/每小时心跳;退出前 forget 可选 | `SYNC_TOKEN`(内置) | 失败静默(下次使用时再试),≥60s 失败间隔 |
| 16 | POST `/v1/feedback` | About 页提交留言 | `SYNC_TOKEN` | 400/413→内容错误、429→限速,均用户可见不重试 |
| 17 | POST `/v1/watch/publish` | 每轮刷新(勾选分享账号时),整体替换 | `SYNC_TOKEN` | 失败静默 Bool 返回 |
| 18 | GET `/v1/watch/quota?email=` | 每轮刷新(有关注地址时) | `SYNC_TOKEN` | 404/410 是实义状态;网络错显示 unreachable |
| 19 | GET `/v1/watch/reads?publisher=` | 分享面板查看被读计数 | `SYNC_TOKEN` | 失败返回空表 |
| 20 | GET `/v1/app-update` | 更新检查(独立模块) | 无 | 失败用本地已知版本 |
| 21 | GET `/healthz` | 诊断/连通性检查 | 无 | — |

不需要实现的:浏览器侧 `/v1/team/*` 管理端点(login/overview/rotate/revoke —— 由 `/team` 网页承担)、`/v1/admin/*`(平台运营台)、`/v1/usage/devices[/revoke]`(管理员手工供应,可用 wrangler/curl 替代)、`DELETE /v1/data`(服务端已封禁)、`/v1/d1-usage`(已关闭)。

### 7.2 必须复刻的客户端不变式(有测试固化)

- **binding 隔离**:一切异步回调在写 UI/发请求前重验"当前 connection binding == 发起时 binding",不等即 CancellationError 静默丢弃(TeamSyncIsolationTests)。
- 队列文件无 binding 或 binding 不符 → 永不发送;容量按团队分别计 50。
- 个人模式(未入团队)不发起任何 quota 读/写;join 返回的 identity.device_id 必须等于本机 deviceID 否则视为攻击面拒绝。
- usageDigest 一律 SHA-256 小写 hex;`LocalUsageConnection.binding = SHA-256(endpoint + "|" + SHA-256(team_id|member_id|device_id))`。
- 日期解析兼容 ISO8601 带毫秒与不带毫秒(服务端 `toISOString()` 总带 `.000Z`)。

### 7.3 D1 错误分类(伪代码)

```
isNonRetryable(err):
  if 400 <= status <= 499: true
  if 500 <= status <= 599 and body 含 "d1" and (含 daily_limit/daily_read_limit/daily_write_limit
     或 (daily|"per day" 且 exceeded 且 row(s) read/written)): true   // d1_daily_limit_exceeded
```

用户文案:"云端数据库当日配额耗尽,00:00 UTC 重置"。

---

## 8. Worker 部署配置(Windows 版直接复用)

### 8.1 部署形态

Cloudflare Pages direct-upload 项目(非独立 Worker):`cloudflare/wrangler.pages.toml`

```toml
name = "ai-quota-bar"                    # → https://ai-quota-bar.pages.dev
pages_build_output_dir = "dist-pages"    # npm run build:pages 产出(官网静态 + 打包后的 _worker.js)
compatibility_date = "2026-05-14"

[vars]
CF_ACCOUNT_ID = "d9b4ce8306afc5594afc55786c3a76e4"
D1_DATABASE_ID = "0d70b7e7-2397-4d89-a925-5c335257dd58"
LATEST_INDEX_ENABLED = "true"            # 0001 heads 读路径开关(迁移完成后常开)

[[d1_databases]]
binding = "DB"
database_name = "ai-quota-bar"
database_id = "0d70b7e7-2397-4d89-a925-5c335257dd58"
```

命令:`npm run check`(node --check 全部 src/public)→ `npm test`(Node 22.5+ experimental-sqlite)→ `npm run build:pages` → `npm run deploy:pages`(`wrangler pages deploy --project-name ai-quota-bar --branch main`)。数据库迁移:`npx wrangler d1 execute ai-quota-bar --remote --file=migrations/00XX_*.sql`(新库先 `schema.sql` 再 0001→0009 顺序)。

### 8.2 Secrets 与环境变量

| 变量 | 类型 | 要求 | 作用 |
|---|---|---|---|
| `SYNC_TOKEN` | secret | =客户端硬编码值 | telemetry/feedback/watch ingestion gate |
| `USAGE_TEAMS_ENABLED` | var/secret | `"true"` 才开放 create/join,否则 503 `teams_not_configured` | 自助团队总开关 |
| `OPS_ADMIN_SECRET` | secret | ≥40 字符,≠ SYNC_TOKEN | `/admin` 会话签名与登录比较 |
| `USAGE_ADMIN_TOKEN` | secret | ≥32 字符,≠ SYNC_TOKEN | 设备手工供应端点 |
| `CF_API_TOKEN` | secret(可选) | Account Analytics: Read | `/v1/admin/d1-usage` GraphQL 查询 |
| `USAGE_MODEL_PRICES` | var(可选) | JSON 数组 ≤20 条 `{model,version,source,effectiveFrom,effectiveTo?,input,cached,cacheWrite?,output}`,区间不得重叠 | usage 聚合计价;客户端经 `/v1/usage/identity` 拿到同一份并本地校验 |
| `MIGRATION_READ_ONLY` | var(可选) | `"true"` | 迁移期全局禁写(503) |
| `APP_LATEST_VERSION` / `APP_RELEASE_URL` / `APP_DOWNLOAD_URL` | var(可选) | — | `/v1/app-update` 的 GitHub 代理失败回退 |
| `LATEST_INDEX_ENABLED` | var | 部署序列控制(见 cloudflare/README) | 遗留 latest 读路径 |

### 8.3 对 Windows 版的部署结论

- **同一 Worker、同一 D1 不动**。Windows 客户端与 Mac 客户端是同一 API 的两个消费者,团队内 Mac + Windows 设备可混用(deviceID 各自独立,凭据各自 Keychain/DPAPI)。
- 唯一可能的服务端增量:`USAGE_MODEL_PRICES` 增补 Windows 端模型、`/v1/app-update` 资产名(`.msi`/`.exe`,当前仅找 `AIQuotaBar.pkg`/`.dmg`,Windows 版更新检查应改为直连 GitHub Releases 或给 Worker 加资产白名单)。
- 内置 `SYNC_TOKEN` 需原样带入 Windows 二进制(仅 ingestion 语义,泄露无害于团队数据)。

---

## 附:关键文件索引

| 职责 | 文件 |
|---|---|
| 路由/静态资产/D1 错误分类/app-update | `cloudflare/src/worker.js` |
| 哈希/编码生成/限速核心 | `cloudflare/src/usage-team-core.js` |
| 团队控制台(create/login/overview/rotate/revoke) | `cloudflare/src/team.js` |
| 浏览器 handoff 与 member 会话 | `cloudflare/src/team-handoff.js` |
| 设备供应/join/事件批次/聚合 | `cloudflare/src/local-usage.js` |
| 团队 quota 读写/审计/admin 数据面 | `cloudflare/src/team-quota.js` |
| 遗留共享表兼容(只读隔离) | `cloudflare/src/legacy-quota.js` |
| 运营台/遥测 | `cloudflare/src/operations.js` |
| 反馈墙 | `cloudflare/src/feedback.js` |
| Codex 关注通道 | `cloudflare/src/codex-watch.js` |
| quota 上传客户端/重试/队列/报告 | `AIQuotaBar/Services/CloudSyncService.swift`、`CloudSyncQueue.swift`、`CloudDiagnosticLog.swift` |
| 团队连接/事件上报状态机 | `AIQuotaBar/Services/CodexLocalUsage/CodexLocalUsageModel.swift`、`Sources/CodexLocalUsageCore/UsageClient.swift`、`UsageStore.swift` |
| 凭据存储 | `AIQuotaBar/Services/KeychainService.swift`(vault.deviceCredentials[binding]) |
| watch 云客户端 | `AIQuotaBar/Services/CodexWatch/CodexWatchCloudClient.swift`、`CodexWatchStore.swift` |
| 设置 UI | `AIQuotaBar/Settings/Components/TeamSettingsSection.swift`、`Settings/Panes/SyncPane.swift` |
| 行为测试 | `AIQuotaBar/Tests/{TeamSyncIsolationTests,CloudSyncRequestPolicyTests,CloudSyncPayloadTests}.swift` |
| 文档 | `cloudflare/README.md`、`cloudflare/DEPLOYMENT_NOTES.md`、`docs/team-isolation.md`、`docs/cloud-sync-implementation-summary.md`、`docs/operations.md` |
