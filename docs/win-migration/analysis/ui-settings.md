# Windows 迁移分析：整体 UI 结构（菜单栏/控制中心/设置）+ 移动端仪表板 + 配置持久化

> 对应源码：`AIQuotaBar/App/`、`AIQuotaBar/Views/`、`AIQuotaBar/Settings/`、`AIQuotaBar/Services/MobileDashboard/`、`AIQuotaBar/Resources/MobileDashboard/`、`AIQuotaBar/Services/Display/`、`AIQuotaBar/ViewModels/UsageViewModel.swift`、`AIQuotaBar/Models/`。
> 目标平台：C# .NET 8 WinForms/WPF 托盘应用。

---

## 1. 菜单栏图标渲染（macOS NSStatusItem → Windows NotifyIcon）

### 1.1 两种外观模式（`menuBarAppearance`，默认 `detailedText`）

源码：`StatusBarController.swift`、`Models/MenuBarDisplayPreferences.swift`。

| 模式 | rawValue | 渲染方式 | 说明 |
|---|---|---|---|
| `detailedText` 详细文字 | `detailedText`（默认） | 两个 10pt 等宽数字 `NSTextField` 直接 addSubview 到 `NSStatusBarButton`，两行 | 第 1 行：供应商名或剩余；第 2 行：状态 |
| `compactRing` 紧凑环形 | `compactRing` | 每个 provider 一个 19pt 宽、22pt 高的环（`StatusBarCompactRingView`），整条 rasterize 成 NSImage 帧序列后挂到 `button.image`（绕开 AppKit 子视图快照开销），30fps 换帧 | 条宽 = padding×2 + 环数×19 + (环数−1)×间距 |

- 文字模式行 1/行 2 由 `statusBarText`（含 `\n`）拆分：`"\(provider.displayName)\n\(状态文本)"` 或 `"C:74% · +12% · 3.2h"`。
- 单行格式（`ModelUsageData.formattedStatusBarLine`）：
  - 带供应商首字母：`<C|K|M|G>:<剩余%> · <±delta%> · <重置时间>`，例 **`C:74% · +12% · 3.2h`**；pace 未知时显示 `—`。
  - 详细文字 + Automatic/All 且有两家数据时，两行各显示一家 provider。
  - 重置时间格式（`formatResetTime`）：`<1h → "45m"`；`<24h → "3.2h"`；更长 → `"2.1d"`；无 → `"0m"`。
- 非激活屏 0.5 透明度跟随（多屏菜单栏复制品规范）；Windows 上无此概念，可忽略。

### 1.2 环形渲染状态机（`QuotaSymbolRenderer` + `MenuBarSnapshot.state`）

快照状态 `MenuBarSnapshotState`：`needsSetup / loading / ready / unavailable / failed / placeholder`（placeholder = 跟随模式下无应用运行或显示被手动暂停，与 failed 刻意区分）。

渲染几何（367×410 坐标系缩放到目标 rect）：外环半径 155.975、线宽 55.05，从 38° 起顺时针扫 256°（顶部 104° 缺口）；环心偏上 21.5。供应商字母 C/K/M/G 以 130pt bold 画在缺口上方（始终可见）。

| 状态 | 外环 | 中心 |
|---|---|---|
| ready + 有剩余值 | 剩余段 = `ringPercent/100`，其余为 18% 透明 track | 见 1.3 pace 扇形 / 趋势线 |
| loading | track + 0–0.28 段 50% 前景扫过 | 中心 muted 点 |
| needsSetup | 只画 track（无剩余弧） | 灰点 + 双侧扇形 muted |
| unavailable / failed / **offline**（Codex + connectivity==unreachable + 非setup + 非自检） | **整环变红 danger**（`#C21515`） | **红色圆角药丸横杠**（88.5,157.5,190×52，r=26），offline 时 0.32–1.0 呼吸脉冲（周期 1s） |
| 低额度 `isLowQuota`（剩余 ≤ warningThreshold，未启用阈值时按 20） | 剩余段变 **warning 琥珀 `#D6A00A`** | 不变 |

颜色阈值汇总：
- **红 danger `rgb(194,21,21)`**：unavailable/failed/offline（阻塞态整环）。
- **琥珀 warning `rgb(214,160,10)`**：`isLowQuota`（ready 且剩余 ≤ 阈值）。
- 其余：前景 `labelColor`（深浅色自适应），track = 前景 18%。

### 1.3 环内双向 pace 扇形（「5h 与 weekly 显示什么」的核心）

- `paceDeltaPercent` =（匀速应已用% − 实际已用%）：正 = 用得慢（reserve 余量），负 = 用得快（deficit 透支）。
- `MenuBarPaceGlyph`：满刻度 = 2 天偏差（周窗口 7 天，`fullScaleDeltaPercent = 100/7×2 ≈ 28.57`）。
  - `staged`（默认）：|delta| ≤ 2 → onTrack 空；否则按 25/50/75/100% 四档向上取整填充；超过 2 天显示活动侧描边。
  - `continuous`：线性填充。
- 绘制：中心点（38pt）+ 上下各两级环形扇区（内 42–69、外 82–109，每级 ±55°）；**上方 = reserve（fill>0）**，**下方 = deficit（fill<0）**。
- 趋势线替代规则：账号「只有 Weekly、没有 5h」且**内环窗口确实落在周窗口**时，环内画 sparkline（≤24 点，窗口内剩余% 采样，x=窗口时间比例，带 0.22 alpha 填充 + 端点 cap），此时不画扇形；点数 < 2 时回退扇形。
- **外环数据窗口**（`menuBarRingQuotaWindow`，默认 `current`）：每 provider 可覆写；Codex/Kimi/GLM 支持 `current(5h)/weekly`，Kimi 额外 `total(月度)`，MiniMax 仅 `current`。GLM 无 5h 时优先取名含 "5h" 的窗口。
- **内环 pace 窗口**（`menuBarReserveQuotaWindow`，默认 `synchronized` 跟随外环）：可独立选 weekly/current/total。
- 只有 Weekly 的账号：环与环内一律退回 Weekly 计算（`hasFiveHourWindow == false` 分支）。

### 1.4 任务能量波（active tasks 动画）

