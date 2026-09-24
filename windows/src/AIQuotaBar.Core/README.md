# AIQuotaBar.Core

Windows 端**纯逻辑层**：配额计算、预测（QuotaConsumptionForecast）、历史存储逻辑、契约模型。对应移植计划的 `src/AIQuotaBar.Core`（计划 §7）。

## 铁律

- **零 Windows / UI 依赖**：不引用 Win32、P/Invoke、任何 UI 框架，也不引用 `AIQuotaBar.Platform`。可在 macOS / Linux 上直接 `dotnet test`（分层环境 A 层的基础）。
- **契约类型勿动**：与 macOS 端共享的契约类型由契约 agent 写入本项目的 `Contracts/` 目录。其他贡献者**只读引用** `Contracts/`，缺类型时向编排者提出申请，不得自行修改。

## 来源与验收

- 代码从 Swift 端（`AIQuotaBar/Models`、部分 `Services`）逐模块翻译；每个文件头注释标注 Swift 来源类型（约定见 `windows/docs/coding-conventions.md`）。
- Swift 端 `AIQuotaBar/Tests/` 已覆盖的纯逻辑行为，xUnit 必须等价覆盖（移植验收表）。
- API 响应解析测试一律使用 `windows/contracts/fixtures/` 的共享样本，禁止在测试内自造 JSON。
