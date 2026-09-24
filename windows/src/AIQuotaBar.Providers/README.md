# AIQuotaBar.Providers

Windows 端 **provider HTTP 客户端层**：Codex（OAuth / CLI / Web 源）、Kimi、GLM、MiniMax 配额客户端与 Clash/Mihomo REST 控制客户端。依赖 `AIQuotaBar.Core` 的模型与契约类型（计划 §7）。

## 铁律

- **零 Windows / UI 依赖**：纯 HTTP + 纯逻辑，不引用 Win32、P/Invoke、任何 UI 框架，也不引用 `AIQuotaBar.Platform`。可在 macOS / Linux 上直接 `dotnet test`。
- `HttpClient` 单例复用连接（计划 §11 性能目标）；序列化统一 `System.Text.Json` camelCase 策略（见 `windows/docs/coding-conventions.md`）。
- 涉及平台能力（凭据读取、ConPTY 等）的部分不写在本层，由 `AIQuotaBar.Platform` 提供、经接口注入。

## 来源与验收

- 从 Swift 端 `AIQuotaBar/Services/` 对应客户端翻译；文件头注释标注 Swift 来源类型。
- 所有网络解析必须对 `windows/contracts/fixtures/` 的真实流量样本做测试；样本只从 macOS 实机录制，**禁止本层或测试内自造 API 响应 JSON**。