- 触发：`activeTaskCount > 0 && state == .ready && !offline && !selfTesting`；每道波对应一个活跃任务，最多 5 道（`MenuBarTaskEnergyMotion.maximumWaveCount`），沿整环逆时针巡游，1.8s/圈（渲染帧 30fps，播放 12fps 节流 `continuousNanoseconds=83.3ms`）。
- 两种布局（`menuBarTaskWaveLayout`，默认 `evenlySpaced`）：均匀分布 / 追逐队列 `chaseQueue`（波首尾相接、头部珠点恒亮）。
- 剩余段内波线亮、消耗段线细且 45% 透明。`NSWorkspace.accessibilityDisplayShouldReduceMotion` 时定格（Windows → `SystemInformation` 无直接等价，可用系统"显示动画"设置或提供应用内开关）。

### 1.5 自检动画（self-test）

`isMenuBarSelfTesting`（刷新图标自检，Codex provider 时）：3s 循环——外环 50±42% 连续扫，中心三相等分演示 deficit(→−28%) / onTrack / reserve(→+28%)。

### 1.6 占位形态（`menuBarPlaceholderStyle`，默认 `openAIConnectivity`）

一个 AI 都没开（跟随模式无活动窗口 / 全部手动暂停，`state == .placeholder`）时：
- `openAIConnectivity`（默认）：哑色开环（22% 前景）+ 中心连通性记号：可达=中性对勾、不可达=红叉（线宽 32）、探测中=45% 灰点（52pt）。刻意与「Codex 掉线」三重信号（整环红+药丸+脉冲）区分。
- `providerCount`：哑色环 + 已启用供应商数量（≤99，10 以上字号缩小）。
- `brandMark`：复刻 App 图标（哑色环 + "A" + 中心点）。

### 1.7 环显示集合（compact 模式）

- `menuBarRingDisplayMode`（默认 `automatic`）：`all` = 显示所有勾选 provider；`automatic` = Codex/Kimi 中取「有活跃任务的 > 剩余最低的」一家 + MiniMax/GLM 常驻。
- `menuBarRingSelectedProviders`：勾选集合（默认全部 4 家：codex/kimi/miniMax/glm）；只显示「已配置 + 未暂停 + 未被跟随隐藏」的。
- 旧 key `menuBarContentSelection`（文字模式 provider 选择 all/automatic/codex/kimi/minimax）迁移决定 ring 模式初值。

### 1.8 Tooltip

每环 hover tooltip = 快照 tooltip（provider·模型·剩余·周剩余·pace·重置）；Codex 不可达时追加「连通性不可用」行；自检中显示自检说明；占位连通性形态追加连通性句。tooltip 文本同时是 Accessibility label。

### 1.9 状态栏点击行为（`handleStatusItemClick`）

- **左键**：打开左键菜单（控制中心面板，见 §2）。
- **右键快击**：打开右键 Clash 面板（路由/连接/保护，见 §3），自动测速。
- **右键长按 ≥0.6s**：触发「暂时离开」全屏调暗（`StepAwayDimController.dim()`），松开不弹面板。
- 鼠标悬停有 hover 高亮（环条 hover 时显示 provider 字母——Windows 迁移可简化掉）。

---

## 2. 左键控制中心面板（MenuView，296pt 宽下拉面板）

源码：`App/MenuBarPanel.swift`（面板容器）、`Views/MenuView.swift`（内容）。

### 2.1 面板容器（`MenuBarPanel` = borderless NSPanel）

- 宽 296、圆角 12、顶部对齐锚点按钮下方 2pt、最大高 = 屏幕可视高 90%（`MenuBarPanelLayout`）。
- 关闭条件：Esc(keyCode 53)、点击其他窗口、全局点击；内容超高时内部 `ScrollView`（可滚动高 = 最大高 − 56 chrome）。
- Windows 映射：`ContextMenuStrip` 太弱——建议 WPF `Popup`/无边框 `Window` + `Deactivated` 关闭 + `HwndSource` 定位到 NotifyIcon 屏幕坐标。

### 2.2 信息架构（自上而下）

```
┌ 顶部统计行：「2 Providers · 5 Models」 · 「Updated 3m ago」(30s 刷新) · [↻ 刷新按钮(loading=hourglass)]
├ Provider 分区 ×N（按 providerOrder 排序，可折叠，点标题行切换）
│   ├ Provider 头：[▸/▾] logo 名字 · 来源摘要(OAuth/Cloud/Mix…) · 右侧=最新采样时间 · 当前账号剩余%
│   ├ (GLM) 可用重置行：「可用重置 · 5h ×2 · 周 ×1」+ 最近到期时间
│   ├ (Codex) 当前账号头（首位置强制置顶）+ CodexLocalUsageMenuCard（本机用量卡：token/时长）
│   ├ 账号分组头 ×M（Codex 可折叠：当前账号默认展开其余收起；右侧=来源图标 · 剩余%：<10 红 / <25 橙）
│   │   └ cycle 切换器（5h / Weekly 胶囊按钮，>1 个窗口才显示；选择按账号持久化）
│   ├ 模型行 ×K（排序：5h→Weekly→Spark短→Spark周→短窗口→其余；账号名→优先级→重置时间→名字）
│   │   ├ 头行：模型名 · 右侧大号剩余文本（"74%" / "12/30"）
│   │   ├ 图表区(84pt 高)：QuotaAreaChart 面积曲线（样本、警告虚线、匀速参考线、≤5 条消耗预测虚线、hover 十字+callout）
│   │   │   或 6pt 胶囊进度条（周窗口含本地 0:00 日分隔线 + pace 指针条纹 3 段式，hover 显示 MM/dd 日标签）
│   │   └ 元数据行：周期种类 · 「周 12/30」/「周无限制」 · pace 标签(onTrack/ahead=红/behind=灰) · 「resets 10/05 11:14」
│   ├ 底部跨周期 utilization 柱图（短窗口 30 个 cycle / 长窗口 12 个；hover 历史 cycle 预览该窗口曲线）
│   ├ 「展开 N 个已用完模型」折叠组（exhausted）
│   └ 「展开 N 个未使用模型」折叠组（full quota unused；未展开时单行可点击展开）
├ 供应商错误区（有数据 provider 之外的错误行：⚠ + provider: 错误描述）
├ Divider
└ Footer：[Settings] … [新版 1.2.3 ↗(有更新时)] … [Quit]
```

