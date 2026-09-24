// Swift 来源：AIQuotaBar/Services/Codex/CodexUsageDataMapper.swift（mapToUsageData / makeModel /
//   makeCreditsModel / makeNotConfiguredPlaceholder / makeDetailText / prettySourceLabel —— 逐字段镜像）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexUsageDataMapperTests.cs（移植
//   AIQuotaBar/Tests/Codex/CodexUsageDataMapperTests.swift）

#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// CodexBarCore 快照 + credits → 应用层 <see cref="Contracts.UsageData"/>（Swift:
/// CodexUsageDataMapper）。模型行：5h / Weekly / 额外窗口 / Credits / 未配置占位；
/// remains = 有余量的窗口数；total = max(行数, 1)。
/// </summary>
public static class CodexUsageDataMapper
{
    /// <summary>codexbar 用 1000 作为 credits 进度条固定满刻度（渲染剩余比例，方向与默认相反）。</summary>
    private const double CreditsFullScale = 1000;

    private static readonly TimeZoneInfo ShanghaiTimeZone = ResolveShanghaiTimeZone();

    public static UsageData MapToUsageData(
        CodexUsageSnapshot snapshot,
        CodexCreditsSnapshot? credits,
        string sourceLabel,
        DateTimeOffset now)
    {
        var models = new List<ModelUsageData>();
        var accountName = snapshot.Identity?.AccountEmail;
        var planType = snapshot.Identity?.LoginMethod;

        if (snapshot.Primary is { } primary)
        {
            models.Add(MakeModel("5h", primary, accountName, planType, sourceLabel, now));
        }

        if (snapshot.Secondary is { } secondary)
        {
            models.Add(MakeModel("Weekly", secondary, accountName, planType, sourceLabel, now));
        }

        if (snapshot.ExtraRateWindows is { } extras)
        {
            foreach (var named in extras)
            {
                var name = named.Title.Length == 0 ? named.Id : named.Title;
                models.Add(MakeModel(name, named.Window, accountName, planType, sourceLabel, now));
            }
        }

        if (credits is { } creditsSnapshot)
        {
            models.Add(MakeCreditsModel(creditsSnapshot.Remaining, accountName, planType, sourceLabel));
        }

        if (models.Count == 0)
        {
            models.Add(MakeNotConfiguredPlaceholder(accountName));
        }

        var readyCount = 0;
        foreach (var model in models)
        {
            if (IsCurrentIntervalAvailable(model))
            {
                readyCount++;
            }
        }

        return new UsageData(
            Provider: UsageProvider.Codex,
            Remains: readyCount,
            Total: Math.Max(models.Count, 1),
            Timestamp: snapshot.UpdatedAt,
            Models: models,
            SubscribeTitle: null,
            SubscribeEndTime: null,
            GlmResetAllowances: null);
    }

    /// <summary>
    /// Swift: makeModel —— 百分比刻度（total=100，remaining=round(100-used)），起点 =
    /// resetsAt - windowMinutes*60，倒计时 = 距 resetsAt 的毫秒（向零截断）。
    /// </summary>
    private static ModelUsageData MakeModel(
        string name,
        CodexRateWindow window,
        string? accountName,
        string? planType,
        string sourceLabel,
        DateTimeOffset now)
    {
        var remainingPercent = (int)Math.Round(100 - window.UsedPercent, MidpointRounding.AwayFromZero);
        var endTime = window.ResetsAt;
        var startTime = endTime is { } end
            ? (DateTimeOffset?)end.AddMinutes(-(window.WindowMinutes ?? 0))
            : null;
        var detail = MakeDetailText(planType, sourceLabel, endTime);

        return new ModelUsageData(
            Provider: UsageProvider.Codex,
            AccountName: accountName,
            ModelName: name,
            CurrentIntervalTotal: 100,
            CurrentIntervalRemaining: remainingPercent,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: endTime is { } resetAt
                ? (int)(resetAt - now).TotalMilliseconds
                : 0,
            StartTime: startTime,
            EndTime: endTime,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: "%",
            DetailText: detail,
            CurrentIntervalRemainingPercent: remainingPercent,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: null,
            ProgressBarRightText: null,
            SampledAt: null);
    }

    /// <summary>
    /// Swift: makeCreditsModel —— 固定 1000 满刻度；进度条按剩余比例渲染（Override 反向语义）；
    /// 无起止时间、无百分比字段（节奏预测禁用）。
    /// </summary>
    private static ModelUsageData MakeCreditsModel(
        double remaining,
        string? accountName,
        string? planType,
        string sourceLabel)
    {
        var intRemaining = (int)Math.Round(remaining, MidpointRounding.AwayFromZero);
        var detail = MakeDetailText(planType, sourceLabel, endTime: null);
        var percentLeft = Math.Min(100, Math.Max(0, remaining / CreditsFullScale * 100));
        var scaleText = $"{TokenCountString((int)CreditsFullScale)} tokens";

        return new ModelUsageData(
            Provider: UsageProvider.Codex,
            AccountName: accountName,
            ModelName: "Credits",
            CurrentIntervalTotal: (int)CreditsFullScale,
            CurrentIntervalRemaining: intRemaining,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: 0,
            StartTime: null,
            EndTime: null,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: " left",
            DetailText: detail,
            CurrentIntervalRemainingPercent: null,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: percentLeft,
            ProgressBarRightText: scaleText,
            SampledAt: null);
    }

