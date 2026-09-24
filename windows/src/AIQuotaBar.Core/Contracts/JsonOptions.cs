// Origin: new file. Shared System.Text.Json conventions for every AIQuotaBar.Core contract.
//
// Swift reference behavior being mirrored (macOS app, v1.28.1):
// - Codable synthesizes camelCase JSON keys from property names, and OPTIONAL properties are
//   omitted from the output when nil (encodeIfPresent semantics). Mirrored here with
//   DefaultIgnoreCondition = WhenWritingNull.
// - Every real persistence / sync boundary in the Swift app pins dates to ISO 8601 via
//   JSONEncoder.dateEncodingStrategy = .iso8601 (ModelQuotaSampleStore,
//   ModelUtilizationHistoryStore, CloudSyncService rawJSONString, MobileDashboardService
//   broadcast loop).
// - Dates use the STRICT Swift .iso8601 wire shape — always UTC with a "Z" suffix, second
//   precision, no fractional seconds — via SwiftIso8601DateTimeOffsetConverter (registered
//   below for DateTimeOffset and DateTimeOffset?). This is a hard requirement for the
//   differential golden tests (same input, Swift and C# outputs byte-equal); do NOT relax it.
//   Reading accepts "Z" and other UTC offsets; non-Z offsets are normalized to UTC so the
//   first re-serialization is already stable (idempotent). Sub-second precision is accepted
//   on read and truncated on write — exactly what Swift's .iso8601 does to a fractional Date.
// - UsageProvider travels as its lowercase Swift raw value ("codex"/"kimi"/"glm"/"minimax"),
//   not the C# enum member name. Pinned by a hand-written converter — no reflection anywhere.
//
// Formatting-only differences that remain (not semantics): Swift's data report encoder uses
// .prettyPrinted + .sortedKeys; callers may clone these options and add WriteIndented /
// ordering when generating report files.

#nullable enable

using System;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// Shared <see cref="JsonSerializerOptions"/> for all quota contract (de)serialization.
/// Treat as frozen: wire compatibility with the macOS app, on-disk formats, and the
/// differential golden tests depend on it.
/// </summary>
public static class QuotaJson
{
    public static JsonSerializerOptions Default { get; } = Create();

    /// <summary>
    /// Builds a fresh options instance (same conventions as <see cref="Default"/>) so callers
    /// can layer additional settings (e.g. <c>WriteIndented = true</c>) without mutating the shared one.
    /// </summary>
    public static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            Converters =
            {
                SwiftIso8601DateTimeOffsetConverter.Instance,
                SwiftIso8601NullableDateTimeOffsetConverter.Instance,
                UsageProviderJsonConverter.Instance,
                UtilizationHistoryModeJsonConverter.Instance,
                QuotaWindowKindJsonConverter.Instance,
            },
        };
        return options;
    }
}

/// <summary>
/// Strict Swift .iso8601 date wire format: writes always-UTC "yyyy-MM-ddTHH:mm:ssZ" (second
/// precision, sub-second digits truncated); reads "Z" as well as other offsets and normalizes
/// them to UTC. Byte-parity with Swift's JSONEncoder dateEncodingStrategy = .iso8601 is what
/// the differential golden tests rely on. Hand-written, zero reflection.
/// </summary>
public sealed class SwiftIso8601DateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    public static SwiftIso8601DateTimeOffsetConverter Instance { get; } = new();

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        // AssumeUniversal: offset-less text is treated as UTC so parsing stays machine-independent.
        if (raw is null ||
            !DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var value))
        {
            throw new JsonException(
                $"Invalid DateTimeOffset '{raw}'. Expected ISO 8601, e.g. \"2026-09-24T10:30:00Z\".");
        }

        return value.ToUniversalTime();
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(FormatStrictSwiftIso8601(value));
    }

    /// <summary>"yyyy-MM-ddTHH:mm:ssZ" in UTC; sub-second precision truncated (Swift .iso8601 shape).</summary>
    public static string FormatStrictSwiftIso8601(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
}

/// <summary>
/// Nullable twin of <see cref="SwiftIso8601DateTimeOffsetConverter"/> for DateTimeOffset? fields.
/// Null tokens pass through as null (for top-level values; property-level nulls are usually
/// skipped entirely by <c>WhenWritingNull</c>).
/// </summary>
public sealed class SwiftIso8601NullableDateTimeOffsetConverter : JsonConverter<DateTimeOffset?>
{
    public static SwiftIso8601NullableDateTimeOffsetConverter Instance { get; } = new();

    public override DateTimeOffset? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
        {
            return null;
        }

        return SwiftIso8601DateTimeOffsetConverter.Instance.Read(ref reader, typeToConvert, options);
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset? value, JsonSerializerOptions options)
    {
        if (value is null)
        {
            writer.WriteNullValue();
            return;
        }

        writer.WriteStringValue(SwiftIso8601DateTimeOffsetConverter.FormatStrictSwiftIso8601(value.Value));
    }
}