- 空态占位卡（`MenuPlaceholderCard`，圆角 10 卡片：图标+标题+说明+主/次按钮）按优先级：
  1. 无任何凭据且无云同步 → 「从一个供应商开始」+ 先看示例预览（`LocalUsageSamplePreview`）；
  2. 云同步已配置等历史 → 「等待云端记录」；
  3. 全部隐藏但有用量 → 「左键菜单已全部隐藏」；
  4. 仅 Codex 已配置无数据 → 「等待 Codex」；
  5. 全部 provider 暂停 → 「已暂停」；6. 无 API key → 配置提示；7. loading → 转圈；8. error → 错误+刷新；9. 空模型 → 刷新。
- 悬停气泡层（`MenuTooltipLayer`）：provider 头、账号头、cycle 按钮、更新按钮各有自定义 tooltip 气泡（多行）。
- GLM/MimiMax/Kimi 的账号分组头不可折叠（折叠语义只属于 Codex）；账号排序：本机/Mix 优先 → Cloud 按采样时间倒序 → 无名分组最后。

### 2.3 折叠行为

- **provider 分区折叠**：`leftClickMenuDisplayPreferences.collapsedProviders`（UserDefaults JSON 持久化，手动点击与跟随模式自动收起共用同一集合，最后一次操作生效）。
- **Codex 账号分组折叠**：内存态 `accountCollapseOverrides`，默认「当前账号展开、其余收起」，切换登录账号时清空（不持久化）。
- **已用完/未使用模型组**：内存态，默认收起。

### 2.4 Follow running apps（跟随运行中的应用）

源码：`Services/ProviderAppPresence.swift`、`UsageViewModel`。

- **检测机制**：`NSWorkspace.shared.runningApplications` 快照 + 监听 `didLaunchApplicationNotification`/`didTerminateApplicationNotification` 增量刷新（启动时全量，之后事件驱动）。
- **匹配规则**（`ProviderAppMatcher`，bundle ID 精确(小写) + bundle ID 片段包含 + 进程名精确(小写 trim)）：

| Provider | bundle IDs | 片段 | 进程名 |
|---|---|---|---|
| codex | `com.openai.codex`, `com.openai.chatgpt.codex`, `com.openai.chat` | `codex` | `chatgpt`, `codex` |
| kimi | `com.moonshot.kimichat` | — | `kimi` |
| miniMax | `com.minimax.agent.cn`, `com.minimax.agent` | — | `minimax code`, `minimax` |
| glm (ZCode) | `dev.zcode.app` | — | `zcode` |

- **作用**（不影响配额刷新与设置页）：
  - 菜单栏：`isProviderDisplayedInMenus` = 已启用 &&（未开跟随 || 应用在运行）；全部被隐藏 → `placeholder` 占位。
  - 左键菜单：未运行的 provider 区自动收起（不删除）；增量 `handleAppPresenceChanged` 只动状态变化的供应商。
  - 右键 Clash 面板：Codex 未运行时 routes/connections 自动收起 + 暂停连接后台轮询与连通性探测（`updateClashWorkGating`）。
- Windows 映射：`Process.GetProcessesByName` 轮询（建议 2s + `SystemEvents`/WMI `Win32_ProcessStartTrace` 可选），进程名匹配表：`chatgpt/codex、kimi、minimax code/minimax、zcode`。

### 2.5 Provider 排序设置

- `LeftClickMenuDisplayPreferences.customProviderOrder`（JSON，仅用户调过顺序才持久化；nil = 默认 `[codex, kimi, glm, miniMax]`）。
- 设置页（Display tab）「左键菜单顺序」区提供每家上移/下移按钮 + 「恢复默认」；调回默认时清掉存储。
- 同一偏好对象还存 `hiddenAccounts` / `hiddenModels` / `collapsedProviders`（见 §6）。

---

## 3. 右键面板（ClashPopoverView，宽 296 的 NSPanel；不是 NSMenu）

> 注意：本项目右键**不是传统菜单**，而是与左键同规格的面板，内容为任务保护/账号切换/路由/连接四个分区。

源码：`App/ClashRoutePopoverController.swift`、`Views/ClashPopoverView.swift`、`ClashRoutePopoverView.swift`、`ClashConnectionPopoverView.swift`、`CodexProtectionPopoverView.swift`、`CodexAccountSwitchPopoverView.swift`。

### 3.1 分区结构（自上而下，均可单独折叠，折叠态持久化）

1. **任务保护（Codex Protection，高 193 固定）**：头部 + 保持唤醒开关 / 防屏保行 + 合盖保护行（安装状态）+ 「暂时离开」行（触发全屏调暗）。
2. **账号切换（Accounts，弹性高）**：当前账号行（名称+邮箱+配额）+ 暂存账号列表（stash，来自 `~/.codex/accounts/`）+ 旧备份文件行 + 登录入口 + 状态行。
3. **路由（Routes，固定高 334，收起 30）**：Clash 路由列表（过滤框 + 自动测速 + 选择切换 + 恢复历史）。
4. **连接（Connections，弹性高）**：上下行速率指标卡 + 活动图（78pt）+ 活动连接表（host/network/route/duration/速率）+ 底部状态行。

面板高度求解（`ClashPopoverLayout.resolveSectionHeights`）：基准 850；超出屏幕先压账号区(≥80) → 再压连接列表(≥0 保 chrome) → 最后账号压到标题行(30)。展示时展开的 connections 开启 live 轮询，收起即停；展开 routes 补一次自动测速。

### 3.2 入口与交互

- 右键快击打开（自动测速）；长按右键 0.6s = step-away dim；Esc/外部点击关闭；通知点「打开路由」也会调 `showClashRoutes()`。
- 折叠状态 `clashPanelDisplayPreferences`（JSON，accounts/routes/connections 三 section 集合）；跟随模式下 Codex 未运行时 routes/connections 自动置为收起。
- 连通性自动恢复：Codex 配置且连通性探测连续 2 次 unreachable → `attemptAutomaticRecovery`（切最优路由）→ 成功发通知 / 需要注意弹本面板。

### 3.3 Windows 映射

右键 → NotifyIcon `MouseRightClick` 弹出与左键同类的无边框 WPF 窗口（不要用 ContextMenuStrip，内容是富交互分区）；长按判定用 `Stopwatch` + 全局鼠标 hook 或省略（改为面板内按钮触发 dim）。

---

## 4. 设置窗口（SettingsWindowController + PreferencesView）

