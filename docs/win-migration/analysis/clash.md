# Clash/Mihomo 集成模块分析（Windows 迁移规格）

> 源码范围：`AIQuotaBar/Services/Clash/`（11 个文件）、`AIQuotaBar/Tests/Clash/`（7 个测试文件）、`AIQuotaBar/Views/Clash*.swift`（3 个视图）、`AIQuotaBar/App/StatusBarController.swift`、`AIQuotaBar/App/ClashRoutePopoverController.swift`、`AIQuotaBar/Services/Codex/CodexConnectivityMonitor.swift`、`AIQuotaBar/Models/AppLanguage+Clash.swift`、README.md。
>
> 本文档为迁移到 C# .NET 8（Windows）的功能规格基准。所有行为均以源码与单元测试为准。

---

## 0. 模块总览

| 能力 | 入口 | 核心文件 |
|---|---|---|
| 控制器发现 | `ClashConfigurationDiscovery.discover()` | ClashConfigurationDiscovery.swift |
| REST/WS 客户端 | `ClashAPIClient` | ClashAPIClient.swift |
| 路由面板（切换/测速/筛选） | `ClashRouteViewModel` + `ClashRoutePopoverView` | ClashRouteViewModel.swift |
| 自动恢复 | `ClashRouteViewModel.attemptAutomaticRecovery(connectivityProbe:)` + `StatusBarController.beginAutomaticRecovery()` | 上述 + CodexConnectivityMonitor.swift |
| 恢复通知 | `ClashRecoveryNotificationService` | ClashRecoveryNotificationService.swift |
| 连接监控 | `ClashConnectionViewModel` + `ClashConnectionPopoverView` | ClashConnectionViewModel.swift |
| 面板折叠/布局 | `ClashPanelDisplayStore` + `ClashPopoverLayout` | ClashPanelDisplayStore.swift / ClashPopoverView.swift |

关键不变量：
- 连接监控是**只读**的（UI 明示 "Read-only monitoring"，绝不调用 DELETE /connections）。
- 只有用户点击行或自动恢复流程会调用 `PUT /proxies/:group` 切换线路；打开面板、手动测速、开关自动恢复选项都不会切。
- 控制器只允许 loopback 地址（安全边界，README 隐私章节明确声明）。

---

## 1. 控制器发现（ClashConfigurationDiscovery）

### 1.1 发现方式：只读配置文件，无端口扫描

不扫描端口。按顺序读取候选配置文件，取第一个**文件存在且含 `external-controller` 顶层键**的：

| 顺序 | 客户端名 (clientName) | 配置路径（macOS） |
|---|---|---|
| 1 | `Clash Verge Rev` | `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml` |
| 2 | `Mihomo` | `~/.config/mihomo/config.yaml` |
| 3 | `Clash` | `~/.config/clash/config.yaml` |

Windows 迁移注意：需替换为 Windows 上的等价路径。Clash Verge Rev 在 Windows 的运行时配置通常在 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml`（或 `clash-verge.yaml`/`verge.yaml`，迁移时需实测确认）；Mihomo/Clash 仍可用 `%USERPROFILE%\.config\mihomo\config.yaml`、`%USERPROFILE%\.config\clash\config.yaml`。发现顺序与「找到文件但无 external-controller」的错误语义必须保持。

### 1.2 错误语义（必须一致）

- 任何候选文件**存在**但都解析不出 `external-controller`（或值为空）→ 抛 `externalControllerDisabled`（UI：'Clash External Controller 尚未开启。'）。
- 所有候选文件都不存在 → 抛 `configurationNotFound`（UI：'未找到受支持的 Clash 配置。'）。
- 即：找到一个文件但键缺失 = 「控制器被禁用」；一个文件都找不到 = 「配置不存在」。测试 `testDiscoversClashVergeRuntimeConfiguration` 验证了完整链路。

### 1.3 YAML 解析（ClashTopLevelYAML）

不引入 YAML 库，只解析**顶层标量键**（手写解析器）：

- 只处理「行首非空白、非 `#`、且含 `:`」的行（嵌套键因有缩进被天然忽略——测试确认 `dns:` 下的 `secret: nested-value` 不会覆盖顶层 `secret`）。
- key = 首个 `:` 之前的文本 trim 后；value = 之后全部文本经 `decodeScalar`。
- `decodeScalar` 规则：
  - 单引号：取首尾引号间内容，`''` 转义为 `'`；找不到闭合则去掉首引号返回剩余。
  - 双引号：优先将整个带引号串按 JSON 字符串解码（处理 `\"` 等转义）；失败则取到闭合双引号（带转义状态机判断闭合）。
  - 否则去掉 ` #` 起的行内注释（注意：注释前必须有空格），再 trim。
- 测试断言：`secret: 'value # with comment'` → `value # with comment`；`mode: rule # active mode` → `rule`。

### 1.4 地址归一化与 loopback 限制（controllerURL(from:)）

对 `external-controller` 原始值依次处理：

