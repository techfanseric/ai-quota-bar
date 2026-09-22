# Kimi 桌面端与网页端额度获取调研

调研日期：2026-09-22。范围：本项目代码、已安装的 Kimi.app、官方产品文档。未修改客户端存储，未将凭证写入日志或研究文档，未触发付费模型调用。

## 结论

已在本项目实现桌面端及网页数据源。本机 Kimi 3.2.12 使用加密 token store，已通过 `kimi-desktop Safe Storage` 钥匙串和 Electron v10 格式只读解密，在正式服务路径实测获得 5h、7d 额度。旧 Cookie 读取器保留为旧版本兼容路径。网页浏览器导入和海外账号仍待实机验证；尚未发布新版本。

## 实施前的项目状态

- `AIQuotaBar/Services/Kimi/KimiService.swift`：手填 API Key 时调用 Code API；留空时要求 CLI 凭证并执行 `/status`。因此并非只能通过 CLI，但自动登录态读取确实仅支持 CLI。
- `AIQuotaBar/ViewModels/UsageViewModel.swift` 的 `isConfigured`：只有 Keychain 中的手填凭证或 CLI 凭证才使 Kimi 参与刷新。仅改 fetcher 不足以支持桌面登录。
- `taskProtectionProviders` 也使用相同凭证判断；额度来源与本地工作活动必须分别处理，网页登录不能被当作本地 Agent 正在运行。
- `KimiUsageDataMapper` 仅映射 primary/secondary 为 7d/5h，未展示上游提供的会员总额度 extraRateWindows。

## 可复用能力

当前本地 `.dependencies/codexbar/Sources/CodexBarCore/Providers/Kimi/` 已包含：

| 能力 | 实现 | 限制 |
| --- | --- | --- |
| Code API 额度 | `KimiUsageFetcher.fetchCodeAPIUsage` | 需要 Code API 凭证 |
| 网页额度接口 | `KimiUsageFetcher.fetchUsage(authToken:)` | 当前固定 www.kimi.com，需有效网页登录态 |
| 旧桌面登录态 | `KimiDesktopAuthToken.load` | 只读取 kimi-desktop/Cookies 的明文 kimi-auth、限定 kimi.com 域名 |
| 浏览器登录态 | `KimiCookieImporter.importSessions` | 依赖浏览器 Cookie 访问权限、有效会话；本次未验证 |
| Code 共享凭证 | `KimiSettingsReader.kimiCodeAccessToken` | 要求未过期的本地 OAuth 凭证；不等同于普通 Kimi 桌面 token |

网页 fetcher 使用以下请求，属于已有实现证据，不是本次成功实测结果：

- `POST /apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`，scope 为 FEATURE_CODING。
- `POST /apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats`。
- `POST /apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription`。

后两者用于补充会员总额度和套餐。会员额度、Code 周限额、Code 短窗口限制应保留各自含义，不能用会员总额度替代 5h/7d。

## 初次调研观察

- `/Applications/Kimi.app`：bundle ID `com.moonshot.kimichat`，版本 3.2.12；另有 `KimiCU.app`，bundle ID `ai.kimi.cu`。不能仅凭名字把它们视为官方 Kimi Code Desktop。
- 只读查询 `~/Library/Application Support/kimi-desktop/Cookies` 与其工作浏览器分区：未发现 kimi-auth。主 Cookie 库同时存在 kimi.ai 与 kimi.com 域名记录，因此不可假定当前账号区域。
- `~/Library/Application Support/kimi-desktop/bridge-store/token-store.json` 存在，顶层为 `encryption` 和 `data`，加密格式为 `safeStorage.v1`。
- 已安装 app.asar 的主进程代码包含 Electron safeStorage 与 decryptString 的调用。这说明新登录态并非旧版明文 Cookie；本次没有解密数据，也没有确认加密内容中的字段或有效性。
- 由于没有获得可验证的网页登录态，本次没有发出带桌面凭证的额度请求。客户端运行中不等于已有可供本项目读取的有效凭证。

## 初次调研提出的实施顺序与验收

1. 增加可测试的数据源解析层，保留手填 API Key 的最高优先级。自动来源显示明确名称及账号标识；多个来源可能属于不同账号，不可静默拼接额度。
2. 适配新版桌面 token store：验证 macOS safeStorage 的合法读取方式、token 字段、过期状态与区域归属。只读客户端文件；不自行刷新、重写其 refresh token。桌面失效时提示在 Kimi 中重新登录。
3. 支持用户选择浏览器导入网页登录态，复用已有 importer。导入应在用户选择来源时发生，避免每次轮询扫描浏览器或触发钥匙串提示。
4. 保留 CLI 兼容来源；自动回退须遵守账号选择，不能因网络失败切到另一个账号。国内/海外 endpoint 必须经官方行为验证，不能盲目把同一 token 发送到两个站点。
5. 同步修改配置识别、设置说明和来源展示。额度来源与活动检测分别建模。
6. 补充会员总额度映射，保持 5h、7d 和会员总额度的标签、重置时间独立。

必要验证：桌面未安装/未登录、旧 Cookie、新 safeStorage、过期或损坏数据、客户端运行时读取、401/403、网络错误、取消请求、多账号、仅网页登录、海外区域；实机比较一次客户端或官网用量页面和项目显示。使用合成凭证 fixture，禁止将真实 token 写入测试、日志或研究文档。

## 官方依据

