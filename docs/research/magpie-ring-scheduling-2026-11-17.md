# Magpie 圆环调度调研 · 2026-11-17

调研目标：让 Codex 的菜单栏圆环"更智能"——不再是一个静态聚合值，而是
跟随**真正在用的那个账号**。前半部分记录调研事实与当时方案，文末
「最终实现」记录已落地行为；中间的候选方案不是最终产品说明。

调研对象：

- 本仓库 `AIQuotaBar`（`76872df`）
- 本机 Magpie 源码 `/Users/ericyim/magpie`（`c1144a8`，即上游贡献分支）
- 本机运行中的 Magpie 网关（loopback `:3425`，PID 992）

## 结论先行

1. **圆环现在显示什么**：Codex 环默认走 `CodexMagpieRingScope.currentAccount`，
   即 `MagpieCodexQuotaService` 合成的 `Codex Current` 行 —— 取 Magpie 报告里
   `last == true` 的那张卡，没有则取 `lastServedAt` 最新的一张，再没有则取
   第一张。这是"上次回答过请求的账号"，**不是"此刻正在用的账号"**。
2. **Magpie 自己怎么判断"在用"**：`provider/served.go` 的 `NoteServed` 在
   **每次请求真正被某个账号回答时**记录 `provider@user` 的时间戳，
   落盘到 `served.json`；`withServed` 把最新者标 `Last: true`。
   也就是说 Magpie 的"在用"= **最近一次实际服务的账号**，粒度是账号，
   语义是"服务过"，不是"正在服务"。
3. **正在服务的账号有更强的证据**：`/v1/magpie/concurrency` 的 `data` 字段
   就是**每个账号/Key 的 in-flight 车道**（`codex@user` → `{busy, waiting}`）。
   本机实测：

   ```
   "codex@1104524667@qq.com": {"busy":1,"waiting":0,"limit":0}
   "codex@node.cyberic@gmail.com": {"busy":1,"waiting":0,"limit":0}
   ```

   这是 AI Quota Bar 目前**完全丢弃**的数据 —— `MagpieModelActivityDetector`
   只解码了 `active` 数组和 `trace`，把 `data` 整个扔掉了。
4. **调度逻辑（Smart）**：`internal/routes/strategies.go` 的 `Smart` 是默认
   策略：先按 tier 分组（还有余量 / 偏低 / 快用完），组内**谁的窗口最先
   重置谁先上**（重置早 = 那点额度即将白白浪费），重置时间到小时粒度比较；
   同小时则比较 credits 过期时间，再比余额；完全一样时**保持原顺序**，
   以保住厂商的 prompt cache。
5. **亲和（affinity）**：`internal/gateway/affinity.go` 让一个会话尽量留在
   回答过它的账号上（ChatGPT 缓存冷却是 1 小时），跨轮次看缓存价值，
   轮内总是保持。所以"一个会话用哪个账号"和"这个时刻哪个账号有在途请求"
   是**两个不同的口径**。

## 已核实的事实（附证据）

### A. 当前 Codex 环的数据来源

`AIQuotaBar/Services/Codex/MagpieCodexQuotaService.swift`

- `fetchUsage()` 读 `GET /v1/magpie/quotas`，**不**带 `kept=1`（避免 Magpie
  直接返回 1 分钟缓存而不刷新）。
- `usageData(from:)` 过滤出 `provider == "codex"` 的本地卡，合成两行：
  - `Codex Pool`（第 0 行）：各账号"最紧窗口"的平均值；`currentCard` 选出的
    当前账号另算一行 `Codex Current`（第 1 行）。
- `currentCard(from:)` 判定顺序：
  1. `last == true` 的卡
  2. `lastServedAt` 最新的卡
  3. 都没有 → 第一张卡

`AIQuotaBar/ViewModels/UsageViewModel.swift`

- `codexMagpieRingScope` 默认 `.currentAccount`（`UsageViewModel.swift:1401`）。
- `pickPrimary(from:)`（`:842`）：`.allAccounts` 时用 Pool；否则优先
  `isCodexCurrentAccountQuota`（`Codex Current`）；再退到 5h 窗口模型。
- `menuBarRingPercent(for:models:)`（`:961`）：Pool / Current 行直接用自身
  百分比，不按周窗口换算。

→ **现状的三个问题**：

