// Origin: AIQuotaBar/Models/UsageData.swift — struct UsageData, struct ModelUsageData.
// Field semantics cross-checked against the filling code:
//   - AIQuotaBar/Services/Codex/CodexUsageDataMapper.swift
//   - AIQuotaBar/Services/Kimi/KimiUsageDataMapper.swift
//   - AIQuotaBar/Services/UsageService.swift (MiniMax decodeMiniMaxUsageData / decodeGLMUsageData)
//
// DATA SHAPE ONLY: every computed property of the Swift structs (percentages, availability
// predicates, pace/reserve/deficit math, formatting, sorting, window classification) is a
// later AIQuotaBar.Core task; the semantic notes below document what that logic may assume.
//
// WIRE COMPATIBILITY NOTE: the C# property names for the three renamed Swift fields carry
// [JsonPropertyName] pins to the exact Swift Codable keys so payloads stay interchangeable:
//   Swift currentIntervalUsed  -> C# CurrentIntervalRemaining ("currentIntervalUsed" on the wire)
//   Swift weeklyUsed           -> C# WeeklyRemaining          ("weeklyUsed" on the wire)
//   Swift remainsTime          -> C# RemainsTimeMilliseconds  ("remainsTime" on the wire)
// 命名经编排者确认（2026-09-24 裁决 1）：字段语义为剩余量，线上键保留 MiniMax 原名。

#nullable enable

using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// One provider's quota snapshot (Swift: UsageData — originally the MiniMax remains-endpoint
/// response, now the app-wide unified shape filled by every provider mapper).
/// </summary>
/// <param name="Provider">Which provider produced this snapshot.</param>
/// <param name="Remains">
/// Count of models that still have quota in the current interval
/// (Swift: remains — every mapper computes models.filter(isCurrentIntervalAvailable).count).
/// Despite the MiniMax heritage this is a MODEL COUNT, not a token count.
/// </param>
/// <param name="Total">
/// Total tracked models (Swift: total). Codex uses max(models.count, 1) so a lone
/// not-configured placeholder still reads as 0/1.
/// </param>
/// <param name="Timestamp">When the response was produced/refreshed.</param>
/// <param name="Models">Per-model quota rows; never null (empty only transiently).</param>
/// <param name="SubscribeTitle">
/// Optional subscription/plan title. MiniMax: from the combo/cycle endpoint
/// (e.g. "TokenPlanMax"), trimmed, null when empty. GLM: data.level (tier name).
/// Codex/Kimi: always null.
/// </param>
/// <param name="SubscribeEndTime">
/// Optional subscription end. MiniMax only; epoch-ms from current_subscribe_end_time_ts,
/// null when absent or 0 (= no active subscription).
/// </param>
/// <param name="GlmResetAllowances">
/// GLM only: read-only personal Coding-Plan reset entitlements attached to the latest fetch.
/// Swift declared this with a default of nil.
/// </param>
public sealed record UsageData(
    UsageProvider Provider,
    int Remains,
    int Total,
    DateTimeOffset Timestamp,
    IReadOnlyList<ModelUsageData> Models,
    string? SubscribeTitle,
    DateTimeOffset? SubscribeEndTime,
    GlmResetAllowances? GlmResetAllowances);