1. trim；若以 `:` 开头（如 `:9097`）→ 前缀补 `127.0.0.1`。
2. `*:9097` → `127.0.0.1:9097`；`0.0.0.0:9097` → `127.0.0.1:9097`；`[::]:9097` → `127.0.0.1:9097`。
3. 不含 `://` → 前缀 `http://`。
4. URL 解析失败 / 无 host / 无端口或端口 ≤ 0 → `invalidControllerAddress(原始串)`。
5. host（小写）必须在 `{127.0.0.1, localhost, ::1}` 集合内，否则抛 `unsafeControllerHost(host)`（UI：'仅支持连接本机 Clash 控制器。'）。测试确认 `192.168.1.2:9097` 被拒绝、`0.0.0.0:9097` 归一化为 `http://127.0.0.1:9097`。

### 1.5 产物

`ClashControllerConfiguration { baseURL: URL, secret: String, clientName: String, configURL: URL }`。`secret` 直接取 YAML 顶层 `secret`（缺失 = 空串 = 不带鉴权头）。

---

## 2. REST / WebSocket API 用法清单（ClashAPIClient）

### 2.1 通用请求约定

- Header：`User-Agent: AIQuotaBar/ClashIntegration`；secret 非空时 `Authorization: Bearer <secret>`（PUT 的 body 为 JSON，带 `Content-Type: application/json`）。
- HTTP 超时：请求 8s / 资源 10s；WebSocket 会话：请求 8s / 资源 24h。
- `URLSessionConfiguration.ephemeral` + `connectionProxyDictionary = [:]`（**绕过系统代理**，避免 API 请求被 Clash 自身代理劫持——Windows 上等价于 `HttpClient` 设 `UseProxy=false` 或 proxy 设为 `null`）。
- 缓存策略 `reloadIgnoringLocalAndRemoteCacheData`。
- 响应处理：非 2xx → 尝试解码 `{"message": "..."}` 作为错误消息，否则用 HTTP 状态描述 → 抛 `apiFailure(statusCode, message)`；传输层错误 → `controllerUnavailable`；JSON 解码失败 → `incompatibleResponse`。
- 路径拼接：baseURL 逐段 append（group 名等不做额外 URL 编码——迁移时注意与 Swift `URL.append(path:)` 行为对齐，特别是含 `[]`、emoji、空格的组名）。

### 2.2 端点清单

| 功能 | 端点 | 请求 | 响应/关键字段 |
|---|---|---|---|
| 健康检查 | `GET /version` | — | `{ "meta": Bool?, "version": "..." }`。每次 refresh/monitor 建连前先调它验证控制器活着 |
| 全量代理 | `GET /proxies` | — | `{ "proxies": { "<名称>": { "name": String?, "type": String, "now": String?, "all": [String]?, "history": [{ "time": String?, "delay": Int }]? } } }` |
| 规则列表 | `GET /rules` | — | `{ "rules": [{ "type": String, "payload": String, "proxy": String }] }` |
| 组测速 | `GET /group/:groupName/delay?url=https://chatgpt.com/&timeout=5000&expected=200-499` | — | `{ "<节点名>": <延迟ms Int>, ... }`（失败/超时节点不在结果中）。注意：**没有用** `GET /proxies/:name/delay` 单节点端点 |
| 切换选择 | `PUT /proxies/:groupName` | body `{"name": "<节点名>"}` | 204（只要 2xx 即成功） |
| 连接快照 | `GET /connections` | — | 同 WebSocket 单帧结构（备用/测试用） |
| 连接流 | `WS /connections?interval=<ms>` | interval = `max(250, 传入值)`；实际传 live 1000 / 后台 60000 | 每帧推送完整快照 |

WebSocket 请求构造：把已构造好的 HTTP 请求 URL 的 scheme `http→ws`、`https→wss`（已是 ws/wss 则不动；其它 scheme 抛 `invalidControllerAddress`），鉴权头沿用。消息帧 `data` 或 `string` 均支持（string 转 UTF-8）；单帧解码失败 → 流以 `incompatibleResponse` 终止；取消时以 `.goingAway` 关闭。

### 2.3 连接快照 JSON 结构（ClashConnectionsResponse）

```json
{
  "downloadTotal": 1234, "uploadTotal": 567, "memory": 999,
  "connections": [{
    "id": "connection-1",
    "download": 400, "upload": 100,
    "chains": ["AI group", "JP 01"],
    "rule": "DomainSuffix", "rulePayload": "openai.com",
    "start": "2026-07-29T07:00:00.123456Z",
    "metadata": {
      "network": "tcp", "type": "HTTP",
      "destinationIP": "203.0.113.1",
      "host": "api.openai.com",
      "process": "Codex", "processPath": "/Applications/Codex.app",
      "remoteDestination": "api.openai.com:443",
      "sniffHost": ""
    }
  }]
}
```

模型只解码上列字段（`memory` 等被忽略；`downloadTotal/uploadTotal` 可空、当前计算未使用——速率按每连接增量自算）。`start` 解析：先试带小数秒的 ISO8601，再试不带（`ClashConnectionDateParser`，两种都必须支持）。

---

## 3. 路由面板行为（ClashRouteViewModel + ClashRoutePopoverView）

### 3.1 找 OpenAI 策略组的算法（ClashOpenAIRouteResolver.resolveGroupName）

