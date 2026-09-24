// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — enum ClashConnectionHistory（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testHistoryReplacesCurrentMinuteAndKeepsSixtySamples

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

namespace AIQuotaBar.Providers.Clash;

/// <summary>活跃连接时序的纯函数集合：分钟对齐、同分钟替换、60 分钟窗口裁剪。</summary>
public static class ClashConnectionHistory
{
    public const double SampleIntervalSeconds = 60;

    public const int RetainedSampleCount = 60;

    public static DateTimeOffset MinuteStart(DateTimeOffset date)
    {
        var seconds = date.ToUnixTimeSeconds();
        return DateTimeOffset.FromUnixTimeSeconds(seconds / 60 * 60);
    }

    public static IReadOnlyList<ClashConnectionHistorySample> Upserting(
        ClashConnectionActivitySnapshot snapshot,
        IReadOnlyList<ClashConnectionHistorySample> samples)
    {
        var timestamp = MinuteStart(snapshot.ObservedAt);
        var sample = new ClashConnectionHistorySample(
            Timestamp: timestamp,
            ConnectionAges: snapshot.Connections
                .Select(connection => connection.Duration)
                .OrderByDescending(age => age)
                .ToList());

        var result = samples
            .Where(existing => existing.Timestamp != timestamp)
            .ToList();
        result.Add(sample);
        result.Sort((lhs, rhs) => lhs.Timestamp.CompareTo(rhs.Timestamp));

        var earliestTimestamp = timestamp.AddSeconds(-SampleIntervalSeconds * (RetainedSampleCount - 1));
        return result
            .Where(existing => existing.Timestamp >= earliestTimestamp)
            .ToList();
    }

    public static IReadOnlyList<ClashConnectionHistorySample> Pruned(
        IReadOnlyList<ClashConnectionHistorySample> samples,
        DateTimeOffset relativeTo)
    {
        var latestTimestamp = MinuteStart(relativeTo);
        var earliestTimestamp = latestTimestamp.AddSeconds(-SampleIntervalSeconds * (RetainedSampleCount - 1));

        return samples
            .Where(sample =>
                sample.Timestamp >= earliestTimestamp &&
                sample.Timestamp <= latestTimestamp)
            .OrderBy(sample => sample.Timestamp)
            .ToList();
    }
}
