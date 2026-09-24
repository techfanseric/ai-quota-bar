# Windows 端移植计划

日期：2026-09-24。状态：**草案，待评审**——本文档只为决策提供依据，评审通过前不启动任何 Windows 端实施。

调研范围：主应用全部源码（128 个 Swift 文件）、AIQuotaBarHook / AIQuotaBarSleepHelper 辅助进程、CodexBarCore 依赖的实际使用面、测试资产、构建与发布链路。基于 v1.28.1 代码快照。

## 1. 结论摘要

- **可行**。项目核心价值（provider 配额协议、预测计算、Clash REST 控制、云端协作）大多是 HTTP 与纯计算逻辑，真正绑定 macOS 的部分可枚举、可映射。
- **推荐路线**：C# / .NET 8 原生重写（WinUI 3 主界面 + Win32 托盘直调），复用移动仪表盘 Web 资产与 Cloudflare 后端，纯逻辑层从 Swift 翻译并用共享契约测试钉住。
- **规模**：预计 C# 代码 28K~35K 行；单人全职约 3~4.5 个月达到功能对等，MVP 约 6~9 周。
- **两个最大不确定点**：CodexBarCore 配额核心的切割移植量；Kimi Windows 桌面版凭据格式。均安排在 Phase 0 用 spike 验证。
- **两个需要重新设计（而非照搬）的功能**：合盖模式（Windows 电源语义不同）、移动仪表盘的网络暴露（Windows 防火墙）。

## 2. 目标与范围

### 2.1 v1 功能对等矩阵

| macOS 功能 | Windows 处理方式 | 备注 |
| --- | --- | --- |
| 菜单栏常驻图标 + 配额环 | **移植**（托盘图标 + 自绘弹层） | 动画继承 30fps 设计，限帧更新位图 |
| 左键控制中心（配额面板） | **移植** | Acrylic 弹窗按托盘位置定位 |
| 右键路由面板 | **移植** | 与左键面板同等实现 |
| Codex 配额（OAuth / CLI / Web 源） | **移植** | 凭据来自 `%USERPROFILE%\.codex\auth.json`，Codex CLI 有 Windows 原生版 |
| Kimi 配额（API key / 桌面 / Web / CLI） | **移植，分层降级** | API key 先行；桌面会话与 Web cookie 依赖 Phase 0 验证 |
| GLM 配额（API key / cURL 导入） | **移植** | 纯 HTTP，零适配 |
| MiniMax 配额 | **移植** | 纯 HTTP |
| Clash/Mihomo 路由切换、测速、自动恢复 | **移植** | external controller 是 HTTP；配置发现路径改为 `%USERPROFILE%\.config` 系列 |
| Clash 连接监控（只读） | **移植** | Clash Verge Rev 有 Windows 版，API 相同 |
| Codex 任务检测 + 防睡眠 | **移植** | 见 §5.1、§5.2 |
| 合盖模式 | **重新设计或降级** | 见 §5.1，v1 建议不做等价实现 |
| 移动仪表盘（局域网 HTTP+WS、配对、PWA） | **移植** | Kestrel 承载，前端资源原样复用；见 §5.3 防火墙 |
| 本地用量统计（SQLite、会话索引） | **移植** | SQLite 文件格式跨端一致 |
| 云同步 + 团队（Usage & Team、仪表盘） | **移植** | 后端零改动，客户端按现有 REST 契约实现 |
| 30 天矩阵、288 格热力图等图表 | **移植** | 属于 UI 重写范围 |
| 跟随运行应用（Follow running apps） | **移植，依赖验证** | 需确认各桌面应用 Windows 版存在性（§13 决策点 D6） |
| 折叠分区、供应商排序、双语 | **移植** | 文案随 AppLanguage 同构迁移 |
| 通知（配额告警、恢复完成等） | **移植** | Windows Toast |
| 开机自启 | **移植** | 注册表 Run 键或 MSIX StartupTask |
| 自动更新检查 | **移植** | 见 §5.5，UpdateChecker 绑定 GitHub Releases，需加平台资产过滤 |
| 匿名使用分析 | **移植** | 上报增加平台字段，端点不变 |

### 2.2 明确不做（v1）

- 合盖模式的等价实现（§5.1）。
- macOS 版特有 UI 形态的像素级还原（如 NSPopover 阴影行为）；按 Windows 惯例重做。
- Windows 商店上架（可后续再议，不影响架构）。

## 3. 现状盘点

### 3.1 代码资产（v1.28.1）