/// <summary>
/// One quota row: a provider x account x model x window tuple (Swift: ModelUsageData).
///
/// Filling semantics by provider (authoritative, from the mappers):
/// - Codex 5h/Weekly rows: CurrentIntervalTotal = 100 (percent scale);
///   CurrentIntervalRemaining = round(100 - usedPercent); ValueSuffix = "%";
///   CurrentIntervalRemainingPercent = same value; Start = resetsAt - windowMinutes*60;
///   RemainsTimeMilliseconds = ms until reset. Weekly fields stay 0/null.
/// - Codex "Credits" row: CurrentIntervalTotal = 1000 (fixed full scale);
///   CurrentIntervalRemaining = remaining credits (clamped int); ValueSuffix = " left";
///   ProgressBarPercentOverride = clamp(remaining/1000*100) — REVERSED bar semantics so a full
///   balance renders a full bar; ProgressBarRightText = fixed scale text (e.g. "1K tokens");
///   no start/end times; percent fields null. Pace math is disabled for such rows.
/// - Codex not-configured placeholder: single "Codex" row with Total=1, Remaining=1,
///   CurrentIntervalRemainingPercent = 0 and a fixed hint in DetailText.
/// - Kimi rows: CurrentIntervalTotal = 100; CurrentIntervalRemaining = clamp(round(
///   remainingPercent)); ValueSuffix = "%"; percent field set; Start inferred from
///   resetsAt - windowMinutes*60 EXCEPT the "kimi-monthly" extra ("Total usage") which keeps
///   Start = null (expiry-only monthly plan). RemainsTimeMilliseconds = max(0, ms until reset).
/// - MiniMax rows: count fields copied straight from model_remains —
///   current_interval_usage_count IS the remaining count and current_weekly_usage_count IS the
///   weekly remaining count; percent fields copied when the API provides them; start/end times
///   are epoch-ms in the payload. Status=3 / total=0 + percent=100 encodes weekly-unlimited.
/// - GLM rows: count or percent scale depending on the limit item; 5h rows may omit reset
///   metadata entirely (window classification then relies on the model name containing "5h").
/// </summary>
public sealed record ModelUsageData(
    UsageProvider Provider,
    string? AccountName,
    string ModelName,
    int CurrentIntervalTotal,
    [property: JsonPropertyName("currentIntervalUsed")] int CurrentIntervalRemaining,
    int WeeklyTotal,
    [property: JsonPropertyName("weeklyUsed")] int WeeklyRemaining,
    [property: JsonPropertyName("remainsTime")] int RemainsTimeMilliseconds,
    DateTimeOffset? StartTime,
    DateTimeOffset? EndTime,
    DateTimeOffset? WeeklyStartTime,
    DateTimeOffset? WeeklyEndTime,
    string? ValueSuffix,
    string? DetailText,
    int? CurrentIntervalRemainingPercent,
    int? WeeklyRemainingPercent,
    double? ProgressBarPercentOverride,
    string? ProgressBarRightText,
    DateTimeOffset? SampledAt)
{
    // ---------------------------------------------------------------------------
    // Semantic notes for later Core logic (Swift computed properties — NOT ported here).
    // ---------------------------------------------------------------------------

    // CurrentIntervalRemaining (Swift field name: currentIntervalUsed):
    //   The API value is REMAINING, not used (Swift comment: "API: 这是剩余数量，不是已用！").
    //   Derived used count = max(0, CurrentIntervalTotal - CurrentIntervalRemaining).
    //   WeeklyRemaining (Swift: weeklyUsed): same inversion for the weekly window.

    // CurrentIntervalRemainingPercent / WeeklyRemainingPercent:
    //   0-100 REMAINING percent straight from APIs (MiniMax). When present they take priority
    //   over count-based math; absence falls back to count ratio. Percent mode is signaled by
    //   ValueSuffix == "%" OR CurrentIntervalRemainingPercent != null.

    // RemainsTimeMilliseconds: milliseconds until the current interval resets
    //   (MiniMax passes API remains_time through; Codex/Kimi compute it from EndTime).
    //   0 when unknown/no reset (credits rows, not-configured placeholder).

    // EndTime is the reset boundary. It is also the cycle-grouping key for utilization
    // history (UtilizationHistoryEntry.ResetsAt snapshots it).

    // ProgressBarPercentOverride (0-100):
    //   When set, the progress bar renders the REMAINING ratio instead of the default USED
    //   ratio (codex credits), and pace/reserve/deficit math must return "unavailable".
    //   Pace reserve/deficit sign convention (Swift currentIntervalPaceDeltaPercent):
    //   positive = burning slower than steady pace (ahead / reserve, shown green);
    //   negative = burning faster (behind / deficit, shown red).

    // DetailText:
    //   Free-form " · "-joined segments, e.g. "Pro 20x · OAuth · resets 04/08 00:00"
    //   (Codex) or a bare source label (Kimi/Cloud rows). Timestamps inside are rendered in
    //   Asia/Shanghai. Parsing rules (parsedDetail) are Core logic, not contract.

    // SampledAt: sampling time for cloud/historical rows used as a freshness signal;
    //   null means live local data.
}
