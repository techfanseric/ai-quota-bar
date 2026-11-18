# 轻量模式：源码对照与 macOS 实现

调研日期：2026-11-12。AI Quota Bar 的目标是：默认开启，关闭的界面在一分钟后释放；不打开任何面板时，菜单栏额度环仍保留额度、趋势、流光、模型悬停信息及提醒。

## 两个项目实际怎样做

| 项目与源码版本 | 默认与时机 | 释放什么 | 保留与代价 |
| --- | --- | --- | --- |
| Magpie `f38ef9821b17cd08af1bca60081d03b00d6970dc` | 当前默认关闭；开启后每 30 秒检查，连续两次关闭即释放，约 30–60 秒 | 已关闭的主窗口/面板及其 WebView | 网关、任务和原生托盘继续运行；下次重新载入页面。源码说明因重开延迟，默认从开启改成关闭 |
| Clash Verge Rev `03d5c3715f0ededabd78431cebb2a8aefd86a912`（dev） | 自动模式默认关闭，默认延迟 10 分钟；静默启动可直接进入轻量 | 销毁主 Tauri WebView 窗口 | 代理核心与托盘独立运行；退出轻量时重新创建窗口。焦点回来会取消待执行定时器，状态机避免重复进入/退出 |
| AI Quota Bar（未发布 macOS 源码） | 按本次用户要求默认开启，关闭后满 60 秒；一分钟内重开则取消回收 | 关闭的左右键面板、设置窗口和警告窗口的 SwiftUI 宿主树/窗口；可重建的用量图表/汇总缓存 | 原生 ring、模型活动、额度刷新、电源保护、Dim、提醒、同步、用量上报、LAN 看板继续运行；已保存设置保留，下次点击重建界面 |

共同点是把界面与后台服务的生命周期分开，不是暂停整个软件。AI Quota Bar 没有它们的独立 WebView 进程，不能直接照搬 WebView 的内存节省数字，也不会通过降低流光帧率来声称进入轻量模式。

Magpie 还特别区分“关闭”与“被遮挡/最小化”。AI Quota Bar 同样只回收已关闭的界面：可见、最小化或带有 sheet 的窗口继续保留；失去焦点不启动回收。

源码：

- [Magpie 轻量规则](https://github.com/yetone/magpie/blob/f38ef9821b17cd08af1bca60081d03b00d6970dc/internal/gui/lightweight_rule.go)、[释放与重建](https://github.com/yetone/magpie/blob/f38ef9821b17cd08af1bca60081d03b00d6970dc/internal/gui/lightweight.go)、[默认设置说明](https://github.com/yetone/magpie/blob/f38ef9821b17cd08af1bca60081d03b00d6970dc/internal/settings/settings.go)。
- [Clash Verge 轻量状态机及定时器](https://github.com/clash-verge-rev/clash-verge-rev/blob/03d5c3715f0ededabd78431cebb2a8aefd86a912/src-tauri/src/core/lightweight.rs)、[窗口销毁](https://github.com/clash-verge-rev/clash-verge-rev/blob/03d5c3715f0ededabd78431cebb2a8aefd86a912/src-tauri/src/utils/window_manager.rs)、[默认配置](https://github.com/clash-verge-rev/clash-verge-rev/blob/03d5c3715f0ededabd78431cebb2a8aefd86a912/src-tauri/src/config/verge.rs)。

## 使用与边界

「设置 → 通用 → 系统 → 轻量模式」默认开启。关闭该开关可以让打开过的界面继续留在内存，方便频繁查看。开关关闭时已回收的界面仍会在下一次点击时重建。

一分钟从界面关闭算起，不是用户全局键盘鼠标停止活动的时间；不会因为在设置里阅读一分钟就销毁正在看的页面。每个界面有自己的关闭时刻，一分钟内重开会重新计时。没有待回收界面时没有轻量模式轮询定时器。

已保存的设置、账号、历史记录、上报队列不会被删除。设置页签与窗口位置由轻量控制器外的状态持有，重建后恢复；显示器布局变化时窗口位置仍由 macOS 校正。关闭界面中的未保存临时输入、展开气泡等短期 UI 状态可能清空。

ring 的图像帧、显示器适配、悬停、模型活动与额度源不被回收；任务计数、Magpie 本机模型路由读取、后台刷新、提醒和电源保护继续按原有逻辑运行。有活动任务时维持原流光帧率，因此轻量模式不承诺动画期间 CPU 降为零。LAN 看板的连接监控 owner 独立保留，回收右键面板不会关闭仍有远端观看者的 live 更新。

该实现仅针对 macOS 原生应用。Windows 未移植本次轻量模式，Mac 稳定版仍为 v1.39.3，Windows 公测版仍为 v1.38.6-beta.1；公开下载尚未包含这些改动。

## 主要实现入口

- `LightweightModeController`：持久化默认开启的本机选项、单次计时、释放前复核窗口状态、回调重入保护。
- `StatusBarController`：左键菜单及右键控制器按需创建；只清除关闭面板的宿主和窗口，保留 ring 与业务模型。
- `ClashRoutePopoverController`：控制面板释放与重建；live 轮询的 LAN owner 不受 popover 关闭影响。
- `SettingsWindowController` / `PreferencesSelection`：设置宿主树可释放，页签/窗口位置单独保留。
- `CodexLocalUsageModel.releasePresentationCaches`：只清除可再计算的图表和汇总缓存，不停止扫描、同步或队列。

## 验证记录

测试和本机安装证据见[轻量模式验证清单](../releases/unreleased-lightweight-checklist.md)。内存应比较相同进程、相同已预热界面的回收前后 physical footprint；RSS 会随系统压缩变化，不能单独视为优化收益。实际回收量取决于打开过哪些页面、数据量和系统缓存，没有固定 MB 保证。

## English

The shared idea is to release rebuildable UI while the core keeps working. Magpie frees closed WebViews after two 30-second checks when enabled; it is currently off by default because rebuilding hurt reopening latency. Clash Verge Rev destroys/recreates its main WebView, with auto mode off and a ten-minute default delay in the reviewed source. Neither setting determines AI Quota Bar's requested defaults.

AI Quota Bar's unreleased macOS implementation is **on by default with a 60-second closed-interface delay**. Menus load on demand; closed native hosting trees/windows and derived usage-chart caches can be reclaimed. Visible, minimized and sheet-owning windows are protected. Opening within the minute cancels reclamation. Saved settings, the settings tab and valid window placement survive rebuilding; unsaved temporary input may be cleared.

Quota refresh, full menu-bar rings/hover, live model lights, notifications, power protection, Dim, reporting, sync and the LAN dashboard continue independently. Existing ring animation frames and cadence remain available. This is native SwiftUI, so WebView memory savings cannot be promised; actual retained/released objects and warmed-process footprint are measured instead. Windows is unchanged, and public downloads do not yet contain this source change.
