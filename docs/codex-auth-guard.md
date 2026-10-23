# 凭据守护镜像（auth.json 护栏）

## 这是什么

给本机见过的**每一个** Codex 账号，在 `~/.codex` 之外留一份凭据副本，
并把「谁改了登录态」这件事在面板上说出来。

路径：`~/Library/Application Support/com.techfanseric.aiquotabar/codex-auth-mirror/<账号指纹>.json`
目录 0700、文件 0600，与 `~/.codex/accounts/` 下的凭据文件同级保护。

## 为什么需要它

`~/.codex/auth.json` 不是只有 Codex 会写。

**magpie 这类 LLM 网关**（`yetone/magpie`）的文档里写得很直白：

> magpie reads the agent's own credentials each time, **refreshes tokens the way the
> agent does — writing a rotated token back where the agent will find it**

而且它还会主动切登录账号：

> Codex 启动 1 分钟后、之后每 5 分钟检查：当前账号用到 98% 窗口或触到 usage cap，
> 就把 Codex 的登录切到下一个账号；等它回落到 90% 以下再切回去。

无论哪一种，**被换走的那个账号的凭据都会从 `auth.json` 上消失**。
如果本机没有另一份副本，那个账号在文件层面就等于丢了——
它并没有被 OpenAI 注销，而是没人再持有那串能用的凭据。

对 ai-quota-bar 来说，这意味着两件事：

1. 面板上的「当前账号」会被外部工具悄悄换掉，看起来像 app 出 bug；
2. 账号池里的备份副本，在该账号的 refresh_token 被轮换后就成了死凭据。

## 它保证什么

一条不变式：

> **任何时刻，任何本机见过的 Codex 账号，都至少有一份凭据副本存在于 `~/.codex` 之外。**

镜像跟随两处：

| 来源 | 跟随时机 |
| --- | --- |
| `~/.codex/auth.json` | 每次刷新都同步。换账号、token 轮换都跟着走。 |
| `~/.codex/accounts/*.json` | 每次刷新都同步。池文件被误删也能从镜像找回。 |

跟随时机有三条：

- **目录 + 文件双监听（即时）**——app 常驻盯着 `~/.codex` 目录与 `auth.json`
  文件本身，任一被改写就同步。这是防丢的关键：外部工具换走登录的那一刻，
  那个账号的凭据已经留在镜像里了。
- **展示期轮询（5 秒）**——账号面板打开时。
- **后台兜底轮询（10 秒）**——事件是快路径，轮询是保底。

只靠轮询会留窗口：外部工具在这个窗口里换走账号，那个账号就来不及进镜像。

### 为什么目录和文件都要盯

两种改写方式产生的事件完全不同（实测）：

| 改写方式 | 目录事件 | 文件事件 |
| --- | --- | --- |
| 原地写入（打开文件覆盖内容） | **0** | 有 |
| 原子替换（写临时文件后 rename） | 有 | 有（但那是旧 inode 的删除事件） |
| 原子替换后再原地写 | 无 | **收不到**（fd 指向已删除的 inode） |

只盯目录会漏掉原地写；只盯文件会在原子替换后失明。magpie 两种写法都可能用，
所以两个都监听，目录事件一来就重新挂文件监听。

## 它不做什么

镜像**只跟随，绝不参与切换**：

- 切换仍然只在 `auth.json` 与账号池之间发生（原子改名）；
- 镜像文件永远不会被读走、不会被移动、不会被切换逻辑改写；
- 镜像目录在真正写入之前不存在（第一次同步时才创建）。

## 面板上怎么看

外部工具改写登录态时，账号分区会多出一行：

> 登录态被外部改写：alice@example.com → bob@example.com。可能是网关切了账号。

同时状态行给出同样的提示。这行**只在本应用自己切的账号之外出现**——
自己点的「切换」不会被算成外部改动。

## 怎么分辨是谁改的

面板提示只说明「不是本应用改的」。要确认是不是 magpie：

```sh
# 看 auth.json 最近有没有被换过（account_id 前 8 位 + 最后刷新时间）
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.codex/auth.json')))
print('account:', d.get('tokens',{}).get('account_id','')[:8], '| last_refresh:', d.get('last_refresh'))
"
```

`last_refresh` 刚刚变过、而你并没有手动登录 → 就是 magpie 这类工具。

## 红线

**不要把账号池交给任何会 import 的工具：**

```sh
magpie accounts import codex:~/.codex/accounts/*.json   # ❌ 会作废池里每个账号
```

magpie 的 import 会先刷新每一份 sign-in，刷新即轮换 refresh_token，
被导入的文件当场失效，账号池直接报废。镜像救不了这一条——
凭据本身已经作废，只能重新登录。

## 已知边界

- **池副本被外部轮换后无法自愈。** magpie 用它自己的副本刷新某个账号时，
  写回的是它那边，ai-quota-bar 池里的那份副本不会同步到。
  症状是切回该账号时 Codex 报 `refresh_token_reused` /
  `refresh_token_invalidated`，需要重新 `codex login`。
  镜像能保证「文件还在」，但保证不了「凭据还有效」。
- **app 退出期间发生的外部切换不会归因。** 归属判断依赖 app 持续运行
  （菜单栏 app 常驻，实践中成立）。镜像是落盘的，不受影响。
- **只覆盖 Codex。** 其它 provider 的凭据模型各不相同，不在本护栏范围内。

## 代码位置

| 文件 | 职责 |
| --- | --- |
| `AIQuotaBar/Services/Codex/CodexAuthMirror.swift` | 镜像库：写入、权限、变化判定 |
| `AIQuotaBar/Services/Codex/CodexAuthAccountStore.swift` | 接入镜像；外部切换归因；`~/.codex` 目录 + 文件双监听 |
| `AIQuotaBar/Views/CodexAccountSwitchPopoverView.swift` | 外部切换行 |
| `AIQuotaBar/App/StatusBarController.swift` | 启动时开监听 |
| `Sources/CodexLocalUsageCore/AuthFileInspection.swift` | `readCredential`：返回原始字节 + generation |
| `Sources/CodexLocalUsageCore/FileStamp.swift` | 新鲜 stat（`URL.resourceValues` 会缓存，不能用） |
| `AIQuotaBar/Tests/Codex/CodexAuthMirrorTests.swift` | 镜像行为与归因的回归测试 |

## 顺带修掉的一个隐患

`URL.resourceValues(forKeys:)` 在**同一个 URL 实例**上会缓存资源值：连续两次读
同一个文件，拿到的 `modificationDate` 完全一样，而文件其实已经被改写。

原来的撕裂读防护（读前读后比对 mtime 与大小）建在这上面，前后比的是同一个
缓存值，比对恒为真，**防护从来没有生效过**。现在改用 `FileStamp`
（`FileManager.attributesOfItem`，每次都是新鲜 stat），防护才真的成立，
`generation` 也才跟得上内容改动。

`Tests/CodexLocalUsageCoreTests/AuthFileReaderTests.swift` 里有这条回归测试。
