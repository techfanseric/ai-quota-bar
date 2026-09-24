# Windows 端编码规范（C# / .NET 8）

日期：2026-09-24（W0 冻结）。适用于 `windows/` 子树全部 C# 代码与测试。配套工具配置：`windows/.editorconfig`（格式与命名建议级别）、`windows/Directory.Build.props`（`TreatWarningsAsErrors`，编译警告即错误）。

移植对象与验收依据：`docs/windows-port-plan-2026-09-24.md` §3.2、§7、§9。本文是所有移植 subagent 任务书的编码规范附件。

## 1. 命名约定

遵循 .NET 官方约定（`windows/.editorconfig` 已内置对应规则）：

| 元素 | 约定 | 示例 |
| --- | --- | --- |
| 类、结构、枚举、命名空间 | PascalCase | `QuotaSnapshot`、`ModelUtilizationHistoryStore` |
| 接口 | `I` 前缀 + PascalCase | `ICredentialStore` |
| 方法、属性、事件 | PascalCase | `RefreshAsync`、`RemainingPercent` |
| 常量、枚举成员、非私有字段 | PascalCase | `MaxRefreshIntervalSeconds`、`UsageProvider.Glm` |
| 私有字段 | `_camelCase` | `_httpClient` |
| 参数、局部变量 | camelCase | `snapshot`、`refreshInterval` |
| 异步方法 | `Async` 后缀 | `FetchQuotaAsync` |
| 类型参数 | `T` 前缀 PascalCase | `TProvider` |

- 布尔成员用 `Is/Has/Can/Should` 前缀；避免缩写（`Quota` 不写 `Qta`）。
- 类型名与 Swift 来源保持语义一致，不做中译（`ModelUtilizationHistoryStore` 而非 `HistoryStorage`），保证双端代码检索可对照。

## 2. 文件组织

- **一类型一文件**：每个 public 类型（class/struct/interface/enum/record）独占一个文件，文件名与类型名一致。私有嵌套类型随宿主类型同文件。
- **文件头注释标注 Swift 来源**，供移植审查与双端追溯。格式：

  ```csharp
  // Swift 来源：AIQuotaBar/Models/ModelUtilizationHistoryStore.swift（v1.28.1）
  // 对应测试：AIQuotaBar/Tests/ModelUtilizationHistoryStoreTests.swift
  ```

  纯新增（无 Swift 对应）的文件标注 `// Swift 来源：无（Windows 端新增）`；骨架占位标注 `// Swift 来源：无（骨架占位）`。
- 文件作用域命名空间（file-scoped namespace）：`namespace AIQuotaBar.Core.Models;`（`.editorconfig` 已设 `csharp_style_namespace_declarations = file_scoped`）。
- `using` 指令置于 namespace 之上（与 file-scoped namespace 配套），`System.*` 排最前。

## 3. async / await 规则

- **库代码（Core / Providers / Platform）一律异步返回 `Task` / `Task<T>`**，不提供同步外壳。
- **禁止 `.Result`、`.Wait()`、`GetAwaiter().GetResult()`**——死锁与伪装异常之源；例外仅限 `Main` 入口与测试断言辅助（须行内注释说明）。CI 中以代码审查 + 后续分析器规则强制。
- 公开异步 API 一律接受 `CancellationToken`（尾参数，默认值可省），并向下贯穿传递。
- I/O 与锁等待不得占用线程池线程；简单异步等待用 `Task.Delay`/`SemaphoreSlim.WaitAsync`，不用 `Thread.Sleep`/`lock` 包异步。
- `async` 方法内部至少一个真实 `await`；事件处理器与测试方法允许 `async void` 之外的唯一豁免是 `async void` 事件处理器本身。

## 4. 分层铁律（架构依赖规则）

计划 §7 的铁律在本仓库的具体化：

1. `AIQuotaBar.Core` 与 `AIQuotaBar.Providers` **禁止引用**：Win32/P-Invoke（`DllImport`、`System.Runtime.InteropServices` 平台调用）、`net8.0-windows` TFM、任何 UI 框架、`AIQuotaBar.Platform` 程序集。
2. 平台能力（凭据、托盘、ConPTY、FileWatcher 等）一律以 Core 定义或注入的接口出现，实现在 `AIQuotaBar.Platform`。
3. 依赖方向单向：`App → Platform → Core`、`App → Providers → Core`、`Providers → Core`。测试项目仅引用被测层。

