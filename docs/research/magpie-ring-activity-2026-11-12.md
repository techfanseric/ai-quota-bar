# Magpie 圆环贡献与实时活动信号

本次目标：将已长期自用的紧凑圆环布局移植为 Magpie 的可选菜单栏样式，让多个订阅同时可见，并保留按实际并发变化的流光。原 AI Quota Bar 的已安装版本和任务流光未被替换。

## 可以准确知道什么

基于 Magpie `47b51c8225a66e753dd249cb782472b0dcbee6c4`：

| 来源 | 已有能力 | 本次用途 |
| --- | --- | --- |
| `internal/gateway/active.go` | 真实请求进入/退出，记录请求 ID、阶段和路由 ID | 请求的真实在途生命周期；重复 ID 不重复计数 |
| `internal/gateway/concurrency.go` | 按账号/Key 区分执行数与排队数；已有本机 `/v1/magpie/concurrency` 接口 | 区分执行和等待；读取另一个本机服务进程的 `active` 快照 |
| `internal/gateway/trace.go` | 路由变更序号、实际尝试、账号、模型和结束状态 | 将 `Active.Route` 关联到未结束的 `Try` 及对应的 `Weighed`；按实际回退目标归属 |
| `internal/gateway/turndone.go` | 根据工具调用、最后回复和 4 秒静默期推断完整回合结束 | 不用作精确任务计数，避免把推断当成确定状态 |
| AI Quota Bar 的 `CodexSleepProtectionCoordinator` | 汇总本地 Hook 与各客户端会话检测，按服务商提供活动任务数 | 原有任务流光继续使用；与 Magpie 请求计数不直接相加 |

原项目圆环按服务商显示，现有计数不是全局的“每个模型的精确请求数”。Magpie 的路由信息可以进一步给出实际模型的请求明细；对于没有经过 Magpie 的工作，它无法提供真实状态。两者不能无条件互相替代。

## Magpie 移植版的显示含义

- 一个执行中的上游模型请求对应一条流光，最多绘制 5 条；悬停保留真实总数与模型明细，例如 `model-a × 2`、`model-b × 1`。
- 只计入 `phase=upstream`。排队、RPM 等待、脱敏、工具执行空档、无法归属的请求不猜测为“模型正在执行”。
- 按未结束的实际尝试归到账号与模型，处理路由组、回退、重试；一次请求不会因多次尝试被重复计数。
- 结束、取消、路由消失或网关进程切换后移除旧状态；读取失败清除旧流光，并提示实时活动状态不可用，不冒充空闲。
- 活动读取与额度刷新分开。动画帧不拉额度、不解析路由；只有可见且活动的圆环启动原生 12 fps 定时器。减少动态效果时保留静止活动标记。

“模型请求正在执行”与“整个编码任务仍未结束”是两个口径。任务执行本地工具时，前者可以为 0，后者仍为 1。若未来给原项目新增 Magpie 数据源，应显式选择这两种活动口径，保留本地任务检测，不能把两份计数相加而重复显示。

## 预览与贡献

独立工作目录：`/Users/ericyim/magpie`；实现分支：`codex/compact-quota-rings`。预览资源与代码分开，使用模拟订阅和模拟并发，不包含真实账号或应用构建产物。

同一组四订阅示例，不含鸟图标：数字模式 185 pt，圆环 95 pt，约少 49%。这是菜单栏宽度与信息密度的取舍：圆环显示首个选中周期，精确数值和全部周期在悬停提示中保留。

Magpie 当前只向协作者开放 PR，因此通过 Issue 提供实现分支、可应用补丁、原生明暗对比、动态预览和验证记录。最终是否合入由维护者决定。

已提交上游 [Issue #6269](https://github.com/yetone/magpie/issues/6269)，实现提交为
[`c1144a85042c02fc16f6adfdcf045b7cc96f25d9`](https://github.com/techfanseric/magpie/commit/c1144a85042c02fc16f6adfdcf045b7cc96f25d9)。
[使用说明和验证记录](https://github.com/techfanseric/magpie/blob/c1144a85042c02fc16f6adfdcf045b7cc96f25d9/docs/compact-quota-rings.md)
包含原生预览、生命周期测试和未通过的全量检查。156 项相关浏览器检查、针对性 Go/race 检查和三平台 vet/build 已通过；全量 Go 测试未全绿，未进行真实账号或已安装 Magpie 实机验证。

本轮没有给 AI Quota Bar 接入新的 Magpie 活动桥接，也没有覆盖安装 Magpie；原项目已安装版本继续使用原有任务流光。后续若接入 Magpie 请求信号，仍须保留本地任务口径并避免重复计数。

后续同日变更：用户明确要求“虽然使用 Codex 客户端，仍按模型归到现有四个环，悬停区分模型”。AI Quota Bar 源码已新增本机 Magpie 元数据读取与模型归属层；上段描述的是贡献提交时的状态。网关请求流光与完整任务的电源保护分开，配置为经 Magpie 的任务不再按客户端重复计入 Codex 环，未知别名不猜测。当前行为和限制见[任务与模型活动对账](../task-activity-reconciliation.md)。Magpie 上游贡献分支未在此次本机实现中变更。

该后续实现已覆盖安装到本机 AI Quota Bar，并验证签名、启动进程及构建/安装文件校验值一致；仍是本地 1.39.3 (86) 工作区构建，未发布公开下载。安装证据见[验证记录](../releases/unreleased-background-quota-checklist.md)。
