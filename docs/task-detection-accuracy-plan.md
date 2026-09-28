# 任务检测准确性:调研结论与实施计划

日期:2026-09-24。背景:菜单栏任务波的数量来自 `CodexSleepProtectionCoordinator.activeTaskCounts`,
对各 provider 的检测链路做了一次全量审查(计数、开始、结束、任务中更新四个维度),
随后用本地数据源勘察 + 官方文档调研 + 现场实验确定了改进方案。

## 审查结论(问题清单)

| Provider | 当时方案 | 主要缺陷 |
|---|---|---|
| Codex | hook 事件(turn 级)+ rollout 文件解析,双源并集 | hook 追踪器无超时;错过 Stop 的 turn 无限残留(幽灵任务);Esc 中断大概率不触发 hook Stop(待实验确认) |
| Kimi | CLI:wire.jsonl turn 生命周期 + 120s mtime 兜底;Desktop:context-usage 的 updatedAt 120s 新鲜度 | CLI 静默 >120s 闪烁;Desktop 无真状态、可能误报 |
| GLM(ZCode) | session.time_updated 120s 新鲜度 | 结束延迟 ~120s;任务中静默闪烁;取消不可感知 |
| MiniMax | CLI/bg 目录 mtime 120s 新鲜度 | 同上;无状态字段 |
| Claude Code | transcript mtime 120s + 尾部 256KB 模型名归因 | 归因粘滞(切回官方模型后仍误计);结束延迟 ~120s |

通用:所有非事件信号共用 120s 窗,"上升沿快、下降沿也快",任务中静默段会被误判为结束。

## 已实施:GLM/ZCode 混合检测(2026-09-24)

**实验证据**(现场验证,三重独立证明):
`turn_usage` 表的行**只在回合到达终态时插入**(`completed`/`error`/`cancelled`,
含 `cancelled_by_user`),开始时间戳为回填值;执行期间无可见的 `running` 行。
证据:①三个并发回合全程 running=0、行在结束后 ≤1s 出现;②rowid 顺序 = 结束顺序 ≠ 开始顺序;
③取消-继续链 `prev.ended == next.started` 精确相等。

**实施内容**(`ZcodeActivityDetector.swift`):
- 开始/运行中:维持 `time_updated` 新鲜度(不变);
- 结束:每次轮询消费 `turn_usage` 的 rowid 增量,新终态行 = 该会话回合已结束,
  立即移出活跃集(门控:`time_updated <= 最后终态 completed_at` 则不活跃——
  若取消后立即继续,新写入会晚于旧终态时间,不会误杀);
- 首次轮询将游标初始化到 `MAX(rowid)`,跳过历史完成账本;
- `status='running'` 行被显式忽略(未来兼容:若 ZCode 改为开始时插入行,不误读为结束);
- `turn_usage` 表或列缺失 → 清空状态回退纯新鲜度(沿用 `columnsNeeded` 防御模式)。

**收益**:结束/取消检测延迟 ~120s → ~2-3s(轮询周期);取消语义可感知;开始与多会话计数不变。
**残余盲区**:`error` 状态无实测样本(处理路径与 completed 相同);schema 无官方契约,回退逻辑是必要组成。

## 已实施:Kimi 桌面状态账本 + Kimi Work 运行时接入(2026-09-28)

**现场实验结论**(计划中的"实验 2",在真实运行中的会话上验证):
`kimi-agent/conversation-statuses.json` 是权威的按会话生命周期账本——任务执行期间
条目为 `"running"`(文件随回合实时改写),结束后为 `"completed"`。
同时实测 `conversation-context-usage.json` 的 `updatedAt` 在任务中约 60–80s 才刷新一次,
贴着 120s 新鲜度窗,曾导致指示闪烁与结束后最长 120s 的滞留。

**实施内容**(`KimiLocalActivityDetector.swift`):
- Desktop:`conversation-statuses.json` 为主信号——`running` 等进行中状态 = 活跃
  (开始即亮、结束即灭);`completed`/`stopped`/`error` 等终态 = 立即不活跃,
  覆盖 `updatedAt` 新鲜度(消除误报与结束滞留);未知状态或账本缺失 → 回退原新鲜度
  启发式(schema 漂移防御,沿用 ZCode 模式);`running` 但 `updatedAt` 静默超过
  10 分钟 = 进程中途死亡,判为不活跃(崩溃兜底);