| 模块 | 文件数 | 行数 | 内容 |
| --- | --- | --- | --- |
| App/ | 8 | 2,345 | 菜单栏壳、面板控制器（AppKit 重度） |
| Models/ | 26 | 6,187 | 数据模型、偏好、语言、符号渲染器（基本纯逻辑） |
| Services/ | 59 | 18,334 | provider 客户端、Clash、云同步、电源、Keychain、仪表盘服务 |
| Settings/ | 25 | 3,202 | SwiftUI 设置窗 |
| ViewModels/ | 1 | 2,065 | UsageViewModel |
| Views/ | 9 | 4,152 | SwiftUI 视图 |
| Tests/ | 59 | 14,874 | XCTest，覆盖大量纯逻辑与展示计算 |
| AIQuotaBarHook | 1 | ~40 | hook 可执行文件，读 stdin JSON 并经 DistributedNotificationCenter 转发 |
| AIQuotaBarSleepHelper | 1 | ~600 | 特权助手：pmset 租约、电池/热监测、心跳超时恢复 |
| CodexBarCore（依赖） | 690 | ~180,000 | 实际使用集中在配额读取/OAuth/账户管理子集，需切割 |

### 3.2 复用性分类

| 类别 | 范围 | 规模 | 策略 |
| --- | --- | --- | --- |
| 零成本复用 | Cloudflare Worker/D1 后端；移动仪表盘前端（HTML/CSS/JS，约 656K 资源）；docs/ 下的 API 字段映射文档；配额符号设计系统 | — | 直接使用 |
| 翻译式移植 | Models + Services 纯逻辑：配额解析、预测（QuotaConsumptionForecast）、历史存储、Clash REST 客户端、云同步队列、用量索引、各 provider mapper | ~15K~18K 行 | 逐模块翻译成 C#，对照 Swift 测试逐个补齐 xUnit |
| 必须重写 | 全部 UI（SwiftUI + AppKit）；平台服务（Keychain/IOKit/PTY/NSWorkspace/SMAppService/通知/IPC/特权助手） | ~14K 行 UI + ~3K 行平台服务 | 按 §4 映射表用 Windows 原生机制实现 |
| 高价值可翻译资产 | Tests/ 的纯逻辑测试 | ~14.9K 行 | 作为移植正确性的验收清单：Swift 测试覆盖的行为，xUnit 必须等价覆盖 |

## 4. 平台机制映射总表

| macOS 机制 | 用途 | Windows 原生等价 | 移植难度 |
| --- | --- | --- | --- |
| `NSStatusItem` | 常驻图标 | `Shell_NotifyIcon`；处理 Explorer 重启（`TaskbarCreated` 重注册）；多 DPI 图标（16/20/24px 档） | 中 |
| `NSPopover` / `NSPanel` | 左右键面板 | 自绘 Acrylic 弹窗，`Shell_TrayWnd` 定位；PerMonitorV2；任务栏自动隐藏处理 | 中高 |
| SwiftUI | 设置窗、图表 | WinUI 3（Fluent）；深浅色跟随 `UISettings.ColorValuesChanged` | 高（重写） |
| Keychain（`SecItem`） | provider 凭据、Kimi Safe Storage 缓存 | Credential Manager（`CredRead/CredWrite`）+ DPAPI | 低 |
| `IOPMAssertionCreateWithName` | 防系统/显示器睡眠 | `SetThreadExecutionState(ES_CONTINUOUS \| ES_SYSTEM_REQUIRED \| ES_DISPLAY_REQUIRED)`，零权限 | 低 |
| `SMAppService` | 自启动 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（或 MSIX StartupTask） | 低 |
| DistributedNotificationCenter | Codex hook → 主进程 | Named Pipe；兜底 `FileSystemWatcher` 监听 `~/.codex/sessions` | 中 |
| `~/.codex/hooks.json` + bundle 内 hook 可执行文件 | Codex 生命周期事件 | 路径与格式不变（codex CLI 跨平台同构）；可执行文件改为安装目录内 `.exe` | 低 |
| `SMJobBless` 特权助手 | 合盖模式改 `pmset` | 无对应；见 §5.1 重新设计 | — |
| `forkpty` | Kimi CLI `/status` PTY 探测 | ConPTY（`CreatePseudoConsole`），.NET 有封装 | 中 |
| `NSWorkspace.runningApplications` | 跟随运行应用 | `System.Diagnostics.Process` 枚举 + `Win32_ProcessStartTrace`/低频轮询合并 | 低中 |
| `Network.framework` NWListener | 移动仪表盘 HTTP+WS | ASP.NET Core Kestrel（WebSocket 一等支持） | 中 |
| NWPathMonitor 等连通性监测 | OpenAI 连通性 | `NetworkChange.NetworkAvailabilityChanged` + 现有 HTTP 探测逻辑 | 低 |
| `UserNotifications` | 通知 | `AppNotificationBuilder` Toast | 低 |
| DispatchSource/FSEvents 文件监听 | 会话活动、凭据变化 | `FileSystemWatcher`（`ReadDirectoryChangesW`） | 低 |
| SQLite3 C API | 用量历史 | `Microsoft.Data.SQLite`，同库同格式 | 低 |
| CryptoKit/CommonCrypto | Kimi 桌面凭据、cookie 解密 | Kimi Windows 桌面版若为 Electron safeStorage → DPAPI；Chromium cookie → DPAPI + AES-GCM | **待验证** |
| `IOKit.ps`（电池） | 合盖安全阈值 | `GetSystemPowerStatus` / `Win32_Battery` | 低 |
| `IOKit` 热压力 | 合盖热保护 | 无可靠等价；v1 不涉及（合盖不做） | — |
| CoreImage 图标合成 | 菜单栏图标 | Win2D/Direct2D 或预生成多档 PNG；`scripts/generate-quota-icons.swift` 管线移植 | 中 |
| UserDefaults | 设置持久化 | `%APPDATA%\AIQuotaBar\settings.json`（不用注册表存业务配置，保持可迁移、可备份） | 低 |
| AppLanguage（枚举内联双语） | 中英文案 | 同构 C# 枚举 + JSON 资源，键名对齐 | 低 |
| GitHub Releases 更新检查 | 版本检查 | 同一仓库 Releases 挂 Windows 资产；客户端按平台过滤 asset | 低 |

