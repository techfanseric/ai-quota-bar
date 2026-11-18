# 任务流光对账 / Task activity reconciliation

2026-11-12 · macOS 未发布源码 / unreleased macOS source

## 显示什么

保留 Codex、Kimi、GLM、MiniMax 四个额度环；流光按模型所属服务商归环，最多绘制五道，悬停显示具体模型与数量。Codex 是客户端名称，不能据此把 MiniMax/GLM/Kimi 模型的活动都算到 Codex 环。

Codex 配置使用本机 Magpie 时，以实际执行中的上游请求驱动流光，包括路由组回退后的目标；直接运行的模型使用本地回合记录的模型身份。完整任务生命周期继续负责电源保护；网关两个请求之间执行本地工具时可能没有流光，但任务保护仍可继续。Kimi 使用现有会话/回合信号；GLM、MiniMax 和 Claude Code 的其他检测路径仍可能依赖最近写入。

## 本次改动

- `CodexLocalActivitySnapshot` 只为内部对账增加会话/回合 ID、开始时间、完成时间和主会话归属；不上传这些 ID，也不新增消息或工具内容读取。
- `CodexActivityTracker` 接收日志中的 `task_complete`、`turn_aborted`、`task_aborted`，用于补足遗漏的 Stop。仅明确的终态关闭匹配回合；空白/失败读取不关闭 Hook 任务。
- Hook 完成/SessionEnd 记录抑制滞后的同回合日志和迟到工具事件。新的回合继续独立计数。终态记录通常在十分钟后回收，但若日志仍声称同回合活跃，会保留到矛盾消失，避免 TTL 到期后“复活”。
- 合并时用已知的主会话 ID 去重 Hook 和日志中的子会话。未确认父子关系时不猜测归属；父任务已结束但子任务仍活跃时保持主任务计数。
- 睡眠保护关闭后仍接收 Hook 并更新流光，电源断言继续由原开关控制。
- ZCode、MiniMax、Claude Code 一轮读取结束后一次发布结果；不修改其数据格式、检测窗口或额度刷新。

## 模型归属与本机 Magpie

`ModelActivityAttribution` 将明确的 GPT、Kimi、GLM、MiniMax 模型归到对应环。`CodexLocalActivityDetector` 读取每个活动线程的模型元数据和 `turn_context`，保留子任务自己的模型，避免一律使用父任务模型。未知别名不按客户端猜测。

`MagpieModelActivityDetector` 只从 Codex `config.toml` 的标准 `[model_providers.<id>]` / `base_url` 发现 loopback 网关（127.0.0.1、localhost、::1）；不扫描默认端口，不连接远程地址，不发送凭据/Cookie，不跟随重定向，也不修改 Codex 配置。多地址存在时优先明确的 magpie 节；无法唯一确定则不猜测。URL 带账号、密码、查询或非标准路径会被拒绝。

每两秒读取既有 `/v1/magpie/concurrency`，只计 Codex 客户端的 `phase=upstream`；将请求的 route ID 对应到 `/v1/magpie/trace` 的未结束尝试及匹配目标。实际返回模型可用时优先使用；排队、脱敏、已完成和无法归属的请求不推断为正在执行。一次请求最多计一次，重试/回退不额外增加并发数。trace 按序号增量读取，只保留活跃路由的 ID、模型和目标等元数据，网关重启/读取失败/取消会清除旧计数。响应大小和等待时间有上限；不在动画帧中联网。

配置明确经过 Magpie 的本地任务，以及会话 ID 匹配网关请求的任务，不再额外按本地任务加入流光。网关不可用时悬停明确提示，不回退为猜测的 Codex 活动。内部会话 ID 仅用于去重，不上传；未读取 Magpie 凭据或新的消息/工具正文端点。现有 trace 响应中的其他字段不进入保留状态。

实现入口：`CodexLocalActivityDetector.detectSnapshot`、`CodexActivityTracker`、`CodexSleepProtectionCoordinator.mergedCodexActiveSessionIDs`。现有两秒轮询间隔保留；Hook 在收到时更新。

## 边界

两秒轮询可能错过在两次采样之间完整结束的短请求；这里是当前并发快照，不是累计请求账本。绕过本机 Magpie 的任意客户端无法统一获得精确网络并发；直接模型元数据是客户端声明的身份，不证明远端没有再映射模型。相同服务商下的多个具体模型共用一个环，悬停分列。额度仍属于原配置账号，流光的模型归属不证明该请求消耗了该额度账号。

部分客户端的最近写入窗口仍会造成延迟或漏判。未确认归属的子任务、回合 ID 缺失的第三方检测器使用原有会话级电源保护兜底，未知模型不强行画到 Codex 环。十分钟 Hook 静默回收仍存在，长时间等待许可可能暂时进入不活跃，后续有效事件可恢复。Windows 未移植此逻辑。公开 macOS 下载仍为 v1.39.3，尚未包含本次源码改动。

## English

The four existing rings follow model families, not client names, drawing at most five waves and listing concrete models/counts on hover. A Codex client using MiniMax lights MiniMax. Known direct models use local turn metadata; Magpie-backed Codex work uses actual in-flight upstream destinations, including fallback. The same work is not added as both a local task and a gateway request. Whole-task lifecycle still controls power protection independently; local tool gaps may have no gateway lights.

Codex hooks and rollout logs now reconcile explicit turn identities and terminal events. Logged completion/cancellation can replace a missing Stop; a completed hook turn cannot be relit by a lagging log or late tool event. Empty reads do not imply completion. Known child sessions merge under their root, while children still running after the root stops keep the task visible. Terminal markers remain while a stale local copy still claims the turn is active.

Hook counting continues with sleep protection off. Power assertions retain their existing controls. ZCode/MiniMax/Claude Code polling publishes each batch once. The Magpie reader discovers configured loopback base URLs in Codex config only, rejects remote/credential-bearing URLs and redirects, bypasses proxies, and sends no credentials. It reads existing concurrency/trace metadata every two seconds, incrementally retaining destination fields only. Failed reads clear old lights and report unavailable. No IDs or activity metadata are uploaded, and no new message/tool-body endpoint is read.

Requests completed entirely between polls can be missed; this is current concurrency, not an accumulated request log. Direct metadata cannot prove that a remote server did not remap a model. Model-family activity does not prove which configured quota account was charged. Other clients still have freshness-based gaps; unknown models are not guessed as Codex. The existing ten-minute hook silence cutoff can temporarily hide long permission waits. Windows has not received these changes, and the public v1.39.3 download does not contain them.

## 验证 / Verification

The focused tests exercise explicit completion/cancellation, missing Stop, stale snapshots, late events, new turns, SessionEnd, child/root deduplication, child work after root completion, disabled protection and terminal-marker retention beyond TTL. The local detector tests parse actual JSONL-shaped fixtures. Ring-rendering and all four provider detectors are included in regression checks. Results and local installation evidence are recorded in [the delivery checklist](releases/unreleased-background-quota-checklist.md).