- 无边框透明标题栏 `.preference` 风格窗口，**固定 792×638**（`PreferencesTab.providersWidth/windowHeight`），TabView 6 页；无凭据且无云同步时自动跳到 Providers 页。
- 页签（`PreferencesTab`）：general（gearshape）/ display（slider，标题「模型与显示」）/ usage（chart）/ mobile（iphone，手机看板）/ providers（grid）/ about（info）。

### 4.1 General 页

| 设置项 | 存储 key | 类型/选项 | 默认 | 作用 |
|---|---|---|---|---|
| 语言 | `appLanguage` | String: `en` / `zh-Hans` | 英文 | 全 app 文案语言（中/英双语） |
| 登录时启动 | `launchAtLogin` | Bool | false | SMAppService 开机自启 |
| 菜单栏外观 | `menuBarAppearance` | `detailedText`/`compactRing` | detailedText | §1.1 |
| （文字模式）显示内容 | `menuBarContentSelection` | all/automatic/codex/kimi/minimax | automatic | 文字模式选 provider |
| （环模式）环显示模式 | `menuBarRingDisplayMode` | all/automatic | automatic | §1.7 |
| （环模式）显示的供应商 | `menuBarRingSelectedProviders` | [String] | 全部4家 | 勾选集合（最后一家不可取消） |
| 节奏显示精度 | `menuBarPaceDisplayMode` | staged/continuous | staged | §1.3 扇形填充映射 |
| 任务波布局 | `menuBarTaskWaveLayout` | evenlySpaced/chaseQueue | evenlySpaced | §1.4 |
| 每家供应商 外环/中心 窗口 | `menuBarProviderRingWindows` | JSON `{provider:{outer,center}}` | 空(跟随全局) | per-provider 覆写；全局默认 `menuBarRingQuotaWindow`=current、`menuBarReserveQuotaWindow`=synchronized |
| 紧凑布局 水平留白 | `menuBarCompactHorizontalPadding` | Double 0–8 | 0 | 环条左右 padding（pt） |
| 紧凑布局 环间距 | `menuBarCompactRingSpacing` | Double 0–8 | 1 | 环间 spacing（pt） |
| 暂时离开 遮罩浓度 | `stepAwayShadeOpacityPercent` | Double 60–100 | 90 | step-away 全屏黑罩不透明度 |
| 匿名使用统计 | `anonymousAnalytics.enabled` | Bool | false | 匿名遥测；「停止并删除本机统计」按钮 |
| 退出按钮 | — | — | — | terminate |

### 4.2 Display 页（模型与显示）

| 设置项 | 存储 key | 类型 | 默认 | 作用 |
|---|---|---|---|---|
| 跟随运行中的应用 | `menuFollowsRunningApps` | Bool | false | §2.4 |
| 菜单栏占位形态 | `menuBarPlaceholderStyle` | openAIConnectivity/providerCount/brandMark | openAIConnectivity | §1.6 |
| 左键菜单 provider 顺序 | `leftClickMenuDisplayPreferences` 内 `customProviderOrder` | JSON | nil(默认顺序) | §2.5 |
| 模型矩阵（按账号分组） | `leftClickMenuDisplayPreferences` 内 `hiddenAccounts`/`hiddenModels`；`quotaChartDisplayPreferences` | JSON | 全显示 | 每账号「菜单显示」总开关、每模型 菜单/手机/图表样式 三列；图表样式 automatic/areaChart/progressBar |
| 手机看板选择联动 | `mobileDashboardSelectedModels` | JSON [SelectionKey] | 自动初始化(≤2) | §5 |

### 4.3 Usage 页

| 设置项 | 存储 key | 类型/选项 | 默认 | 作用 |
|---|---|---|---|---|
| 团队区（TeamSettingsSection） | `localUsage.reporting` 等 | — | — | 创建/加入团队、共享本机用量、共享账号额度(`cloudSyncEnabled`)、团队摘要图表、成员口令、同步状态（详见 cloud-team.md） |
| 本机用量区（CodexLocalUsageSection） | — | 只读+刷新 | — | 本月/24h token 统计、按模型、扫描状态、存储占用 |
| 低额度警告 | `warningThresholdEnabled` + `warningThreshold` | Bool + Double 1–100 | false / 20 | 启用后剩余% ≤ 阈值时：菜单栏环变琥珀 + 弹 WarningPanel（HUD 右下角 280×120） |
| 刷新间隔 | `refreshInterval` | Int 秒: 30/60/120/300/600/900/1800/3600 | 600 | 自动刷新周期 |
| 启动时刷新 | `autoRefreshOnLaunch` | Bool | true | — |
| 利用率历史模式 | `utilizationHistoryMode` | includeCurrent/completedOnly | (includeCurrent) | 柱图是否计入当前未完周期 |
| 消耗预测回看 | `quotaForecastLookbackIntervals` | Int 1–5 | (见默认) | 预测线使用的刷新间隔数 |
| 云数据可见性(在其它 key) | `cloudCurrentWindowVisibilityLimit` / `cloudShortCyclesVisibilityLimit` / `cloudWeeklyCyclesVisibilityLimit` | oneHour/fiveHours/oneDay/oneWeek/never | (默认见源码 CloudDataVisibilityLimit) | 云端快照/周期在 UI 的展示时效 |
| 云数据保留 | `cloudDataRetentionLimit` | Int 7/14/30/60/90/180 | 0 (=默认档) | 本地保留云端历史时长 |

### 4.4 Mobile（手机看板）页

| 设置项 | 存储 key | 类型/选项 | 默认 |
|---|---|---|---|
| 启用手机看板 | `mobileDashboardEnabled` | Bool | false |
| 看板模型选择（1–2 个） | `mobileDashboardSelectedModels` | JSON | 自动 |
| 需要配对码 | `mobileDashboardRequiresPairingCode` | Bool | false（新旧安装均默认关） |
| 分享任务进度文本 | `mobileDashboardShareTaskProgressText` | Bool | false（且强制依赖配对码开启） |
| 掩码账号名 | `mobileDashboardMasksAccountNames` | Bool | true |
| 颜色方案 | `mobileDashboardColorScheme` | auto/dark/light | auto |
| 待机黑屏跑马灯 | `mobileDashboardIdleBlackoutMarqueeEnabled` | Bool | true |
| OLED 保护 | `mobileDashboardOLEDProtectionEnabled` | Bool | true |
| 活动背景效果 | `mobileDashboardActivityBackgroundEffect` | grainyDigitalRain/dotWaves/taskTelemetryMarquee | grainyDigitalRain |
| 遥测字段（跑马灯时） | `mobileDashboardTaskTelemetryFields` | [20 个枚举] | 全选 |
| 实验性唤醒媒体 | `mobileDashboardExperimentalWakeMediaEnabled` | Bool | false |
| 二维码/链接/复制/重置链接、IP 备用地址列表、手动配对码(8位 5 分钟) | —（token 在 Keychain） | UI | — |