## 5. 需重新设计的功能

### 5.1 合盖模式

macOS 语义（特权助手临时改 `pmset`，带电池/热/心跳/时长安全线）在 Windows 没有直接对应：合盖行为由电源策略的 lid action 控制，修改需要管理员权限且全局生效，"外接电源时合盖不睡眠"是用户级设置而非应用可安全租借的状态。

方案（v1）：**不做等价实现**。提供：
1. 防系统睡眠 + 防屏保（`SetThreadExecutionState`，任务期间自动、零权限）——这是 macOS 版主路径的对应物；
2. 合盖场景改为一次性引导："检测到任务进行中且用户可能合盖 → 打开电源选项引导页"，让用户自己设置 lid action；
3. 未来可选：临时电源计划切换（一次性 UAC + 自动还原 + 租约超时），独立提案再评。

### 5.2 Codex 任务检测

主路径不变：hook（`~/.codex/hooks.json`，跨平台同构）+ named pipe 事件；增强路径为 `FileSystemWatcher` 监听 sessions 目录。Windows 上文件监听比 macOS 更可靠，hook 可降级为加速器。

### 5.3 移动仪表盘网络暴露

Windows 首次监听局域网端口会触发 Defender 防火墙授权弹窗。设计：
- 首次开启仪表盘时明确引导（说明弹窗来源、建议仅专用网络）；
- 监听地址沿用仅本机/局域网边界；配对、short code、install credential、只读面等安全机制原样移植；
- 稳定主机名：macOS 用 mDNS `.local`；Windows 10+ 解析 `.local` 没问题，但**对外通告** mDNS 名称的行为差异需 Phase 0 验证，不行则回退 NetBIOS 名 + IP 列表双通道（现有 IP fallback 机制已支持）。

### 5.4 Clash 配置发现

发现逻辑改为扫描 `%USERPROFILE%\.config\clash*`、`%APPDATA%\clash-verge-rev` 等 Windows 路径；external controller 仅限 loopback 的安全边界不变。

### 5.5 更新与发布

- UpdateChecker 现指向 `techfanseric/ai-quota-bar/releases/latest`。Windows 资产（安装包）挂同一 Releases，客户端按 asset 名/平台标记过滤。
- 分发形态：**Velopack（或 Inno Setup + Velopack 增量更新）**为主选；MSIX 为备选（Store 侧载策略、StartupTask、签名要求不同）。决策点见 §13 D4。

## 6. 技术选型

| 方案 | 原生规范 | 性能 | 移植成本 | 评估 |
| --- | --- | --- | --- | --- |
| **C# / .NET 8 + WinUI 3 + Win32 托盘** | ★★★ | ★★★ | 逻辑翻译 + UI 重写 | **推荐** |
| Swift on Windows | ★（无原生 UI 方案） | ★★ | 互操作层开发量 ≈ 重写 | 不推荐：工具链/生态不成熟，长期风险最高 |
| Rust + Tauri | ★★（WebView 渲染） | ★★★ | 与 C# 相当，Windows API 绑定自拼 | 不推荐：与原生规范诉求冲突 |
| Electron / Flutter | ★ | ★/★★ | — | 排除 |

推荐 .NET 的决定性理由：对 Windows API 覆盖最全（ConPTY、DPAPI、`SetThreadExecutionState`、`ReadDirectoryChangesW`、Named Pipe、Kestrel WS 全部开箱即用），tray-first 工具类应用有成熟路径。

