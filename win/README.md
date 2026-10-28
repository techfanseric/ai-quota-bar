# AI Quota Bar — Windows 迁移版

macOS 菜单栏应用 [AI Quota Bar](../README.md) 的 Windows 版本(C# / .NET 8 WinForms 托盘应用)。
功能规格分析文档见 [`docs/win-migration/analysis/`](../docs/win-migration/analysis/),模块级迁移对照见下文。

## 当前 Windows 预发布：v1.38.6-beta.1

- [下载 Windows x64 ZIP](https://github.com/techfanseric/ai-quota-bar/releases/download/v1.38.6-beta.1/AIQuotaBar-win-x64.zip)；解压运行 `AIQuotaBar/AIQuotaBar.exe`。自包含 .NET 8，支持 64 位 Windows 10+；目前没有安装器或代码签名。
- 托盘两种模式使用深色底和浅色边框，文字模式用两行显示服务商及剩余额度，完整信息在悬停提示中。
- 设置页使用自动行高和换行，普通窗口使用明确的 96 DPI 布局基准，控制中心响应主屏 DPI 变化。尚未完成所有窗口、所有缩放比例和多屏组合的目视验收。
- 「Settings → Providers → Codex · 账号分享与关注」支持逐账号分享、添加/移除关注、邮箱校验、防重复、手动刷新、状态、全部额度窗口、云端更新时间和被查看记录。Watch 修改即时保存，不随 Cancel 撤销；旧版 General 页的邮箱列表自动沿用。
- 分享默认关闭。只有本机获取到额度的账号会发布；知道邮箱的其他用户可读取已分享额度，登录凭据不会上传。账号池尚未获取额度的条目需先登录并刷新。
- 服务商多账号登录管理、数据源选择和 macOS v1.38.5 凭据镜像尚未移植；不宣称完整功能对齐。
- 此 Windows 标签基于已合入 macOS v1.38.5 的源码。当前 Mac 版推进至 v1.39.0，Windows 仍为独立预发布 v1.38.6-beta.1；共享仓库中的 Mac 更新不会自动出现在已发布 Windows ZIP 中。

历史验证：2026-10-24 Windows Release 全套 **543/543 通过**；当次官网语法检查与 **124/124 测试通过**。这是已有 Windows 发行包的记录，不代表本次在 macOS 上重跑了 Windows UI；本次 Mac v1.39.0 验证见独立发布清单。

打包：仓库根目录执行 `powershell -ExecutionPolicy Bypass -File win/scripts/package.ps1`，产物和校验清单位于 `win/artifacts/v1.38.6-beta.1/`。请在已提交的发布源码上构建，确保程序集的 SourceRevision 对应发布标签。

## 安装、更新和首次使用

1. 下载上方 x64 ZIP，可在 GitHub Release 中核对同页的 `SHA256SUMS.txt`。将整个 ZIP 解压到可写目录，保留 `AIQuotaBar/` 里面的所有文件，直接运行 `AIQuotaBar.exe`，不要只拷贝一个 exe。
2. 应用常驻系统托盘。没有看到图标时先展开任务栏的隐藏图标区；左键打开额度控制中心，右键打开原生命令菜单、设置、线路、连接和退出。支持详细文字、紧凑额度环两种托盘模式，以及主题、开机启动和单实例保护。
3. 先登录供应商，再在右键菜单点刷新。Settings → Providers 可启停各供应商；Kimi 可选 API Key，GLM 推荐个人 Coding Plan API Key（网页 cURL 为高级替代），MiniMax 填 coding-plan token。Codex 默认读取本机登录；连接排查见下文。
4. Settings → General 调整刷新间隔、跟随运行中的应用、供应商顺序及更新提醒。Settings → Clash 设置线路筛选与自动恢复；需先有本机 Clash/Mihomo 控制器。
5. 更新前右键退出旧版，替换完整程序目录后重新运行。用户数据与程序分开存放，无需删除设置。更新提醒只打开发布页，不会自动安装；Windows 版本以独立预发布标签为准。

当前发行包没有代码签名，Windows 可能显示未知发布者或 SmartScreen 提示。请核对下载来源与校验和，不需要全局关闭系统安全保护。普通额度、托盘和防睡眠不要求管理员；合盖模式修改系统电源策略，需要以管理员权限运行。

## 当前可用的功能与操作边界

| 功能 | Windows 当前行为 | 操作入口与边界 |
| --- | --- | --- |
| 四家额度 | Codex、Kimi、GLM、MiniMax，额度窗口、重置倒计时与历史 | 左键控制中心；各家返回窗口不同，不保证都有 5h 和 Weekly |
| Codex 关注 | 分享本机已取得额度的账号、按邮箱查看远程已分享额度 | Settings → Providers → Codex；无需团队、同一网络或对方登录凭据 |
| 路由与连接 | Clash/Mihomo 控制器发现、线路测速/切换、连接速率与自动恢复 | 右键线路/连接，Settings → Clash 配置筛选；自动恢复需双站连续失败 |
| 任务保护 | Codex hook、状态库及 rollout 检测，任务期间阻止休眠，结束后宽限再释放 | Settings → Power；**当前宿主只接入 Codex 任务**，不能把 Mac 四家检测当成 Windows 能力 |
| 合盖工作 | 保护期间修改当前电源方案 LIDACTION，结束后恢复，有恢复 marker | 默认关闭；需管理员，热压力保护尚无 Windows 等价实现 |
| 本机用量 | 扫描本机 Codex 日志并显示 tokens、缓存命中和估算成本 | 与供应商账号剩余额度分开；使用 JSON 缓存，成本不是账单 |
| 手机看板 | 同局域网只读 HTTP＋SSE，默认端口 18765，可选配对和账号掩码 | Settings → Mobile Dashboard；复用 PWA 资源，Windows 快照只是 Mac schema 的子集 |
| 团队与云同步 | 底层创建/加入/上报/浏览器票据接口已实现；上报需有效 `team.credentials` | 当前 Settings → Usage & Team 只有开关，**桌面建队/加入引导尚未对齐**；打开开关不等于已加入或开始上报 |
| 自动更新 | 定期检查、横幅提示、打开 Release 页 | 不提供静默下载、安装器或自动替换 ZIP |

手机看板默认关闭，启用后仅在可信局域网使用，通过界面设置决定是否要求配对并保留默认账号掩码。Windows 防火墙可能需要允许本地网络访问；不需要把看板端口暴露到公网。

### Codex 分享与关注

分享方在 Providers 中开启分享，勾选本机账号；该账号必须先成功刷新过额度。关注方输入邮箱后添加，可手动刷新、查看全部额度窗口、状态及云端更新时间。分享变更与添加/移除关注**立即保存并请求同步**，点 Cancel 不会撤回这些修改。正常后台关注轮询为十分钟，手动刷新请求会提前执行。

分享是按邮箱公开查询：知道已分享邮箱的任何用户都能读到额度，不能视为只有团队可见。只上传额度、套餐、时间及账号标签，不上传 OAuth token、API Key 或账号密码；分享默认关闭，不会因为加入团队而自动开启。账号池尚未获得本地额度的备份不会自动成为可发布额度。

### 数据位置和迁移

| 数据 | 路径或保护方式 |
| --- | --- |
| 应用设置 | `%APPDATA%\AIQuotaBar\settings.json` |
| 凭据保险库 | `%APPDATA%\AIQuotaBar\vault.bin`，Windows DPAPI `CurrentUser` 加密 |
| 额度历史 | `%APPDATA%\AIQuotaBar\quota-history.json` |
| 运行日志 | `%LOCALAPPDATA%\AIQuotaBar\app.log` |
| Codex 登录 | `CODEX_HOME`，未设置则 `%USERPROFILE%\.codex\auth.json` |

备份用户数据时先退出应用；DPAPI 保险库与当前 Windows 用户身份绑定，单独复制 `vault.bin` 到另一台机器或另一用户不能视为可用的凭据迁移，必要时重新登录或填写凭据。不要提交或分享这些本机文件。Windows 没有 Mac 的独立 Codex 凭据守护镜像。

## Codex 额度与连接排查

- Windows 默认读取 `CODEX_HOME`（未设置时为 `%USERPROFILE%\.codex`）中的登录信息，先请求 OAuth 额度接口；失败时通过本机 Codex CLI 的 `app-server` / `account/rateLimits/read` 回退查询。CLI 查询不创建对话或执行模型任务。
- 支持 PATH 中的 `codex.exe`，以及 `%APPDATA%\npm` / PATH 目录下 npm 安装的 Windows 原生 Codex 二进制。
- 只有周额度、没有 5 小时额度的账户，托盘仍显示可用的周额度。
- 同一账户刷新失败时，控制中心保留本次运行中上次成功的额度，并标明时间和错误；账号切换后不复用旧账号额度。
- SSL/TLS 错误会在 `%LOCALAPPDATA%\AIQuotaBar\app.log` 保留内层连接原因。控制中心错误提示的悬浮说明包含完整错误。OAuth 使用系统默认代理和证书验证，CLI 使用自身网络配置；回退不能保证修复两条路径共同的代理或证书故障。
- 当前回退仍需要可读取的 `auth.json`；尚未实现 macOS 全部数据源设置、Web 回退及完整额度附加信息的界面对齐。

## 从源码构建

要求：.NET 8 SDK；Windows 桌面宿主需要 Windows 系统。

```powershell
cd win
dotnet build AIQuotaBar.Win.sln -c Release
dotnet test AIQuotaBar.Win.sln -c Release # 全部单元/集成测试；最近 Windows 记录为 543 项
dotnet run --project src/AQB.App          # 启动托盘应用
```

冒烟测试(构建 Release、启动托盘应用、校验进程/日志/看板端点):

```powershell
bash scripts/smoke-test.sh
```

## 架构(解决方案 `win/AIQuotaBar.Win.sln`)

| 项目 | 职责 | macOS 对应 |
| --- | --- | --- |
| `AQB.Core` | 共享模型、pace 算法、时间/指纹工具、仪表板快照 DTO | `Models/` + CodexBarCore 数学 |
| `AQB.Settings` | `%APPDATA%\AIQuotaBar\settings.json` 设置 + DPAPI 凭据保险库 | UserDefaults + Keychain vault |
| `AQB.Providers.Codex` | `~/.codex/auth.json` 解析、OAuth 刷新、5h/Weekly 配额、多账号池 | `Services/Codex/` |
| `AQB.Providers.Kimi` | 桌面/网页会话 + CLI `/status` 解析 | `Services/Kimi/` |
| `AQB.Providers.GlmMiniMax` | GLM(API key/cURL 导入)与 MiniMax 配额 | `Services/GLM*` + MiniMax |
| `AQB.Clash` | 控制器发现、路由切换、延迟测试、自动恢复、连接监控 | `Services/Clash/` |
| `AQB.Power` | `PowerCreateRequest`/`SetThreadExecutionState` 防睡眠、电量/12h 安全网 | `Services/Power/` + SleepHelper |
| `AQB.CodexTasks` | hook 事件日志 + state_5.sqlite + rollout 监视 → 活跃任务 | `Services/Codex/*Watch*` |
| `AQB.Hook` | Codex notify hook 可执行文件(stdin JSON → 事件日志) | `AIQuotaBarHook` |
| `AQB.Usage` | 本地用量扫描/聚合(tokens、缓存命中率、成本) | `Sources/CodexLocalUsageCore` |
| `AQB.Dashboard` | 18765 端口只读 HTTP + SSE 移动看板(复用原 PWA 静态资源) | `Services/MobileDashboard/` |
| `AQB.Team` | Cloudflare Worker 客户端(建队/加入/用量上报/配额上传) | Team/Sync services |
| `AQB.App` | WinForms 托盘宿主(图标、控制中心、设置、路由/连接面板) | `App/` + `Views/` + `Settings/` |

Cloudflare Worker(`cloudflare/`)为跨平台 JS,**原样复用**,无需迁移。

## 与 macOS 版的差异

- 凭据存储:Keychain → DPAPI(CurrentUser)单文件 `vault.bin`。
- 防睡眠:无需特权 helper;`PowerCreateRequest` 崩溃安全。合盖模式改用 `powercfg LIDACTION`(需管理员)。
- Kimi CLI 探测:PTY → 普通子进程管道(Windows 无 PTY),解析逻辑一致。
- 菜单栏 → 系统托盘 `NotifyIcon`;控制中心为无边框弹出窗。
- 移动看板:PWA 静态资源原样复用,SSE 快照为 Windows 侧 schemaVersion 2 子集。

详细分析规格(逐端点/逐公式/逐测试行为):`../docs/win-migration/analysis/*.md`

## 本机验证记录(2026-10-17,Windows 10 19045)

- `dotnet test AIQuotaBar.Win.sln`:**529/529 通过**——Core 34、Codex 55、Kimi 47、GLM/MiniMax 58、Clash 151、Power 29、CodexTasks 46、Usage 58、Dashboard 8、Team 43。
- Clash 集成测试真实执行:从 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\config.yaml` 发现控制器 `127.0.0.1:9097`,`GET /version` 返回 `meta v1.19.31`;路由解析命中真实分组,看板快照回传当前选中节点。
- 移动看板:端口 18765,`/api/v1/health` 200;SSE `Bearer` 鉴权(无 token 401)、首帧快照、账号标签掩码生效;PWA 静态资源(index.html/app.js/app.css/manifest/图标)由原 macOS 资源原样服务。
- 任务→防睡眠链路:向 hook 事件日志注入 `turn.started` → 看板 `protection` 变 `active/1`;`session.end` → `grace/0` → 5 分钟后 `released`(边界行为由单测锁定);`PowerCreateRequest` 冒烟测试确认 `powercfg /requests` 可见句柄。
- 合盖模式:`PowerRead/WriteAC|DCValueIndex` 真机读取 LIDACTION 冒烟通过;非管理员会话在任务激活时正确降级告警,写入/精确恢复/崩溃自愈(marker)由单测锁定。
- CodexWatch:真实 Worker 调用验证(`GET /v1/watch/quota` 返回 not shared、发布侧空数据防误清守卫生效);邮箱校验、周窗口起点推导、未来 sampledAt 回退、`account_key` 哈希映射均有单测向量锁定。
- 自动更新:真实 `GET /v1/app-update` 返回 `1.37.0` 并触发一次提醒(版本比较、24h 节流、按版本只提醒一次)。
- 托盘应用:单实例互斥、托盘图标渲染(详细文字/紧凑环双模式)、左键控制中心(Watched 账号卡片+更新横幅)、右键菜单(Clash 路由/连接/设置/退出),连续运行无崩溃。

## 已知差异与限制

- Kimi CLI 探测用普通管道而非 PTY:"Trust this folder?" 交互提示无法自动回应(会以 `workspaceTrustRequired` 上报);解析逻辑与 macOS 一致。
- Kimi 账号粘性(网络错误不切源)未移植,门面按固定顺序回退。
- 合盖模式通过 Power* API 读写当前方案的 LIDACTION(等价 `powercfg /setacvalueindex … LIDACTION`),需要管理员权限的应用进程——未实现 macOS 的特权 LaunchDaemon 服务形态;防睡眠本体(`PowerCreateRequest`)无需特权且崩溃安全,合盖改动带 marker 崩溃自愈。
- 热压力安全网无 Windows 等价物,空实现;电量 <20% 降级逻辑保留。
- 用量库为 JSON 缓存而非 SQLite WAL;无账号归属切分与云端 outbox 回执;团队上报只发未绑定事件(≤200/轮)。
- 团队浏览器 handoff:`TeamClient.RequestHandoffAsync` 获取 120s 单次票据并生成控制台 URL;`/admin` 代铸属 Worker 运营台(网页端),不在客户端范围。
- 自动更新目前只做检查、提醒并打开发布页；没有 Windows 自动下载/安装链路，不能仅修改服务端资产名就视为已支持。
- macOS v1.39.0 的公开 Codex 重置收件箱、重复通知、Dim 屏幕月亮标记、分屏亮度控制及凭据守护镜像都尚未移植。
- `AQB.Team` 接口已实现不等于当前桌面 App 具有完整团队流程；原生建队、加入、凭据写入及成员视图仍需补齐。
