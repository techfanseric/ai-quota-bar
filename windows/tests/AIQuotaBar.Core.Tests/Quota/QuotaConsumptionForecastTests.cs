// Swift 来源：AIQuotaBar/Tests/QuotaConsumptionForecastTests.swift — final class
// QuotaConsumptionForecastTests（被测：AIQuotaBar.Core/Quota/QuotaConsumptionForecaster.cs）。
//
// 验收对照表（Swift 函数 → xUnit 方法）：
// - testFlatLatestIntervalProducesNoImmediateForecast          → FlatLatestInterval_ProducesNoImmediateForecast
// - testOlderConsumptionStillProducesLongerLookbackForecast    → OlderConsumption_StillProducesLongerLookbackForecast
// - testMultipleLookbacksProduceDifferentForecastSpeeds        → MultipleLookbacks_ProduceDifferentForecastSpeeds
// - testIncreaseStopsForecastBeforeEarlierCycle                → IncreaseStopsForecast_BeforeEarlierCycle
// - testLookbackIsClampedToFiveIntervals                       → Lookback_IsClampedToFiveIntervals
// - testOldSampleGapStopsForecastFromReachingStalePoints       → OldSampleGap_StopsForecastFromReachingStalePoints

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;

using Xunit;

namespace AIQuotaBar.Core.Tests.Quota;

public sealed class QuotaConsumptionForecastTests
{
    private static readonly DateTimeOffset Base = new(1_700_000_000, TimeSpan.Zero);

    // Swift: private func sample(minutes:remaining:) — percent 模式下 percent = remaining。
    private static ModelQuotaSample Sample(int minutes, int remaining) =>
        new(Base.AddMinutes(minutes), remaining, remaining);

    // Swift: private func forecasts(_:limit:) — isPercentMode: true，不设 maximumSampleGap。
    private static IReadOnlyList<QuotaConsumptionForecast> Forecasts(
        IReadOnlyList<ModelQuotaSample> samples,
        int limit) =>
        QuotaConsumptionForecaster.Forecasts(new QuotaForecastRequest(
            Samples: samples,
            IsPercentMode: true,
            MaximumLookbackIntervals: limit));

    [Fact]
    public void FlatLatestInterval_ProducesNoImmediateForecast()
    {
        var samples = new[] { Sample(minutes: 0, remaining: 80), Sample(minutes: 10, remaining: 80) };

        Assert.True(Forecasts(samples, limit: 1).Count == 0, "最近区间平坦（无消耗）不应产生预测线");
    }

    [Fact]
    public void OlderConsumption_StillProducesLongerLookbackForecast()
    {
        var samples = new[]
        {
            Sample(minutes: 0, remaining: 100),
            Sample(minutes: 10, remaining: 80),
            Sample(minutes: 20, remaining: 80),
        };

        var result = Forecasts(samples, limit: 2);
        var forecast = Assert.Single(result);
        Assert.Equal(2, forecast.LookbackIntervals);
        Assert.Equal(samples[^1].Timestamp, forecast.StartsAt);
        // 20 单位 / (20/60) 每秒 = 4800 秒后烧完（Swift accuracy: 0.001）。
        Assert.Equal(
            4_800,
            (forecast.ExhaustsAt - forecast.StartsAt).TotalSeconds,
            precision: 3);
    }

    [Fact]
    public void MultipleLookbacks_ProduceDifferentForecastSpeeds()
    {
        var samples = new[]
        {
            Sample(minutes: 0, remaining: 100),
            Sample(minutes: 10, remaining: 90),
            Sample(minutes: 20, remaining: 60),
        };

        var result = Forecasts(samples, limit: 5);
        Assert.Equal(new[] { 1, 2 }, result.Select(static forecast => forecast.LookbackIntervals));
        Assert.True(
            result[0].ConsumptionPerSecond > result[1].ConsumptionPerSecond,
            $"短回看速率应大于长回看（应然：{result[0].ConsumptionPerSecond} > {result[1].ConsumptionPerSecond}）");
    }

    [Fact]
    public void IncreaseStopsForecast_BeforeEarlierCycle()
    {
        var samples = new[]
        {
            Sample(minutes: 0, remaining: 40),
            Sample(minutes: 10, remaining: 100),
            Sample(minutes: 20, remaining: 80),
        };

        var result = Forecasts(samples, limit: 5);
        // 剩余回升（refill/reset）后，预测不得穿回更早的消耗段。
        Assert.Equal(new[] { 1 }, result.Select(static forecast => forecast.LookbackIntervals));
    }

    [Fact]
    public void Lookback_IsClampedToFiveIntervals()
    {
        var samples = Enumerable.Range(0, 8)
            .Select(index => Sample(minutes: index * 10, remaining: 100 - index * index))
            .ToList();

        var result = Forecasts(samples, limit: 99);
        Assert.True(
            result.All(static forecast => forecast.LookbackIntervals <= 5),
            "回看区间应被钳制到 ≤ 5（实然包含更大值）");
    }

    [Fact]
    public void OldSampleGap_StopsForecastFromReachingStalePoints()
    {
        var samples = new[]
        {
            Sample(minutes: 0, remaining: 100),
            Sample(minutes: 60, remaining: 80),
            Sample(minutes: 61, remaining: 70),
        };

        var result = QuotaConsumptionForecaster.Forecasts(new QuotaForecastRequest(
            Samples: samples,
            IsPercentMode: true,
            MaximumLookbackIntervals: 5,
            MaximumSampleGap: TimeSpan.FromSeconds(180)));

        // 0min→60min 间隔 3600s > 180s 阈值：回看不得越过间隙去取陈旧样本。
        Assert.Equal(new[] { 1 }, result.Select(static forecast => forecast.LookbackIntervals));
    }
}