| 问题 | 原因 |
| --- | --- |
| 环显示的账号未必是"在用"的 | `last`/`lastServedAt` 是"最后服务过"，可能是几小时前 |
| 环内扇形/趋势为空 | `Codex Current` 行没有 `startTime`/`endTime`，`paceDelta` 算不出 |
| 悬停看不出"现在谁在服务" | tooltip 只有 `Magpie · N/M accounts` + 各账号窗口，没有在途归属 |

### B. Magpie 的"在用"语义

`magpie/internal/provider/served.go`

- `NoteServed(p, at)`：由 `internal/gateway/routing.go:89`
  `provider.NoteServed(c.p, time.Now())` 调用，位置在 `servedCandidate` ——
  即**某账号真正回答完一次请求**时。
- 键为 `ServedID(p)`：账号是 `loginProvider(agent) + "@" + lower(user)`，
  Key 是 `provider#keyid`。
- 落盘 `served.json`（与 providers 同目录），保留 30 天，2 秒防抖写。
- `withServed(qs, served)` 给每张卡打 `lastServedAt`，并把**最新者**标
  `Last: true`。时间相同则**多张都标**（注释：key 的 plan 与 balance 持平时）。

`magpie/internal/gui/trayusage_tray.go:41`

- `provider.OnServedMoved(onTrayUsage)`：**另一个账号回答时立刻推一次刷新**，
  不等定时器。`OnServedMoved` 在 `servedAt.by[of] != id` 时触发（即服务商
  维度上"回答者换人了"）。

→ Magpie 的托盘因此是**跟随正在被使用的账号**的，但更新粒度是"换了人才
立刻刷"，平时按 `trayUsageEvery()`（分钟级）轮询。

### C. 真正"正在服务"的证据

`magpie/internal/gateway/concurrency.go`

- `Lane{Busy, Waiting, Limit}`，键为 `provider@account` / `provider#keyid`。
- `s.concurrency` 同时返回 `data`（车道）、`active`（每个在途请求）、
  `requests`/`waiting`/`tools` 汇总。
- `Busy` = 该账号此刻**在厂商侧正在处理**的请求数。

本机实测（读 `GET /v1/magpie/concurrency`）：

```json
{
  "active": [
    {"id":5591,"agent":"codex","model":"codex/gpt-6.1-sol","provider":"codex",
     "session":"01a1e815-…","phase":"upstream","route":1794881621153},
    {"id":5601,"agent":"codex","model":"codex/gpt-6-astra","provider":"codex",
     "session":"01a1e815-…","phase":"upstream","route":1794881621163}
  ],
  "data": {
    "codex@1104524667@qq.com": {"busy":1,"waiting":0,"limit":0},
    "codex@node.cyberic@gmail.com": {"busy":1,"waiting":0,"limit":0}
  }
}
```

注意：`active[].provider` 是 **provider 级**（`codex`），**不带账号**；
账号归属只能从 `trace` 的 `route.order[].who` / `route.tries[].id` 推。
本机实测 `trace` 的 seat 结构：

```
SEAT id= codex                          who= node.cyberic@gmail.com     kind=account
SEAT id= codex@1104524667@qq.com        who= 1104524667@qq.com         kind=account
SEAT id= codex@marvaggarrett@gmail.com  who= marvaggarrett@gmail.com   kind=account
SEAT id= codex@wangyang815@gmail.com    who= wangyang815@gmail.com     kind=account
TRY  id= codex  model= gpt-6.1-terra  done=false
```

`try.id` 是**服务商的 rest id**，不能单独拿来判断账号；但对应 seat 的
`who` + `kind == "account"` 可以。实测已直接观察到
`try.id == "codex"` 的 seat 仍然带有完整邮箱。
`magpie/internal/gateway/fallback.go:379` `accountCandidate`：

```go
rest := p.ID
if !a.Own { rest += "@" + a.Account.User }
```

`Own` 为真表示"Codex 当前登录着的那个账号"（`provider/route_accounts.go:30`
 `AccountsOn()`），它**共用** `codex` 这个 rest id，与其它账号的
 `codex@user` **区分不开**。这正是 `affinity.last` 里出现
`"last": "codex"`（不带 `@`）与 `"last": "codex@1104524667@qq.com"` 两种值
的原因 —— 实测 trace 里两种都有。

