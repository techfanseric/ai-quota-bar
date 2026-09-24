// Swift 来源：AIQuotaBar/Models/ModelUtilizationHistory.swift — struct ModelUtilizationHistory 的
// mutating append(_:) / trimToLimit() / cycles(limit:now:mode:)（Swift class 内可变状态 +
// mutating 方法；C# 端 Contracts 的 record 不可变，改为返回新实例的扩展方法），
// 以及 struct ModelUtilizationStoreData 的 historiesOrEmpty。
// 行为常量（2200 条上限、120s 合并容差）来自 Contracts/UsageHistory.cs 的冻结常量。
// 与 Swift 的差异：append 返回裁剪后的新 history（Swift 的 @discardableResult Bool
// "是否实际裁剪" 在唯一调用点 UsageViewModel.swift:1629 被丢弃，不再暴露）。
// 对应测试：AIQuotaBar/Tests/ModelUtilizationCycleMergerTests.swift（cycles 分组部分）

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// ModelUtilizationHistory / ModelUtilizationStoreData 的纯计算逻辑（append/trim/cycles/合并容差）。
/// record 不可变，全部返回新实例。
/// </summary>
public static class ModelUtilizationHistoryCalculations
{
    /// <summary>
    /// 追加一条 entry 并裁剪到上限内。Swift: append(_:) -> Bool（Bool 见文件头说明，已省略）。
    /// </summary>
    public static ModelUtilizationHistory Append(
        this ModelUtilizationHistory history,
        UtilizationHistoryEntry entry) =>
        TrimToLimit(history with { Entries = history.Entries.Append(entry).ToList() });

    /// <summary>
    /// 裁剪到 MaxEntriesPerModel 内：按 capturedAt 升序丢最旧的（返回排序后的新实例；
    /// 未超限时原样返回）。Swift: trimToLimit()。
    /// </summary>
    public static ModelUtilizationHistory TrimToLimit(this ModelUtilizationHistory history)
    {
        if (history.Entries.Count <= ModelUtilizationHistory.MaxEntriesPerModel)
        {
            return history;
        }

        var overflow = history.Entries.Count - ModelUtilizationHistory.MaxEntriesPerModel;
        var sorted = history.Entries.OrderBy(static entry => entry.CapturedAt).ToList();
        sorted.RemoveRange(0, overflow);
        return history with { Entries = sorted };
    }

    /// <summary>Swift: cycles(limit:now:mode:)，默认 now（Date()）。</summary>
    public static IReadOnlyList<UtilizationCycle> Cycles(
        this ModelUtilizationHistory history,
        int limit) =>
        history.Cycles(limit, DateTimeOffset.Now, UtilizationHistoryMode.IncludeCurrent);

    /// <summary>Swift: cycles(limit:now:mode:)，默认 mode = includeCurrent。</summary>
    public static IReadOnlyList<UtilizationCycle> Cycles(
        this ModelUtilizationHistory history,
        int limit,
        DateTimeOffset now) =>
        history.Cycles(limit, now, UtilizationHistoryMode.IncludeCurrent);

    /// <summary>
    /// 按 resetsAt 分组取 peak，返回按时间倒序的最近 limit 个周期。Swift: cycles(limit:now:mode:)。
    /// - includeCurrent：所有 resetsAt 参与计算，in-progress 周期也会出现（最右一根）；
    /// - completedOnly：仅 resetsAt ≤ now 参与计算；
    /// - 同周期多个样本取 max(usedPercent)；usedPercent ≤ 0 的样本与 resetsAt 为 null 的样本跳过；
    /// - reset 边界相差 ≤ 120s（ResetBoundaryMergeToleranceSeconds）视为同周期，合并取更晚边界；
    /// - 时钟回退保护：now 早于最早 entry.capturedAt 时把 now 拉回 capturedAt 上限，
    ///   避免 completedOnly 误把全部历史过滤掉。
    /// </summary>
    public static IReadOnlyList<UtilizationCycle> Cycles(
        this ModelUtilizationHistory history,
        int limit,
        DateTimeOffset now,
        UtilizationHistoryMode mode)
    {
        if (limit <= 0)
        {
            return Array.Empty<UtilizationCycle>();
        }

        var earliestCapture = history.Entries.Count > 0
            ? history.Entries.Select(static entry => entry.CapturedAt).Min()
            : now;
        var effectiveNow = now < earliestCapture ? earliestCapture : now;

        var tolerance = TimeSpan.FromSeconds(ModelUtilizationHistory.ResetBoundaryMergeToleranceSeconds);
        var buckets = new List<(DateTimeOffset ResetsAt, double PeakPercent)>();
        foreach (var entry in history.Entries
                     .OrderBy(static entry => entry.ResetsAt ?? DateTimeOffset.MinValue))
        {
            if (entry.ResetsAt is not { } resetsAt)
            {
                continue;
            }

            if (entry.UsedPercent <= 0)
            {
                continue;
            }

            if (mode == UtilizationHistoryMode.CompletedOnly && resetsAt > effectiveNow)
            {
                continue;
            }

            var index = LastIndexWithinTolerance(buckets, resetsAt, tolerance);
            if (index >= 0)
            {
                var bucket = buckets[index];
                buckets[index] = (
                    resetsAt > bucket.ResetsAt ? resetsAt : bucket.ResetsAt,
                    Math.Max(bucket.PeakPercent, entry.UsedPercent));
            }
            else
            {
                buckets.Add((resetsAt, entry.UsedPercent));
            }
        }

        return buckets
            .Select(static bucket => new UtilizationCycle(bucket.ResetsAt, bucket.PeakPercent))
            .OrderByDescending(static cycle => cycle.ResetsAt)
            .Take(limit)
            .ToList();
    }

    /// <summary>histories 为 null（旧版 JSON 缺字段）时视为空。Swift: ModelUtilizationStoreData.historiesOrEmpty。</summary>
    public static IReadOnlyDictionary<string, ModelUtilizationHistory> HistoriesOrEmpty(
        this ModelUtilizationStoreData data) =>
        data.Histories ?? new Dictionary<string, ModelUtilizationHistory>();

    // Swift: buckets.lastIndex(where: { |$0.resetsAt - resetsAt| <= tolerance }) — 从尾部向前找。
    private static int LastIndexWithinTolerance(
        IReadOnlyList<(DateTimeOffset ResetsAt, double PeakPercent)> buckets,
        DateTimeOffset resetsAt,
        TimeSpan tolerance)
    {
        for (var index = buckets.Count - 1; index >= 0; index--)
        {
            if (Math.Abs((buckets[index].ResetsAt - resetsAt).TotalSeconds) <= tolerance.TotalSeconds)
            {
                return index;
            }
        }

        return -1;
    }
}