输入：`GET /rules` 的 rules（按序）+ `GET /proxies` 的 proxies。

1. **收集候选**：`proxies` 中 `type` 忽略大小写等于 `"Selector"` 且 `all` 非空（可切换的组）。URLTest 组不算。
2. **规则优先**：按规则顺序找第一条「OpenAI 规则」且其 `proxy`（目标组名）在候选集合中 → 返回该组名。OpenAI 规则判定（`type` 先小写并**只保留字母**归一化；`payload` trim + 小写）：
   - `domain`：payload 完全等于 `openai.com` 或 `chatgpt.com`。
   - `domainsuffix`：`{openai.com, chatgpt.com}` 中任一 domain 满足 `domain == payload || domain.hasSuffix("." + payload)`（即 payload 为 `openai.com`/`chatgpt.com` 或其父后缀，如 `com` 也命中——按源码行为保留）。
   - `domainkeyword`：payload 包含 `openai` 或 `chatgpt` 子串。
   - `ruleset` / `geosite`：payload == `"ai"`，或包含 `openai` / `chatgpt` / `category-ai` / `ai-chat`。注意 payload `"private_domain"` 不命中（有专门测试）。
   - 其它 type 一律不命中。
3. **名称兜底**：没有规则命中时，候选组按 `localizedStandardCompare`（本地化自然排序）升序，取第一个名字「像 OpenAI 组」的：小写后包含 `openai` / `chatgpt` / `海外ai` / `人工智能`，或匹配正则 `(^|[^a-z])ai([^a-z]|$)`（忽略大小写，即独立的 "ai" 单词，如 `[类]-海外AI🤖`）。
4. 都没有 → `strategyGroupNotFound`（UI：'没有找到可切换的 OpenAI 策略组。'）。

### 3.2 路由快照与排序

`loadRouteSnapshot()` 并发 `GET /proxies` + `GET /rules` → 解析组 → `routes = group.all.map { name, proxy → ClashRoute(name, type: proxy?.type ?? "Unknown", delay: proxy?.history?.last?.delay, isSelected: name == group.now) }`。

排序（`ClashRouteSorter`，必须与测试一致）：
1. `hasUsableDelay`（delay != nil 且 > 0）的在前。
2. 都可用：delay 升序；delay 相同 → 名字 `localizedStandardCompare` 升序。
3. 都不可用（delay 为 0=超时 或 nil=未测）→ 名字自然排序兜底。
4. 测试基准：`fast(72) < slow(210) < timeout(0) < unknown(nil)`。

测速后（见 3.4）列表重新按此排序，`delay = 结果[名] ?? 0`（缺结果的节点记 0=超时）。

### 3.3 延迟展示规则

- `delay == nil` → `—`；`delay == 0` → '超时'/'Timeout'；否则 `"<n> ms"`。
- 颜色：`< 120` 绿、`< 300` 橙、否则红；不可用值用次级色 65% 透明。

### 3.4 测速（testRoutes / performSpeedTest）

- 端点：`GET /group/:group/delay?url=https%3A%2F%2Fchatgpt.com%2F&timeout=5000&expected=200-499`。默认目标 URL 固定 `https://chatgpt.com/`，**超时 5000ms**，期望状态码 200-499。
- `testRoutes()` 只测速+排序，**不改当前选中**（代码注释明确：自动切换只属于恢复流程）。若 phase 不是 ready，先 refresh 再测（一次递归）。
- 互斥：`isSpeedTesting`/`isSwitching` 任一为 true 时不再进入。
- 状态文案：测速中「正在测速…」→ 完成「测速完成。」/ 失败「测速失败：<错误>」。

### 3.5 手动切换（selectRoute）

- `PUT /proxies/:group {"name": route}` → 成功后本地更新 `selectedRouteName`、行 isSelected 标记，并记录切换历史；失败 → 状态栏「线路切换失败：<错误>」。
- 切换期间所有行禁用（`isSwitching`）。
- **外部变更检测**：`refresh()` 应用快照时，若 groupName 未变而 `selectedRouteName` 变化（用户在 Clash 客户端里切的），同样记入切换历史。

### 3.6 筛选（ClashRouteFilter）——国家搜索 / 正则

持久化：查询串 `clashRouteFilterQuery`、正则开关 `clashRouteFilterUsesRegularExpression`（UserDefaults）。`isFilterEditing` 是纯 UI 态（只读展示 vs 编辑态，需显式进入/退出；测试确认重建 VM 后查询串保留、编辑态复位为 false）。

**归一化 normalize**：`folding(caseInsensitive + diacriticInsensitive + widthInsensitive, locale: en_US_POSIX)` → 小写 → trim。（全角/半角、变音符折叠；Windows 上可用 `string.ToLowerInvariant()` + 手工 NFKD 宽度折叠近似，注意中日文别名不受影响。）

**正则模式**（usesRegularExpression=true）：
- 用 `NSRegularExpression`（.NET 用 `Regex`，`RegexOptions.IgnoreCase`）对**原始（未归一化）节点名**做「任意位置匹配」。
- 非法正则 → 返回空列表 + `errorMessage`（UI：红框 + 「正则表达式无效：…」，输入框描红）。
- 测试基准：`^(🇯🇵|SG-).*(01)$` 命中两条；`^JP` 命中 0 条（正则匹配原始名，不做国家别名展开）。

