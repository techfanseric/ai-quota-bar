// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexAdditionalRateLimitMapper.swift
//   （extraRateWindows / sparkWindows / namedWindow / slug —— 逐分支镜像；resetDescription 的
//   UsageFormatter 本地化文案不在此生成，见 CodexRateWindow.ResetDescription 注释）

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// additional_rate_limits（模型专属限额，如 GPT-5.3-Codex-Spark）→ 命名额外窗口
/// （Swift: CodexAdditionalRateLimitMapper）。Spark 专属固定 ID/标题；其余条目用
/// "codex-&lt;slug&gt;" ID 与原始 limit_name 标题；重复 ID 只保留首次出现。
/// </summary>
public static class CodexAdditionalRateLimitMapper
{
    public const string SparkWindowId = "codex-spark";
    public const string SparkWeeklyWindowId = "codex-spark-weekly";
    public const string SparkWindowTitle = "Codex Spark 5-hour";
    public const string SparkWeeklyWindowTitle = "Codex Spark Weekly";

    public static IReadOnlyList<CodexNamedRateWindow> ExtraRateWindows(
        IReadOnlyList<AdditionalRateLimit>? additionalRateLimits)
    {
        var result = new List<CodexNamedRateWindow>();
        if (additionalRateLimits is null || additionalRateLimits.Count == 0)
        {
            return result;
        }

        var usedIds = new HashSet<string>();
        foreach (var entry in additionalRateLimits)
        {
            if (IsSpark(entry))
            {
                AppendSparkWindows(entry, usedIds, result);
            }
            else
            {
                AppendGenericWindow(entry, usedIds, result);
            }
        }

        return result;
    }

    private static void AppendSparkWindows(
        AdditionalRateLimit entry,
        HashSet<string> usedIds,
        List<CodexNamedRateWindow> result)
    {
        AppendSparkWindow(entry.RateLimit?.PrimaryWindow, SparkKind.FiveHour, usedIds, result);
        AppendSparkWindow(entry.RateLimit?.SecondaryWindow, SparkKind.Weekly, usedIds, result);
    }

    private static void AppendSparkWindow(
        CodexUsageResponse.WindowSnapshot? snapshot,
        SparkKind fallbackKind,
        HashSet<string> usedIds,
        List<CodexNamedRateWindow> result)
    {
        if (snapshot is null)
        {
            return;
        }

        var kind = SparkKindFor(snapshot, fallbackKind);
        if (!usedIds.Add(kind.Id()))
        {
            return;
        }

        result.Add(new CodexNamedRateWindow(kind.Id(), kind.Title(), MakeWindow(snapshot)));
    }

    private static void AppendGenericWindow(
        AdditionalRateLimit entry,
        HashSet<string> usedIds,
        List<CodexNamedRateWindow> result)
    {
        // 模型专属限额报在 primary 窗口；仅当 primary 缺失才回退 secondary。
        var snapshot = entry.RateLimit?.PrimaryWindow ?? entry.RateLimit?.SecondaryWindow;
        if (snapshot is null)
        {
            return;
        }

        var id = WindowId(entry);
        if (id is null || !usedIds.Add(id))
        {
            return;
        }

        result.Add(new CodexNamedRateWindow(id, WindowTitle(entry), MakeWindow(snapshot)));
    }

    internal static CodexRateWindow MakeWindow(CodexUsageResponse.WindowSnapshot snapshot)
    {
        var resetsAt = snapshot.ResetAt > 0
            ? DateTimeOffset.FromUnixTimeSeconds(snapshot.ResetAt)
            : null;
        return new CodexRateWindow(
            UsedPercent: snapshot.UsedPercent,
            WindowMinutes: snapshot.LimitWindowSeconds > 0 ? snapshot.LimitWindowSeconds / 60 : null,
            ResetsAt: resetsAt,
            ResetDescription: null);
    }

    private enum SparkKind
    {
        FiveHour,
        Weekly,
    }

    private static string Id(this SparkKind kind) => kind switch
    {
        SparkKind.FiveHour => SparkWindowId,
        SparkKind.Weekly => SparkWeeklyWindowId,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static string Title(this SparkKind kind) => kind switch
    {
        SparkKind.FiveHour => SparkWindowTitle,
        SparkKind.Weekly => SparkWeeklyWindowTitle,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static SparkKind SparkKindFor(
        CodexUsageResponse.WindowSnapshot snapshot,
        SparkKind fallback)
    {
        var minutes = snapshot.LimitWindowSeconds > 0 ? snapshot.LimitWindowSeconds / 60 : 0;
        if (minutes > 0 && minutes <= 6 * 60)
        {
            return SparkKind.FiveHour;
        }

        if (minutes >= 6 * 24 * 60)
        {
            return SparkKind.Weekly;
        }

        return fallback;
    }

    private static string? WindowId(AdditionalRateLimit entry)
    {
        var source = FirstNonEmpty(entry.MeteredFeature, entry.LimitName);
        if (source is null)
        {
            return null;
        }

        var slug = Slug(source);
        return slug.Length == 0 ? null : $"codex-{slug}";
    }

    private static string WindowTitle(AdditionalRateLimit entry) =>
        FirstNonEmpty(entry.LimitName, entry.MeteredFeature) ?? "Codex extra limit";

    private static bool IsSpark(AdditionalRateLimit entry) =>
        Array.Find(
            new[] { entry.LimitName, entry.MeteredFeature },
            value => value is not null && value.IndexOf("spark", StringComparison.OrdinalIgnoreCase) >= 0)
        is not null;

    private static string? FirstNonEmpty(params string?[] values)
    {
        foreach (var value in values)
        {
            var trimmed = value?.Trim();
            if (!string.IsNullOrEmpty(trimmed))
            {
                return trimmed;
            }
        }

        return null;
    }

    /// <summary>Swift: slug —— 小写化后非字母数字折叠为单个连字符，首尾连字符去除。</summary>
    private static string Slug(string value)
    {
        var builder = new System.Text.StringBuilder(value.Length);
        var lastWasDash = false;
        foreach (var c in value.ToLowerInvariant())
        {
            if (char.IsAsciiLetterOrDigit(c))
            {
                builder.Append(c);
                lastWasDash = false;
            }
            else if (!lastWasDash)
            {
                builder.Append('-');
                lastWasDash = true;
            }
        }

        return builder.ToString().Trim('-');
    }
}
