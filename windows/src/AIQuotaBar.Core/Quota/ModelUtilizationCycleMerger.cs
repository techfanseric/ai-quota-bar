// Swift 来源：AIQuotaBar/Models/ModelUtilizationHistory.swift — enum ModelUtilizationCycleMerger
// （mergeLiveCurrentCycle(_:model:limit:now:mode:)、private liveUsedPercent(for:)、
// private clampedPercent(_:)）。
// 对应测试：AIQuotaBar/Tests/ModelUtilizationCycleMergerTests.swift

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 把历史 cycles 与 live 行的"当前 in-progress 周期"合并（柱图数据源）：
/// includeCurrent 模式下用 live 行覆盖/插入当前周期，并把 120s 容差内的陈旧历史边界
/// 归并掉（同一周期在展示上只留一根柱）。
/// </summary>
public static class ModelUtilizationCycleMerger
{
    /// <summary>
    /// 合并历史 cycles 与 live 行的当前周期，返回按时间倒序的最近 limit 个周期。
    /// - 历史 cycle 的 peak 先各自钳到 0-100，同 resetsAt 取 max；
    /// - includeCurrent 且 live 行处于进行中（endTime ≥ now、startTime 缺失或 ≤ now）时：
    ///   删除与 endTime 相差 ≤ 120s 的陈旧边界，再以 endTime 为键写入 live usedPercent；
    /// - completedOnly 不插入 live 周期（由调用方保证传入的历史已过滤）。
    /// </summary>
    public static IReadOnlyList<UtilizationCycle> MergeLiveCurrentCycle(
        IReadOnlyList<UtilizationCycle> historicalCycles,
        ModelUsageData model,
        int limit,
        DateTimeOffset now,
        UtilizationHistoryMode mode)
    {
        if (limit <= 0)
        {
            return Array.Empty<UtilizationCycle>();
        }

        var peakByReset = new Dictionary<DateTimeOffset, double>();
        foreach (var cycle in historicalCycles)
        {
            var peakPercent = ClampedPercent(cycle.PeakPercent);
            peakByReset[cycle.ResetsAt] = Math.Max(
                peakByReset.GetValueOrDefault(cycle.ResetsAt),
                peakPercent);
        }

        if (mode == UtilizationHistoryMode.IncludeCurrent &&
            model.EndTime is { } endTime &&
            endTime >= now &&
            (model.StartTime is not { } startTime || startTime <= now) &&
            LiveUsedPercent(model) is { } liveUsedPercent)
        {
            var tolerance = TimeSpan.FromSeconds(ModelUtilizationHistory.ResetBoundaryMergeToleranceSeconds);
            var staleResets = peakByReset.Keys
                .Where(reset => Math.Abs((reset - endTime).TotalSeconds) <= tolerance.TotalSeconds)
                .ToList();
            foreach (var staleReset in staleResets)
            {
                peakByReset.Remove(staleReset);
            }

            peakByReset[endTime] = liveUsedPercent;
        }

        return peakByReset
            .Select(static pair => new UtilizationCycle(pair.Key, pair.Value))
            .OrderByDescending(static cycle => cycle.ResetsAt)
            .Take(limit)
            .ToList();
    }

    // Swift private static liveUsedPercent(for:)：优先 API 剩余百分比（100 - percent），
    // 否则按已用 count / 总量。已用 = max(0, total - remaining)（UsageDataCalculations 同一公式）。
    private static double? LiveUsedPercent(ModelUsageData model)
    {
        if (model.CurrentIntervalRemainingPercent is { } percent)
        {
            return ClampedPercent(100 - percent);
        }

        if (model.CurrentIntervalTotal <= 0)
        {
            return null;
        }

        var usedCount = Math.Max(0, model.CurrentIntervalTotal - model.CurrentIntervalRemaining);
        return ClampedPercent((double)usedCount / model.CurrentIntervalTotal * 100);
    }

    // Swift private static clampedPercent(_:)。
    private static double ClampedPercent(double percent) => Math.Clamp(percent, 0, 100);
}