**模糊模式**（默认）：
1. trim 后为空 → 全量返回。
2. 归一化后的节点名包含归一化查询串 → 命中（如 `家宽`）。
3. 否则做**国家别名匹配**：查询串归一化后与某国家的某个别名**完全相等** → 得到查询国家集合；节点名若包含任何国家的任何别名（别名判定见下）且其国家集合与查询集合有交集 → 命中。
4. **短别名防误伤**：若归一化别名匹配 `^[a-z]{2,3}$`（如 `JP`、`SG`、`US`），用词边界正则 `(^|[^a-z])<alias>([^a-z]|$)`（忽略大小写）匹配，避免 `JP` 命中 "Japan" 之外的假阳性（如 `us` 命中 "Russia"）；旗帜 emoji 与中日文别名走包含匹配。
5. 国家别名表（12 国，迁移必须原样保留）：

| 代码 | 别名 |
|---|---|
| JP | 🇯🇵, 日本, Japan, JP |
| SG | 🇸🇬, 新加坡, Singapore, SG |
| US | 🇺🇸, 美国, United States, USA, US |
| HK | 🇭🇰, 香港, Hong Kong, HK |
| TW | 🇹🇼, 台湾, 臺灣, Taiwan, TW |
| KR | 🇰🇷, 韩国, 韓國, Korea, KR |
| GB | 🇬🇧, 英国, 英國, United Kingdom, UK, GB |
| DE | 🇩🇪, 德国, 德國, Germany, DE |
| FR | 🇫🇷, 法国, 法國, France, FR |
| CA | 🇨🇦, 加拿大, Canada, CA |
| AU | 🇦🇺, 澳洲, 澳大利亚, Australia, AU |
| NL | 🇳🇱, 荷兰, 荷蘭, Netherlands, NL |

6. 测试基准：查询 `🇯🇵` / `日本` / `JP` / `Japan` 结果完全相同（命中 `🇯🇵 Tokyo 01` 与 `日本-家宽-02` 两条）；`家宽` 命中 1 条。

### 3.7 协议徽章（ClashRouteTypeBadge）

`type` 小写并只保留字母数字后映射：

| 原始 type | 徽章 |
|---|---|
| hysteria2 / hy2 | H2 |
| hysteria | HY |
| vless | VL |
| vmess | VM |
| anytls | TLS |
| shadowsocks / ss | SS |
| trojan | TR |
| wireguard / wg | WG |
| tuic | TU |
| snell | SN |
| ssh | SSH |
| 其它非空 | 前 3 个字符大写（如 `Custom Proxy`→`CUS`，URLTest→`URL`） |
| 空 | `—` |

徽章 18×16pt 圆角胶囊，选中态强调色；tooltip 显示完整 type。测试断言 Hysteria2→H2、VLESS→VL、AnyTLS→TLS、WireGuard→WG、`Custom Proxy`→CUS。

### 3.8 最近 3 次切换历史（ClashRouteSwitchHistoryStore）

- 记录结构：`{ id: UUID, switchedAt: Date, fromRoute, toRoute }`；UserDefaults key `clashRouteSwitchHistory`，JSON 编码数组。
- 容量 3：写入时 `[新记录] + 旧记录` 按 `switchedAt` 降序取前 3 持久化；`load()` 同样排序截断。`from == to` 不记录（no-op）。测试断言连续记录 4 次后只剩最近 3 条（to 依次 Route4/3/2）。
- 时间格式（ClashRouteSwitchTimeFormat，相对当前时间，`elapsed = max(0, now-date)`）：
  - `< 60s` → `now` / `刚刚`
  - `< 1h` → `Nm ago` / `N 分钟前`（N = max(1, elapsed/60)，59m59s 仍显示 59m）
  - 同一天 → 仅时刻（短格式，如 `14:05`）
  - 跨天 → `MM-dd HH:mm`（24 小时制）
- UI：面板底部「最近切换」区，每行 `from → to`（中截断 + tooltip 全名）+ 相对时间；TimelineView 每 60s 重算一次；空历史显示「暂无切换记录」。

### 3.9 面板 UI 行为（ClashRoutePopoverView）

- 右键菜单栏图标打开整版面板（宽 296pt，基准高 850pt）；路由分区固定高 334pt（收起 30pt），列表最小高 96pt。
- 打开面板 → `prepareForDisplay(automaticallyTest: !路由区收起)`：先 refresh（发现+version+快照），ready 后自动测速一次。展开路由分区同样补一次自动测速（「用户想看」语义）。
- ready 态头部：组名（次级色）+「可见/总数 条线路」计数；加载中转圈；不可用态显示错误 + 帮助文案 +「重试」按钮（重试时 automaticallyTest=true）。
- 空筛选结果：「没有线路符合当前筛选条件。」+ 建议。
- 行：徽章 + 节点名（选中加粗 + checkmark 强调色 + 6.5% 强调色底）+ 延迟（右对齐、等宽数字）。点击行即切换。
- 底部状态条：进度点/圈 + statusMessage + clientName（如 "Clash Verge Rev"）。
- 「连接异常时，自动切换到筛选结果中的最快线路」开关（UserDefaults `clashRouteAutoSelectBest`）；开启但筛选为空时提示「输入筛选条件后，自动恢复才会生效。」