### 4.5 Providers 页（左列表 200pt + 右详情）

- 每家：监控开关（`pausedUsageProviders`，暂停时保留凭据）+ 凭据输入（SecureField + 测试 + 保存，存 Keychain）。
- Codex：数据来源 `codexSourceMode`(auto/oauth/cli/web)、账号切换退出模式 `codexAccountSwitchExitMode`(manual/automatic)、账号列表（刷新/登出/移除，`~/.codex/auth.json` + accounts/ 暂存）、「关注」区（`codexWatch.isSharing`、共享名单 `codexWatch.shared.v1`、关注列表 `codexWatch.watched.v1`）。
- Kimi：额度来源 `kimiSourceMode`(auto/desktop/cli/web) + 浏览器/站点高级选项 + API 凭据；`kimiSavedWebSessionAvailable`、`kimiLastSuccessfulSource`。
- GLM：凭据（`GLMCredential` 解析）+ 打开 bigmodel.cn 用量页链接。MiniMax：凭据。

### 4.6 About 页

版本号、检查更新（`lastAutomaticUpdateCheckAt`/`cachedAppUpdateRelease`/`lastAppUpdateAttempt`/`lastNotifiedUpdateVersion`）、反馈表单（昵称/内容/联系方式）、退出。

---

## 5. 移动端仪表板（手机看板）

### 5.1 服务生命周期（`MobileDashboardService`）

- 启用后：异步从 Keychain 读 bearer token（`mobileDashboardAccessToken`，32 字节随机 base64url；缺失则生成保存），随后 `server.start(port: 18765, …)`。
- **端口固定 18765**（`defaultPort`），TCP 监听所有接口（NWListener，`allowLocalEndpointReuse`）；**入站端点限局域网**：`isAllowedLocalEndpoint` 只接受 loopback / 私有 / link-local 对端，公网 peer 直接拒连。
- 状态机 `off → starting → ready(port) / failed(msg)`；`viewerCount` = 活跃 SSE 连接数；地址 = `http://<LocalHostName>.local:18765/`（Bonjour 主名，SCDynamicStore 监听改名），备用 = 各私有 IPv4。
- 有 viewer 时：1s 循环构造快照 → 内容变化才 SSE 广播（否则 20s 心跳 `: heartbeat`）；每 15s 刷新 Clash 路由（测速 ≥5min 一次）；viewer 清零 15s 宽限后停止广播循环并触发 Clash 连接 live 轮询停止。
- 网络变化（NWPathMonitor + 主机名监听）→ 重算访问 URL。

### 5.2 REST / SSE 端点（`MobileDashboardHTTPServer`，自研 HTTP/1.1）

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/api/v1/health` | 无（CORS 白名单校验 Origin） | `{"requiresPairingCode":bool,"status":"ok"}`，供手机探测地址 |
| GET | `/api/v1/events` | `Authorization: Bearer <token>`（常数时间比较） | **SSE** `text/event-stream`，`data: <快照JSON>`；retry:3000；上限 8 viewer（超出 429 `viewer_limit_reached`, Retry-After 15）；响应带 `X-AI-Quota-Server-Instance` |
| POST | `/api/v1/pwa/bootstrap` | Bearer + 严格同源 | 签发 bootstrap nonce cookie（`ai_quota_pwa_bootstrap`, HttpOnly SameSite=Strict, 1h）+ install credential cookie（`ai_quota_pwa_install`, 30 天） |
| POST | `/api/v1/pwa/claim` | 同源；无配对码模式直接发 token；有配对码模式需 bootstrap/install 凭据 | 返回 `{token}` 供 PWA 安装态使用 |
| POST | `/api/v1/pwa/manual-claim` | 无 cookie/authorization（刻意）；Content-Type 必须 application/json；body ≤256B | body `{"code":"12345678"}` → `{serverInstanceID, token}`；错误码 `pairing_disabled/credentials_not_allowed/invalid_request/unsupported_media_type/invalid_pairing_code(401)/pairing_rate_limited(429)/pairing_unavailable(503)` |
| GET/HEAD | `/`, `/app.css`, `/app.js`, `/manifest.webmanifest`, `/icon-192.png`, `/icon-512.png`, `/icon-maskable-512.png`, `/apple-touch-icon.png`, `/wake-ambient.mp4`(支持 Range) | 静态资源（内嵌 bundle） | `/` 按当前 colorScheme 重写 4 处 meta；CSP/安全头见下 |
| GET | `/api/v1/watch/quota` | — | 保留路由（关注通道占位，当前直接返回） |
| OPTIONS | health/manual-claim/events | — | 受限 CORS 预检（仅本机地址 origin + 指定 header） |

**安全边界**（迁移必须保留）：
- 只读：非 GET/HEAD 一律 405 "This dashboard is read-only."；无任何写端点。
- 安全响应头：`Content-Security-Policy`（default-src 'none' + 白名单）、`X-Content-Type-Options: nosniff`、`Referrer-Policy: no-referrer`、`Cross-Origin-Resource-Policy`、`Permissions-Policy`（仅 screen-wake-lock(self)）。
- 限制：连接 ≤32、viewer ≤8、请求头 ≤16KB、body ≤1KB、头超时 8s、拒绝 Transfer-Encoding/pipelining/Range 滥用。
- CORS：敏感端点仅允许「当前访问主机名/本机地址 + 服务端口」的 origin；manual-claim 允许跨源（配对场景）但无凭据。
- 掩码：`masksAccountNames=true` 时账号名替换为掩码形式（MobileDashboardAccountPrivacy）。

### 5.3 QR 配对流程

1. 主机生成 **8 位数字短码**（均匀采样 UInt32 取模 10^8，5 分钟有效 `manualPairingCodeLifetime`），设置页大字显示（每秒倒计时）+ 可复制 + 可刷新。
2. 手机扫码得到 `http://host.local:18765/#token=<bearer>`（token 走 URL fragment，不落服务器日志）或直接访问地址后进入 gate 界面输入 8 位码。
3. 手机 POST `/api/v1/pwa/manual-claim` {code} → 校验通过返回 `{serverInstanceID, token}` → 前端存 `localStorage["aiQuotaBar.mobileDashboard.token"]` → EventSource 带 Bearer 连 `/api/v1/events`。
4. 短码防爆破（`MobileDashboardManualPairingBroker`）：单 peer 5 次/5min、单 client(peer+origin) 5 次/5min、全局 20 次/5min 失败即 429（Retry-After）；同一时刻锁定单个 client（后到者拒绝）；成功兑换上限 3 次后需刷新码；比较为常数时间（不泄露码存在性）。
5. PWA install credential：`PWAInstall <base64>` scheme，绑定 origin + token + installID，30 天有效，token 轮换即失效（重置访问链接会撤销所有已发凭据）。