→ **更正：不要把 rest id 的歧义误当成 seat 身份的歧义。** `try.id == codex`
 时，匹配的 seat 仍能报告 `who=node.cyberic@gmail.com, kind=account`，
 因此**在途请求可以直接归属到账号**。resolver 同时使用这条身份和
 `concurrency.data` 的车道计数，取两者的账号 busy 最大值而不是相加。
 裸车道键 `codex` 仍不猜账号；没有 seat 身份、又没有账号车道时才报
 `.ambiguous`。

### D. 调度（Smart）策略

`magpie/internal/routes/strategies.go:114` `Smart`：

1. `seatTier` 分三档：`2` = 快用完（all but used up）、`1` = 偏低、
   `0` = 还有余量。
2. `fine` 组内排序（关键）：
   - 谁的**最大窗口最先重置**谁先上 —— 快重置的额度不花就白花。
     比较到**小时**粒度（"to the hour, so a few minutes don't reorder"）。
   - `Unreached`：大窗口的剩余量在下次重置前根本用不完，则跳过它，
     让下一个决定。
   - 同小时 → 比 `Lapse`（credits 最先过期）→ 比余额 → **保持原顺序**
     （保住厂商 prompt cache）。
3. `low` 组按 `Used` 升序；`spent` 组按 `spentBefore`。
4. `leadFirst`：`UseFirst` 的供应商排在前面。

`magpie/internal/gateway/affinity.go`：

- `affine(scope, mode, ...)`：一个会话优先留在回答过它的成员上。
- ChatGPT/Codex 账号的缓存冷却是 **1 小时**（`chatGPTCold`），实测注释里
  记录了 7/12/25/45/60 分钟的缓存命中。
- `Why` 取值：`session` / `turn` / `cache` / `off` / `first` / `resting` /
  `spent` / `busy` / `main` / `order` / `back` / `hours` 等。
- 实测 trace：`{"mode":"","last":"codex","why":"turn","kept":true,"turn":20,"within":true}`
  与 `{"last":"codex@1104524667@qq.com","why":"lead"}`。

→ **结论：Magpie 有四层"谁在用"的信号，实时请求与车道回答"此刻"**：

| 层 | 数据源 | 含义 | 精度 |
| --- | --- | --- | --- |
| 1 | `quotas[].last` / `lastServedAt` | 最后**服务过**的账号 | 账号级，滞后 |
| 2 | `trace[].affinity.last` | 会话上次**停留**的账号 | 会话级 |
| 3 | `concurrency.data[who].busy` | 该账号**此刻在途**的请求数 | 账号级，实时 |
| 4 | `trace` 当前 try 对应 seat 的 `who/kind` | 该请求**此刻由哪个账号服务** | 请求级，实时 |

### E. AI Quota Bar 现有的活动归属

`AIQuotaBar/Services/Codex/MagpieModelActivityDetector.swift`

- `Concurrency` 只解码 `object` 和 `active`（`id/agent/phase/route/session`）。
  **`data` 车道字段未解码。**
- `Trace.Route.Seat` 只解码 `id/provider/model`，**丢掉了 `who` 和 `kind`** ——
  而 `who` 正是账号身份。
- `requests(active:routes:)` 用
  `route.order.first(where: {$0.id == attempt.id && $0.model == model})`
  找座位，然后 `ModelActivityAttribution.provider(model:provider:)` 归到
  **模型族**（Codex / Kimi / GLM / MiniMax），不是账号。

`AIQuotaBar/Services/ModelActivityAttribution.swift`

- 活动按**模型族**归环，这是用户明确要求过的（"虽然使用 Codex 客户端，
  仍按模型归到现有四个环"）。
- `ProviderModelActivity.codex(turns:gateway:)` 去重：配置明确经过 Magpie
  的本地任务、以及 session ID 匹配网关请求的任务，不再按本地任务重复加入。

→ **这不冲突**：模型族归属回答"环属于谁"，账号归属回答"这个账号在不在用"。
两者是正交的信息通道。

## 方案

### 目标

让 Codex 环**在正确的时刻显示正确的账号**，并把"为什么是这个账号"
变得可见；同时不破坏已有的模型族流光语义。

### 设计原则

1. **实时性优先，稳定性次之。** 环是 22pt 的小部件，每秒跳动一次会让人
   无法阅读。所以**数值只在"归属改变"时更新**，流光继续走 12fps 动画，
   二者分离。
