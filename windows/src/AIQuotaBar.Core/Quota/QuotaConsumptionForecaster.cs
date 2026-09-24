// Swift 来源：AIQuotaBar/Models/QuotaConsumptionForecast.swift — enum QuotaConsumptionForecaster
// （forecasts 预测算法与 maximumSampleGap(refreshInterval:)；输入/输出形状即同文件的
// QuotaConsumptionForecast / ModelQuotaSample，已由 Contracts/QuotaForecast.cs 冻结）。
// 对应测试：AIQuotaBar/Tests/QuotaConsumptionForecastTests.swift

#nullable enable

using System;
using System.Collections.Generic;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 匀速消耗预测器（Swift: QuotaConsumptionForecaster）。从最新样本出发，按不同回看区间
/// 计算恒定消耗速率并外推"烧完时刻"，多条预测线描述不同置信口径。
/// </summary>
public static class QuotaConsumptionForecaster
{
    /// <summary>回看区间硬上限：Swift 的 min(max(value, 1), 5) 钳制上界。</summary>
    public const int MaximumLookbackIntervalCap = 5;

    /// <summary>
    /// 计算一个 model 窗口的预测线（Swift: forecasts(samples:isPercentMode:maximumLookbackIntervals:maximumSampleGap:)）。
    /// 规则（与 Swift 逐条对齐）：
    /// - 回看区间钳制到 [1, 5]；样本按时间升序，仅取最近 limit+1 条；
    /// - percent 模式下缺 percent 的样本被跳过；非有限或负的剩余值被跳过；
    /// - 最新样本剩余必须 &gt; 0 才有预测意义；
    /// - 逐级回看：相邻两样本间隔超过 maximumSampleGap（staleness 防护）即停止；
    /// - 剩余值回升（refill / reset / 修正）即停止，绝不穿过它向前一段消耗区外推；
    /// - 斜率重复（相对差 &lt; 1%）的回看只保留第一条，避免同一斜率反复加深描线。
    /// </summary>
    public static IReadOnlyList<QuotaConsumptionForecast> Forecasts(QuotaForecastRequest request)
    {
        var limit = Math.Clamp(request.MaximumLookbackIntervals, 1, MaximumLookbackIntervalCap);

        var sorted = new List<SamplePoint>(request.Samples.Count);
        foreach (var sample in request.Samples)
        {
            var remaining = RemainingValue(sample, request.IsPercentMode);
            if (remaining is null || !double.IsFinite(remaining.Value) || remaining.Value < 0)
            {
                continue;
            }

            sorted.Add(new SamplePoint(sample.Timestamp, remaining.Value));
        }

        sorted.Sort(static (lhs, rhs) => lhs.Timestamp.CompareTo(rhs.Timestamp));

        var recentCount = Math.Min(sorted.Count, limit + 1);
        var recent = sorted.GetRange(sorted.Count - recentCount, recentCount);
        if (recent.Count < 2)
        {
            return Array.Empty<QuotaConsumptionForecast>();
        }

        var latest = recent[^1];
        if (latest.Remaining <= 0)
        {
            return Array.Empty<QuotaConsumptionForecast>();
        }

        var result = new List<QuotaConsumptionForecast>();
        var maximumAvailable = recent.Count - 1;

        for (var lookback = 1; lookback <= maximumAvailable; lookback++)
        {
            var older = recent[^(lookback + 1)];
            var newer = recent[^lookback];

            if (request.MaximumSampleGap is { } maximumSampleGap &&
                newer.Timestamp - older.Timestamp > maximumSampleGap)
            {
                break;
            }

            // An increase marks a refill, reset, or correction. Never project
            // through it into an earlier consumption run.
            if (newer.Remaining > older.Remaining)
            {
                break;
            }

            var elapsed = (latest.Timestamp - older.Timestamp).TotalSeconds;
            var consumed = older.Remaining - latest.Remaining;
            if (elapsed <= 0 || consumed <= 0)
            {
                continue;
            }

            var rate = consumed / elapsed;
            if (!double.IsFinite(rate) || rate <= 0)
            {
                continue;
            }

            // Several lookbacks can describe effectively the same slope. A
            // single line is clearer than repeatedly darkening that path.
            if (IsDuplicateSlope(result, rate))
            {
                continue;
            }

            result.Add(new QuotaConsumptionForecast(
                LookbackIntervals: lookback,
                ConsumptionPerSecond: rate,
                StartsAt: latest.Timestamp,
                StartingRemaining: latest.Remaining,
                ExhaustsAt: latest.Timestamp.AddSeconds(latest.Remaining / rate)));
        }

        return result;
    }

    /// <summary>
    /// 样本间隔 staleness 防护阈值（Swift: maximumSampleGap(refreshInterval:)）：
    /// max(刷新间隔 x 3, 180s)。
    /// </summary>
    public static TimeSpan MaximumSampleGap(int refreshIntervalSeconds) =>
        TimeSpan.FromSeconds(Math.Max(refreshIntervalSeconds * 3.0, 180.0));

    private static double? RemainingValue(ModelQuotaSample sample, bool isPercentMode)
    {
        if (isPercentMode)
        {
            return sample.Percent is { } percent ? percent : null;
        }

        return sample.Remaining;
    }

    private static bool IsDuplicateSlope(IReadOnlyList<QuotaConsumptionForecast> existing, double rate)
    {
        foreach (var forecast in existing)
        {
            if (Math.Abs(forecast.ConsumptionPerSecond - rate) /
                Math.Max(forecast.ConsumptionPerSecond, rate) < 0.01)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>时间戳 + 该时刻的剩余值（count 或百分比点），预测的最小样本单元。</summary>
    private readonly record struct SamplePoint(DateTimeOffset Timestamp, double Remaining);
}
