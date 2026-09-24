# AIQuotaBar.Platform

Windows **平台服务层**（计划 §4 映射表、§7）：承载一切 Windows 原生机制，向 Core/App 暴露接口。依赖 `AIQuotaBar.Core`。

## 职责清单（待 Phase 1 逐步落地）

| 能力 | Windows 机制 |
| --- | --- |
| 托盘图标 | `Shell_NotifyIcon`；处理 Explorer 重启（`TaskbarCreated` 重注册）；多 DPI 图标档 |
| 凭据存储 | Credential Manager（`CredRead/CredWrite`）+ DPAPI |
| 防系统/显示器睡眠 | `SetThreadExecutionState`（零权限） |
| Codex 事件 | Named Pipe（hook）+ `FileSystemWatcher`（sessions 目录）双路 |
| Kimi CLI PTY 探测 | ConPTY（`CreatePseudoConsole`） |
| Toast 通知 | `AppNotificationBuilder` |
| 开机自启 | 注册表 Run 键（用户级，HKCU） |
| 单实例 | Named mutex；二次启动激活已有实例 |
| mDNS / 主机名通告 | 待 Phase 0 验证（风险 R8） |

## 约束

- 本项目 TFM 为 **net8.0-windows**，仅可在 Windows 上构建与运行（见 csproj 内注释）；CI 走 windows-latest。
- 平台能力一律以接口形式暴露给上层（App / MobileServer），Core 与 Providers **禁止**反向引用本项目（分层铁律）。
- 合盖模式 v1 不做（决策 D7），只做防睡眠 + 电源选项一次性引导。