2. **不猜测。** 无法唯一归属时（trace 的 `Own` 账号 rest id 不可分），
   显示"多账号在用"，而不是随便挑一个。
3. **失败不等于空闲。** 读不到网关时显示"不可用"，不清零、不冒充。
4. **零新增凭据边界。** 只读本机 loopback 的既有端点，不碰 Magpie 的
   账号库、token、cookie；不新增任何上传通道。

### 分层信号与调度

引入一个 **Codex 账号归属解析器**（新文件，建议
`AIQuotaBar/Services/Codex/MagpieAccountActivityResolver.swift`），
输入已有的 `MagpieModelActivitySnapshot` + `MagpieCodexQuotaService` 的卡片，
输出：

```swift
struct CodexAccountUsage {
    enum State {
        case idle                        // 无在途请求
        case active(accounts: [String])  // 明确在服务的账号（按 busy 车道）
        case ambiguous                   // 有在途请求但账号不可唯一归属
        case unavailable                 // 网关读失败
    }
    var state: State
    var busyAccounts: [String: Int]  // accountKey → busy 计数
    var requestedAccounts: [String] // affinity.last 提到的账号（次级信号）
}
```

**判定顺序（严格按可信度降级）**：

1. 网关不可达 / 读失败 → `.unavailable`（显示"活动不可用"，不清零）
2. `concurrency.data` 有 `busy > 0` → `.active(那些 busy 的账号)`
   —— 账号级、实时、来自网关自己的 lane 记账
3. 有 active 请求但 busy 车道里没有 `codex@user` → `.ambiguous`
   （`Own` 账号共享 rest id，归属不可分；此时用 trace 的 `order[].who`
   给出"候选账号"但标注不可确定）
4. 无 active 请求 → `.idle`

**次级信号**（只影响 tooltip 文案，不影响环的数值归属）：

- `trace[].affinity.last`：会话上次停留的账号。
- `quotas[].last` / `lastServedAt`：最后服务过的账号。

### 环显示什么

**这是本方案的核心决策点**，我推荐 **A**：

#### 方案 A（推荐）：环内数字 = 在用账号的额度；无在用时回落到"最后服务过"

- 有一个账号在服务（`.active` 且能唯一归属）→ Codex 环显示**那个账号**的
  窗口百分比与重置时间。
- 多个账号同时在服务 → 显示**其中额度最紧的那个**（最需要被看见的），
  tooltip 里列出全部在用账号。
- 没有在途请求（`.idle`）→ 保持现在的行为：`Codex Current`（最后服务过的
  账号）。**行为不变**，所以现有用户不会看到任何回退。
- `.ambiguous` / `.unavailable` → 环保持最后一次可信的数值，但 tooltip
  明确标注"账号归属不可确定 / 活动不可用"。

理由：

- 用户关心的正是"在用的那个"。`busy` 车道是唯一账号级实时信号。
- 回落路径与现状一致，`lastServedAt` 兜底，所以**任何时候都有数字可读**，
  不会出现空环。
- 额度百分比来自账号卡，**不需要**额外的模型族语义改动。

#### 方案 B：新增一个"Codex 账号"子环

在四个模型族环之外，为每个在用的 Codex 账号各画一个小环。

- 优点：一眼看到多个账号各自的额度。
- 缺点：菜单栏宽度失控（每账号 +19pt）；账号数是动态的，环的位置会跳；
  与"四个模型族环"的设计前提冲突。**不推荐**，除非做成 hover 展开。

#### 方案 C：只做 tooltip，不改数值

环不变，hover 里加"现在在用：xxx"。

- 优点：零风险。
- 缺点：没解决"环显示的账号不是在用的那个"这个核心问题。
  可作为方案 A 的**第一阶段**。

### 实现要点

1. **解码 `concurrency.data`**：在 `MagpieModelActivityDetector.Concurrency`
   里加 `let data: [String: Lane]`，`Lane{Busy, Waiting, Limit}`。
   注意 `object == "concurrency"` 的既有校验不变。

2. **解码 `trace` 的 `who`/`kind`**：在 `Trace.Route.Seat` 里加
   `who: String?`、`kind: String?`。这让 `order` 里的座位带上账号身份。
   **隐私边界**：只保留账号标识用于归属，**不进 tooltip**（tooltip 用
   现有的 `MenuAccountPrivacy` 脱敏路径）。