- Kimi Work(daimon)运行时:新增扫描桌面 App 托管运行时 home
  (`kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions`)的
  wire.jsonl,会话目录不再要求 `session_` 前缀(该运行时用 `conv-*`/`ctitle-*`),
  以 `kimi:work:` 前缀上报,移动端标签为 "Kimi Work";
- CLI/Work 开着 turn 但静默的 mtime 门从 120s 放宽到 10 分钟
  (`defaultOpenTurnSilenceWindow`):turn 生命周期仍由 `turn.prompt`/`turn.ended`
  驱动,mtime 只做进程死亡兜底,消除长工具调用/慢模型期间的闪烁。

**收益**:Kimi 任务的开始/结束在 ring 上 ≤2s(轮询周期)反映;Desktop 误报消除;
Kimi Work 桌面会话从不可见变为精确 turn 级检测。

## 已实施:Codex hook turn TTL(2026-09-28)

`CodexActivityTracker` 新增 `defaultTurnTTL`(10 分钟)与 `pruneStaleTurns(now:)`;
协调器每次合并刷新(轮询周期 2s)时回收超过 TTL 无事件的 turn,
消灭 kill -9 / hook Stop 丢失场景的无限幽灵任务。权限等待等合法长停顿被回收后,
用户响应产生的新事件会自动重建 turn(自愈)。Esc 是否触发 Stop 的实验(实验 3)
仍待做,若证实不触发可再叠加 rollout 双源对账。

## 已实施:Claude Code 归因粘滞修复(2026-09-28)

`ClaudeCodeActivityDetector.lastAssistantModel` 改为以转录尾部**最新一条** assistant
消息的模型为准:会话切回官方 Anthropic 模型后立即不再计入 GLM/MiniMax,
不再粘滞整个新鲜度窗。官方钩子方案(下方横切项)仍可做,用于彻底解决 120s 结束延迟。

## 待实施(实验驱动,按优先级)

### 1. Codex:Esc 中断实验 + 双源对账(需实验 3)

- **已完成**:turn 级 TTL(见上文"已实施:Codex hook turn TTL")。
- **待做实验**:开一个 Codex 任务 → 中途按 Esc 中断 → 观察 os_log
  (`log stream --predicate 'subsystem == "com.techfanseric.aiquotabar" AND category == "CodexActivity"'`)
  是否出现 Stop 事件,以及 rollout 是否写 `turn_aborted`。
- **若实验证实 Esc 不触发 Stop**:增加双源对账——rollout 判定回合已结束
  (`task_complete`/`turn_aborted`/`task_aborted`)而 hook 侧仍活跃时,采纳文件结论摘除 turn。

### 2. Kimi:已完成(2026-09-28)

见上文"已实施:Kimi 桌面状态账本 + Kimi Work 运行时接入"。
`stopped-turn-blocks.json` 未单独接入:手动停止后 `conversation-statuses.json`
已立即离开 `running`,账本信号足够。

### 3. MiniMax:activeGeneration 语义(需实验 4)

- **待做实验**:在 MiniMax 任一入口跑一个 ≥60s 任务,观察会话目录
  `history-catalog.json` 的 `activeGeneration` 是否从 0 变为非 0(空闲时实测为 0)。
- **若是状态字段**:CLI 会话直读;**若否**:维持 mtime + 下述状态机。

### 无需实验、可直接实施的横切项

- **Claude Code 官方钩子**:在 `~/.claude/settings.glm.json` / `settings.minimax.json`
  安装 UserPromptSubmit/Stop/SubagentStop/SessionEnd 钩子(复用 `AIQuotaBarHook` 二进制
  + 分布式通知转发,与 Codex 同架构;须合并保留用户已装的 Stop 通知钩子)。
  归因由 settings 文件天然区分 GLM/MiniMax,替代尾部模型嗅探。
- **Tier-3 非对称状态机**(全 provider 兜底底座):fresh → grace(保留 5–10 分钟,UI 降透明度)→ drop,
  上升沿 ≤2s、下降沿慢,统一消除静默闪烁;上面所有信号源失效时仍独立有效。

## 实验工具

`scripts/task-lifecycle-probe.py`:每秒轮询 ZCode turn_usage / Kimi 状态账本 /
Codex rollout 尾部 / MiniMax catalog,状态变化时追加时间戳日志到
`/tmp/aqb-probe/observations.log`(只记录状态、ID、时间戳,不记录消息内容)。
用法:`python3 scripts/task-lifecycle-probe.py [秒数,默认1800]`。
Codex 钩子事件另用上文 `log stream` 命令并行采集。
