# Codex 本机用量与成员上报

## 功能入口

- 菜单顶部显示本机今日 token、有效用量记录数、缓存命中率和已定价部分的估算成本。
- 设置 → 用量 → Codex 本机用量：今天 / 7 天 / 30 天、输入输出、缓存读写、模型分布、解析诊断、价格覆盖率。
- 同一页“成员归属与上报”用于绑定设备和选择是否上报；“团队成员用量”按所选时间范围加载成员统计，可展开设备。
- 本地统计自动运行，每 60 秒补扫，不依赖账号额度刷新、OAuth 或 Codex App 是否开启。读取 `CODEX_HOME`，否则读取 `~/.codex`，覆盖 `sessions` 和 `archived_sessions`。

源日志只读。SQLite 数据保存在 `~/Library/Application Support/AIQuotaBar/local-usage.sqlite`，包括统计事件、解析缓存和持久化待上传状态，不保存对话正文。首次导入大型历史可能需要数分钟；后续扫描只重读变化文件，重启复用解析缓存。

## 统计口径

输入已含缓存读取，输出已含推理 token，不能再次相加。总量为输入 + 输出；缓存率为汇总缓存读取 / 汇总输入，输入为零显示“—”。缓存写入单独保留并参与输入校验。异常计数不自动裁剪成看似正常的数据。

先排除重复 total/last 快照，再优先使用 last_token_usage；缺失时使用累计差值并标为估计记录。累计值回退且缺少 last 时跳过不确定部分并记录异常。续页、归档复制、重复刷新、分叉继承均有专门去重。缺失父会话的分叉暂缓计入；界面会展示待解析数量。这里的记录数不是完整 HTTP 请求数，不显示无法从日志证明的成功率。

本机可见日志不等于对执行设备的密码学证明。复制他人日志可能形成错误归属，因此团队同一事件跨设备上传只计一次，跨成员冲突会隔离。事件的模型、时间或 token 内容发生冲突时不会覆盖云端已入账内容；拒绝原因保存在本地，需管理员核验。当前版本不提供账本修订接口。

## 成本配置

成本是 API 等价估算，不是订阅扣款。未知价格显示“未定价”，不回退到相近型号、不按零成本处理。未配置价格时，本地和团队 token 统计仍可用。

可在界面导入价格 JSON；服务器通过 `USAGE_MODEL_PRICES` 配置相同 JSON（最多 20 个互不重叠的模型价格区间）。连接或同步时以团队价格表覆盖本地价格，从而保持团队口径一致。管理员应填写已确认的价格、来源和生效日期。以下是格式示例，**数值仅用于说明，不能作为真实模型报价**：

```json
[
  {
    "model": "your-exact-model-id",
    "version": "approved-rate-v1",
    "source": "https://your-approved-price-source.example",
    "effectiveFrom": "2026-01-01T00:00:00Z",
    "effectiveTo": null,
    "input": 2,
    "cached": 0.2,
    "cacheWrite": null,
    "output": 10
  }
]
```

单位为 USD / 百万 token。cacheWrite 为 null 时，含缓存写入的记录保持未定价，避免猜测费率。按模型精确匹配。历史价格按事件时间选择；服务端查询时重新计价，补录价格后历史立即生效。客户端 Decimal 计算，服务端按价格区间聚合后四舍五入到微美元，展示时可能有微小舍入差异。

## 自助团队（/team）

在 App「设置 → 用量与团队」直接创建或加入团队；也可从 `https://ai-quota-bar.pages.dev/team` 创建。新建团队的管理密码自动保存在本机钥匙串，请另外备份；服务端只存哈希。

1. 创建时填写团队名称、自己的名字和成员口令，把邀请码分享给队友，不分享管理密码。
2. 成员用邀请码、自己的名字和成员口令加入。设置自动加载 7 / 30 / 90 天团队用量，按成员展开设备，显示账号汇总。
3. 所有成员点击「查看团队」即可打开只读团队面板，查看本团队全部成员、设备、用量和额度账号。服务端拒绝成员的删除、撤销和邀请管理请求。
4. 管理者点击「管理团队」直接进入管理页。旧版本未保存管理凭据，需要首次补录一次管理密码，验证后写入钥匙串。
5. 已加入的设备可以「创建或加入其他团队」，成功后切换，原团队历史与已归属用量保留在原团队。