3. **归属解析**：新增 resolver，把 `data` 的 busy 车道与 trace 的 seat
   `who` 关联。注意 `codex`（Own 账号）与 `codex@user` 是两个不同的键。

4. **环数值来源**：给 `MenuBarSnapshot` 增加一个可选的
   `codexInUseAccountKey: String?`，由 `UsageViewModel` 在构造
   `MenuBarSnapshot` 时用它挑选 Codex 的那一行。
   现在的实现是 `pickPrimary(from:)` 里 `isCodexCurrentAccountQuota` 优先，
   改成：**在用账号 > Current 账号 > 第一张卡**。

5. **稳定性**：归属只在**变化时**触发一次状态更新（`@Observable` 的
   `menuBarSnapshots` 重建），流光动画不受影响。轮询周期沿用现有的
   2 秒（`CodexSleepProtectionCoordinator.swift:1068`）。

6. **降级路径**：
   - Magpie 未配置 / 未运行 → 完全走现有逻辑（`CodexService` 已经会
     fallback 到本机 `~/.codex` 读取器）。
   - 网关可读但 `data` 为空 → 视为 idle，回落到 Current 账号。
   - 读失败 → `.unavailable`，tooltip 提示，**不改变**环的数值。

### 需要新增的测试

| 测试 | 覆盖 |
| --- | --- |
| `MagpieCodexAccountResolverTests` | busy 车道 → 唯一账号 / 多账号 / 歧义 / 不可用 / 空闲 |
| `MagpieModelActivityDetectorTests` | `data` 与 `who` 的解码；既有 fixture 需补这两个字段 |
| `MenuBarRingRenderingTests` | 在用账号优先于 Current；空闲时行为不变（回归） |
| `UsageViewModel` 相关 | `.allAccounts` 池模式下不受影响 |

### 风险与边界

- **`Own` 账号的不可分性**：Codex 当前登录的那个账号与网关共用 rest id
  `codex`，单个请求无法区分是它还是别人。`concurrency.data` 的 busy 车道
  **能**区分（`codex@user`），这是绕开该限制的关键。
- **两秒轮询的漏窗**：两次采样之间完整结束的短请求会被漏掉。这是
  **并发快照**，不是请求账本 —— 与现有文档口径一致。
- **窗口**：Magpie 的 `/v1/magpie/quotas` 有 12 秒的厂商读取超时；
  AI Quota Bar 现有超时是 15/20 秒（`MagpieCodexQuotaService`）。
  新逻辑**不应**在动画帧里发起网络请求。
- **Windows**：本次只做 macOS，Windows 未移植。
- **Magpie 上游**：需要的 `data` / `who` 两个字段**上游已经提供**，
  不需要改 Magpie。

## 修订：多账号同时显示（2026-11-17 追加）

用户要求：**多个账号同时在用时，同时显示多个 C 的环**；左键菜单打开时
**展开对应的多个 ChatGPT 账号**。

这把方案从"选一个"改成"按账号展开"。可行性核查结论：

### 可行 ✅ —— Magpie 自己就是这么做的

`magpie/internal/gui/trayusage.go:40`：

```go
func trayCardID(q provider.SubscriptionQuota) string {
    if q.User == "" { return q.Provider }
    return q.Provider + "|" + q.User
}
```

Magpie 的托盘**每个账号一张卡/一个环**，ID 就是 `provider|user`。
`trayRingCells`（`trayrings.go`）按 `cards` 逐个转成环，**没有**"一个
provider 只能一个环"的限制。所以这个形态有可运行的上游参照。

### AI Quota Bar 侧的结构可行性

