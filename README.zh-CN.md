# AI Quota Bar

<p align="center">
  原生 macOS 菜单栏工具：统一查看 AI 编程配额、保护 Codex 长任务，并在 OpenAI 连接异常时协助恢复 Clash/Mihomo 线路。
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

AI Quota Bar 把长时间 AI 编程过程中最常用的信息和控制能力集中在一个紧凑的菜单栏应用中。左键查看 Codex 与 MiniMax 的配额、重置时间和消耗趋势；右键打开控制中心，管理 Codex 任务保护、Mac 睡眠策略、OpenAI 线路以及实时连接。

<p align="center">
  <img src="./docs/images/control-center.png" alt="AI Quota Bar 右键控制中心" width="373">
</p>

## 核心能力

| 模块 | 功能 |
| --- | --- |
| 配额 | Codex 多账户与 MiniMax 配额、重置时间、短周期趋势、Weekly 消耗节奏、告警和紧凑菜单栏圆环 |
| OpenAI 线路 | 自动发现本机 Clash/Mihomo 策略组、延迟测速、国家别名与正则筛选、手动切换和保守的故障恢复 |
| 活跃连接 | 只读展示 `openai.com` / `chatgpt.com` 活跃连接、总速率、连接数和最近 60 分钟时序图 |
| 任务保护 | 检测正在运行的 Codex 任务，只在任务进行中阻止显示器、屏保和系统空闲睡眠 |
| 合盖继续 | 可选的管理员辅助程序，包含电量、温度、心跳、任务结束和最长时限等自动恢复保护 |
| 云同步 | 可选的内置配额快照同步、保留时长、远端账户清理和本地数据报告 |

## 界面预览

### 配额面板

<p align="center">
  <img src="./docs/images/dropdown.png" alt="配额面板" width="464">
</p>

### 菜单栏配额圆环

外环表示 Weekly 剩余配额，中心表示当前消耗相对可持续节奏是盈余还是透支。当 `openai.com` 与 `chatgpt.com` 同时不可达时，圆环会切换到断网状态。

<p align="center">
  <img src="./docs/images/menu-bar-self-test-preview.png" alt="Codex 配额圆环状态" width="792">
</p>

### 云同步与数据保留

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

安装官方 Codex CLI，完成一次登录，然后刷新 AI Quota Bar：

```bash
codex
```

AI Quota Bar 通过 [`CodexBarCore`](https://github.com/steipete/CodexBar) 发现 Codex 账户和配额来源。设置中可选择：

- **Auto**：依次尝试 OAuth、CLI 本地数据和浏览器会话。
- **OAuth**：只使用 Codex CLI OAuth 凭证。
- **CLI**：只使用 Codex/CodexBar 本地配置。
- **Web**：只使用本机 OpenAI 浏览器会话。

Codex 凭证保留在本机 Codex/CodexBar 账户存储中。多个账户会在配额面板中分组展示。

### MiniMax

打开“Settings → Providers → MiniMax”，粘贴 MiniMax 编程套餐配额接口所使用的 bearer token，然后刷新。Token 保存在 macOS 钥匙串中。

## 配额与菜单栏逻辑

菜单栏可以固定展示 Codex、MiniMax，或使用自动选择。自动模式会优先考虑低剩余配额和不可持续的消耗节奏，再比较重置时间。

Codex 展示逻辑：

- 主要短周期通常显示为 **5h**。
- 次要周期通常显示为 **Weekly**。
- 数据源返回 Credits 或其他计数器时一并展示。
- 短周期使用趋势图；Weekly 默认使用进度条。当 Weekly 是唯一有意义的当前周期趋势时，会自动提升为七日曲线。
- 紧凑圆环无需打开菜单即可看到 Weekly 剩余量及消耗节奏的盈余或透支。

刷新间隔和低配额提醒可在设置中调整。

## OpenAI 线路恢复

AI Quota Bar 会发现本机 Clash/Mihomo external controller，并定位承载 `openai.com` 或 `chatgpt.com` 规则的可切换策略组。控制器必须绑定到 `127.0.0.1`、`localhost` 或 `::1`，远程地址会被拒绝。

右键菜单栏图标后可以：

- 自动开始延迟测试，并按延迟从低到高排序。
- 使用普通文本及 `🇯🇵`、`日本`、`JP` 等国家别名筛选线路。
- 打开正则模式，使用开头结尾、或关系和精确命名规则。
- 手动切换任意匹配线路。
- 查看最近三次线路切换记录。

自动恢复严格由故障触发：

1. `openai.com` 与 `chatgpt.com` 必须连续两轮同时不可达。
2. 只测速并尝试非空、有效筛选条件下的线路。
3. 从最低延迟候选开始依次尝试。
4. 每次切换后重新检查 OpenAI 连通性。
5. 恢复成功后发送 macOS 系统通知。

打开面板、点击“重新测速”或打开自动恢复开关本身都不会触发线路切换。

## OpenAI 实时连接

右键控制中心读取 Clash/Mihomo 的连接流，并固定只保留匹配 `openai|chatgpt` 域名规则的活跃连接。

面板展示：

- 总下载和上传速度。
- 当前活跃连接总数。
- 最近 60 分钟、每分钟采样一次的堆叠时序图。
- 一个连接对应一个堆叠块；新连接为绿色，持续较久后逐渐过渡到橙色。
- 紧凑的活跃连接列表；在数据可用时展示域名、进程、网络类型、线路、连接时长和当前速率。

连接监控完全只读，AI Quota Bar 不会关闭或改写 Clash 连接。

## Codex 任务保护

AI Quota Bar 通过 Codex 生命周期 Hook 和只读的本地状态兜底检测活跃任务。应用只判断任务生命周期事件，不会上传任务提示词或回复内容。

开启保护且至少有一个任务活跃时，应用可以：

- 保持显示器亮起。
- 阻止屏幕保护程序。
- 阻止系统因空闲进入睡眠。

这些能力使用临时 macOS power assertion。最后一个任务结束、关闭保护或退出 AI Quota Bar 后会立即释放。

### 合盖继续运行

合盖模式是独立的可选能力，默认关闭。首次启用时会弹出管理员授权，安装一个体积很小的特权辅助程序。辅助程序以租约方式修改必要的 `pmset` 状态，并在以下任一条件出现时恢复原值：

- Codex 任务结束。
- 应用断开连接或停止发送心跳。
- 电量低于安全阈值。
- macOS 报告严重或临界温度压力。
- 达到 12 小时最长租约。
- 用户关闭功能。

MacBook 合盖后散热能力会下降，请只在通风和供电条件合适时使用。

## 云同步与数据

云同步默认关闭。启用后，每次成功刷新会把紧凑配额历史上传到内置 Cloudflare 服务，用于跨设备恢复和查看近期图表。

云端数据包含随机生成的设备 ID、供应商与账户标签、模型名称、配额数值、重置时间和利用率历史。供应商密钥不会上传：MiniMax token 保留在钥匙串，Codex 凭证保留在 Codex/CodexBar 本地账户存储。

设置中可以：

- 设置 30 至 180 天云端保留时间。
- 分别控制过期的当前周期、短周期和 Weekly 数据可见时长。
- 生成本地 HTML 数据报告。
- 按账户删除云端数据。
- 在 Advanced Cleanup 中删除全部本地或远端数据。

[`cloudflare/`](./cloudflare/) 中保留了 Worker 与 D1 schema，供开发和自托管扩展使用；当前正式版界面固定使用内置服务。

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