---

## 4. 自动恢复状态机

### 4.1 故障检测（CodexConnectivityMonitor / Checker）

- **探测请求**：对 `https://chatgpt.com/` 与 `https://openai.com/` 各发一个 **HEAD** 请求（不是 DNS、不是 ICMP）。每个请求超时 **3 秒**（request 与 resource 均 3s）；ephemeral 会话、无 cookie、无缓存、UA `AIQuotaBar/Connectivity`。
- 判定：**收到任何 HTTP 响应（任意状态码）= 该端点可达**；DNS/连接/超时异常 = 不可达。两端点**并发**探测，任一可达即整体 `reachable`（提前取消其余）；都失败才 `unreachable`。
- 周期：循环「探测 → 睡 8~12 秒抖动（`8 + rand*4`）」；每次结果驱动状态更新。
- `recheckNow()`：**新建**一个 checker/会话立即探测——避免换线路后旧路由的连接池连接掩盖新路由状态（Windows 迁移同样要新建 `HttpClient`/`SocketsHttpHandler` 做即时复检）。

### 4.2 触发条件（StatusBarController.handleConnectivityCheck）

监听连通性状态每次变化：

1. 前提：Codex 供应商已配置（`configuredProviders.contains(.codex)`），否则清零计数返回。
2. 「跟随运行中的应用」开启且 Codex 未运行 → 清零计数、清 `hasHandledCurrentOutage`，不触发（探测此时也已停止）。
3. `reachable` → 计数清零、`hasHandledCurrentOutage = false`。
4. `unreachable` → `consecutiveUnreachableChecks += 1`；当 **`>= 2`**（即两个域名同时失败、连续 2 个探测周期）且 `!hasHandledCurrentOutage` 且 `recoveryTask == nil` → 置 `hasHandledCurrentOutage = true`，启动 `beginAutomaticRecovery()`（同一轮故障只处理一次）。

README 口径：「openai.com 与 chatgpt.com 连续两次失败后才行动；打开面板、测速、开关选项都不会触发」。

### 4.3 恢复流程（attemptAutomaticRecovery）——守卫按序评估

| # | 守卫 | 结果 |
|---|---|---|
| 1 | `autoRecoveryEnabled == false` | `.needsAttention(shouldTestWhenShown: true)` → 直接弹出路由面板并自动测速 |
| 2 | 筛选为空（`hasActiveFilter == false`） | `.needsAttention(true)` |
| 3 | 正则筛选非法（`filterErrorMessage != nil`） | `.needsAttention(false)`（弹出但不自动测速） |
| 4 | 正在 preparing / 测速 / 切换中 | `.suppressed`（静默，什么都不做） |
| 5 | 距上次恢复尝试 < **10 分钟**（`clashRouteLastRecoveryAttempt` 存 UserDefaults，Date） | `.suppressed`；否则立刻写入本次时间戳（**先占坑再干活**，防并发重入） |

通过守卫后：
1. `refresh()`：重新发现配置 + `GET /version` + 路由快照；失败 → `.needsAttention(false)`。
2. `performSpeedTest()`（组测速，参数同 3.4）；失败 → 状态栏「测速失败：…」+ `.needsAttention(false)`。
3. 候选 = **筛选后的路由中 delay > 0 的前 3 个**（测速后已按延迟升序，即「从快到慢」）。为空 → 「自动恢复未能重新连接 OpenAI…」+ `.needsAttention(false)`。
4. 逐个尝试候选：
   - 候选 ≠ 当前选中 → `selectRoute(候选)`；切换失败 → `continue` 试下一个。
   - 切换（或本已是该线路）后调 `connectivityProbe()`（即 `connectivityMonitor.recheckNow() == .reachable`，全新会话即时复检）。
   - 可达 → 返回 `.recovered(ClashRecoveryResult(previousRoute: 恢复前选中名（nil 则 "—"）, selectedRoute: 候选名, delay: 候选 delay ?? 0))`，**立即停止**，不再回滚。
5. 3 个候选全部探测失败 → 状态栏恢复失败文案 + `.needsAttention(false)`。

注意：`previousRoute` 记录的是流程开始时的原始线路；若最终选中的就是原线路（第一候选恰为当前线路且复检成功），`didSwitchRoute == false`，不发通知。

### 4.4 结果分发（StatusBarController.beginAutomaticRecovery）

- `.recovered(result)` → `ClashRecoveryNotificationService.notifyRecovery`（`didSwitchRoute == false` 时静默跳过）。
- `.suppressed` → 无动作。
- `.needsAttention(shouldTestWhenShown)` → `showClashRoutes(automaticallyTest: shouldTestWhenShown)`（自动弹出整版右键面板，必要时自动测速）。

### 4.5 通知（ClashRecoveryNotificationService）