### 5.4 SSE 快照 JSON（schemaVersion 4）

`MobileDashboardEventEnvelope`：`{oledProtectionEnabled, experimentalWakeMediaEnabled, activityBackgroundEffect, taskTelemetryFields[], colorScheme, idleBlackoutMarqueeEnabled, snapshot}`。

`MobileDashboardSnapshot` 顶层：`schemaVersion:4, generatedAt, language, macName, appVersion, connectivity(unknown/reachable/unreachable), menuBar{state,providerID,modelName,remainingPercent,ringPercent,paceDeltaPercent,resetsAt,isLowQuota,appearance,paceDisplayMode}, quota{state(loading/ready/error/empty), lastRefreshAt, primaryRemainingPercent, warningThresholdPercent, errors[], providers[]}, activitySummary{state,activeTaskCount,oldestStartedAt,elapsedSeconds,lastActivityAt,phase,toolCategory,toolStatus,progressLines?,recentEvents[],tasks[]{state,title?,projectName?,gitBranch?,source,model,modelProvider,reasoningEffort,sandboxPolicy,approvalMode,tokensUsed,activeSubtaskCount,subtaskNames?,createdAt,startedAt,elapsedSeconds,lastActivityAt,cliVersion,phase,toolCategory,toolStatus,progressLines?,recentEvents[]},activeProviders[]}, protection{isEnabled,activeTaskCount,hasActiveTasks,status(idle/active/failed),keepDisplayAwake,preventScreenSaver,hookStatus,hookActionRequired,closedLidEnabled,closedLidStatus,closedLidActionRequired,lastActivityAt}, route{state,groupName,selectedRouteName,selectedRouteType,selectedRouteDelay,clientName,autoRecoveryEnabled,isSpeedTesting,lastTestedAt,recentSwitches[]}, connections{state,observedAt,clientName,isLive,uploadBytesPerSecond,downloadBytesPerSecond,activeCount,longestActiveDuration,history[]{timestamp,connectionCount,oldestConnectionAge,connectionAges[]},active[]{host,network,route,duration,uploadBytesPerSecond,downloadBytesPerSecond}}`。

`providers[]`（MobileProviderQuotaSnapshot）：`{id,name,subscriptionTitle,subscriptionEndsAt,models[]}`；`models[]`（MobileModelQuotaSnapshot）：`{displayOrder,isPrimary,accountName(可掩码),modelName,plan,source,detail,remainingText,remainingPercent,total,remaining,startsAt,resetsAt,resetText,isShortWindow,cyclesKind(short/weekly/monthly),isExhausted,isFull,isCurrentIntervalPercentMode,usesReverseProgressTint,rendersAreaChart,hasCurrentIntervalPace,paceStage,paceGuideTone,paceGuideExpectedUsedPercent,paceGuideExpectedRemaining,paceGuideShowsMarker,weeklyTotal,weeklyRemaining,weeklyRemainingPercent,weeklyUnlimited,paceDeltaPercent,sampledAt,samples[]≤240(等距降采样 {timestamp,remaining,remainingPercent}),consumptionForecasts[]{lookbackIntervals,consumptionPerSecond,startsAt,startingRemaining,exhaustsAt},cycles[]{resetsAt,usedPercent}}`。

隐私：任务标题/项目/git 分支/子任务/进度行只有 `shareTaskProgressText && requiresPairingCode` 才输出，否则字段为 null；payload 限制：活动连接 ≤100 条、每样本连接年龄 ≤100、连接不含进程路径等内部标识。

### 5.5 PWA 前端资源（`Resources/MobileDashboard/`）

文件：`index.html`(176 行)、`app.js`(5146 行, 纯原生 JS)、`app.css`(2024 行)、`manifest.webmanifest`（id "/", name "AI Quota", standalone, 黑底）、`icon-192/512/maskable-512.png`、`apple-touch-icon.png`、`wake-ambient.mp4`（活动时环境视频，支持 Range）。
页面结构：masthead（机器名 + live 状态）→ pairing gate（8 位码输入 / 已存地址列表）→ dashboard：task-hero（活动大区：wake 视频 + 数字雨 canvas / 点波 / 遥测跑马灯 + 状态文案 + 遥测行）→ quota 区 → protection ticker → route/connections 区。前端常量：`EVENTS_PATH/HEALTH_PATH/PWA_BOOTSTRAP_PATH/PWA_CLAIM_PATH/MANUAL_CLAIM_PATH`、token 存 localStorage。
**迁移结论：前端可原样复用**（纯静态资源 + SSE），只需 C# 侧实现相同端点与 envelope。

### 5.6 测试（`Tests/MobileDashboard/`）

- `MobileDashboardStartupTests`：token 异步读延迟/不存在生成保存/已存在不覆盖/Keychain 失败不启动/配对策略切换不轮换主 token/任务文本分享默认关且依赖配对/启动期间改隐私设置不重启。
- `MobileDashboardSecurityTests`（≈40 用例）：主机名/Bonjour 校验、账号掩码默认开、选择键不泄露账号、envelope 白名单值、进度文本结构级省略、activeProviders 推导、bearer 精确比较、header 解析、Range 严格解析、PWA claim 严格同源、bootstrap cookie 解析、nonce 强度、broker 一次性/过期/上限、手动配对过期/锁定/限速/全局预算、install credential 绑定 origin/过期/被轮换吊销、仅本机 peer 可连、公开 peer 拒绝、静态资源可读、唤醒视频小/无声/faststart。
- `MobileDashboardFrontendTests`：前端 install 身份与紧凑看板契约、OLED 与 schema 钩子存在。