直达使用有效期 120 秒的一次性票据：设备凭据只进入 HTTPS Authorization，管理密码只进入 HTTPS 请求体；URL 仅含短时票据，页面兑换前立即删除 fragment。兑换后使用 Secure / HttpOnly / SameSite=Strict Cookie，有效期 8 小时。成员会话每次请求重新检查设备授权，退出、撤销或设备 token 轮换立即失效。管理权限仍需验证当前团队的管理密码。多标签页切换团队时，旧页面携带的团队 ID 与当前 Cookie 不匹配则拒绝请求。跨团队数据只在独立认证的 `/admin` 中展示。

同名规则：一名成员的多台 Mac 使用同一名字。第二台 Mac 加入已存在的名字必须提供该成员的成员口令——首次加入后可在设置里设置（4–64 字符，服务端存哈希），防止队友冒用他人名字归属用量。没有口令的同名加入返回 `name_taken`；口令错误返回 401。已绑定设备换绑到其他成员同样需要对方口令（等价于管理员 `--reassign`）。同一设备重复加入同名是普通凭据轮换。

护栏：每 IP 每小时最多创建 3 个团队；加入按 IP（20 次/15 分钟）和邀请码（30 次/15 分钟）限速，成功后清零；登录按团队+IP 限速（10 次/15 分钟）；每队上限 20 名成员。会话 Cookie `__Host-aqb_team` 由该团队的登录哈希签名，8 小时有效。账本仍不自动清理（见上文不变量），废弃团队的数据会保留。

私有部署默认关闭自助团队。按顺序执行：应用 `migrations/0005_team_selfservice.sql`，部署 Worker，再在 `[vars]` 加入 `USAGE_TEAMS_ENABLED = "true"` 并重新部署；未开启时 create/login/join 返回 503 `teams_not_configured`。

## 部署团队接口

新接口与原有额度快照接口隔离，不会因原有云同步已启用而自动上传个人用量。先按照 cloudflare/README.md 配置目标 Worker 和 D1。随后在仓库的 cloudflare 目录执行：

```sh
npm ci
npx wrangler d1 execute ai-quota-bar --remote --file=migrations/0002_local_usage.sql
npx wrangler secret put USAGE_ADMIN_TOKEN
npx wrangler deploy
```

`USAGE_ADMIN_TOKEN` 必须至少 32 字符且与旧 `SYNC_TOKEN` 不同；它仅用于管理员注册、轮换和撤销设备，不放入客户端。`USAGE_MODEL_PRICES` 可作为 Worker JSON 字符串配置，缺省为 `[]`。本地验证通过不代表以上生产部署已执行。

复制客户端展示的设备 ID，用管理员凭据签发绑定成员的设备凭据：

```sh
# 在仓库根目录运行；USAGE_ADMIN_TOKEN 由终端环境注入。
node scripts/provision-usage-device.mjs \
  https://your-worker.example team-id member-id '成员姓名' device-id
```

脚本仅在成功时输出新设备凭据，应交给对应成员保存在客户端 Keychain。一个成员的多台电脑使用同一 member-id、不同 device-id。服务器只存凭据哈希。重复注册相同成员与设备会轮换凭据，旧凭据立即失效。

把地址与设备凭据填入设置，点击“验证并绑定设备”，核对成员后启用“成员用量上报”。默认只归属绑定后产生的用量；主动勾选历史选项才会归属尚未分配的本机历史。旧记录不会从其他成员名下自动转移。大量历史会分批补传，待传数量可见，实际吞吐也受 D1 配额约束。

需要轮换使用同一电脑的成员时，管理员在签发命令后追加 `--reassign`。先确保原成员待传队列已清空；旧身份待传记录不会被新成员凭据发送，恢复旧成员绑定后才能继续发送。历史事件仍归原成员，新绑定默认从当前时间开始。客户端切换成员或服务器后会关闭上报，待核对后再启用。

撤销设备：管理员调用 `POST /v1/usage/devices/revoke`，body 为 `{"teamID":"...","deviceID":"..."}`。401 会暂停自动重试，需重新绑定；网络失败指数退避至最长一小时。关闭上报会取消进行中的客户端任务，已经被服务端接收的事件保留。单条拒绝不阻塞其他事件，拒绝记录和原因持久保存。

## 协议

