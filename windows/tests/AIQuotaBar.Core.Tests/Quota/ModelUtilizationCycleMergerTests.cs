// Swift 来源：AIQuotaBar/Tests/ModelUtilizationCycleMergerTests.swift — final class
// ModelUtilizationCycleMergerTests（被测：AIQuotaBar.Core/Quota/
// ModelUtilizationHistoryCalculations.cs 的 Cycles + ModelUtilizationCycleMerger.cs；
// 被测类型在 Swift 端位于 AIQuotaBar/Models/ModelUtilizationHistory.swift）。
//
// 验收对照表（Swift 函数 → xUnit 方法）：
// - testHistoryCyclesIgnoreUnusedSamples             → HistoryCycles_IgnoreUnusedSamples
// - testHistoryCyclesMergeNearbyResetBoundaries      → HistoryCycles_MergeNearbyResetBoundaries
// - testIncludeCurrentOverwritesStaleHistoricalCycle → IncludeCurrent_OverwritesStaleHistoricalCycle
// - testIncludeCurrentRemovesNearbyStaleResetBoundary → IncludeCurrent_RemovesNearbyStaleResetBoundary
// - testCompletedOnlyDoesNotInsertInProgressCycle    → CompletedOnly_DoesNotInsertInProgressCycle
// - testIncludeCurrentInsertsUnusedCurrentCycle      → IncludeCurrent_InsertsUnusedCurrentCycle

#nullable enable

using System;

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;

using Xunit;

namespace AIQuotaBar.Core.Tests.Quota;

public sealed class ModelUtilizationCycleMergerTests
{
    // Swift: private func weeklyModel(startTime:endTime:remainingPercent:)。
    // remainsTime 在 Swift 用真实 Date() 现算；此处取固定毫秒数（断言不依赖该字段）。
    private static ModelUsageData WeeklyModel(
        DateTimeOffset startTime,
        DateTimeOffset endTime,
        int remainingPercent) =>
        new(
            Provider: UsageProvider.Codex,
            AccountName: "user@example.com",
            ModelName: "Weekly",
            CurrentIntervalTotal: 100,
            CurrentIntervalRemaining: remainingPercent,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: 3_600_000,
            StartTime: startTime,
            EndTime: endTime,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: "%",
            DetailText: null,
            CurrentIntervalRemainingPercent: remainingPercent,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: null,
            ProgressBarRightText: null,
            SampledAt: null);

    [Fact]
    public void HistoryCycles_IgnoreUnusedSamples()
    {
        var reset = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var history = new ModelUtilizationHistory(
            ModelId: "codex:user@example.com:5h",
            Entries: new[]
            {
                new UtilizationHistoryEntry(
                    CapturedAt: reset.AddHours(-1),
                    UsedPercent: 0,
                    ResetsAt: reset.AddHours(5)),
                new UtilizationHistoryEntry(
                    CapturedAt: reset.AddSeconds(-1_800),
                    UsedPercent: 12,
                    ResetsAt: reset),
            });

        var cycles = history.Cycles(30, reset.AddSeconds(1), UtilizationHistoryMode.IncludeCurrent);

        Assert.Equal(1, cycles.Count);
        Assert.Equal(reset, cycles[0].ResetsAt);
        Assert.Equal(12, cycles[0].PeakPercent, precision: 6);
    }

    [Fact]
    public void HistoryCycles_MergeNearbyResetBoundaries()
    {
        var reset = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var history = new ModelUtilizationHistory(
            ModelId: "codex:user@example.com:5h",
            Entries: new[]
            {
                new UtilizationHistoryEntry(
                    CapturedAt: reset.AddSeconds(-2_000),
                    UsedPercent: 59,
                    ResetsAt: reset),
                new UtilizationHistoryEntry(
                    CapturedAt: reset.AddSeconds(-1_000),
                    UsedPercent: 8,
                    ResetsAt: reset.AddSeconds(20)),
            });

        var cycles = history.Cycles(30, reset.AddSeconds(1), UtilizationHistoryMode.IncludeCurrent);

        // 20s < 120s 容差：两个边界合并为一个周期，边界取更晚者，peak 取更大者。
        Assert.Equal(1, cycles.Count);
        Assert.Equal(reset.AddSeconds(20), cycles[0].ResetsAt);
        Assert.Equal(59, cycles[0].PeakPercent, precision: 6);
    }

    [Fact]
    public void IncludeCurrent_OverwritesStaleHistoricalCycle()
    {
        var now = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var reset = now.AddHours(1);
        var model = WeeklyModel(
            startTime: reset.AddHours(-7 * 24),
            endTime: reset,
            remainingPercent: 6);

        var cycles = ModelUtilizationCycleMerger.MergeLiveCurrentCycle(
            new[] { new UtilizationCycle(ResetsAt: reset, PeakPercent: 89) },
            model: model,
            limit: 12,
            now: now,
            mode: UtilizationHistoryMode.IncludeCurrent);

        Assert.Equal(1, cycles.Count);
        Assert.Equal(reset, cycles[0].ResetsAt);
        // live used = 100 - 6 = 94，覆盖同边界的陈旧历史 89。
        Assert.Equal(94, cycles[0].PeakPercent, precision: 6);
    }

    [Fact]
    public void IncludeCurrent_RemovesNearbyStaleResetBoundary()
    {
        var now = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var reset = now.AddHours(1);
        var staleResetInSameDisplayedMinute = reset.AddSeconds(20);
        var model = WeeklyModel(
            startTime: reset.AddHours(-5),
            endTime: reset,
            remainingPercent: 44);

        var cycles = ModelUtilizationCycleMerger.MergeLiveCurrentCycle(
            new[] { new UtilizationCycle(ResetsAt: staleResetInSameDisplayedMinute, PeakPercent: 8) },
            model: model,
            limit: 12,
            now: now,
            mode: UtilizationHistoryMode.IncludeCurrent);

        // 20s < 120s 容差的陈旧边界被删除，仅剩 live 周期（used = 100 - 44 = 56）。
        Assert.Equal(1, cycles.Count);
        Assert.Equal(reset, cycles[0].ResetsAt);
        Assert.Equal(56, cycles[0].PeakPercent, precision: 6);
    }

    [Fact]
    public void CompletedOnly_DoesNotInsertInProgressCycle()
    {
        var now = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var reset = now.AddHours(1);
        var model = WeeklyModel(
            startTime: reset.AddHours(-7 * 24),
            endTime: reset,
            remainingPercent: 6);

        var cycles = ModelUtilizationCycleMerger.MergeLiveCurrentCycle(
            Array.Empty<UtilizationCycle>(),
            model: model,
            limit: 12,
            now: now,
            mode: UtilizationHistoryMode.CompletedOnly);

        Assert.True(cycles.Count == 0, "completedOnly 模式不应插入 in-progress 周期");
    }

    [Fact]
    public void IncludeCurrent_InsertsUnusedCurrentCycle()
    {
        var now = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var reset = now.AddHours(1);
        var model = WeeklyModel(
            startTime: reset.AddHours(-5),
            endTime: reset,
            remainingPercent: 100);

        var cycles = ModelUtilizationCycleMerger.MergeLiveCurrentCycle(
            Array.Empty<UtilizationCycle>(),
            model: model,
            limit: 12,
            now: now,
            mode: UtilizationHistoryMode.IncludeCurrent);

        Assert.Equal(1, cycles.Count);
        Assert.Equal(reset, cycles[0].ResetsAt);
        // 未使用的 live 周期 peak = 100 - 100 = 0。
        Assert.Equal(0, cycles[0].PeakPercent, precision: 6);
    }
}
