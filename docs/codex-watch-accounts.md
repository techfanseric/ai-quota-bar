# 关注账号（局域网跨设备）

## 这是什么

让一台 Mac 把自己的 Codex 额度**显示在另一台 Mac 的菜单栏里**，而不必在那台 Mac 上登录这个账号。

典型场景：小王有一台常驻跑 Codex 的机器，那台机器登录了某个账号；他自己另一台 Mac 想盯着这个账号的额度用，但不想、也不需要在那台 Mac 上登录它。

## 为什么不是另外两条路

| 方案 | 为什么不选 |
| --- | --- |
| 把 `auth.json` 拷到本机 | 两台机器共用同一个 `refresh_token`，轮换时会互相把对方挤下线（`refresh_token_reused`）。 |
| 走团队云同步 | 需要建团队、对方要开「共享账号额度」，而且额度要绕一圈公网服务器；只想看一台机器时纯属绕远。 |

本方案里 **Codex 登录凭据永远不离开 owner 那台机器**，也不经过任何服务器：owner 自己抓额度，只把结果按白名单吐给局域网对端。

## 数据流

```
owner 设备                                        watcher 设备
┌──────────────────────────────┐                 ┌────────────────────────┐
│ 本机 Codex 凭据 → 抓额度      │                 │ CodexWatchPeerStore    │
│            ↓                  │                 │  名单 + 令牌(钥匙串)   │
│ providerUsageSections         │                 │          ↓ 轮询 60s   │
│            ↓                  │  HTTP 局域网     │ CodexWatchPeerClient  │
│ CodexWatchProjector           │  Bearer 令牌     │  仅回环/私有网主机     │
│  × 授权名单（默认拒绝）        │ ──────────────► │  拒绝一切重定向        │
│            ↓                  │  只读 JSON      │          ↓            │
│ /api/v1/watch/quota          │                 │ ModelUsageData(Peer …) │
└──────────────────────────────┘                 │          ↓            │
                                                 │ 菜单栏按账号分组显示    │
                                                 └────────────────────────┘
```

## 设置在哪

**设置 → 服务商 → Codex → 关注账号**，一个区块里两半：

- **允许其他 Mac 关注我的账号**（owner 侧）：全局开关 + 逐账号勾选。默认全关。
- **我关注的账号**（watcher 侧）：添加/移除对端，填局域网地址、端口、访问密钥。

两半互不依赖。

## 使用步骤

1. **owner 那台 Mac**：打开上面的开关，勾选要分享的账号。
2. **owner 那台 Mac**：在「手机看板」里取到**访问地址与访问密钥**（`http://<局域网IP>:18765` + 一串密钥）。
   - 分享额度不要求打开手机看板：只开关注开关时，局域网服务照样起来，但看板页面与账号名掩码策略不受影响。
3. **watcher 那台 Mac**：在「关注账号」里点「添加设备」，填 host / 端口 / 密钥。
   - 会先握手一次再入库：地址写错、对方没开分享、密钥不对，当场给出一句明确的话，
     而不是加进去之后菜单里永远挂一个连不上的条目。
4. 之后 watcher 每 60 秒自动刷新；菜单里出现 `账号 @ 对方设备名` 的分组行。

## 安全边界

这是本功能最要紧的部分，逐条都有测试兜着：

1. **默认拒绝。** 授权名单里没有的邮箱一律不外发，即使本机确实有那个账号的数据。
2. **凭据不出机器。** 线上传输的只有额度百分比、重置时刻、套餐名。没有 token、没有 API key、
   没有任何能拿去调用 OpenAI 的东西。
3. **令牌不出局域网。** `CodexWatchPeerClient.isAllowedHost` 只放行回环 / RFC1918 / 链路本地
   地址字面量，以及裸主机名。用户把公网地址粘进来会在本地就被拒。
4. **拒绝一切重定向。** owner 端一个 302 就能把 Bearer 令牌骗到别的主机去。
5. **令牌只在 Authorization 头里**，不进 URL、不进错误提示。
6. **令牌存钥匙串。** 对端令牌复用既有的 `deviceCredentials` 通道，但用
   `codexWatch.peer.<uuid>` 前缀隔离，不会和本机自己的设备凭据混淆；删除对端时真删。
7. **令牌不对时不泄露任何账号信息。** 401/403 只表示令牌无效，
   状态码不能被用来推断这台机器上有哪些 Codex 账号。
8. **授权可随时收紧且立刻生效。** 取消勾选会马上重算对外应答，不等下次用量刷新或重启。
9. **撤销授权后对端清缓存。** 对端收到 `notAuthorized` 会丢掉本地缓存，
   不会继续显示一份已经不获授权的额度。

## 两种「没有数据」必须分开

对端 UI 刻意区分这两种状态，因为用户要做的动作完全相反：

- `notAuthorized` — 对方在线，但没勾选任何账号 → 「请让对方去设置里勾一下」
- `disabled` — 对方没开分享 → 「请对方打开开关」
- `unreachable` — 设备不可达 → 「检查地址 / 同一局域网 / 应用在运行」
- `pendingAccountNames` — 授权了，但那台设备当前没跑 Codex → 等一下

## 一个刻意的产品决定：被关注的账号不许自己消失

云端账号 today 有一条既有行为：数据超过 `cloudCurrentWindowVisibilityLimit` 就整条隐藏。
对「云端团队数据」这是对的（陈旧的数不该冒充现值）；但对**用户明确点名要看的账号**是错的——
账号会因为对方机器安静下来而从菜单里凭空消失。

所以关注来的账号走另一条路（`CodexWatchPeerStore.model`）：

- 额度窗口过期时，把显示区间撑到当下，行仍然在，标 `stale`；
- 对端不可达时保留上一份数据，标 `stale`，而不是让用户以为额度清零了。

未标 `stale` 的旧数字会被读成现值，所以这个标记不是装饰。

## 代码位置

| 文件 | 职责 |
| --- | --- |
| `Services/CodexWatch/CodexWatchPayload.swift` | 线格式与授权条目语义 |
| `Services/CodexWatch/CodexWatchGrantStore.swift` | owner 侧授权名单（默认拒绝） |
| `Services/CodexWatch/CodexWatchProjector.swift` | 本机用量 → 只含被授权账号的应答（纯函数） |
| `Services/CodexWatch/CodexWatchResponseBox.swift` | 主 actor ↔ HTTP 队列之间的加锁快照 |
| `Services/CodexWatch/CodexWatchPeerClient.swift` | 对端抓取 + 地址白名单 + 拒绝重定向 |
| `Services/CodexWatch/CodexWatchPeerStore.swift` | watcher 侧名单、轮询、陈旧策略 |
| `MobileDashboardHTTPServer` | `GET /api/v1/watch/quota` 只读端点 |
| `Settings/Components/CodexWatchSettingsSection.swift` | 设置 UI（两侧） |

## 已知边界

- 只覆盖 Codex。其它 provider（Kimi / GLM / MiniMax）各有各的凭据模型，混进来会让「授权」语义变模糊。
- 明文 HTTP。局域网服务本来就是明文的，所以沿用同一套访问密钥；
  没有为它单独引入 TLS。
- 需要 owner 那台 Mac 上的 AI Quota Bar 处于运行状态。它关机或退出，watcher 侧就转为 `stale`。