- `POST /v1/team/create`：`{teamName}`，公开但限速；一次性返回 teamID、inviteCode、loginPassword。需要 `USAGE_TEAMS_ENABLED`。
- `POST /v1/team/handoff`：设备 Bearer 鉴权，`{}` 创建成员票据；`{managementPassword}` 验证同团队管理密码后创建管理员票据。
- `POST /v1/team/redeem`：浏览器同源 POST `{ticket}`，原子消费票据并设置会话 Cookie。
- `POST /v1/team/login` / `POST /v1/team/logout`：团队 ID + 管理密码换取签名 Cookie 会话（8 小时）。
- `GET /v1/team/overview?days=7|30|90`：成员或管理会话鉴权，返回权限标识、成员/设备/账号结构与按成员、设备、账号的用量聚合（UTC 日期）。
- `POST /v1/team/invite/rotate`、`POST /v1/team/devices/revoke`：仅管理员会话鉴权。
- `POST /v1/usage/join`：`{inviteCode, memberName, deviceID, memberPassphrase?}`，邀请码即凭证；返回一次性设备 token，响应形状与 `/v1/usage/devices` 相同。
- `POST /v1/usage/member/passphrase`：设备鉴权，设置或更换本成员口令（4–64 字符）。
- `POST /v1/usage/devices`：独立管理员鉴权，注册或轮换设备，返回一次性可见的设备 token。
- `POST /v1/usage/devices/revoke`：独立管理员鉴权，撤销设备。
- `GET /v1/usage/identity`：设备鉴权，返回绑定身份和价格表。
- `POST /v1/usage/events/batch`：设备鉴权，最多 50 条，返回 accepted/rejected。客户端收到完整匹配回执后才确认本地发送状态。
- `GET /v1/usage/summary?from=...&to=...&group_by=member|device|model|account`：设备鉴权，只查所属团队；可带 member_id。范围为包含起点、不含终点，最长 366 天；客户端按本地日历转成 UTC 边界，因此正确覆盖夏令时。

事件没有客户端可指定的可信成员身份；服务器以凭据绑定身份为准。幂等键为团队 + 不透明事件 ID，跨设备复制也不重复计入。事件 ID 由会话、时间、计数快照和同时间的有效事件序号摘要生成。不会上传原始会话 ID、路径、提示词或 OpenAI 凭据。

不自动清理新用量账本，避免删除去重键后旧设备重传导致再次入账。当前查询使用团队/时间索引进行聚合，不建立需要维护一致性的二级日汇总表。

## 构建和验证

此次构建的同级 CodexBar 基线为 `b6e65a83dc471817b7ff7678e68e0204c9dd604f`；新版依赖要求 Swift 6.2+。锁文件更新为与该依赖匹配的版本。原有 Codex mapper 测试去掉了已不支持的三个可选 nil 参数，不改变被测行为。

```sh
swift test
make build
cd cloudflare
npm test
cd ..
node --experimental-sqlite cloudflare/tests/local-usage-http.mjs
```

HTTP 测试使用回环地址、内存 SQLite 和合成凭据，运行真实 Swift URLSession 到 Worker 路由；不接触生产云服务。

只读检查本机来源并验证复扫 / 重启持久化：

```sh
swift run -c release CodexUsageAudit "$HOME/.codex" /path/to/scratch/audit.sqlite
```

只输出统计和诊断，源文件不变、不上传；数据库必须指向独立验证目录。测试覆盖重复快照、相同大小的不同真实请求、累计回退、模型切换、分叉和嵌套分叉、续页、归档、半行、持久化补传、身份不重写、价格区间、加权缓存率、跨团队隔离、凭据轮换撤销、事务失败及真实 HTTP 幂等。

## 历史趋势与服务访问（2026-09-18）

左键菜单将本机用量放在同一个 Codex 分组内，与账号额度历史一起查看。默认展示最近 7 天，支持今天（小时）、7 天和 30 天（每天），并可切换 Tokens、有效用量记录、缓存命中率、估算成本；悬停显示对应历史时段的值。设置页同步提供趋势图。日期以本地时区划分，当前时段尚未结束。缓存命中率按 token 加权；缺失价格的时段留空，避免误认为零成本。

生产服务新增直连入口 `https://quota.talktrace.app`，保留原 `https://ai-quota-bar-sync.techfanseric.workers.dev`。两者连接同一个 Worker 和 D1。首页提供服务说明，`GET /healthz` 提供公开的存活检查（不查询 D1）；业务 API 仍要求认证。首页不是团队统计网页，团队统计入口在 App 设置 → 用量。部分网络无法直连 workers.dev，此时可使用自定义域名。

已有设备连接的地址也是本地上报账本绑定标识的一部分，不应直接改写偏好设置来切换域名；先完成旧连接待传数据，再在 App 中验证绑定新地址。原地址继续工作时无需迁移。

## 账号维度与跨账号云端迁移（2026-09-18）