| 环节 | 现状 | 结论 |
| --- | --- | --- |
| 环容器 | `StatusBarCompactRingsView.setSnapshots` 按数组长度创建/销毁 `StatusBarCompactRingView`，**与 provider 无关** | ✅ 天然支持同 provider 多个环 |
| 宽度 | `preferredWidth` = `padding*2 + count*19 + (count-1)*spacing` | ✅ 自动跟随，但见下方预算 |
| 快照 | `MenuBarSnapshot` 有 `provider` 但**没有账号字段** | ⚠️ 需加一个 `accountKey` |
| 数据源 | `MagpieCodexQuotaService` 已按账号生成多行（`accountName` = 邮箱），每账号有 5h/Weekly 行 | ✅ 数据已到位 |
| 选中逻辑 | `pickPrimary` 每个 provider 只挑一个 primary | ⚠️ 需改为"挑多个" |
| 活动归属 | `ringActivityCounts: [UsageProvider: Int]` 按 provider 计数 | ⚠️ 需加账号维度 |
| tooltip | `StatusBarCompactRingsView` 的 hover tracking area 覆盖**整个条**（`rect: bounds`），`setHovered` 广播给所有环 | ⚠️ tooltip 是**整条一个**，无法逐环区分 |
| 左键菜单 | `groupedVisibleModels` 已按 `accountName` 分组，Magpie 行带 `accountName` 会自动成组 | ✅ 账号分组已存在 |
| 账号折叠 | `accountHeader` 已有 chevron + `toggleAccountCollapsed`，`isAccountCollapsed` 按组控制 | ✅ 展开/折叠机制已存在 |

→ **左键菜单那半几乎是免费的**：Magpie 的每个账号已经是独立的
`AccountModelGroup`，菜单已经按账号分组、已经支持折叠、已经用
`MenuAccountPrivacy` 脱敏。缺的只是"默认展开哪些"这一条策略。

→ **环那半需要改 4 处**：`MenuBarSnapshot` 加账号字段、`pickPrimary`
→ 多选、活动计数加账号维度、tooltip 改为逐环。

### 三个必须解决的真问题

#### 问题 1：tooltip 是整条一个，无法逐环显示

`StatusBarCompactRingsView.updateTrackingAreas()` 的 tracking area 是
`rect: bounds`（整条），`mouseEntered` 把 `isHovered` 广播给**所有**
`ringView`。所以现在 hover 任何位置，tooltip 都一样。

→ 修法：给每个 `StatusBarCompactRingView` 加自己的 tracking area，
让 `setHovered` 只作用于单个环；`StatusBarController.quotaTooltip` 改成
按"当前悬停的环"取对应快照的 tooltip，而不是拼接全部。

⚠️ 这是一个**独立于本次需求**的改动，会影响现有四个环的 hover 行为
（现在悬停整条看到全部 provider 的信息，改后只看到当前环的）。
建议做成**渐进式**：先保留整条 tooltip，另加逐环高亮；或者按设置项切换。

#### 问题 2：菜单栏宽度预算

每个环 19pt + 1pt 间距 = 20pt。本机实测 Magpie 有 **4 个 Codex 账号**：

```
node.cyberic@gmail.com     prolite  剩 71%
1104524667@qq.com          pro      剩 44%   ← last=true
marvaggarrett@gmail.com    prolite  剩 23%
wangyang815@gmail.com      pro      剩 19%
```

若四个 Codex 账号同时在用：**4×20 = 80pt**，加上 Kimi/MiniMax/GLM
三个环各 20pt = **140pt**。这比现在（4 环 ≈ 76pt）多出近一倍。

但注意两个事实：

1. 用户说的是"**多个账号同时在用时**" —— 不是"所有账号都常驻"。
   空闲账号不占宽度，只有 `busy > 0` 的才多出一个环。
2. 本机实测**同时最多 2 个账号在服务**（`busy` 车道）。四个账号同时
   在用是极端情况。

→ 常态 2 个 Codex 环 + 3 个模型族环 = 5 环 ≈ **100pt**，可接受。
→ 极端 4 个 = 140pt，会挤占菜单栏。**需要一个上限**（如最多 3 个账号环，
超出按额度最紧的排序取前 N，其余在 tooltip 里列出）。

#### 问题 3：多个 C 环的字母都一样，如何区分？

现在 `MenuBarSnapshot.providerInitial` 按 provider 返回 `"C"`。多个
Codex 账号环会是 `C C C C` —— **视觉上无法区分**。

Magpie 的做法（`trayrings.go`）是：

```go
// Use the provider's name, not its account alias, for the mark.
if initial := []rune(strings.TrimSpace(q.Name)); len(initial) > 0 {
    c.Letter = strings.ToUpper(string(initial[0]))
}
```

它也用 provider 名（Codex → "C"），靠 **hover tooltip + 位置**区分，
不靠字母。

