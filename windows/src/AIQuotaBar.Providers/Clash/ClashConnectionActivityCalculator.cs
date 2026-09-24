// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionModels.swift — struct ClashConnectionActivityCalculator（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testActivityCalculatorComputesFilteredPerSecondRates 等

#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 逐帧计算过滤后连接的每秒速率：按连接 id 保留上一帧计数器；新连接与计数器回退（重连）
/// 不产生速率尖峰。Swift 为 mutating struct，C# 为可变 sealed class（状态语义一致）。
/// </summary>
public sealed class ClashConnectionActivityCalculator
{
    private Dictionary<string, Counter> _previousCounters = new();

    public void Reset() => _previousCounters = new Dictionary<string, Counter>();

    public ClashConnectionActivitySnapshot Update(
        ClashConnectionsResponse response,
        DateTimeOffset? observedAt = null)
    {
        var now = observedAt ?? DateTimeOffset.UtcNow;
        var matchingConnections = response.Connections
            .Where(ClashOpenAIConnectionFilter.Matches)
            .ToList();

        var nextCounters = new Dictionary<string, Counter>(matchingConnections.Count);
        var activeConnections = new List<ClashActiveConnection>(matchingConnections.Count);

        foreach (var connection in matchingConnections)
        {
            _previousCounters.TryGetValue(connection.Id, out var previous);
            var elapsed = previous is null
                ? 0.0
                : Math.Max(0, (now - previous.ObservedAt).TotalSeconds);

            var uploadSpeed = Speed(connection.Upload, previous?.Upload, elapsed);
            var downloadSpeed = Speed(connection.Download, previous?.Download, elapsed);
            var startedAt = ClashConnectionDateParser.Date(connection.Start);

            activeConnections.Add(
                new ClashActiveConnection(
                    Id: connection.Id,
                    Host: ClashOpenAIConnectionFilter.DisplayHost(connection),
                    Process: NonEmpty(connection.Metadata.Process),
                    Network: NonEmpty(connection.Metadata.Network),
                    Chains: connection.Chains,
                    StartedAt: startedAt,
                    Duration: startedAt is null
                        ? 0.0
                        : Math.Max(0, (now - startedAt.Value).TotalSeconds),
                    UploadSpeed: uploadSpeed,
                    DownloadSpeed: downloadSpeed));

            nextCounters[connection.Id] = new Counter(
                connection.Upload,
                connection.Download,
                now);
        }

        _previousCounters = nextCounters;
        activeConnections.Sort(CompareActiveConnections);

        return new ClashConnectionActivitySnapshot(
            ObservedAt: now,
            Connections: activeConnections,
            UploadSpeed: activeConnections.Sum(connection => connection.UploadSpeed),
            DownloadSpeed: activeConnections.Sum(connection => connection.DownloadSpeed));
    }

    private static int CompareActiveConnections(ClashActiveConnection lhs, ClashActiveConnection rhs)
    {
        // 新连接在前（startedAt 降序）；同为 null 视作相等，回退到名称比较
        //（localizedStandardCompare 的 Windows 近似：CurrentCultureIgnoreCase）。
        if (lhs.StartedAt != rhs.StartedAt)
        {
            var left = lhs.StartedAt ?? DateTimeOffset.MinValue;
            var right = rhs.StartedAt ?? DateTimeOffset.MinValue;
            return right.CompareTo(left);
        }

        return string.Compare(lhs.Host, rhs.Host, CultureInfo.CurrentCulture, CompareOptions.OrdinalIgnoreCase);
    }

    private static double Speed(long current, long? previous, double elapsed)
    {
        if (previous is not { } previousValue || current < previousValue || elapsed <= 0)
        {
            return 0.0;
        }

        return (current - previousValue) / elapsed;
    }

    private static string? NonEmpty(string? value)
    {
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    private sealed record Counter(long Upload, long Download, DateTimeOffset ObservedAt);
}
