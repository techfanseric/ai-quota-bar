# ADR-001：Windows 移植启动决策（D1~D7 与环境）

- 日期：2026-09-24
- 状态：已接受（由编排者确认，作为 W0 解决方案骨架的输入）
- 关联文档：`docs/windows-port-plan-2026-09-24.md`（§13 待决策事项、§10 开发与测试环境）
- 后续 ADR：WinUI 3 vs WPF 选型（Phase 0 spike S7 产出）

## 背景

Windows 端移植计划评审通过后，§13 列出的 7 项待决策事项需要逐一拍板，开发/测试环境路线（§10）需要在"本地虚拟机"与"远程 Windows 机器"之间做出选择，W0（解决方案骨架、contracts 冻结、CI、编码规范）才能开工。本 ADR 记录全部启动决策及其理由摘要。

## 决策

### D1 仓库策略：同仓库 `windows/` 目录

- **决策**：Windows 端代码放在本仓库 `windows/` 子树，不建独立仓库。
- **理由摘要**：契约 fixtures（`windows/contracts/fixtures/`）与 macOS 端天然共享、双端可同 PR 同 tag 发版，直接支撑"契约即源"的长期维护流程（计划 §15）；代价是 CI 需按路径过滤（已实现于 `.github/workflows/windows-ci.yml`）。

### D2 最低系统版本：Windows 10 21H2+ 与 Windows 11

- **决策**：目标 Windows 10 21H2 及以上、Windows 11（WinUI 3 支持下限）。
- **理由摘要**：WinUI 3 在 Win10 21H2 可用；仅支持 Win11 会砍掉存量用户，Win10 测试矩阵成本可接受。

### D3 架构矩阵：CI 先 x64，arm64 后补

- **决策**：CI 首阶段仅 `windows-latest`（x64）构建测试；arm64 矩阵（GitHub 托管 arm64 runner 或远程物理机自托管 runner）后续补齐。
- **理由摘要**：.NET 差异小，x64 先行即可满足 PR 门禁；arm64 增量补成本低。CI workflow 中已留 TODO 注释。

### D4 分发与更新：Veloppack（Phase 3 实施）

- **决策**：主选 Veloppack（增量更新 + GitHub Releases 挂 Windows 资产）；MSIX 仅作备选。
- **理由摘要**：tray-first 常驻应用的成熟分发路径，免管理员安装到 `%LOCALAPPDATA%\Programs\AIQuotaBar`；具体打包在 Phase 3 落地，本 ADR 先锁方向。

### D5 代码签名：OV 证书起步，暂缓采购

- **决策**：接受 OV 证书（含 SmartScreen 信誉累积期）；采购与接入暂缓至 Phase 3。
- **理由摘要**：OV 年费远低于 EV，SmartScreen 信誉可随分发量累积；开发期无需证书。

### D6 "跟随运行应用"覆盖面：待 Phase 0 spike 结论

- **决策**：按 S3 顺带产出的桌面应用 Windows 存在性清单（ChatGPT/Kimi/ZCode/MiniMax 桌面版）定覆盖面，再决定裁剪范围。
- **理由摘要**：该功能价值依赖各桌面应用 Windows 版的实际存在，提前拍板无依据；兜底为 v1 砍掉该功能。

### D7 合盖模式：v1 不做等价实现

- **决策**：不做合盖模式等价实现；只做 `SetThreadExecutionState` 防系统/显示器睡眠（任务期间自动、零权限）+ 检测到合盖场景时一次性引导用户到电源选项设置页。
- **理由摘要**：Windows 的 lid action 属全局电源策略，修改需管理员权限且无法安全租借，无应用级对应物；未来若做"临时电源计划切换"另立独立提案（一次性 UAC + 自动还原 + 租约超时）。

## 环境决策

### E1 B/D 层环境：用户提供的远程 Windows 物理机（SSH 访问）

- **决策**：开发/测试环境四层模型（计划 §10.1）中的 B 层（Windows 日常）与 D 层（物理终验）由用户提供的远程 Windows 物理机承担，agent 经 SSH 远程执行构建、测试、spike、日志回传；UI 冒烟采用"远程启动应用 → 截屏 scp 回传 → 目检"闭环，UI 截屏验证会话串行预约。
- **理由摘要**：主力 Mac 磁盘紧张（实测剩 88 GB），远程物理机路线下 Mac 侧仅剩仓库工作副本，磁盘零占用；物理机还兼做性能基线与真实 Explorer/自启行为终验。替代方案（Apple Silicon 上 Win11 ARM 虚拟机，磁盘 30~80 GB）被否。

### E2 本 Mac 不装 .NET SDK，构建验证走 CI 与远程机

- **决策**：开发者主力 macOS 机器不安装 .NET SDK；Windows 端构建与测试验证一律走 GitHub Actions（`windows-latest`）与远程 Windows 机。
- **理由摘要**：与 E1 一致的最小磁盘占用路线；代价是 Mac 本机无法本地跑 `dotnet test`（原计划 A 层收益由 CI + 远程机分担）。若后续想要本地即时反馈，可再装 .NET SDK（约 4~5 GB），不与本决策冲突。

## 后果

- W0 骨架按上述决策落地：`windows/` 子树 + x64 CI（`.github/workflows/windows-ci.yml`）+ `windows/Directory.Build.props`（net8.0 基线，Platform 单独 net8.0-windows）。
- 分层铁律（Core/Providers 零 Windows/UI 依赖）是 A 层（逻辑层环境）在"E2 不装 SDK"下仍成立的前提，必须坚持并用 NetArchTest 固化（见 `windows/docs/coding-conventions.md` §4 TODO）。
- 待办追踪：D6 依赖 S3 结论；D4/D5 在 Phase 3 落地；D3 的 arm64 矩阵在 CI workflow 中留有 TODO 注释。