→ 跟随 Magpie：字母仍是 C，靠 **tooltip（需先解决问题 1）+ 顺序稳定性**
区分。同时给"在用"的那个环加一个可见标记（如实心描边），让用户一眼
看到哪个是当前活跃的。

⚠️ 顺序稳定性很重要：如果环的顺序随 busy 数抖动，用户会无法建立
"第二个环 = 那个账号"的空间记忆。**必须按账号身份固定排序**
（如按 Magpie 账号顺序或按额度百分比），不能用"先到先得"。

### 修订后的方案

**环的构成**：

```
[Codex 模型族环]  ← 保留：模型族总览（Codex/Kimi/GLM/MiniMax 各一）
[Codex 账号环 ×N]  ← 新增：每个 busy>0 的 Codex 账号一个
```

等等 —— 这里有个设计问题需要你定：**Codex 模型族环和 Codex 账号环是否
共存？**

- **选项 1（共存）**：模型族环照旧显示 Codex 的池/当前额度，账号环额外
  挂在旁边。信息最全，但宽度翻倍，且两个 Codex 环的百分比可能不一致
  （一个是池平均值，一个是单账号），容易误读。
- **选项 2（替换，推荐）**：Codex 位置**只显示账号环**（有账号在用就显示
  账号环，没有就退回现在的单个 Codex 环）。宽度可控，语义清晰：
  "Codex 这一栏 = 你正在用的那些账号"。
- **选项 3（账号环嵌套在 tooltip）**：菜单栏不动，只在 hover 里列出账号。
  最保守。

我推荐 **选项 2**：Codex 那一栏的语义从"Codex 模型族"变成"Codex 账号"，
每个环一个账号。空闲时退回单个 Codex 环（显示当前/最后服务账号），
行为与现在完全一致 —— **零回退风险**。

**左键菜单**：

现状已经是按账号分组了。需要补的只有：

1. **默认展开在用的账号**：把 `isAccountCollapsed` 的默认态改成
   "在用（busy>0）的账号默认展开，其余按用户既有偏好折叠"。
2. **在用账号的视觉标记**：账号头加一个"活跃"标记（如小圆点）。
3. Magpie 账号行目前显示的是 `Magpie · Pro · 剩 44% · resets …`，
   已经有 plan/百分比/重置时间，**不需要额外加工**。

### 修订后的实现清单

| # | 改动 | 文件 | 难度 |
| --- | --- | --- | --- |
| 1 | 解码 `concurrency.data` 车道 | `MagpieModelActivityDetector.swift` | 低 |
| 2 | 解码 `trace` seat 的 `who`/`kind` | 同上 | 低 |
| 3 | 新增账号归属解析器 | 新文件 `MagpieAccountActivityResolver.swift` | 中 |
| 4 | `MenuBarSnapshot` 加 `accountKey` | `MenuBarDisplayPreferences.swift` | 低 |
| 5 | Codex 快照从"一个"变"多个" | `UsageViewModel.swift` (`pickPrimary`/`allProviderRingSnapshots`) | **中高** |
| 6 | 活动计数加账号维度 | `CodexSleepProtectionCoordinator.swift` | 中 |
| 7 | 逐环 tooltip（可选，独立改动） | `StatusBarController.swift` | 中 |
| 8 | 账号环上限 + 固定排序 | `UsageViewModel.swift` | 中 |
| 9 | 菜单默认展开在用账号 | `MenuView.swift` | 低 |

**难度集中在 #5**：现在 `allProviderRingSnapshots` 是
`visible.map { provider in ... }` —— **一个 provider 一个快照**。要改成
一个 provider 多个快照，且不影响其它三个 provider 的既有行为。

### 仍然有效的边界

- `Own` 账号（Codex 当前登录的那个）在途时，车道键是裸 `codex`，
  **无法区分是哪个邮箱**。此时该环的账号名显示为"Codex（当前登录）"
  之类的中性表述，**不猜**。
- 两秒轮询的漏窗仍在：短请求可能整个落在两次采样之间。
- 只做 macOS。
- 不需要改 Magpie 上游 —— `data` 和 `who` 上游都有。

## 待用户确认的决策点

1. **方案 A / B / C 选哪个？**（推荐 A）
2. **多个账号同时在用时，环显示哪一个？**（推荐：额度最紧的那个；
   备选：busy 数最多的；备选：lastServedAt 最新的）
