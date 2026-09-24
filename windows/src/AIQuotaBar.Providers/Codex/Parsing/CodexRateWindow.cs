// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/UsageFetcher.swift（struct RateWindow，
//   仅保留 Codex 管线消费的字段；nextRegenPercent / isSyntheticPlaceholder 为其他 provider 专用，裁剪）

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 一个额度窗口（Swift: RateWindow）。usedPercent 不做全局归一（保留原始超限值）；
/// 渲染层的钳制属后续 AIQuotaBar.Core 任务。
/// </summary>
/// <param name="UsedPercent">已用百分比（原始值，可超 100）。</param>
/// <param name="WindowMinutes">窗口分钟数（5h=300，weekly=10080）；null 未知。</param>
/// <param name="ResetsAt">重置时刻；null 未知。</param>
/// <param name="ResetDescription">
/// 可选重置描述文案。Windows 差异：usage 响应侧不在此处生成（Swift 由 UsageFormatter.resetDescription
/// 按当前 locale 生成，属行为等价风险项、后续 Core 阶段统一）；仅 usage-snapshot 反序列化时从线上带入。
/// </param>
public sealed record CodexRateWindow(
    double UsedPercent,
    int? WindowMinutes,
    DateTimeOffset? ResetsAt,
    string? ResetDescription = null)
{
    /// <summary>Swift: remainingPercent = max(0, 100 - usedPercent)。</summary>
    public double RemainingPercent => Math.Max(0, 100 - UsedPercent);
}
