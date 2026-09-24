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

## 待实施(实验驱动,按优先级)

### 1. Codex:turn TTL + 双源对账(需实验 3)

- **待做实验**:开一个 Codex 任务 → 中途按 Esc 中断 → 观察 os_log
  (`log stream --predicate 'subsystem == "com.techfanseric.aiquotabar" AND category == "CodexActivity"'`)
  是否出现 Stop 事件,以及 rollout 是否写 `turn_aborted`。
- **无论结果都要做**:hook 追踪器加 turn 级 TTL(~10 分钟无任何事件即失效,
  与 mobile summary 的 stale 语义对齐),消灭 kill -9 / hook 丢失场景的无限幽灵。
- **若实验证实 Esc 不触发 Stop**:增加双源对账——rollout 判定回合已结束
  (`task_complete`/`turn_aborted`/`task_aborted`)而 hook 侧仍活跃时,采纳文件结论摘除 turn。

### 2. Kimi:Desktop 状态账本 + CLI mtime 门放宽(需实验 2)

- **待做实验**:在 Kimi Desktop 跑一个 ≥60s 任务,观察
  `~/Library/Application Support/kimi-desktop/kimi-agent/conversation-statuses.json`
  是否出现 `completed` 以外的枚举值(如 running/generating);
  同时做一次手动停止,观察 `stopped-turn-blocks.json`;再静置打开 3 分钟检验 context-usage 是否持续刷新(误报验证)。
- **若存在运行枚举**:Desktop 直读状态文件为主、updatedAt 回退;
- **若无**:Desktop 维持启发式;CLI 侧把"turn 开着但静默"的 mtime 门从 120s 放宽到 ~10min
  (turn 生命周期仍由 `turn.prompt`/`turn.ended` 驱动,mtime 只做进程死亡兜底)。

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
