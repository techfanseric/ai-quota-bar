# Codex 重置线索与持续提醒

调研日期：2026-10-28（Asia/Shanghai）。使用 ego-browser 实际访问两个站点，并从页面加载资源及公开 API 文档核验接口。测试 fixtures 是当次公开响应的节选，没有账户数据。

## 来源与语义

| 来源 | 本次接入 | 语义与注意事项 |
| --- | --- | --- |
| [codex-reset.com](https://codex-reset.com/) | [GET /api/timeline](https://codex-reset.com/api/timeline) | `events[]` 包含 `id/type/summary/announced_at/url/confirmed/preview/banked_grant/reset_kind/official_window`。重置候选、已观察重置、banked 消息都在其中；普通额度/产品更新不触发提醒。 |
| [codex-resets.com](https://codex-resets.com/) | [GET /api/v1/status](https://codex-resets.com/api/v1/status) | `data.latest_reset`、`scheduled_reset`、`active_watch`。站点明确说明：预告时间过去不代表已执行；watch 是 AI 分类的预测线索，不是 OpenAI 官方承诺。 |
| 同上 | [GET /api/v1/resets?limit=100](https://codex-resets.com/api/v1/resets?limit=100) | 历史公告、常规与 banked 重置，`source.type` 为 `x_post/observed`。补充 status 只有一条 latest 的限制，应用离线期间的公告仍有机会补齐。最多读取最近 100 条。 |

codex-resets.com 的 [API 文档](https://codex-resets.com/api/docs) 与 [OpenAPI](https://codex-resets.com/api/openapi.json) 确认公开、只读、无需 API Key，并要求展示数据时链接回来源；每条消息的来源名称都是可点击链接。

codex-reset.com 的页面还公开了 `/api/feed`、`/api/forecast`、`/feed.xml`。本次选择 timeline，直接获得逐条重置消息与确认状态，不因预测百分比、点赞数、抓取时间变化产生新提醒。

现场例子：两站在调研时都展示了 X 帖子 `2115273253711409208` 的 “Lands by midnight PST.”。codex-reset.com timeline 的该消息是 `confirmed:false`；codex-resets.com 的 public status 将其放在 `scheduled_reset`，`scheduled_for=2026-10-28T07:00:00Z`（上海 15:00）。两站对 10 月 26 日上次重置的记录时间也有差异。因此客户端保留各自的描述与时间，不自行判定用户账户已重置。

## 提醒约定

- 应用启动后独立轮询三个 feed，每分钟一次；唤醒后立即检查。网络/格式失败后该 feed 等待五分钟，不影响其他 feed，也不清理本地未读。
- 首次成功读取每个 feed 时，超过 24 小时的历史只建立已读基线；近 24 小时的消息会提醒。后续新增的延迟公告不按原帖年龄过滤。
- 跨站不去重。同站 status/history 按公告 ID 合并；内容、执行状态或预告时间变更生成新版本并重新未读。抓取时间、概率与互动计数不参与版本身份。
- `UserDefaults` 的 `codexResetAlerts.v1` 保存消息版本、已读状态、已见版本和每个 feed 的初始化状态。保留全部未读与最近 30 天的消息；消息从源站消失不会自动已读。
- 未读期间菜单栏显示橙色提醒铃，每 0.75 秒切换明暗，暂停原额度图标动画。系统“减少动态效果”开启时常亮。全部确认后恢复原图标。
- 新消息立即尝试系统通知，之后每五分钟再次提醒。通知使用固定 ID 更新汇总，避免通知中心堆积；通知包含来源、类型、内容和确认按钮。
- 打开菜单、打开原文、点击通知正文、关闭通知都不自动已读。只有菜单中的逐条/批量确认或通知中的明确确认按钮结束对应消息的提醒。
- 通知确认只确认该次通知携带的版本 ID，不会清除之后新增或升级的消息。
- 系统通知受 macOS 授权、专注模式和通知展示设置影响。未授权时显示设置入口，菜单栏提醒持续；不会将通知投递成功或失败视为已读。

## 菜单交互（2026-10-28 调整）

- 消息标题右侧的外链图标查看原文：先关闭面板，再打开浏览器；查看不会自动已读。
- 标题右侧的勾选图标确认已读：原窗口内更新，保持面板打开。头部的勾选图标确认全部未读。
- 头部单行显示标题、未读数、全部已读、历史、刷新；提醒规则移到悬停提示，不再常驻占行。
- 时钟图标一直可用，包括没有未读时。展开后显示最近 30 天的消息，不受旧版“仅 5 条”限制；超过 30 天的未读仍保留在未读列表，直到确认。
- 没有未读新消息时，常驻最近一条明确的重置预告、已报告重置或 Banked 消息。该条消息即使超过 30 天也独立保留到被更新的明确消息替代；普通历史仍只显示最近 30 天，已读消息不会重新触发通知。
- 材质层使用 AppKit 原生可拉伸圆角蒙版，使内容、背景和系统窗口阴影使用相同轮廓，并在尺寸变化后刷新阴影。
- 左键菜单复用现有 MenuBarPanel；更新内容只调整同一个窗口的尺寸，不再执行 NSMenu 的关闭/重建跟踪流程。
- 已移除本机测试入口、测试消息和自动生成测试提醒的启动参数。
- 闪烁使用两帧预渲染图标，并过滤 AppKit 没有实际外观变化的回调，避免重绘循环。

## 验证

`swift test --filter 'CodexResetAlertTests|CodexResetHistoryTests|MenuBarRingRenderingTests'`

覆盖真实响应解析、初次基线、跨站独立、同站合并、确认升级、旧通知确认保护、离线/单站失败、重复提醒、通知拒绝授权、重启恢复和中英文离屏渲染。此前实现会话已在实际应用中验收系统通知与菜单交互；单测使用通知替身避免干扰真实用户。最终发布包的验证、签名和安装记录见 [v1.39.0 发布清单](../releases/v1.39.0-checklist.md)，不能以单测代替系统通知权限与横幅的实机验证。

## 面向当前版本的说明

历史 API 的 `limit=100` 是每次远端抓取数量上限，与本机历史界面无关。本机历史按最近 30 天保留并展示，额外保留全部未读及最新一条明确线索；不再采用“最近 100 条已读”或“只展示 5 条”的旧规则。

「暂时离开」Dim 的屏幕＋月亮标记与重置铃铛可同时出现，Dim 标记常亮且没有进度语义。用户使用与确认步骤见 [当前使用说明](../codex-reset-alerts.md)。