UI 分工：
- **设置窗与图表**：WinUI 3（Fluent、Win11 观感；x:Bind 高性能图表可行）。
- **托盘**：`Shell_NotifyIcon` 直调（P/Invoke 或 H.NotifyIcon.WinUI），不用 Windows App SDK 实验性 TrayIcon。
- **弹层**：无边框 Acrylic Win32 窗口 + WinUI 3 内容，失焦自动关闭、随任务栏对齐。
- **兜底**：Phase 0 若弹层/DPI/部署发现 WinUI 3 阻断问题，设置窗降级 WPF（Core/Providers/Platform 层不受影响）。

明确不用 NativeAOT（与 WinUI 3/WPF 均不兼容），用 ReadyToRun；GC 工作站模式 + `GCConserveMemory`。

## 7. 目标架构

```
ai-quota-bar-windows/            （仓库策略见 §13 D1）
  src/AIQuotaBar.Core            # 纯逻辑：配额计算/预测/历史/契约模型；零 Windows/UI 依赖；xUnit 全覆盖
  src/AIQuotaBar.Providers       # Codex/Kimi/GLM/MiniMax/Clash 网络客户端（依赖 Core）
  src/AIQuotaBar.Platform        # 托盘、DPAPI/CredMan、电源、ConPTY、FileWatcher、Toast、自启、单实例 mutex、mDNS
  src/AIQuotaBar.App             # WinUI 3：设置窗 + 弹层宿主（依赖上面三层）
  src/AIQuotaBar.MobileServer    # Kestrel 仪表盘；静态资源直接复制自 AIQuotaBar/Resources/MobileDashboard
  contracts/fixtures/            # 与 macOS 端共享的 API 请求/响应样本（JSON），双端契约测试共用
  assets/icons/                  # 由 generate-quota-icons 管线产出的 Windows 多档图标
```

分层铁律：
1. Core 与 Providers 不引用任何 UI 框架与 Win32 API，可在任何机器跑单测；
2. 所有 provider 网络解析必须对 `contracts/fixtures` 的样本做测试，样本从 macOS 版真实流量录制；
3. Swift 端已有测试（Tests/ 59 个文件）覆盖的纯逻辑行为，xUnit 必须等价覆盖——测试清单作为移植验收表。

## 8. Windows 原生规范清单（验收标准）

| 项 | 规范 |
| --- | --- |
| 托盘 | Explorer 崩溃/重启后图标自动恢复；右键菜单符合 Win11 风格（图标列、分隔线、助记键） |
| 弹层 | 按任务栏位置自动对齐（下/上/左/右）；多显示器正确；DPI 变化不糊；失焦/ESC 关闭 |
| 安装 | 默认装 `%LOCALAPPDATA%\Programs\AIQuotaBar`（免管理员）；卸载干净 |
| 数据 | 配置/凭据引用放 `%APPDATA%\AIQuotaBar`；缓存与 SQLite 历史 `%LOCALAPPDATA%\AIQuotaBar`；凭据本体只在 Credential Manager |
| 自启 | 注册表 Run 键（用户级），设置内可开关，且可在系统"启动应用"中管理 |
| 单实例 | Named mutex；二次启动激活已有实例 |
| 通知 | Toast（`AppNotificationBuilder`）；尊重系统专注助手/通知开关 |
| 高 DPI | PerMonitorV2 清单声明 |
| 深浅色 | 跟随系统，即时响应 `UISettings` 变更 |
| 无障碍 | UIA 基本可达（弹层与设置窗控件可被屏幕阅读器读出）；高对比度主题可用 |
| 输入 | 键盘完整可达（Tab/ESC/助记键）；中文输入法下正常 |
| 安全 | 不明文落盘任何凭据；仅 loopback 访问 Clash controller；SmartScreen 签名策略见 §13 D5 |
| 资源 | 图标含 16/20/24/32 多档；任务管理器名称/发布者/版本信息完整 |

## 9. 分期实施计划

每期结束有可验证的验收物；任何一期失败可就地止损。

### Phase 0 — 验证性 spike（1~2 周）

| # | 验证项 | 通过标准 |
| --- | --- | --- |
| S1 | CodexBarCore 切割清单 | 枚举 App 实际引用的 CodexBarCore API 面，产出"需移植文件清单 + 行数"，量化最大不确定点 |
| S2 | Codex Windows 凭据 + 配额 | C# 读 `%USERPROFILE%\.codex\auth.json`（含 OAuth 刷新）调通 usage API，出真实配额 |
| S3 | Kimi Windows 桌面凭据 | 确认 Kimi Windows 桌面版是否存在及其凭据存储（Electron safeStorage/DPAPI？），样本解密成功；或明确降级到 API key/Web 源 |
| S4 | Chromium cookie | Windows Chrome/Edge cookie DPAPI+AES-GCM 解密样本成功；确认 Chrome 127+ app-bound encryption 影响面 |
| S5 | ConPTY | C# 在 ConPTY 里跑 Kimi CLI `/status`（前提：Kimi CLI 有 Windows 版；否则此项改判 Kimi CLI 可用性） |
| S6 | 托盘 + 弹层 demo | Shell_NotifyIcon + Acrylic 弹窗：Explorer 重启恢复、多显示器 DPI、任务栏四向对齐 |
| S7 | WinUI 3 vs WPF 定稿 | 用 S6 结论 + 设置窗原型决定；产出 ADR 记录 |