---

## 6. 数据持久化

### 6.1 UserDefaults（`com.techfanseric.aiquotabar` domain）完整清单

**通用（UsageViewModel）**
| key | 类型 | 默认 | 作用 |
|---|---|---|---|
| `refreshInterval` | Int | 600 | 刷新间隔秒 |
| `warningThreshold` | Double | 20（>0 才读） | 低额阈值 |
| `warningThresholdEnabled` | Bool | false | 阈值开关（effectiveWarningThreshold 未启用=0） |
| `autoRefreshOnLaunch` | Bool | true | 启动即刷新 |
| `appLanguage` | String | en | 语言 |
| `launchAtLogin` | Bool | false | 开机自启 |
| `usageProvider` | String | —（迁移遗留） | 旧单 provider 选择（chatgpt→codex 迁移用） |
| `pausedUsageProviders` | [String] | [] | 暂停的供应商（凭据保留） |
| `menuFollowsRunningApps` | Bool | false | 跟随运行应用 |
| `accountQuotaCycleChoices.v1` | [String:String] | {} | 账号→选中 cycle 窗口名 |
| `utilizationHistoryMode` | String | includeCurrent | 柱图含当前周期 |
| `quotaForecastLookbackIntervals` | Int | 3（1–5） | 预测回看 |
| `cloudCurrentWindowVisibilityLimit` / `cloudShortCyclesVisibilityLimit` / `cloudWeeklyCyclesVisibilityLimit` | String | (源码默认档) | 云端快照时效 |
| `cloudDataRetentionLimit` | Int | 0 | 云历史保留天数(7/14/30/60/90/180) |
| `menuBarContentSelection` | String | automatic | 文字模式 provider |
| `menuBarAppearance` | String | detailedText | 外观模式 |
| `menuBarPaceDisplayMode` | String | staged | pace 精度 |
| `menuBarTaskWaveLayout` | String | evenlySpaced | 任务波布局 |
| `menuBarRingQuotaWindow` | String | current | 全局外环窗口 |
| `menuBarReserveQuotaWindow` | String | synchronized | 全局内环窗口 |
| `menuBarProviderRingWindows` | Data(JSON) | 空 | per-provider 窗口覆写 |
| `menuBarRingDisplayMode` | String | automatic | 环集合模式 |
| `menuBarRingSelectedProviders` | [String] | 全部 | 环显示集合 |
| `menuBarPlaceholderStyle` | String | openAIConnectivity | 占位形态 |
| `menuBarCompactHorizontalPadding` | Double | 0 | 环条留白 |
| `menuBarCompactRingSpacing` | Double | 1 | 环间距 |
| `leftClickMenuDisplayPreferences` | Data(JSON) | `{hiddenAccounts:[],hiddenModels:[],collapsedProviders:[],customProviderOrder:null}` | §2.5 |
| `quotaChartDisplayPreferences` | Data(JSON) | `{overrides:{}}` | 每模型图表样式 |
| `clashPanelDisplayPreferences` | Data(JSON Set) | [] | 右键面板折叠 sections |
| `clashRouteFilterQuery` / `clashRouteFilterUsesRegularExpression` / `clashRouteAutoSelectBest` / `clashRouteLastRecoveryAttempt` | String/Bool/Bool/Date | ""/false/false/— | 路由过滤与自动恢复 |
| `clashRouteSwitchHistory` | Data(JSON) | — | 路由切换历史 |

**手机看板（MobileDashboardService）**：`mobileDashboardEnabled`(false)、`mobileDashboardMasksAccountNames`(true)、`mobileDashboardIdleBlackoutMarqueeEnabled`(true)、`mobileDashboardOLEDProtectionEnabled`(true)、`mobileDashboardExperimentalWakeMediaEnabled`(false)、`mobileDashboardActivityBackgroundEffect`(grainyDigitalRain)、`mobileDashboardTaskTelemetryFields`(全选)、`mobileDashboardColorScheme`(auto)、`mobileDashboardRequiresPairingCode`(false)、`mobileDashboardShareTaskProgressText`(false)、`mobileDashboardSelectedModels`(Data JSON)。废弃：`mobileDashboardShowsFullAccountNames`(故意不迁移)。

**其它服务**：`codexSleepProtectionEnabled`/`codexSleepProtectionKeepDisplayAwake`/`codexSleepProtectionPreventScreenSaver`(false)、`codexSleepProtectionAllowClosedLid`(false, Power)、`closedLidDimSavedBrightness`(临时)、`codexSourceMode`(auto)、`codexAccountSwitchExitMode`(manual)、`kimiSourceMode`(auto)、`kimiLastSuccessfulSource`、`kimiSavedWebSessionAvailable`(false)、`codexWatch.isSharing`/`codexWatch.shared.v1`/`codexWatch.watched.v1`/`codexWatch.grants.v1`(遗留)、`cloudSyncEnabled`(false)/`cloudSyncDeviceID`/`cloudSync.lastStatusSnapshot.v1`/`cloudSyncEndpointURL`(已废弃写)、`localUsage.reporting`(false)/`localUsage.connection`(JSON)/`localUsage.prices`(JSON)/`localUsage.lastUploadConfirmedAt`、`anonymousAnalytics.enabled`(false)/`.token`/`.lastActive`/`.lastPulse`、`lastAutomaticUpdateCheckAt`/`cachedAppUpdateRelease`/`lastAppUpdateAttempt`/`lastNotifiedUpdateVersion`、`keychainConfiguredProviderKeys`([String] 凭据仓库已配置集合缓存)、`stepAwayShadeOpacityPercent`(90)、`stepAwayDimSavedLevels`(Data 临时)、`didMigrateDefaultsFromLegacyBundle`/`codexMigration_v1`(迁移标记)、菜单栏旧 key `menuBarPlaceholderShowsCount`(废弃不读)。

### 6.2 Keychain（service `com.techfanseric.aiquotabar`）

- 供应商凭据（provider → 凭据，经 `UsageService.prepareCredentialForStorage` 处理后存）。
- `mobileDashboardAccessToken`（看板 bearer token）、`cloudSyncToken`。
- Windows 映射：DPAPI（`ProtectedData.CurrentUser`）或 Windows Credential Manager（`CredentialManager.Write`）。

