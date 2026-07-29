# AI Quota Bar

<p align="center">
  随时知道 AI 编程配额还能用多久，让 Codex 长任务不中断，并在 OpenAI 连不上时直接从菜单栏恢复线路。
</p>

<p align="center">
  <a href="https://github.com/techfanseric/ai-quota-bar/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/techfanseric/ai-quota-bar?display_name=tag"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/release-Apple%20Silicon-6f42c1">
  <a href="./LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

<p align="center">
  <a href="./README.md">English</a> ·
  <a href="https://github.com/techfanseric/ai-quota-bar/releases/latest/download/AIQuotaBar.dmg">下载 DMG</a> ·
  <a href="https://github.com/techfanseric/ai-quota-bar/releases">版本记录</a>
</p>

做 AI 编程时，配额在一个地方、代理线路在另一个地方，Mac 睡眠设置又在第三个地方。AI Quota Bar 把这些事情放进菜单栏：左键判断当前配额够不够完成接下来的工作，右键让 Codex 安心跑完长任务，或者快速处理 OpenAI 连接异常。

<p align="center">
  <img src="./docs/images/control-center.png" alt="AI Quota Bar 右键控制中心" width="373">
</p>

## 它能帮你解决什么

| 你遇到的问题 | AI Quota Bar 如何帮你 |
| --- | --- |
| 不知道配额能不能撑到工作完成 | 同时展示剩余量、重置时间、近期消耗和当前节奏是否可持续 |
| ChatGPT 或 Codex 突然连不上 | 直接在菜单栏测试和切换 Clash/Mihomo 线路，真正故障时也可自动恢复 |
| 感觉连接很慢，却不知道卡在哪里 | 查看当前有没有连接、是否真的在传输，以及是否堆积了持续很久的连接 |
| Codex 跑长任务时担心 Mac 睡着 | 只在 Codex 工作期间保持唤醒，任务完成后自动恢复正常 |
| 偶尔需要合盖让任务继续 | 可选开启合盖模式，并用电量、温度、心跳和最长时间保护机器 |
| 希望换台 Mac 还能看到近期趋势 | 可选同步最近的配额快照，保留真正有用的历史 |

## 界面预览

### 配额面板

多个账户放在一起看。百分比回答“还剩多少”，趋势和盈余/透支提示则回答更关键的问题：“照现在的用法，能不能撑到下次重置？”

<p align="center">
  <img src="./docs/images/dropdown.png" alt="配额面板" width="464">
</p>

### 不打开菜单也能快速判断

菜单栏圆环让你一眼看到 Weekly 剩余配额。中心区域表示当前用量是还有余裕，还是消耗得过快；如果两个 OpenAI 站点都无法连接，圆环会直接变成断网提醒。

<p align="center">
  <img src="./docs/images/menu-bar-self-test-preview.png" alt="Codex 配额圆环状态" width="792">
</p>

### 云同步与数据保留

可以选择保留多久的近期配额历史、检查已经保存的数据，也可以只删除某个账户而不影响其他账户。

<p align="center">
  <img src="./docs/images/cloud-sync-settings.png" alt="云同步设置" width="720">
</p>

## 系统要求

- macOS 14 Sonoma 或更高版本。
- 预编译 DMG 当前面向 Apple Silicon；源码构建会使用构建 Mac 的架构。
- 至少配置一个配额来源：
  - 已安装并登录的 Codex CLI。
  - MiniMax 编程套餐 bearer token。
- 可选：启用了本地 external controller 的 Clash Verge Rev、Mihomo 或 Clash。
- 可选：启用合盖继续运行时需要管理员授权。

## 安装

