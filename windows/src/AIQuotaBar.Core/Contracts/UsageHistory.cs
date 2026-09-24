// Origin: AIQuotaBar/Models/ModelUtilizationHistory.swift — struct UtilizationHistoryEntry,
// struct ModelUtilizationHistory, struct ModelUtilizationStoreData; and
// AIQuotaBar/Models/UtilizationHistoryMode.swift — enum UtilizationHistoryMode.
//
// DATA SHAPE ONLY: cycle grouping (cycles(limit:now:mode:)), trim/append bookkeeping and
// ModelUtilizationCycleMerger are later AIQuotaBar.Core tasks. Their behavioral constants
// are pinned below because tests will assert against them.

#nullable enable

using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// Whether utilization cycles include the in-progress one (Swift raw values "includeCurrent" /
/// "completedOnly"; persisted as a preference string).
/// </summary>
public enum UtilizationHistoryMode
{
    IncludeCurrent,
    CompletedOnly,
}

/// <summary>One utilization sample for one model (Swift: UtilizationHistoryEntry).</summary>
/// <param name="CapturedAt">Sampling time (throttled to ~1 sample/hour by the collector).</param>
/// <param name="UsedPercent">USED percent 0-100 (Core logic clamps; matches pace convention).</param>
/// <param name="ResetsAt">
/// The cycle reset boundary the sample belonged to — i.e. ModelUsageData.EndTime at capture
/// time. Null for open-ended rows; the cycle grouping keys on this value.
/// </param>
public sealed record UtilizationHistoryEntry(
    DateTimeOffset CapturedAt,
    double UsedPercent,
    DateTimeOffset? ResetsAt);

/// <summary>
/// Full utilization history for one model, keyed by modelId (Swift: ModelUtilizationHistory).
/// Entries are append-only; consumers group by ResetsAt to derive per-cycle peaks.
/// </summary>
public sealed record ModelUtilizationHistory(string ModelId, IReadOnlyList<UtilizationHistoryEntry> Entries)
{
    /// <summary>
    /// Cap per model: 2200 entries x 1h throttle = ~91 days. Overflow drops oldest by
    /// CapturedAt (Swift: maxEntriesPerModel — enforced by Core logic after append).
    /// </summary>
    public const int MaxEntriesPerModel = 2200;

    /// <summary>
    /// Reset boundaries within 120 seconds of each other describe the same cycle and must be
    /// merged during grouping (Swift: resetBoundaryMergeTolerance — seconds).
    /// </summary>
    public const double ResetBoundaryMergeToleranceSeconds = 120;
}

/// <summary>
/// On-disk file content: one store per provider, histories nested by modelId (Swift:
/// ModelUtilizationStoreData). The modelId string is a QuotaIdentity key, so provider and
/// account are embedded and multi-account data is naturally isolated.
/// </summary>
/// <param name="Histories">
/// Nullable on purpose: older JSON files lack the field entirely and must still decode,
/// treating absence as empty (Swift comment on the field).
/// </param>
public sealed record ModelUtilizationStoreData(Dictionary<string, ModelUtilizationHistory>? Histories);

/// <summary>Exact Swift raw-value wire format for <see cref="UtilizationHistoryMode"/>.</summary>
public sealed class UtilizationHistoryModeJsonConverter : JsonConverter<UtilizationHistoryMode>
{
    public static UtilizationHistoryModeJsonConverter Instance { get; } = new();

    public override UtilizationHistoryMode Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        return raw switch
        {
            "includeCurrent" => UtilizationHistoryMode.IncludeCurrent,
            "completedOnly" => UtilizationHistoryMode.CompletedOnly,
            _ => throw new JsonException($"Unknown UtilizationHistoryMode raw value '{raw}'."),
        };
    }

    public override void Write(Utf8JsonWriter writer, UtilizationHistoryMode value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value switch
        {
            UtilizationHistoryMode.IncludeCurrent => "includeCurrent",
            UtilizationHistoryMode.CompletedOnly => "completedOnly",
            _ => throw new ArgumentOutOfRangeException(nameof(value), value, null),
        });
    }
}