- 系统通知（macOS UNUserNotificationCenter；Windows 用 ToastNotification）。授权状态 authorized/provisional/ephemeral 直接发；notDetermined 现场请求 alert+sound；denied/未知 → 不发。
- 标题：'OpenAI 线路已自动恢复' / 'OpenAI route recovered'。
- 正文：`检测到连接异常，已从「<from>」切换到「<to>」（<delay> ms）。`（英文对应）。带默认声音，无触发器（立即）。
- identifier：`clash-recovery-<UUID>`。
- userInfo：`{ "notificationAction": "openClashRoutes" }` —— 点击通知回调（AppDelegate）据此调用 `showClashRoutes()` 打开路由面板。Windows 上等价于 Toast 的 protocol/activation 参数路由。

### 4.6 跟随模式联动（updateClashWorkGating）

「跟随运行中的应用」开启且 Codex 未运行时：自动收起路由/连接分区（`alignWithCodexPresence`）、暂停连接后台轮询（`setBackgroundMonitoringAllowed(false)`）、**停止连通性探测**（`connectivityMonitor.stop()`）——自动恢复自然不会触发。Codex 运行或跟随关闭 → 恢复。

---

## 5. 连接监控（ClashConnectionViewModel + ClashConnectionPopoverView）

### 5.1 数据通路与采样间隔

- 每轮：重新 `discover()` → `GET /version` 验活 → 订阅 `WS /connections?interval=<ms>` 持续收帧。流意外结束视作 `controllerUnavailable` 进入重试。
- 两种档位：
  - **Live（面板/移动面板打开时）**：`interval=1000ms`（1 秒/帧），失败重试延迟 **3 秒**。
  - **后台**：`interval=60000ms`（1 分钟/帧），失败重试延迟 **60 秒**。
- WS interval 下限 250ms（客户端钳制）。
- 生命周期（多 owner 计数，`liveUpdateOwners: Set<String>`，默认 owner "popover"，移动面板用 `MobileDashboardService.liveUpdateOwner`）：
  - App 启动即 `startBackgroundMonitoring()`（后台档常开）。
  - 面板展示且连接分区未收起 → `beginLiveUpdates()`；收起/关闭面板（`onDismiss`/`onDisappear`）→ `endLiveUpdates()`；最后一个 owner 退出时保存历史并回落后台档。
  - `stop()`（应用退出）：取消任务、保存历史。
  - 每次重启监控：代际号 `monitoringGeneration+1` 使旧任务退出，`activityCalculator.reset()`（速率基准清零）。
  - 不可用态：清空连接/速率、重置计算器、`phase = .unavailable(错误文案)`。
- 跟随模式 Codex 未运行 → 后台档暂停（live 档不受影响，见 `isBackgroundAllowed` 注释）。

### 5.2 OpenAI 连接过滤（ClashOpenAIConnectionFilter）

观测域名集合：`{"openai.com", "chatgpt.com"}`（固定，UI 副标题明示「仅活跃连接 · openai.com | chatgpt.com」）。

- 候选字段（任一命中即算）：`metadata.host`、`metadata.sniffHost`、`metadata.remoteDestination`、`rulePayload`。
- host 归一化（normalizedHost）：trim + 小写 → 若能按 URL 解析出 host 则取 host → 去掉 `+.` 前缀或开头的 `.` → 去尾部 `:端口`（仅当不含 `]`（非 IPv6 字面量）且冒号后全为数字）→ 去尾部 `.`。
- 命中：归一化后 `== 域名` 或 `hasSuffix("." + 域名)`。
- 测试基准（必须一致）：
  - 命中：`openai.com`、`api.openai.com`、`chatgpt.com:443`、`https://ab.chatgpt.com/path`、sniffHost=`ios.chatgpt.com`、rulePayload=`+.openai.com`。
  - 不命中：`notopenai.example`、`openai.example.com`、`oaistatic.com`、`chatgpt.example`。
- 显示 host（displayHost）：host → sniffHost → remoteDestination 依次取第一个归一化后非空的；都空 → `destinationIP`；再空 → `—`。

### 5.3 速率计算（ClashConnectionActivityCalculator）

- 状态：`[连接id → (上次 upload, 上次 download, 上次观测时间)]`，每帧全量重建。
- 每连接速率：`speed = (当前字节 - 上次字节) / elapsed`，仅当 `上次存在 && 当前 >= 上次 && elapsed > 0`，否则 0。首帧（新 id）与计数器回退（Clash 重启）都为 0 —— 测试 `testNewAndResetConnectionsDoNotCreateSpeedSpikes` 锁定「新连接/重置连接不得产生速率尖峰」。
- 连接时长 `duration = max(0, 观测时间 - start解析值)`；`startedAt` 解析失败为 nil、duration 0。
- 列表排序：`startedAt` 降序（新连接在上；nil 视为 distantPast）；相同则 host `localizedStandardCompare` 升序。
- 面板总量：三条指标卡 —— 总下载速率（蓝 ↓）、总上传速率（紫 ↑）、活跃连接数（橙）= 过滤后各连接速率求和。
- 速率格式（rate，十进制 1000 进位）：`B/s→KB/s→MB/s→GB/s`；缩放后 ≥100 或单位是 B/s 取整（%.0f）；≥10 一位小数；否则两位小数。
- 时长格式（duration）：<60s → `Xs`；<60m → `Xm Ys`；<24h → `Xh Ym`；再大 → `Xd Yh`（负数钳 0）。
- 行详情（detail）：`network.uppercased() · 链路首节点`（`chains.first`），空段跳过；两段皆空返回 nil 不显示。测试：`("tcp","Japan 01")→"TCP · Japan 01"`、`(" udp ",nil)→"UDP"`、`(nil,"Singapore 02")→"Singapore 02"`、`(" ",nil)→nil`。