- [Kimi Code Desktop 快速开始](https://www.kimi.com/code/docs/kimi-code-desktop/getting-started.html)：Code Desktop 使用 OAuth，国内和海外登录站点不同；与 CLI 共享部分账号、模型及插件配置，具体共享范围以配置为准。这不能推导为普通 Kimi 桌面也使用同一路径。
- [Kimi Code 权益与计费说明](https://www.kimi.com/help/kimi-code/benefits)：用于核对会员权益与 Code 使用限制的产品含义。

以上接口与本地存储结论来自当前代码及本机版本观察，并非官方稳定集成协议承诺。

## 已实施（同日更新）

- `KimiDesktopSessionReader`：支持 `safeStorage.v1` / v10 密文，准确限定钥匙串 service；只读取 access_token 和原始 origin，不刷新或修改客户端凭证。后台通过 LAContext 禁止交互，设置中的显式按钮可以请求授权。
- `KimiWebSession`：凭证绑定精确的 www.kimi.com / www.kimi.ai origin，验证 JWT 过期时间；不自动跨区域重试。账号标识参与模型 ID，避免桌面/网页账号历史混用。
- `KimiWebUsageClient`：官网只读额度请求，短超时的可选会员额度补充。禁止 HTTP 重定向，不记录返回正文或 token。会员失败不丢弃 Code 额度；无 Code 限额时仍可展示有效会员总额度。
- `KimiService`：自动模式使用 API Key → 有效 Desktop → 已保存 Web → CLI → 自动检测的浏览器登录；可明确选择 Desktop、CLI 或 Web。请求失败不会回退到另一个账号。
- `KimiSourceSection`：显式浏览器导入、候选账号选择、手动 Cookie 输入、验证保存与移除。网页登录存入现有本机 device credential vault，轮询不扫描浏览器。浏览器导入当前限定 kimi.com，海外使用手动输入。
- 配置识别支持桌面来源；来源改变会清除旧结果并丢弃旧请求。网页登录不被当作本地 CLI 活动。
- 配额映射展示 Code 短窗口、7d、会员总额度；未知短窗口不会被标为 5h，会员总额度不臆造月周期起始时间。

### 验证记录

- Swift Debug 构建通过；`make sign` 完成 Release 应用打包及本地 ad-hoc 签名验证，产物为 `dist/AIQuotaBar.app`。本轮在验证后重装到 `/Applications/AIQuotaBar.app` 并重启；不发布公共版本。
- Kimi 相关 28 项测试：26 项通过，2 项 opt-in 实机测试默认跳过；覆盖解密 fixture、来源隔离、取消、HTTP 错误、区域、会员补充失败、映射及既有菜单展示。
- `AIQUOTABAR_LIVE_KIMI_DESKTOP_TEST=1 swift test --filter KimiWebSourceTests.testLiveAutomaticDesktopWhenExplicitlyEnabled` 通过：正式路径实际读取当前桌面登录并取得 5h / 7d 数据。
- 完整回归：应用测试 377 项，4 项 opt-in 测试跳过；核心测试 41 项，2 项 opt-in 测试跳过；均无失败。
- 浏览器导入与海外账号未实机验证；新网页登录格式如不再提供 kimi-auth，可使用桌面来源。登录过期要求官方客户端重新登录，网页来源重新导入。

加密机制背景：[Electron safeStorage 官方文档](https://www.electronjs.org/docs/latest/api/safe-storage)。

## 自动检测更新

用户要求无需手动选择来源，并在完成后重装、重启。

- 默认自动模式优先读取有效桌面登录；过期、损坏或无权读取的本地登录不阻断后续来源。已保存网页登录其次，CLI 不可用时继续查找浏览器登录。
- 浏览器检测严格使用 background 访问上下文，禁止弹出钥匙串交互；正、负结果均缓存 5 分钟，并发刷新共享扫描。多个不同网页账号不自动任选一个；同账号多个 profile 使用较新的 token。
- 启动刷新在供应商配置过滤前执行发现，网页单独登录也可被识别。扫描不会写入 Kimi 或浏览器凭据。
- 手动来源、导入与授权入口收进高级选项。已保存 API Key 保持最高优先级。
- 已选中有效桌面/网页登录后的网络、服务端错误不引发跨账号回退；取消会停止整个检测链。
- 实机遇到桌面 token 过期（短期登录态），官方客户端打开会员入口后自行更新；无需变更额度来源，自动模式实测重新读到 Desktop 的 5h/7d。项目不接管官方 refresh token 的轮换。
- 本地安装构建号提升为 51，以便核对实际运行的新构建。

### 自动检测版安装验收

- 完整测试：应用 387 项（4 项跳过）、核心 41 项（2 项跳过），0 失败。
- 自动模式桌面实机测试通过，无需设置 desktop 模式。
- 已完成 `make install`，新应用安装至 `/Applications/AIQuotaBar.app`，版本 1.23.1，构建 51。
- 已停止旧进程并重启新进程；2026-09-22 20:36:31 启动的进程 PID 19024 使用上述安装路径。
- 已安装可执行文件与 dist 产物 SHA-256 相同：`f60280f2f4b79f98f96a00922e1e27c7fd4e1882f599541aed61dc172915c96a`；签名验证通过。
- 运行中应用写入的最近成功来源为 `Kimi Desktop`；未设置 kimiSourceMode，使用默认自动检测。该状态只在真实请求成功并映射完成后更新，不包含 token。
- 新设置页展示最近成功来源。重启后 GUI 自动化取窗口超时，因此运行验收依据安装路径、构建号、哈希、活动进程及成功来源状态，而非截图。
