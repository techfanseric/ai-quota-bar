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

- `POST /v1/usage/devices`：独立管理员鉴权，注册或轮换设备，返回一次性可见的设备 token。
- `POST /v1/usage/devices/revoke`：独立管理员鉴权，撤销设备。
- `GET /v1/usage/identity`：设备鉴权，返回绑定身份和价格表。
- `POST /v1/usage/events/batch`：设备鉴权，最多 50 条，返回 accepted/rejected。客户端收到完整匹配回执后才确认本地发送状态。
- `GET /v1/usage/summary?from=...&to=...&group_by=member|device|model`：设备鉴权，只查所属团队；可带 member_id。范围为包含起点、不含终点，最长 366 天；客户端按本地日历转成 UTC 边界，因此正确覆盖夏令时。

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

新版 App 的默认额度同步、设备列表、资源用量和更新检查切换到新入口。本机成员上报针对两个旧官方入口，会先在新服务验证同一团队/成员/设备身份，才迁移本地绑定与凭据；上报起点、已发送状态、待传队列保持不变。自定义第三方入口不自动改写。

旧 Cloudflare 资源在全量快照导入、逐表行内容哈希一致和新 App 实际上报通过后清理。旧版 App/其他设备需要更新到迁移后的版本；不会在旧账号长期保留消耗请求额度的代理。
