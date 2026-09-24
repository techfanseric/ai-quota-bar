// Origin: derived from AIQuotaBar/Models/UsageData.swift — ModelUsageData's startTime/endTime/
// weeklyStartTime/weeklyEndTime timestamps plus the window-classification computed properties
// (isGLMFiveHourWindow, isKimiMonthlyTotalWindow, isCodexFiveHourHistoryWindow,
// isCodexWeeklyCurveWindow, isShortCurrentInterval, quotaChartWindow(now:)).
//
// Swift has no standalone window type; boundaries live directly on ModelUsageData and window
// "kinds" are implied by classification logic. This contract centralizes the window VOCABULARY
// the ported Core logic will classify into — the classification itself is a later Core task
// and is intentionally NOT implemented here.

#nullable enable

using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// The kind of quota window a ModelUsageData row describes. C#-side contract invention
/// (vocabulary pinned here so Core logic and UI agree); Swift equivalents are the computed
/// classifiers listed in the file header.
/// </summary>
public enum QuotaWindowKind
{
    /// <summary>Not classified yet (or the data carries no recognizable window shape).</summary>
    Unknown = 0,

    /// <summary>
    /// Codex "5h" / GLM "5h" rolling short window.
    /// Swift classification reference: model name contains "5h"/"5-hour"/"5 hour", or a
    /// 4.5h–5.5h measured duration for Codex history windows. GLM's variant may omit reset
    /// metadata entirely (isGLMFiveHourWindow) and then only has a display-only rolling
    /// window of [now-5h, now] — never a real reset boundary.
    /// </summary>
    FiveHour,

    /// <summary>
    /// Codex "Weekly" (7d) window — also the fallback-curve window when no short-window curve
    /// is visible (Swift: isCodexWeeklyCurveWindow — named "weekly", or 6–8 day duration).
    /// </summary>
    Weekly,

    /// <summary>
    /// Kimi monthly plan row ("Total usage"): only an expiry (End) exists; Start must be
    /// derived by back-dating one calendar month for display/pace purposes.
    /// </summary>
    MonthlyTotal,

    /// <summary>Any other bounded window (MiniMax intervals, Kimi rate-limit windows, extras).</summary>
    Custom,
}

/// <summary>
/// A quota window's time boundaries. Boundaries are optional because several providers omit
/// them: Kimi monthly has only End; GLM 5h may have neither; MiniMax always has both.
/// Never invent reset dates — Swift's rule ("A display-only rolling window; never invent
/// reset dates") applies to derived display windows, which are Core logic, not this shape.
/// </summary>
public sealed record QuotaWindow(DateTimeOffset? Start, DateTimeOffset? End, QuotaWindowKind Kind)
{
    /// <summary>Swift duration bucketing reference: intervals shorter than 24h are "short".</summary>
    public static readonly TimeSpan OneDay = TimeSpan.FromDays(1);

    /// <summary>The canonical 5-hour window length (GLM display window, Codex classification midpoint).</summary>
    public static readonly TimeSpan FiveHours = TimeSpan.FromHours(5);

    /// <summary>End - Start when both boundaries exist and are ordered; otherwise null.</summary>
    public TimeSpan? Duration
    {
        get
        {
            if (Start is { } start && End is { } end && end > start)
            {
                return end - start;
            }

            return null;
        }
    }

    /// <summary>True when <paramref name="at"/> falls inside [Start, End]; open-ended windows contain everything.</summary>
    public bool Contains(DateTimeOffset at) =>
        (Start is null || Start <= at) && (End is null || at <= End);
}

/// <summary>camelCase-string serialization for <see cref="QuotaWindowKind"/> (e.g. "fiveHour", "monthlyTotal").</summary>
public sealed class QuotaWindowKindJsonConverter : JsonConverter<QuotaWindowKind>
{
    public static QuotaWindowKindJsonConverter Instance { get; } = new();

    public override QuotaWindowKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return raw switch
        {
            "unknown" => QuotaWindowKind.Unknown,
            "fiveHour" => QuotaWindowKind.FiveHour,
            "weekly" => QuotaWindowKind.Weekly,
            "monthlyTotal" => QuotaWindowKind.MonthlyTotal,
            "custom" => QuotaWindowKind.Custom,
            _ => throw new JsonException($"Unknown QuotaWindowKind raw value '{raw}'."),
        };
    }

    public override void Write(Utf8JsonWriter writer, QuotaWindowKind value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value switch
        {
            QuotaWindowKind.Unknown => "unknown",
            QuotaWindowKind.FiveHour => "fiveHour",
            QuotaWindowKind.Weekly => "weekly",
            QuotaWindowKind.MonthlyTotal => "monthlyTotal",
            QuotaWindowKind.Custom => "custom",
            _ => throw new ArgumentOutOfRangeException(nameof(value), value, null),
        });
    }
}