1. 下载最新的 [`AIQuotaBar.dmg`](https://github.com/techfanseric/ai-quota-bar/releases/latest/download/AIQuotaBar.dmg)。
2. 打开镜像，将 **AI Quota Bar** 拖入 **Applications**。
3. 启动应用，在左键菜单底部打开 **Settings**。

### Gatekeeper 提示

项目目前没有使用付费 Apple Developer 证书，公开版本采用 ad-hoc 签名，未经过 Apple 公证。首次启动时，macOS 可能要求按住 Control 点击应用并选择“打开”，或在“系统设置 → 隐私与安全性”中允许打开。不要全局关闭 Gatekeeper。

## 快速开始

### Codex

如果 Codex 已经能在终端正常使用，设置几乎已经完成。用官方 CLI 登录一次，然后刷新 AI Quota Bar：

```bash
codex
```

账户会自动出现，并在配额面板中分别展示。凭证继续保存在本机 Codex/CodexBar 账户存储中。

<details>
<summary>进阶：选择从哪里读取 Codex 配额</summary>

AI Quota Bar 通过 [`CodexBarCore`](https://github.com/steipete/CodexBar) 提供以下数据来源：

- **Auto**：依次尝试 OAuth、CLI 本地数据和浏览器会话。
- **OAuth**：只使用 Codex CLI OAuth 凭证。
- **CLI**：只使用 Codex/CodexBar 本地配置。
- **Web**：只使用本机 OpenAI 浏览器会话。

</details>

### MiniMax

打开“Settings → Providers → MiniMax”，粘贴你的 MiniMax 编程套餐 token，然后刷新。Token 会留在 macOS 钥匙串中。

## 在配额耗尽前安排好工作

AI Quota Bar 不只是显示一个百分比。它会把剩余配额、重置时间和近期消耗放在一起，让你判断现在适不适合开始一个大任务，是否需要放慢使用速度，或者换到另一个账户继续。

- 在同一个菜单里查看 Codex 与 MiniMax，包括多个 Codex 账户。
- 同时看到 **5h** 这类短周期和 **Weekly** 这类长周期限制。
- 从趋势线看出配额下降速度。
- 用“盈余/透支”判断当前节奏能否坚持到重置。
- 在配额真正见底之前收到提醒。
- 平时只看菜单栏圆环，也能快速掌握状态。

菜单栏既可以固定展示某个供应商，也可以使用自动模式，让最需要关注的账户优先出现。

## OpenAI 连不上时，不必再切回 Clash

当 ChatGPT 或 Codex 无法连接时，右键菜单栏图标即可。AI Quota Bar 会找到相关的本机 Clash/Mihomo 策略组，测试其中的线路，并把延迟最低的可用选择放在前面。

- 可以用 `🇯🇵`、`日本` 或 `JP` 等习惯用法筛选国家。
- 需要精确匹配时可以打开正则模式。
- 点击一次即可手动切换，并能看到最近三次换线记录。
- 设定常用国家或线路范围后，也可以让应用在 OpenAI 确实中断时自动选择其中延迟最低的线路。

自动恢复不会因为打开面板、测速或勾选开关就换线。只有 `openai.com` 与 `chatgpt.com` 连续两轮同时失败时，它才会从筛选结果中按延迟依次尝试；连接恢复后立即停止，并发送系统通知。

为避免访问远程控制器，AI Quota Bar 只接受位于本机的 Clash/Mihomo 地址：`127.0.0.1`、`localhost` 或 `::1`。

## 看懂 OpenAI 为什么慢、是不是卡住了

感觉 ChatGPT 很慢时，连接面板可以快速回答三个问题：

- **现在到底有没有连接？** 直接看 OpenAI/ChatGPT 活跃连接数。
- **数据有没有在传？** 查看总上传和下载速度。
- **这是刚发起的请求，还是已经挂了很久？** 新连接是绿色，持续越久越接近橙色。

最近 60 分钟的图表能看出连接高峰、空白时段，以及持续时间异常的长连接。下方列表会在 Clash/Mihomo 提供数据时显示域名、应用、线路、连接时长和速度。

这里完全只读，不会关闭连接，也不会改动 Clash 配置。

## 让 Codex 长任务自己跑完

启动一个耗时较长的 Codex 任务后，你可以放心离开，而不必为了这一项任务把 Mac 全天设为永不睡眠。AI Quota Bar 会判断 Codex 是否真的在工作，并只在这段时间保持显示器、阻止屏保和系统空闲睡眠。

最后一个任务完成、关闭保护或退出应用后，Mac 会立刻恢复原来的行为。多个任务同时运行时也会分别计数，不会因为其中一个先结束就提前停止保护。

### 合盖继续运行

如果偶尔需要合上 MacBook 仍让任务完成，可以单独开启合盖模式。它默认关闭，第一次使用时会请求管理员授权。

辅助程序会在以下情况恢复原来的睡眠设置：

- Codex 任务结束。
- 应用断开连接或停止发送心跳。
- 电量低于安全阈值。
- macOS 报告严重或临界温度压力。
- 达到 12 小时最长租约。
- 用户关闭功能。

这是一道安全保障，并不能替代良好散热。MacBook 合盖后散热能力会下降，请只在通风和供电条件合适时使用。

## 换台 Mac 也能保留近期配额趋势

如果你使用多台 Mac，或者希望重装后还能看到近期趋势，可以选择开启云同步。每次成功刷新后，应用会备份精简的配额快照，让另一台设备也能恢复有用的近期图表。

数据仍由你控制：

- 选择保留 30 至 180 天。
- 自动隐藏已经过时的纯云端图表。
- 用本地报告检查保存了什么。
- 单独删除一个账户，或清空全部本地/云端历史。

云同步默认关闭。它会上传配额元数据和账户标签，但不会上传 MiniMax 或 Codex 凭证。准确的数据边界见下一节。

## 隐私与安全边界

- MiniMax 凭证存储在 macOS 钥匙串。
- Codex 凭证由本机 Codex/CodexBar 管理。
- Clash/Mihomo 只允许访问回环地址的 external controller。
- 连接监控只读。
- Codex 活跃检测只读取本机生命周期状态，不上传任务内容。
- 云同步必须由用户主动开启，不上传供应商凭证，但会上传上一节列出的配额元数据。
- 合盖相关系统修改必须明确管理员授权，并由辅助程序自动恢复。

## 从源码构建

Swift Package 当前要求 CodexBar 与本仓库处于同级目录：

```bash
mkdir ai-quota-bar-workspace
cd ai-quota-bar-workspace
git clone https://github.com/steipete/CodexBar.git codexbar
git clone https://github.com/techfanseric/ai-quota-bar.git
cd ai-quota-bar

make build
make install
```

构建要求：

- Xcode Command Line Tools，Swift 5.9 或更高版本。
- macOS 14 SDK 或更高版本。
- macOS/Xcode 自带的 `hdiutil`、`iconutil`、`sips` 与 `codesign`。

常用命令：

```bash
swift test       # 运行测试
make build       # 构建 release 二进制
make app         # 组装 dist/AIQuotaBar.app
make install     # 替换 Applications 中的应用并重启
make package     # 生成 dist/AIQuotaBar.dmg
```

`make package` 默认使用 ad-hoc 签名。如果维护者具备 Developer ID，可通过 `CODESIGN_IDENTITY` 指定签名身份，并在单独的发布流水线中完成公证。

## 常见问题

### 找不到 Clash 线路

- 确认 Clash/Mihomo 正在运行。
- 启用 external controller。
- 将控制器绑定到回环地址。
- 确认 `openai.com` 或 `chatgpt.com` 的当前规则最终进入可切换策略组。

### 自动恢复没有换线路

- 两个公开域名必须连续两轮同时失败。
- 自动恢复开关必须打开。
- 线路筛选条件必须非空且有效。
- 至少有一条匹配线路成功完成测速。

### Codex 保护一直显示没有活跃任务

- 确认 Codex 正在执行，而不是等待输入。
- 保持默认的 `~/.codex` 状态目录，或在所有相关进程中一致设置 `CODEX_HOME`。
- 升级后重启一次 AI Quota Bar，让应用注册随包附带的生命周期 Hook。

### 合盖模式不可用

让应用保持在前台，打开一次合盖模式开关并批准管理员提示。新的应用版本会改变辅助程序指纹，因此升级后可能需要一次性更新辅助程序。

## 致谢

- [`CodexBar`](https://github.com/steipete/CodexBar) 提供 `CodexBarCore`。
- Clash、Mihomo 与 Clash Verge Rev 提供本机线路和连接监控所使用的控制器 API。

## 许可证

AI Quota Bar 使用 [MIT License](./LICENSE) 发布。