### Phase 1 — MVP（5~7 周）

- Core：配额模型、预测、历史存储（对照 Swift 测试翻译）；契约 fixtures 机制建立。
- Providers：Codex（OAuth/CLI 源）、GLM、MiniMax；Clash REST 客户端 + 路由切换/测速。
- Platform：托盘 + 环形图标（限帧动画）、弹层宿主、Credential Manager、Toast、自启、单实例。
- App：左键控制中心、右键路由面板、设置窗基础（供应商凭据、显示偏好）。
- 验收：四类配额真实显示、路由一键切换、低额度告警 Toast、空闲性能达标（§11）。

### Phase 2 — 深度功能（5~7 周）

- Kimi 全源降级链（API key → 桌面会话 → Web 会话 → CLI，按 S3/S4/S5 结论裁剪）。
- 防睡眠（任务检测 + SetThreadExecutionState + hook/FileWatcher 双路）。
- 移动仪表盘（Kestrel + 前端复用 + 配对/短码/install credential + 防火墙引导 + mDNS 或回退）。
- 本地用量统计（SQLite + FileWatcher 索引，格式与 macOS 端一致）。
- 自动路由恢复（双域名两次失败判定逻辑照搬）。
- 跟随运行应用（按桌面应用 Windows 存在性清单裁剪）。

### Phase 3 — 协作与发布（3~4 周）

- 云同步 + 团队全功能（REST 契约客户端、团队仪表盘复用 Web 端）。
- 打包、签名、Velopack/MSIX 更新通道、UpdateChecker 平台过滤。
- 性能调优冲刺 + 10 分钟空闲/负载双模式测量（对齐 performance-audit 方法）。
- 文档：Windows README、安装引导（防火墙/SmartScreen 说明）、docs/README.md 收录。

### 执行模型：Subagent 划分与并行策略

划分原则：

1. 按分层与模块划分，一个 subagent 独占一个目录，杜绝同文件并发编辑。
2. 契约先行：contracts 与共享模型由主会话（编排者）在 fan-out 前单独完成并冻结；subagent 只读引用，缺类型时提出申请而非自行修改。
3. 任务书自包含：输入 = Swift 源文件清单（移植规格）+ 对应 Swift 测试清单（验收表）+ 编码规范；输出 = C# 实现 + 等价 xUnit；验收 = `dotnet test` 全绿。
4. 集成走 PR + CI：分支 → GitHub Actions x64 全绿 → 编排者串行评审合并，防契约漂移。

并行波次（以 Phase 1 为例）：

- **W0（串行）**：解决方案骨架、contracts 冻结、CI 工作流、编码规范。
- **W1（5 路并行）**：Core 数学与存储 / Clash 客户端 / GLM+MiniMax / Platform 基础（凭据、Toast、自启、单实例）/ Codex 凭据与配额（最大块，按 S1 清单可内拆）。
- **W2（4 路并行）**：Kimi 客户端（依赖 S3/S4）/ 托盘与弹层（依赖 S6/S7）/ 设置窗 UI / 移动仪表盘 server。
- **W3（收敛，串行为主）**：联调、性能、打包发布。

Phase 0 的 spike 天然独立：S1 在 Mac 本地，S2/S4/S5/S6 四路并行。

资源争用规则：W1 全部任务在 macOS 本地构建测试（分层铁律的回报），不占远程机；远程 Windows 机构建/测试可多 agent 并发（不同目录、不同测试过滤），**UI 截屏验证会话串行预约**，避免互相污染画面。

并行度与工期：有效并行 4~6 个 subagent，更多则瓶颈转移到评审与集成；编排者负责契约、评审、合并与联调。预期墙钟时间较单人顺序执行压缩约 30%~50%，总工期（§14）相应按 2.5~3 个月修正；瓶颈从编码转移到评审与联调。

### 审查与验收体系（质量门禁）

自动化门禁（CI，每 PR，确定性防线承载主要质量责任）：

- 编译警告即错误；单元 + 契约 + **差分金标测试**（同一输入分别跑 Swift 原实现与 C# 移植，输出必须一致——原实现即 oracle，移植项目独有的最强验证手段）。
- 架构依赖测试（NetArchTest）：强制 Core/Providers 零 Win32/UI 引用，保护"Mac 本地可测"的并行根基。
- 密钥扫描（gitleaks 类）；diff 目录越界检查（不得触碰非所属目录）。
- 测试齐全性以"对照 Swift 测试清单逐项打勾"为准，不以行覆盖率为准。

