# GLM 与 Ring 功能兼容性调研

调研日期：2026-09-11。本报告记录 v1.15.0 时的基线；后续 Ring 额度接入与多选改造见 [v1.16.0 发布说明](./releases/v1.16.0.md)。范围：当前项目的 compactRing、国内个人 GLM Coding Plan，以及补齐任务活动数据的可行性。仅调研，未修改产品代码。

## 结论

仅依赖 GLM 额度 API，不能完整支持 Ring 的全部功能。额度数据基本具备；任务计数需要运行 GLM 的客户端提供生命周期事件。限定在已适配的本机客户端，可以实现额度、活动动画、任务数和防休眠；无法据此承诺覆盖所有工具、设备及账户的全局任务数。

当前项目已经接入 GLM 额度，但尚未完成 Ring 接入，不能把“额度页面支持 GLM”等同于“Ring 已支持 GLM”。

## 功能对照

| 功能 | 数据可行性 | 当前实现 / 缺口 |
| --- | --- | --- |
| 5 小时剩余额度、总量、已用量 | 可获取 | 自有解析器已支持 CREDIT_LIMIT、服务端 remaining、百分比降级 |
| 每周剩余额度 | 可获取 | 已解析为独立 weekly 记录，但 Ring 周期路由排除 GLM |
| 多服务商并列 Ring | 可实现 | compactMenuBarSnapshots 的 displayOrder 只有 Codex、Kimi |
| 手动指定 GLM Ring | 可实现 | MenuBarContentSelection 缺少 glm 选项 |
| 低额度颜色、历史记录 | 可复用通用能力 | 需先接通 Ring；告警阈值应明确对应外圈还是短周期 |
| 周重置倒计时 | 有 nextResetTime 时可实现 | 无时间字段时应显示未知，不猜测 |
| 5 小时恢复倒计时 | 有条件 | 官方描述为每笔消耗 5 小时后恢复，不能承诺存在统一的全量重置时刻 |
| 中心余量/赤字节奏 | 周窗口可实现 | 需要完整周起止时间；5 小时滚动窗口不能直接套固定周期线性预算 |
| 进行中的任务数 | 需要客户端适配 | 当前活动计数仅 Codex、Kimi；未发现官方账户级编码任务列表接口 |
| 任务波纹动画 | 有任务数即可复用 | 渲染器接收通用 provider→count；当前波纹最多显示 5 道，不等于无限精确数字显示 |
| 任务期间防休眠 | 需要可靠活动源 | taskProtectionProviders 与合并逻辑均未包含 GLM |
| 离线特殊图形、连接状态 | 需要新状态定义 | 当前特殊离线视觉与检测路径针对 Codex，额度请求失败不等于 GLM 客户端离线 |
| 国际 Z.ai、团队版、多账号 | 本次不承诺 | API Key 默认域名为 open.bigmodel.cn；GLM 记录 accountName 为 nil，需另做区域及账户建模与验证 |

## API 证据与边界

