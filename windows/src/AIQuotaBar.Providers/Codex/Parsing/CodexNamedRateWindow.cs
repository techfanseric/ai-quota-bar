// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/UsageFetcher.swift（struct NamedRateWindow）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 命名的额外额度窗口（Swift: NamedRateWindow），如 GPT-5.3-Codex-Spark 的独立 5h/weekly 限额。
/// </summary>
/// <param name="Id">稳定标识（如 "codex-spark" / "codex-spark-weekly" / "codex-&lt;slug&gt;"）。</param>
/// <param name="Title">展示标题（如 "Codex Spark 5-hour"）。</param>
/// <param name="Window">窗口数据。</param>
public sealed record CodexNamedRateWindow(
    string Id,
    string Title,
    CodexRateWindow Window);