### 5.4 连接年龄颜色分级

- `oldestColorAge = 3600s`（**60 分钟从绿到橙**，线性插值，`progress = clamp(age/3600, 0, 1)`）。
- 新连接色 RGB `(0.20, 0.78, 0.35)`（绿）；最旧色 `(1.00, 0.49, 0.05)`（橙）。负年龄钳为 0，≥1h 钳为 1（测试 `testAgeScaleClampsAtOneHour`：-1→0，30min→0.5，2h→1）。
- 应用位置：行首 24×24 圆形图标（填充色 16% 透明度 + 前景色同色）、右侧时长文字同色；图表图例「新→旧」渐变条。

### 5.5 60 分钟图表（ClashConnectionHistory + ClashConnectionActivityChart）

- 采样：`sampleInterval = 60s`，`retainedSampleCount = 60` → 覆盖 60 分钟。每帧观测时对齐到分钟栅格（`minuteStart = floor(epoch/60)*60`），同一分钟内多次观测**覆盖**该分钟样本；保留时间戳 ≥ `当前分钟 - 59×60` 的样本，升序。测试：65 条旧样本 upsert 后恰 60 条、当前分钟被替换。
- 样本结构 `ClashConnectionHistorySample { timestamp, connectionAges: [TimeInterval] }` —— **只存时长数组**（降序），不存 host/process/IP（隐私；测试断言持久化文本不含 `openai.com`/`process`/`destinationIP`）。`connectionCount = connectionAges.count`。
- 持久化（ClashConnectionHistoryStore，单例 `shared`）：`<AppSupport>/com.techfanseric.aiquotabar/clash/openai-connection-history.json`，`{ "version": 1, "samples": [...] }`，ISO8601 日期，原子写；加载时 `version <= 1` 才接受并 `pruned`（只留 `[now-59min, now]`）。保存时机：分钟时间戳变化时、live 结束时、stop 时。Windows 路径等价：`%APPDATA%\com.techfanseric.aiquotabar\clash\openai-connection-history.json`。
- 绘制（Canvas 柱状图，高 78pt）：
  - 60 个桶按分钟对齐到当前分钟（最右 = 当前分钟），缺数据的桶留空。
  - Y 轴最大值 = max(1, 各桶连接数最大值)；刻度线取 `{0, ceil(max/2), max}` 去重升序（0 为实线，其余虚线），左侧 7pt 数字标签。
  - 每分钟一列，列内**每个连接一个单位格**（按该分钟的年龄降序堆叠），颜色 = 年龄绿→橙梯度；单位格间留 16% 间隔，圆角 1.2。
  - X 轴标签：`−60m`（左）、`−30m`（中）、`now`（右），7pt。
- 列表空态：「当前没有活跃的 OpenAI 连接」+「这里只监测 openai.com 与 chatgpt.com。」；列表最小高 90pt。
- 头部 live 指示：绿点 +「实时 · 1 秒」或灰点 +「后台 · 1 分钟」；底部「只读监测」+ clientName（缺省 "Clash / Mihomo"）。

### 5.6 面板布局（ClashPopoverLayout，迁移需保留的压缩算法）

- 常量：宽 296；面板基准高 850；保护分区 193；路由分区 334（收起 30）；连接列表最小高 90；连接分区 chrome（48+58+104+24+29+3=266）+ 列表最小高 = 分区最小高 356；账号分区最小高 80、行高 44、chrome 39；divider 余量 2×3。
- 高度求解（`resolveSectionHeights`）三档让位：无约束/放得下 → 账号自然高、连接区拿 850 残余（不低于分区最小高）；超屏幕上限（锚点屏幕可用高的 90%）→ 先压账号区（下限 80，内部滚动）→ 再压连接列表（下限 0，保 chrome 完整）→ 最后账号压到标题行 30。面板不再封顶 850，内容多则长高、屏幕放不下按上述压缩。有整组测试锁定各档数值。

### 5.7 面板折叠状态（ClashPanelDisplayStore）

- UserDefaults key `clashPanelDisplayPreferences`，JSON 编码的 `Set<ClashPanelSection>`（accounts/routes/connections），默认空（全展开）。
- 用户点标题切换持久化；「跟随运行中的应用」开启时 `alignWithCodexPresence` 把 routes+connections 对齐 Codex 运行状态（未运行=收起），**最后一次操作生效**（手动展开会在下一次 presence 对齐时被覆盖——测试 `testManualExpandHoldsUntilNextPresenceAlignment` 锁定）；跟随关闭则完全不动。

---

## 6. 测试揭示的必须一致的精确行为

以下是 `AIQuotaBar/Tests/Clash/`（7 文件）锁定的行为，Windows 版必须有等价单测：