> **TODO（W1 后补）**：引入 NetArchTest（`xunit` + `NetArchTest.Rules` 包）编写架构依赖测试，纳入 CI 强制执行上述规则，保护"Core/Providers 可在 macOS 本地 `dotnet test`"的并行开发根基。在此之前以代码审查把关。

## 5. DTO 与不可变模型

- **DTO 一律 `record`**（不可变、值语义、模式匹配友好）：

  ```csharp
  public sealed record QuotaSnapshot(
      UsageProvider Provider,
      double RemainingPercent,
      DateTimeOffset RetrievedAt);
  ```

- 领域内部可变状态（如 store、缓存）可用 `sealed class`；默认一切类型 `sealed`，需继承时显式打开并注释理由。
- 集合成员暴露 `IReadOnlyList<T>` / `IImmutableList<T>`，不暴露可变 `List<T>`。

## 6. JSON 序列化

- 统一 `System.Text.Json`；**属性命名 camelCase**，与 macOS 端 `Codable` + provider API 实际字段（多为 snake/camel 混合）对齐时以 `windows/contracts/fixtures` 样本为准，用 `[JsonPropertyName]` 显式标注差异字段，不全局改命名策略迁就单一 provider。
- `JsonSerializerOptions`（camelCase、`ReadCommentHandling` 默认、`NumberHandling` 按需）以**单例**复用，禁止每次调用 `JsonSerializer.Serialize*` 现场构造。
- 反序列化目标用 record；未知字段容忍（默认行为），缺失字段靠测试钉住。
- > TODO（性能冲刺，Phase 3 评估）：切换 `JsonSerializerContext` source generator 减少反射开销（对 AOT 无诉求，仅启动/内存收益）。

## 7. 测试规范

### 7.1 命名：与 Swift 测试类一一对应

Swift 端 `AIQuotaBar/Tests/`（59 个文件）是移植验收清单：**每个 Swift 测试类对应一个同名 xUnit 测试类**；`test_` 前缀去掉、下划线分段转 PascalCase，保留 Given/When/Then 语义分段。对应示例：

| Swift | C#（xUnit） |
| --- | --- |
| `AIQuotaBar/Tests/ModelUtilizationHistoryStoreTests.swift`<br>`final class ModelUtilizationHistoryStoreTests: XCTestCase`<br>`func test_noFile_returnsEmptyWithoutCorruptDir()` | `windows/tests/AIQuotaBar.Core.Tests/ModelUtilizationHistoryStoreTests.cs`<br>`public sealed class ModelUtilizationHistoryStoreTests`<br>`[Fact] public void NoFile_ReturnsEmptyWithoutCorruptDir()` |

- 纯逻辑测试方法用 `[Fact]`；对 fixtures 参数化的用 `[Theory]` + `[MemberData]`。
- 一个 Swift 测试方法允许拆为多个 C# 测试方法，但不得合并遗漏断言；移植 PR 的描述里给出"Swift 方法 → xUnit 方法"的逐项映射表。

### 7.2 fixtures：共享契约样本，禁止自造

- 所有 API 请求/响应样本位于 `windows/contracts/fixtures/`（与 macOS 端共享，契约 agent 维护），按 `<provider>/<场景>.json` 组织。
- **测试内禁止手写/内联 API 响应 JSON 字符串**——解析测试必须从 fixtures 目录加载真实录制样本。缺样本时向编排者申请补录，不得用 `"{\"quota\": 1}"` 之类的临时字符串顶替。
- fixtures 定位约定：测试运行时从 `AppContext.BaseDirectory` 逐级向上查找仓库根（以 `windows/Directory.Build.props` 存在为标记），再拼接 `windows/contracts/fixtures/` 相对路径。公共加载辅助类由契约 agent 提供（`AIQuotaBar.Core.Tests` 内 `Fixtures/` 目录），各测试项目复用同一实现。
- 临时文件/目录测试遵循 Swift 端 `setUp/tearDown` 模式：xUnit 中用构造函数 + `IDisposable`（或 `IAsyncLifetime`），临时根用 `Path.GetTempPath()` + UUID 子目录。

### 7.3 其他

- 断言消息写清"应然 vs 实然"中文说明（对齐 Swift 端习惯），便于失败时定位。
- 测试齐全性以"对照 Swift 测试清单逐项打勾"为准，不以行覆盖率为准（计划 §9）。
