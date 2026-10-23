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
- 本次已合入 macOS v1.38.5；Windows 使用独立预发布，不改变 macOS 稳定版或 `releases/latest`。

验证：2026-10-24 Windows Release 全套 **543/543 通过**；官网语法检查与 **124/124 测试通过**。macOS 测试未在 Windows 重跑，沿用 v1.38.5 发布记录中的结果。

打包：仓库根目录执行 `powershell -ExecutionPolicy Bypass -File win/scripts/package.ps1`，产物和校验清单位于 `win/artifacts/v1.38.6-beta.1/`。请在已提交的发布源码上构建，确保程序集的 SourceRevision 对应发布标签。

## 构建

### Codex 额度与连接排查

- Windows 默认读取 `CODEX_HOME`（未设置时为 `%USERPROFILE%\.codex`）中的登录信息，先请求 OAuth 额度接口；失败时通过本机 Codex CLI 的 `app-server` / `account/rateLimits/read` 回退查询。CLI 查询不创建对话或执行模型任务。
- 支持 PATH 中的 `codex.exe`，以及 `%APPDATA%\npm` / PATH 目录下 npm 安装的 Windows 原生 Codex 二进制。
- 只有周额度、没有 5 小时额度的账户，托盘仍显示可用的周额度。
- 同一账户刷新失败时，控制中心保留本次运行中上次成功的额度，并标明时间和错误；账号切换后不复用旧账号额度。
- SSL/TLS 错误会在 `%LOCALAPPDATA%\AIQuotaBar\app.log` 保留内层连接原因。控制中心错误提示的悬浮说明包含完整错误。OAuth 使用系统默认代理和证书验证，CLI 使用自身网络配置；回退不能保证修复两条路径共同的代理或证书故障。
- 当前回退仍需要可读取的 `auth.json`；尚未实现 macOS 全部数据源设置、Web 回退及完整额度附加信息的界面对齐。

要求:.NET 8 SDK(仅 Windows 桌面需要 Windows 系统)。

```powershell
cd win
dotnet build AIQuotaBar.Win.sln -c Release
dotnet test AIQuotaBar.Win.sln            # 全部单元/集成测试(529 项)
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
- 自动更新目前只做检查+提醒并打开发布页;Windows 安装包资产名(`.msi`/`.exe`)需 Worker 端 `/v1/app-update` 资产选择跟进后才会自动下载。
