// Swift 来源：AIQuotaBar/Views/ClashConnectionPopoverView.swift — enum ClashConnectionFormat（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testConnectionDetailStartsWithNetworkAndOmitsProcess
// 说明：虽位于 Swift 的 Views 文件，但为纯字符串格式化（无 AppKit 依赖），随连接测试一并移植。

#nullable enable

using System;
using System.Globalization;
using System.Linq;

namespace AIQuotaBar.Providers.Clash;

/// <summary>连接面板展示格式化：网络·链路明细、速率（B/s 级进）、时长（s/m/h/d 进位）。</summary>
public static class ClashConnectionFormat
{
    public static string? Detail(string? network, string? chain)
    {
        string[] parts = new[]
            {
                network?.Trim().ToUpperInvariant(),
                chain?.Trim(),
            }
            .Where(part => !string.IsNullOrEmpty(part))
            .Select(part => part!)
            .ToArray();

        if (parts.Length == 0)
        {
            return null;
        }

        return string.Join(" · ", parts);
    }

    public static string Rate(double bytesPerSecond)
    {
        var value = Math.Max(0, bytesPerSecond);
        string[] units = { "B/s", "KB/s", "MB/s", "GB/s" };
        var scaled = value;
        var unitIndex = 0;
        while (scaled >= 1_000 && unitIndex < units.Length - 1)
        {
            scaled /= 1_000;
            unitIndex++;
        }

        var format = scaled >= 100 || unitIndex == 0
            ? "F0"
            : scaled >= 10
                ? "F1"
                : "F2";
        return scaled.ToString(format, CultureInfo.InvariantCulture) + " " + units[unitIndex];
    }

    public static string Duration(double interval)
    {
        var seconds = Math.Max(0, (int)interval);
        if (seconds < 60)
        {
            return $"{seconds}s";
        }

        var minutes = seconds / 60;
        if (minutes < 60)
        {
            return $"{minutes}m {seconds % 60}s";
        }

        var hours = minutes / 60;
        if (hours < 24)
        {
            return $"{hours}h {minutes % 60}m";
        }

        var days = hours / 24;
        return $"{days}d {hours % 24}h";
    }
}