1. **YAML 顶层解析**：嵌套 `dns.secret` 不污染顶层；带引号/注释标量按 1.3 规则解码（`ClashConfigurationDiscoveryTests`）。
2. **控制器地址**：`0.0.0.0:9097 → http://127.0.0.1:9097`；`192.168.1.2:9097` 抛 `unsafeControllerHost`；临时 home 目录下的 Clash Verge Rev 配置端到端发现成功（baseURL/secret/clientName 全对）。
3. **策略组解析**：RuleSet payload=`ai` 指向 Selector `[类]-海外AI🤖` → 选中该组；RuleSet payload=`private_domain` 不算 AI 规则（即使指向唯一 Selector 也不选）。
4. **排序**：`fast(72) < slow(210) < timeout(0) < unknown(nil)`；同档按本地化名称序。
5. **筛选**：`🇯🇵`/`日本`/`JP`/`Japan` 四种查询结果集合相同（且恰为两条日本节点）；`家宽` 普通包含；正则 `^(🇯🇵|SG-).*(01)$` 精确命中两条；正则 `^JP` 命中 0 条（不做别名展开）；非法正则 → 空结果 + 错误消息；VM 重建后筛选串保留、编辑态归 false。
6. **切换历史**：只留最近 3 条、降序；`from == to` 不记录；徽章映射（Hysteria2→H2 等、`Custom Proxy`→CUS）；相对时间（-59s→`now`、-60s→`1m ago`、-59m59s→`59m ago`、中文 `1 分钟前`）。
7. **连接过滤**：6 个命中样例与 4 个不命中样例（5.2 列表）逐一锁定；sniffHost/rulePayload 兜底生效。
8. **速率计算**：首帧速率 0；第 2 帧 (Δ1600B, Δ1400B)/2s → 上传 300B/s、下载 500B/s... 实际断言 uploadSpeed=300、downloadSpeed=500（对应上传 Δ600/2s=300、下载 Δ1000/2s=500）、duration 累加正确；连接计数回退/新连接不产生尖峰。
9. **历史**：upsert 同分钟覆盖、总数恰 60、最后一桶 ages 降序；store 往返只含 ages，文本无 host/process/IP；`minuteStart` 对齐；prune 窗口 60 分钟。
10. **年龄梯度**：-1s→0、30min→0.5、2h→1（钳制）。
11. **折叠状态**：toggle 持久化往返；跟随模式对齐/不对齐/手动覆盖后被下一次对齐收回的完整语义。
12. **自适应布局**：无约束随账号内容长高（>850）；路由收起时维持 850 基线；连接收起高度公式；屏幕 1000/850 两档压缩的精确数值（accounts 111/51、connections 保最小高/仅 chrome）；离屏渲染 PNG 冒烟（`AIQUOTABAR_LIVE_CLASH_TEST=1` 才跑真实 Clash 的 live 测试，默认 XCTSkip）。

---

## 7. 持久化键与文件汇总（Windows 等价物）

| 用途 | macOS 存储 | Windows 等价建议 |
|---|---|---|
| 筛选查询串 | UserDefaults `clashRouteFilterQuery` | 同名设置项 |
| 正则开关 | `clashRouteFilterUsesRegularExpression` | 同名 |
| 自动恢复开关 | `clashRouteAutoSelectBest`（历史命名，勿改） | 同名 |
| 上次恢复尝试时间 | `clashRouteLastRecoveryAttempt`（Date） | 同名 |
| 切换历史（3 条） | `clashRouteSwitchHistory`（JSON 数组） | 同名 |
| 分区折叠集合 | `clashPanelDisplayPreferences`（JSON Set） | 同名 |
| 连接历史 60 样本 | `…/com.techfanseric.aiquotabar/clash/openai-connection-history.json`（version=1, ISO8601, 原子写） | `%APPDATA%\com.techfanseric.aiquotabar\clash\openai-connection-history.json` |

## 8. 迁移实现要点速查（.NET 8）

- HTTP：`HttpClient`（`SocketsHttpHandler { UseProxy = false }`）+ Bearer 头 + 8s 超时；对应每功能端点照 §2.2 直译。204 无 body。
- WS：`ClientWebSocket`，`ws://127.0.0.1:port/connections?interval=1000`，Bearer 需手动加到请求头（`ClientWebSocket.SetRequestHeader("Authorization", "Bearer …")`）；Text/Binary 帧都要处理；间隔下限 250ms。
- 探测：`HttpClient.SendAsync(new HttpRequestMessage(HttpMethod.Head, url))` 3s 超时、双端并发（`Task.WhenAll` 提前成功即整体可达）、Any HTTP 响应算可达；`recheckNow` 必须新建 handler。
- 正则/词边界/别名表/徽章表/时间与速率格式化：按 §3 逐条照抄，配等价单测。
- 通知：Windows Toast，payload 携带 `openClashRoutes` action 以复刻点击打开路由面板。
- 轮询节流与档位（1s/60s + 3s/60s 重试 + owner 计数 + 10 分钟恢复冷却 + 2 次连续失败 + 单轮故障单次处理）是能耗/安全语义，必须保留。