### 6.3 其它落盘文件

| 路径 | 格式 | 内容 |
|---|---|---|
| `~/Library/Application Support/com.techfanseric.aiquotabar/samples/{provider}.json` | JSON | 每模型额度采样（曲线数据，`ModelQuotaSampleStore`） |
| `…/com.techfanseric.aiquotabar/sync-queue/<binding>/<uuid>.json` | JSON | 云同步待上传队列（按团队绑定分目录，`CloudSyncQueue`） |
| `…/com.techfanseric.aiquotabar/clash/openai-connection-history.json` | JSON | Clash 连接历史 |
| `~/.codex/auth.json`、`~/.codex/accounts/*.json` | JSON | Codex 登录与账号池（原子改名切换） |
| `~/.codex/sessions/**`（只读）、Kimi/MiniMax/ZCode 各自数据目录 | — | 活动探测数据源 |
| Codex 本机用量数据库/日志（`CodexLocalUsageModel`） | SQLite/日志 | 详见 codex-local-usage 文档 |
| Windows 映射 | — | `%APPDATA%\ai-quota-bar\`（samples/sync-queue/clash），凭据走 DPAPI |

---

## 7. Windows (C# .NET 8) 映射建议汇总

| macOS | Windows |
|---|---|
| `NSStatusBar.system.statusItem` + 自定义子视图 | WinForms `NotifyIcon`（`Icon` 动态生成：文字模式用 GDI+ 双行位图；环模式逐帧 `Bitmap` + `Timer` 30/12fps 换帧）或 WPF 托盘（Hardcodet.NotifyIcon.Wpf / TrayIcon.Core）。NotifyIcon 只有一张图标 → 环模式需把整条多环渲染进一张位图 |
| 左键 NSMenu 内嵌 SwiftUI | 无边框 WPF `Window`（`ShowActivated=false, WindowStyle=None, AllowsTransparency`）+ `Deactivated`/全局钩子关闭；296pt 宽度与分区结构 1:1 复刻，图表用 `Canvas`/ScottPlot 或自绘 |
| 右键 NSPanel（Clash 面板） | 同上另一窗口；`MouseRightClick`/`MouseUp` 区分；长按 dim 用 `Stopwatch` |
| `NSWorkspace.runningApplications` + 通知 | `Process.GetProcessesByName` 轮询 2s（或 WMI Win32_ProcessStartTrace/StopTrace 事件）；匹配表见 §2.4 |
| `NSApp.setActivationPolicy(.accessory)` | WinForms 无此问题（默认无主窗口 + `ShowInTaskbar=false` + `ApplicationContext`） |
| UNUserNotificationCenter | `System.Windows.Forms.NotifyIcon.ShowBalloonTip` 或 Windows Toast（`Microsoft.Toolkit.Uwp.Notifications`） |
| Keychain | DPAPI / Credential Manager |
| UserDefaults | `Microsoft.Extensions.Configuration` JSON（`%APPDATA%\ai-quota-bar\settings.json`）——建议把 §6.1 表整体搬为强类型 Options，保持相同默认值 |
| NWListener HTTP/SSE | `HttpListener`（prefix `http://+:18765/`）或 Kestrel；SSE 用 `Response.ContentType=text/event-stream` + flush；端点/安全头/限流按 §5.2 逐条移植 |
| Bonjour `host.local` | Windows 对 mDNS 支持有限：主地址建议直接用 IPv4（`NetworkInterface.GetAllNetworkInterfaces` 过滤私网），`hostname.local` 可作尽力而为项 |
| SCDynamicStore 主机名监听 | `NetworkChange.NetworkAddressChanged` |
| CIFilter QRCodeGenerator | `QRCoder` NuGet |
| DDC 显示器调暗 / StepAwayDim | 全屏黑罩 WPF Topmost 窗口即可（opacity 默认 90%）；DDC 用 `VCPMonitor`/WMI 可选 |
| 减弱动态 `accessibilityDisplayShouldReduceMotion` | `SystemParameters.ClientAreaAnimation` 或应用内开关 |
| SMAppService 登录启动 | Registry `HKCU\...\Run` 或 `StartupTask`（打包 MSIX 时） |

### 迁移优先级建议

1. **P0**：托盘图标（两种模式 + 状态机着色）、左键面板（provider/账号/模型三级 + 曲线）、设置窗口与全部设置项、JSON 配置存储。
2. **P1**：手机看板（HTTP/SSE 服务可近乎直接移植契约）、QR 配对 + 手动短码、follow running apps。
3. **P2**：任务能量波/自检动画、Clash 路由/连接面板（依赖 Clash API 分析文档）、step-away dim、OLED/跑马灯等装饰项。

---

## 附：关键源码文件索引

- 菜单栏：`AIQuotaBar/App/StatusBarController.swift`（2010 行）、`AIQuotaBar/Models/QuotaSymbolRenderer.swift`、`AIQuotaBar/Models/MenuBarDisplayPreferences.swift`
- 左键面板：`AIQuotaBar/App/MenuBarPanel.swift`、`AIQuotaBar/Views/MenuView.swift`（2190 行）
- 右键面板：`AIQuotaBar/App/ClashRoutePopoverController.swift`、`AIQuotaBar/Views/ClashPopoverView.swift`、`AIQuotaBar/Services/Clash/ClashPanelDisplayStore.swift`
- 视图模型：`AIQuotaBar/ViewModels/UsageViewModel.swift`（2448 行，statusBarText/menuBarSnapshots/折叠/跟随）
- 设置：`AIQuotaBar/Settings/`（PreferencesView + 6 Panes + 15 Components）
- 手机看板：`AIQuotaBar/Services/MobileDashboard/MobileDashboardService.swift`（1222）、`MobileDashboardHTTPServer.swift`（2839）、`MobileDashboardSnapshotBuilder.swift`（677）、`AIQuotaBar/Resources/MobileDashboard/*`、`AIQuotaBar/Tests/MobileDashboard/*`
- 跟随应用：`AIQuotaBar/Services/ProviderAppPresence.swift`、`AIQuotaBar/Models/LeftClickMenuDisplayPreferences.swift`
- 调暗：`AIQuotaBar/Services/Display/StepAwayDimController.swift`（StepAwayPreferences 默认 90%）、`DDCBrightnessController.swift`