3. **空闲时是否保持现状（Current 账号）？**（推荐：是，无回退风险）
4. **是否需要把这个能力做成一个设置项？**（推荐：先不做，行为符合直觉；
   若要加，建议放在 Codex 环的窗口设置旁）

### 追加（多账号同时显示）

5. **Codex 模型族环与账号环共存还是替换？**（推荐**替换**：Codex 那一栏
   只显示账号环，空闲时退回单个 Codex 环）
6. **账号环的数量上限？**（推荐 3 个，其余进 tooltip）
7. **tooltip 要不要改成逐环？**（推荐：是，但要意识到这会改变现有
   "悬停整条看到全部 provider"的行为；可以做成只对多账号场景生效）
8. **左键菜单默认展开在用账号？**（推荐：是）

## 最终实现（2026-11-17）

用户已确认采用**替换**：有明确账号活动时，Codex 一栏不再保留一个 Pool /
Current 总环，而是每个在用账号一个 C 环。已落地行为：

- `busy` 的正确含义是**该账号此刻有请求正在厂商上游处理**，不是排队数、
  不是本地任务数，也不代表请求已完成。trace seat 的账号身份与 lane
  busy 合并；同一请求不重复相加。
- 空闲或无法唯一归属时保持原单 Codex 环；归属不明时在 tooltip 解释，
  不伪装成空闲。短暂读失败保留最后可信账号及额度，并标记活动不可读。
- 最多三个账号环；按 busy 数降序、同数按账号名稳定排序，超过的账号列在
  tooltip。每个环优先显示该账号的 5h 行，没有才选最受限窗口。
- 账号环右上角有实心活跃点。多个 Codex 环时逐环 tooltip 显示脱敏账号、
  额度与「正在使用」；只有一个 Codex 环时保留整条汇总 hover 的既有交互。
- 左键菜单的每个在用账号默认展开，包括有别名的账号；用户明确手动折叠
  仍然优先，不会被自动规则强行展开。
- 只读已配置的本机 loopback Magpie；只保留账号归属和计数，不新增凭据
  读取、远程访问或活动上传。2 秒并发快照仍可能漏掉极短请求。仅 macOS。

验证：新增 resolver、真实 HTTP 快照、快照调度、别名、多账号额度、稳定
排序、上限提示、读失败与菜单在用判定测试；相关 113 项测试通过。

## English

The Codex ring currently shows "Codex Current": Magpie's `last`-marked card,
or the card with the newest `lastServedAt`, or the first card. That is the
account that served *last*, not the one being served *now*.

Magpie's own notion of "in use" lives in `provider/served.go`: `NoteServed`
records the account that actually answered, and `withServed` marks the newest
one `Last`. Its tray refreshes immediately when another account takes over
(`OnServedMoved`). That is still "last served".

The genuinely live signals are `/v1/magpie/concurrency`'s `data` map (per
account/key lanes with `busy`/`waiting`) and the current trace seat's
`who`/`kind`. The original implementation decoded neither. Live verification
also corrected an earlier assumption: `try.id == "codex"` does **not** make
the account unknowable when its matching seat says `kind=account` and gives
the account email in `who`.

Magpie's scheduling (`routes.Smart`) puts the account whose largest window
renews soonest first — quota about to be lost is spent first — comparing to
the hour, keeping the listed order when equal so the vendor's prompt cache
stays warm. `gateway/affinity.go` keeps a conversation on whoever answered
it, for up to an hour on ChatGPT/Codex accounts.

Proposed: resolve the Codex ring's account from the busy lanes (account
level, live), fall back to the existing "last served" card when idle, and
never guess when the account cannot be uniquely attributed — the `Own`
account shares the `codex` rest id with its siblings, so a single request is
not always separable, while the seat identity and busy lanes are.

### Implemented behavior

The agreed replacement design is implemented for macOS. Each concurrently
active Codex account gets its own C ring instead of adding a separate pool
ring. At most three account rings are shown, with stable ordering and any
remaining accounts named in the tooltip. Idle or genuinely ambiguous activity
falls back to the existing single Codex ring; a temporary gateway read failure
retains the last known account and explicitly marks activity unavailable.
Per-ring hover identifies the account when multiple Codex rings are present.
The left-click menu expands every in-use account by default, including aliased
accounts, while respecting an explicit manual collapse. Only configured
loopback metadata is read; no Magpie credentials or activity are uploaded.