    /// <summary>
    /// Swift: makeNotConfiguredPlaceholder —— 占位分支固定文案，不落 source label
    /// （Swift 代码注释：plan 原文的 detail ?? "..." 会落到 source label，必须硬编码）。
    /// </summary>
    private static ModelUsageData MakeNotConfiguredPlaceholder(string? accountName) =>
        new(
            Provider: UsageProvider.Codex,
            AccountName: accountName,
            ModelName: "Codex",
            CurrentIntervalTotal: 1,
            CurrentIntervalRemaining: 1,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: 0,
            StartTime: null,
            EndTime: null,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: null,
            DetailText: "Codex not configured — run `codex` to sign in",
            CurrentIntervalRemainingPercent: 0,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: null,
            ProgressBarRightText: null,
            SampledAt: null);

    /// <summary>
    /// Swift: makeDetailText —— “计划 · 来源 · resets MM/dd HH:mm”三段式（重置时间按
    /// Asia/Shanghai 渲染，en_US_POSIX 位数格式）。
    /// </summary>
    private static string? MakeDetailText(
        string? planType,
        string? sourceLabel,
        DateTimeOffset? endTime)
    {
        var parts = new List<string>();
        if (CodexPlanFormatting.DisplayName(planType) is { } planDisplay)
        {
            parts.Add(planDisplay);
        }

        if (!string.IsNullOrEmpty(sourceLabel))
        {
            parts.Add(PrettySourceLabel(sourceLabel));
        }

        if (endTime is { } resetAt)
        {
            parts.Add(
                "resets " + resetAt
                    .ToOffset(ShanghaiTimeZone.GetUtcOffset(resetAt))
                    .ToString("MM/dd HH:mm", CultureInfo.InvariantCulture));
        }

        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    /// <summary>Swift: prettySourceLabel —— oauth → OAuth、cli/codex-cli → Codex CLI、web/openai-web → OpenAI Web，其余首字母大写。</summary>
    private static string PrettySourceLabel(string raw) => raw.ToLowerInvariant() switch
    {
        "oauth" => "OAuth",
        "cli" or "codex-cli" => "Codex CLI",
        "web" or "openai-web" => "OpenAI Web",
        _ => raw.Length == 0
            ? raw
            : char.ToUpperInvariant(raw[0]) + raw[1..],
    };

    /// <summary>
    /// Swift: ModelUsageData.isCurrentIntervalAvailable —— 有百分比字段按百分比 &gt; 0，
    /// 否则按剩余计数 &gt; 0。TODO(W1 后续)：随百分比/可用性计算一并下沉到 AIQuotaBar.Core。
    /// </summary>
    private static bool IsCurrentIntervalAvailable(ModelUsageData model) =>
        model.CurrentIntervalRemainingPercent is { } percent
            ? percent > 0
            : model.CurrentIntervalRemaining > 0;

    /// <summary>
    /// Swift: UsageFormatter.tokenCountString（credits 满刻度文案用）——K/M/B 缩写，
    /// &lt;10 保留一位小数（去掉 ".0"），升级阈值 1000/999_500/999_500_000。
    /// </summary>
    private static string TokenCountString(int value)
    {
        var absValue = Math.Abs((long)value);
        var sign = value < 0 ? "-" : string.Empty;

        (long Threshold, double Divisor, string Suffix)[] units =
        {
            (999_500_000, 1_000_000_000, "B"),
            (999_500, 1_000_000, "M"),
            (1000, 1000, "K"),
        };

        foreach (var (threshold, divisor, suffix) in units)
        {
            if (absValue < threshold)
            {
                continue;
            }

            var scaled = absValue / divisor;
            string formatted;
            if (scaled >= 10)
            {
                formatted = scaled.ToString("F0", CultureInfo.InvariantCulture);
            }
            else
            {
                var text = scaled.ToString("F1", CultureInfo.InvariantCulture);
                formatted = text.EndsWith(".0", StringComparison.Ordinal)
                    ? text[..^2]
                    : text;
            }

            return $"{sign}{formatted}{suffix}";
        }

        return $"{sign}{absValue}";
    }

    private static TimeZoneInfo ResolveShanghaiTimeZone()
    {
        // ICU 时代各平台都有 IANA "Asia/Shanghai"；Windows 旧环境可能只认显示名，做一级回退。
        try
        {
            return TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
        }
        catch (TimeZoneNotFoundException)
        {
            return TimeZoneInfo.FindSystemTimeZoneById("China Standard Time");
        }
    }
}