- 左键菜单 Codex 优先，其余供应商维持原顺序；本机趋势使用现有绿色/灰色样式。
- 左键菜单没有账号选择器，只显示当前 Codex 登录账号在本机的用量和趋势，打开菜单及定时扫描时更新账号；未识别账号时提示不可用，不混入历史未知记录。设置面板可选全部账号、账号未知或已观测账号，设置筛选独立于菜单。明确出现在用量事件/turn_context 的账号标记来源为 `log`；相邻采样（最多 90 秒）登录账号与 auth.json 文件代次一致的区间标为 `login-observation`。后者只是本机登录推断，不能证明每个实际请求使用的账号，尤其是多个客户端并行登录时。
- 首次观察前、切换边界、休眠/重启缺口、API Key 模式和无依据历史均保持未知。旧事件一旦入账不重写归属；现在登录的账号不会接管过去的全部记录。服务端接收账号的 SHA-256 标识和来源，不接收 OAuth token 或账号邮箱。邮箱仅供本地显示。
- 服务端支持 `group_by=account`，未知组 ID 为 `unknown`。新迁移 `0003_usage_accounts.sql` 只运行一次；旧设备未传账号字段的事件继续兼容。

新生产入口：`https://ai-quota-bar.pages.dev`。计算和数据库位于 **node.cyberic@gmail.com**（Account ID `d9b4ce8306afc5594afc55786c3a76e4`）：Pages Functions `ai-quota-bar`，D1 `ai-quota-bar` / `0d70b7e7-2397-4d89-a925-5c335257dd58`。

部署：在 cloudflare 目录将 `wrangler.pages.toml` 复制为 `wrangler.toml`，使用对应账号的 `CLOUDFLARE_API_TOKEN` 与 `CLOUDFLARE_ACCOUNT_ID` 环境变量，再执行 `npm ci && npm run deploy:pages`。Pages 不支持任意命名的配置文件路径，也不支持配置里的 account_id 字段；账号通过环境变量指定。运行时需要 SYNC_TOKEN、USAGE_ADMIN_TOKEN、CF_API_TOKEN 三个服务端 secret；不得写入版本库。

官网（产品首页、`/changelog`、`/feedback`、`/team`、`/admin`）与 API 同属这个 Pages 项目。部署凭证在本机 `~/cf-fb-setup`（node.cyberic@gmail.com 账号）：API Token 在 `secrets/cloudflare-api-tokens.md`，账号实况与历次部署记录在 `accounts/node-cyberic.md`；命令详见 `cloudflare/README.md` 的 Website 小节。发布新版本后的官网同步：`npm run sync:releases`（从 GitHub 拉取已发布 release 生成 `content/releases.json`）→ `npm run build:pages` → `npm run deploy:pages`；更新检查接口 `/v1/app-update` 随最新 GitHub Release 自动生效。运营后台管理员密码见 `docs/operations.md`。

新版 App 的默认额度同步、设备列表、资源用量和更新检查切换到新入口。本机成员上报针对两个旧官方入口，会先在新服务验证同一团队/成员/设备身份，才迁移本地绑定与凭据；上报起点、已发送状态、待传队列保持不变。自定义第三方入口不自动改写。

旧 Cloudflare 资源在全量快照导入、逐表行内容哈希一致和新 App 实际上报通过后清理。旧版 App/其他设备需要更新到迁移后的版本；不会在旧账号长期保留消耗请求额度的代理。

## v1.20 部署补充

先执行 `cloudflare/migrations/0008_team_handoff.sql`，再部署 Pages。新表仅保存票据哈希和绑定信息；过期票据在签发时清理。此迁移新增表和索引，不修改团队用量历史。原有管理密码登录继续可用。

## 团队图表

设置与网页均提供成员用量对比，以及月历、最近 24 小时 / 指定日期的 288 个五分钟桶。团队图表统一采用 UTC，可组合成员、设备、账号筛选；比较范围与月历范围分别明确标识。缓存命中按输入 token 加权，成本按记录对应的价格区间计算，未完整定价时明确标识，避免与零成本混淆。

`GET /v1/usage/timeline` 使用设备凭据，`GET /v1/team/timeline` 使用成员或管理员会话。参数：`from`、`to`、`bucket_seconds=300|86400`，以及可选的 `member_id`、`device_id`、`account_id`（哈希或 `unknown`）。五分钟查询最多 24 小时，日桶最多 366 天；服务端从鉴权身份确定团队，忽略客户端伪造的团队范围。返回的是价格分段后合并的桶聚合，不是原始事件。