角色分工（implementer ≠ reviewer）：

1. **编排者**（主会话）：契约冻结、串行合并、联调、终责。
2. **Fixture 采录者**：样本只从 macOS 实机真实流量录制，不得由移植该模块的 agent 自造。
3. **移植审查 agent**：每 PR 新起零上下文，核对规格对应、测试清单齐全性、目录越界。
4. **平台验收 agent**：远程机脚本化清单（托盘四向、Explorer 重启、DPI、防火墙），证据截图与日志回传。
5. **性能守门**：里程碑按 §11 指标实测，回归即阻断。
6. **安全审查**：PR 级自动扫描 + Phase 3 凭据处理路径审查收口。

门禁节奏：

- **G1 每 PR**：CI 全绿 + 独立审查通过；缺陷率超阈值的 PR 打回重审而非修补免审。
- **G2 每波次收口**：集成树全量差分 + 冒烟。
- **G3 每阶段出口**：§8 原生规范表逐项验收 + §11 性能基线 + 文档同步，产出证据包（测试报告/截图/性能数字）提交用户终审（对应 §14 里程碑 M0~M3）。

防过度设计：机械检查全部自动化；agent 审查只用于判断类问题（规格对应、视觉合理性）；不设层层人工评审。审查体系不改变有效并行度（4~6），新增成本为 CI 时长与编排者评审带宽。

## 10. 开发与测试环境（macOS 主机）

前提：开发者主力机是 macOS（Apple Silicon）。核心思路是**分层环境**——纯逻辑层在 macOS 直接开发测试，真实 Windows 用本地虚拟机覆盖日常，CI 覆盖 x64 矩阵，物理机只做最终验收。这也是 §7 分层铁律的直接收益：Core/Providers 零 Windows 依赖，使大部分移植工作完全不依赖 Windows。

### 10.1 四层环境

| 层 | 环境 | 覆盖内容 |
| --- | --- | --- |
| A. 逻辑层（日常） | macOS 本机：VS Code + C# Dev Kit（或 Rider）+ .NET SDK | Core/Providers 全部单元测试与契约测试（`dotnet test` 原生跨平台）；fixtures 与 Swift 端共享 |
| B. Windows 日常 | Apple Silicon 上 Win11 ARM 虚拟机（VMware Fusion 个人免费 / Parallels / UTM；微软官方提供 ARM64 ISO）+ Visual Studio 2022 Community（免费）；**或远程 Windows 机器（磁盘零占用，见 §10.4）** | UI 开发（XAML 热重载）、Platform 层联调（托盘/ConPTY/DPAPI/FileWatcher/Toast）、真实 provider 联调（Codex/Kimi CLI、Clash Verge Rev）、防火墙弹窗、SmartScreen、Explorer 重启恢复 |
| C. CI 矩阵 | GitHub Actions `windows-latest`（公开仓库免费） | x64 构建与测试、打包、发布产物；PR 门禁。与 B 层（ARM64）合成双架构矩阵 |
| D. 物理机终验（少量） | 任一真实 Windows 机器（借用或廉价迷你主机） | 性能基线、多显示器 DPI、真实 Explorer/自启行为、发布签名终验 |

要点：

- Visual Studio for Mac 已退役（2025-05），macOS 侧用 VS Code + C# Dev Kit 或 Rider；完整 VS 2022 在虚拟机内使用。
- .NET 8 原生支持 Windows ARM64，应用在 ARM 虚拟机原生运行（非模拟）；x64 功能兜底可依赖 Win11 ARM 的 x64 模拟，正式覆盖靠 C 层。
- 代码同步：git 为主（Mac 推分支、虚拟机拉取），或虚拟机共享目录直接打开同一工作区。
- 移动仪表盘联调：虚拟机网络改桥接模式获得独立局域网 IP，手机扫码可验证 QR/配对/PWA/防火墙全链路。
- 托盘 Explorer 崩溃恢复：虚拟机内结束 `explorer.exe` 后重启验证 `TaskbarCreated` 重注册。

### 10.2 测试类型 × 环境矩阵

| 测试 | 环境 | 方式 |
| --- | --- | --- |
| 单元/契约测试（Core/Providers） | A + C | `dotnet test`；fixtures 与 Swift 端共享 |
| Platform 集成（托盘、DPAPI、ConPTY、FileWatcher、电源、自启） | B + C | VM 内以 Trait 过滤跑集成测试 |
| UI 冒烟 | B | 手动为主，后期可选 WinAppDriver/Appium |
| 真实 provider 联调 | B | VM 内安装真实 CLI/桌面应用与凭据 |
| 防火墙 / SmartScreen / 签名 | B，D 终验 | 真实安装包在 VM 安装验证 |
| 性能基线（§11 指标） | D | VM 虚拟化开销会污染 CPU/内存数字，以物理机为准 |
| 多显示器 DPI、Explorer 崩溃恢复 | B 日常，D 终验 | VM 可配多显示器 |