官方 [zai-coding-plugins](https://github.com/zai-org/zai-coding-plugins) 的 [query-usage.mjs](https://github.com/zai-org/zai-coding-plugins/blob/main/plugins/glm-plan-usage/skills/usage-query-skill/scripts/query-usage.mjs) 调用三个 GET 接口：

- `/api/monitor/usage/quota/limit`：额度。
- `/api/monitor/usage/model-usage`：指定时间范围的模型用量。
- `/api/monitor/usage/tool-usage`：指定时间范围的工具用量。

脚本分别支持 open.bigmodel.cn 与 api.z.ai，使用 Authorization 传入凭据。本项目 API Key 路径添加 Bearer 前缀；官方脚本直接传环境变量内容，两者认证兼容性仍应通过实际凭据验证。

本次下载并阅读了官方最新脚本；没有执行该脚本，没有读取用户 API Key，没有进行登录态额度实测。新版 CREDIT_LIMIT 字段依据本项目已有的 [接口字段记录](./glm-api-field-mapping.md)，该记录注明此前网页验证过响应、API Key 尚未在线验证。本次未找到这几个 monitor 接口的完整公开 OpenAPI 契约，因此不把脚本解析字段视为穷尽所有响应字段的稳定承诺，也没有用其他项目的 API 文档代替 GLM 规范。

现有字段映射：usage 为总量，currentValue 为已用，remaining 为剩余，percentage 为已用百分比，nextResetTime 为可选毫秒时间戳，unit/number 表示周期，level 为套餐等级。项目历史字段 currentIntervalUsed 实际保存剩余量，不能按字段名称直接填入已用值。

[官方套餐概览](https://docs.bigmodel.cn/cn/coding-plan/overview) 描述了 5 小时动态恢复和 7 天周期重置。结合该说明，建议周额度用于中心预算节奏；5 小时额度只显示剩余比例，除非能确认服务端提供的恢复时间语义。不能简单把 nextResetTime 减去 5 小时视作有效固定窗口开始时间。

未在本次核对的官方插件与文档中发现全局 activeTaskCount、活跃编码会话列表或对应推送接口。这是“未找到可依赖的公开能力”，不是证明智谱内部绝不存在此类接口。

官方另有 [异步对话补全 API](https://docs.bigmodel.cn/api-reference/模型-api/对话补全异步)，返回单个异步请求的任务 ID 和状态；它不能直接替代 Claude Code/OpenCode 完整编码任务的状态。一次编码任务可能包含多次模型请求、工具执行、重试及等待用户。

## 建议的任务活动方案

1. 首先统一口径为“本机、已接入客户端中正在执行的 GLM 会话数”，与当前 Codex/Kimi 通过活跃 session 集合计数的方式对齐。子代理单独记录，默认不重复增加父会话数。
2. Claude Code 可以通过 [官方 hooks](https://code.claude.com/docs/en/hooks) 的 UserPromptSubmit、Stop、StopFailure、SessionEnd 等事件建立状态机，SubagentStart/SubagentStop 辅助处理子代理。Stop 可被其他 hook 阻止，不能仅凭一次回调无条件认定任务结束；还需处理权限等待、异常退出和重启恢复。实际支持事件以客户端版本为准。
3. OpenCode 可以通过 [官方插件事件](https://opencode.ai/docs/plugins/) 适配 session.status、session.idle 等生命周期。该路径是可行性方案，尚未实现或实测。
4. 必须依据实际 provider、端点及会话配置识别 GLM，处理会话内模型切换，不能把所有 claude/opencode 进程都计入 GLM。
5. 事件去重、心跳/进程存活校验、过期清理、应用重启恢复应组合使用。数据源失联显示“未知/过期”，不能自动宣称任务数为零；等待用户应与运行区分。

仅统计 TCP 连接、进程数量、近期 token 增量或在途 HTTP 请求，均不能可靠替代任务数。其他电脑也需部署活动采集端并汇总，额度接口不能补出缺失的任务状态。

## 代码落点与实施顺序

第一阶段接通额度 Ring：

- `AIQuotaBar/Models/MenuBarDisplayPreferences.swift`：增加 GLM 内容选择。
- `AIQuotaBar/ViewModels/UsageViewModel.swift`：扩展并列显示、缺数据状态、5h 主窗口、weekly 外圈/中心来源及 tooltip。
- 同文件 `combinedProviderPriority` 未包含 GLM，只有 GLM 时顶层 provider 会回退 Codex，应一并修正。
- 当前 GLM 缺失 5h 重置时间时，在按重置时间排序的候选列表中，weekly 可能先于 5h；需要显式按窗口类型选择。
- 避免继续增加 provider 白名单，考虑以“支持周额度、固定/滚动窗口、活动源”等能力决定行为。

第二阶段增加一个客户端活动适配器，再扩展其他工具：

- 在 `AIQuotaBar/Services/Codex/CodexSleepProtectionCoordinator.swift` 周边抽象通用活动输入，增加 GLM 会话状态合并。
- 扩展 taskProtectionProviders；在来源有效时将任务数送入现有 Ring 渲染器。
- `AIQuotaBar/App/StatusBarController.swift`：决定是否推广离线/未知视觉，保持额度失败与客户端活动失联分离。

验收应覆盖：5h/weekly 两条额度、额度为零、缺重置时间、滚动恢复、多会话、等待权限、取消、异常退出、子代理去重、非 GLM 会话排除、源失联。最终以真实账号只读额度请求及客户端生命周期集成验证为准。