### 10.3 对计划的影响与成本

- Phase 0 的 S1（CodexBarCore 切割清单）在 macOS 直接做；S2~S6 需要虚拟机。
- 新增成本接近零：VMware Fusion/UTM、VS 2022 Community、GitHub Actions（公开仓库）均免费；可选开销为 Parallels 订阅与物理终验设备。Windows 许可证可用评估/未激活模式开发（有水印与少量个性化限制）。
- 磁盘预算（2026-09 主力机实测剩 88 GB）：Mac 侧约 4~5 GB（.NET SDK、VS Code、仓库与 NuGet 缓存）；虚拟机干净安装实占 22~28 GB（ISO 5.5 GB 装完即删）；Phase 0 合计约 30~35 GB，够用；Phase 1 起加装 VS 2022（+10~15 GB）与长期增长（+10~20 GB）后稳态约 70~80 GB，主力机余量偏紧。缓解：VM 放外接 SSD（VMware Fusion/UTM 均支持）、Phase 0 不装 VS 2022（dotnet CLI + VS Code 足够）、VM 内瘦身（`powercfg /h off` 省 8~13 GB、pagefile 固定 2 GB、关系统还原、虚拟盘压缩）。若采用 §10.4 远程机器方案，Mac 侧仅剩仓库浅克隆（<200 MB），磁盘不再构成约束。

### 10.4 远程 Windows 机器方案（Mac 磁盘零占用路线）

适用：主力机磁盘紧张（实测剩 88 GB），或已有可远程访问的 Windows 物理机/云机。此路线下 B 层由远程机器替代，主力机不再需要任何虚拟机。

工作方式：agent（ZCode）经 SSH 远程执行全部 Windows 侧工作——环境安装（.NET SDK、git）、构建、单元/集成测试、Phase 0 spike、日志与测试报告回传；UI 冒烟采用"远程启动应用 → 截屏 scp 回传 → 目检"闭环。RDP 图形会话由开发者本人按需使用（视觉手感类最终确认）。CI 照旧走 GitHub Actions，不依赖本地资源。

Mac 侧占用与清理：仅本地仓库工作副本（浅克隆 <200 MB，经 git 与远程机同步）；.NET SDK、NuGet 缓存、构建产物全部留在远程机。项目结束删除本地副本即净，Mac 侧无任何 SDK/运行时残留。

远程机准备清单（一次性）：

1. Windows 10 21H2+ / Windows 11，启用 OpenSSH Server（管理员 PowerShell：`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`）。
2. 提供账户（建议管理员，安装工具需要）；建议 SSH 密钥登录，密钥可随时吊销。
3. 网络可达：同局域网直连；跨网络时两端安装 Tailscale 组网。
4. UI 验证需交互桌面会话：配置自动登录；Phase 0 的 S2~S5 为纯命令行工作，可先行。
5. 若为物理机：真实 Explorer 与性能数字可信，可兼任 D 层物理终验；云 VM 性能测量仍不可信。

## 11. 性能目标与度量

继承 macOS v1.23.0 性能治理的纪律（该版本把常驻 CPU 从 95% 降到 9%）：

| 指标 | 目标 | 度量方法 |
| --- | --- | --- |
| 空闲 CPU | ≈0%（任务管理器 0.0~0.1%） | 10 分钟无操作采样 |
| 常驻内存 | < 50 MB（工作集） | 同上 |
| 冷启动到托盘可见 | < 2 s | 计时 |
| 面板动画 | 面板打开时 30fps，关闭时 0 渲染 | 帧率计数 + ETW |
| 网络请求 | HttpClient 单例连接复用；刷新间隔自适应（照搬 Swift 逻辑） | 代码审查 + 抓包 |

实现要点：事件驱动优先（FileWatcher 替代轮询）；托盘图标位图限帧更新；计时器合并；无 UI 时零渲染线程活动。

## 12. 风险登记册

| # | 风险 | 概率 | 影响 | 缓解 |
| --- | --- | --- | --- | --- |
| R1 | CodexBarCore 移植量超预期（18 万行依赖中配额核心的切割不干净） | 中 | 高 | S1 spike 先量化；必要时按"API 面"而非"文件"切割；协议以 fixtures 为准而非照搬实现 |
| R2 | Kimi Windows 桌面凭据格式无法读取（或桌面版无 Windows 端） | 中 | 中 | 降级链保证 API key/Web/CLI 仍可用；S3 提前验证 |
| R3 | Chrome 127+ app-bound encryption 阻断 Web 会话发现 | 中 | 中 | Edge/Kimi 桌面内置浏览器不受限的可能高；S4 验证；文档明确支持范围 |
| R4 | 杀软/EDR 误报（常驻托盘 + 读 cookie + ConPTY 的行为画像） | 中 | 中 | 代码签名（D5）、行为透明化文档、避免混淆加壳 |
| R5 | WinUI 3 弹层/托盘坑（聚焦丢失、DPI、部署运行时） | 中 | 中 | S6/S7 定稿；WPF 兜底且不影响 Core 层 |
| R6 | 双端功能漂移（后续新增 provider 只有一端实现） | 高（长期） | 中 | 契约 fixtures 共享 + "Swift 测试清单"作为移植验收表 + 发版核对流程（§15） |
| R7 | Kimi CLI 无 Windows 原生版 | 低中 | 低 | PTY 探测路径整体砍掉，Kimi 走 API key/桌面/Web 源 |
| R8 | mDNS 通告差异导致仪表盘稳定主机名不可用 | 中 | 低 | 现有 IP fallback 机制兜底；S6 顺带验证 |
| R9 | 单人带宽不足，工期超 4.5 个月 | 中 | 中 | 分期可止损；MVP 先发；Phase 2/3 可并行第二人 |

## 13. 待决策事项（评审时拍板）

| # | 决策 | 建议 | 备选 |
| --- | --- | --- | --- |
| D1 | 仓库策略 | 同仓库 `windows/` 目录（契约 fixtures 天然共享、发版同 tag） | 独立仓库（CI 简单，契约同步成本高） |
| D2 | 最低系统版本 | Windows 10 21H2 + Windows 11（WinUI 3 均支持） | 仅 Win11（省 Win10 测试矩阵） |
| D3 | 架构矩阵 | x64 + arm64（.NET 差异小，CI 双跑） | 仅 x64 起步 |
| D4 | 分发与更新 | Velopack 增量更新 + GitHub Releases | MSIX（Store/侧载） |
| D5 | 代码签名 | OV 证书起步（约 ¥700~2000/年），接受 SmartScreen 信誉累积期 | EV 证书（贵，SmartScreen 信誉即时） |
| D6 | "跟随运行应用"的 Windows 覆盖面 | 按 S3 顺带产出的桌面应用存在性清单定（ChatGPT/Kimi/ZCode/MiniMax 桌面版） | v1 砍掉该功能 |
| D7 | 合盖模式 | v1 不做，只做防睡眠 + 电源设置引导 | 临时电源计划切换（后续独立提案） |

## 14. 工期与里程碑

| 里程碑 | 内容 | 单人工期 |
| --- | --- | --- |
| M0 | Phase 0 完成：spike 报告 + 选型 ADR + 本计划修订 | 1~2 周 |
| M1 | MVP：Codex/GLM/MiniMax + Clash 切换 + 托盘环 + 面板 | +5~7 周 |
| M2 | 功能对等 v1：Kimi 全源 + 防睡眠 + 仪表盘 + 用量统计 | +5~7 周 |
| M3 | 发布：云同步团队 + 更新通道 + 性能达标 + 签名 | +3~4 周 |

合计约 3~4.5 个月（单人全职）。两人分工（核心移植 / UI 平台）M1 可压缩至 3~4 周。估算基于 v1.28.1 代码行数与功能清单，属数量级估计，M0 后修正。

## 15. 双端长期维护流程

1. **契约即源**：provider 协议变化先改 `contracts/fixtures`，两端实现与测试同步更新；fixture 变更在 PR 中强制列出两端影响。
2. **测试对齐**：Windows 端的 Core 测试与 Swift 端 Tests/ 按模块一一对应；新增纯逻辑功能双端同 PR（或 issue 关联）落地。
3. **发版核对**：发布 checklist 增加"双端功能矩阵"核对（§2.1），明确每版两端各自覆盖范围。
4. **共享资产**：移动仪表盘前端、图标设计系统、Cloudflare 后端为单源，禁止在 Windows 仓库复制修改。

## 附录 A：Spike 产出物清单（Phase 0 结束时）

1. CodexBarCore API 使用面清单（文件 × 引用计数 × 建议处置：移植/绕开/砍）。
2. Windows 端各 provider 数据源可用性结论表（Codex auth.json、Kimi 桌面/CLI、Chromium cookie、Clash 路径）。
3. 托盘 + 弹层 demo（可执行）与已知问题列表。
4. WinUI 3 / WPF 选型 ADR。
5. 修订后的本计划（工作量、风险、D6 覆盖范围更新）。

## 附录 B：许可证合规

- CodexBar（MIT，Copyright Peter Steinberger）：移植其逻辑到 C# 需在 Windows 端 NOTICE/关于页保留版权与许可声明。
- AI QuotaBar 本体 MIT，无阻碍。
- 拟引入的 .NET 依赖（H.NotifyIcon、Velopack 等）均 MIT，引入时逐一登记。
