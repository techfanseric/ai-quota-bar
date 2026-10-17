using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Usage;

/// <summary>
/// Token counters of one usage event. Invariants mirror the macOS parser:
/// input already contains cached reads, output already contains reasoning,
/// <c>Total = Input + Output</c> (never add cached/reasoning again).
/// </summary>
public readonly record struct UsageTokens(long Input, long Cached, long CacheWrite, long Output, long Reasoning)
{
    public const long MaxValue = 1_000_000_000_000;

    public long Total => Input + Output;

    public bool IsValid =>
        Input >= 0 && Input <= MaxValue
        && Cached >= 0 && Cached <= MaxValue
        && CacheWrite >= 0 && CacheWrite <= MaxValue
        && Output >= 0 && Output <= MaxValue
        && Reasoning >= 0 && Reasoning <= MaxValue
        && Cached + CacheWrite <= Input
        && Reasoning <= Output;

    /// <summary>Same shape as the macOS signature: "in:cached:write:out:reason".</summary>
    public string SignatureText => $"{Input}:{Cached}:{CacheWrite}:{Output}:{Reasoning}";

    public static UsageTokens operator +(UsageTokens left, UsageTokens right) => new(
        left.Input + right.Input, left.Cached + right.Cached, left.CacheWrite + right.CacheWrite,
        left.Output + right.Output, left.Reasoning + right.Reasoning);

    public static UsageTokens Delta(UsageTokens total, UsageTokens previous) => new(
        total.Input - previous.Input, total.Cached - previous.Cached, total.CacheWrite - previous.CacheWrite,
        total.Output - previous.Output, total.Reasoning - previous.Reasoning);

    public static bool MonotonicFrom(UsageTokens total, UsageTokens previous) =>
        total.Input >= previous.Input && total.Cached >= previous.Cached
        && total.CacheWrite >= previous.CacheWrite && total.Output >= previous.Output
        && total.Reasoning >= previous.Reasoning;
}

/// <summary>
/// One billable local usage event, the unit persisted to <c>local-usage.json</c>.
/// OccurredAt uses the fixed ISO format (lexicographically ordered); Id is the
/// SHA-256 idempotency key "session|timestamp|signature|occurrence" like macOS.
/// </summary>
public sealed record LocalUsageEvent
{
    public required string Id { get; init; }

    public required string OccurredAt { get; init; }

    /// <summary>Normalized model name (trimmed, lowercase); "unknown" when never seen.</summary>
    public required string Model { get; init; }

    public required UsageTokens Tokens { get; init; }

    /// <summary>"exact" (from last_token_usage) or "cumulative-delta" (estimated).</summary>
    public required string Quality { get; init; }

    /// <summary>rate_limits.limit_id of the emitting line, "default" when absent.</summary>
    public required string LimitId { get; init; }

    /// <summary>total/last counter signature of the source snapshot.</summary>
    public required string Signature { get; init; }

    /// <summary>Team reporting binding (future); null while unbound.</summary>
    public string? Binding { get; init; }

    /// <summary>Team reporting delivery state (future); "pending" by default.</summary>
    public string Delivery { get; init; } = "pending";
}

/// <summary>
/// USD per million tokens for one model over an effective interval.
/// Exact model matching only: no fuzzy fallback, no implicit zero price.
/// </summary>
public sealed record UsagePrice
{
    public required string Model { get; init; }

    public required string Version { get; init; }

    public required string Source { get; init; }

    /// <summary>Inclusive interval start (ISO, normalized to fixed format).</summary>
    public required string EffectiveFrom { get; init; }

    /// <summary>Exclusive interval end (ISO); null = open ended.</summary>
    public string? EffectiveTo { get; init; }

    public required decimal Input { get; init; }

    public required decimal Cached { get; init; }

    public decimal? CacheWrite { get; init; }

    public required decimal Output { get; init; }

    public string NormalizedModel => Model.Trim().ToLowerInvariant();

    /// <summary>Fixed-format bounds usable for lexicographic [from, to) matching.</summary>
    public (string From, string To) Bounds() => (NormalizeBound(EffectiveFrom, DateTimeOffset.MinValue),
        EffectiveTo is null ? NormalizeBound(null, DateTimeOffset.MaxValue) : NormalizeBound(EffectiveTo, DateTimeOffset.MaxValue));

    /// <summary>Cost in USD for the given aggregated tokens; null when cacheWrite is unpriced.</summary>
    public decimal? Cost(UsageTokens tokens)
    {
        if (tokens.CacheWrite > 0 && CacheWrite is null)
        {
            return null;
        }

        return ((tokens.Input - tokens.Cached - tokens.CacheWrite) * Input
                + tokens.Cached * Cached
                + tokens.CacheWrite * (CacheWrite ?? 0m)
                + tokens.Output * Output) / 1_000_000m;
    }

    /// <summary>Tolerant JSON parse of one price row (null when the row is not an object).</summary>
    public static UsagePrice? FromNode(JsonNode? node)
    {
        if (node is not JsonObject obj)
        {
            return null;
        }

        string Str(string key) => obj[key]?.ToString() ?? "";
        decimal? Num(string key)
        {
            var value = obj[key];
            if (value is null)
            {
                return null;
            }

            return value is JsonValue json && json.TryGetValue<decimal>(out var parsed) ? parsed
                : decimal.TryParse(value.ToString(), NumberStyles.Number, CultureInfo.InvariantCulture, out var text) ? text : null;
        }

        var from = Str("effectiveFrom");
        if (!AQB.Core.TimeText.TryParseIso(from, out var fromTime))
        {
            return null;
        }

        string? to = null;
        var rawTo = obj["effectiveTo"]?.ToString();
        if (!string.IsNullOrEmpty(rawTo))
        {
            if (!AQB.Core.TimeText.TryParseIso(rawTo, out var toTime))
            {
                return null;
            }

            to = AQB.Core.TimeText.FixedIso(toTime);
        }

        return new UsagePrice
        {
            Model = Str("model"),
            Version = Str("version"),
            Source = Str("source"),
            EffectiveFrom = AQB.Core.TimeText.FixedIso(fromTime),
            EffectiveTo = to,
            Input = Num("input") ?? 0m,
            Cached = Num("cached") ?? 0m,
            CacheWrite = Num("cacheWrite"),
            Output = Num("output") ?? 0m,
        };
    }

    /// <summary>Validates the whole table: required fields, ordered bounds, rate ranges, no overlaps per model.</summary>
    public static void Validate(IEnumerable<UsagePrice> prices)
    {
        var list = prices.ToList();
        foreach (var price in list)
        {
            if (string.IsNullOrWhiteSpace(price.Model) || string.IsNullOrWhiteSpace(price.Version)
                || string.IsNullOrWhiteSpace(price.Source)
                || !AQB.Core.TimeText.TryParseIso(price.EffectiveFrom, out var from)
                || (price.EffectiveTo is not null
                    && (!AQB.Core.TimeText.TryParseIso(price.EffectiveTo, out var to) || to <= from))
                || !InRateRange(price.Input) || !InRateRange(price.Cached) || !InRateRange(price.Output)
                || (price.CacheWrite is { } write && !InRateRange(write)))
            {
                throw new ArgumentException("Invalid model price or effective date");
            }
        }

        for (var i = 0; i < list.Count; i++)
        {
            for (var j = i + 1; j < list.Count; j++)
            {
                if (!string.Equals(list[i].NormalizedModel, list[j].NormalizedModel, StringComparison.Ordinal))
                {
                    continue;
                }

                var (fromA, toA) = list[i].Bounds();
                var (fromB, toB) = list[j].Bounds();
                if (string.CompareOrdinal(fromA, toB) < 0 && string.CompareOrdinal(fromB, toA) < 0)
                {
                    throw new ArgumentException($"Overlapping prices for {list[i].Model}");
                }
            }
        }

        return;

        static bool InRateRange(decimal value) => value >= 0m && value <= 1_000_000m;
    }

    /// <summary>Parses a JSON array of price rows, skipping non-object entries, then validates.</summary>
    public static List<UsagePrice> ParseTable(string json)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            throw new ArgumentException("Price table is not valid JSON");
        }

        var prices = (root as JsonArray)?.Select(FromNode).OfType<UsagePrice>().ToList()
            ?? throw new ArgumentException("Price table must be a JSON array");
        Validate(prices);
        return prices;
    }

    private static string NormalizeBound(string? text, DateTimeOffset fallback)
        => text is not null && AQB.Core.TimeText.TryParseIso(text, out var parsed)
            ? AQB.Core.TimeText.FixedIso(parsed)
            : AQB.Core.TimeText.FixedIso(fallback);
}

/// <summary>One local-calendar-day bucket of the summary rows.</summary>
public sealed record DailyUsageRow
{
    /// <summary>Local calendar date, "yyyy-MM-dd".</summary>
    public required string Date { get; init; }

    public long InputTokens { get; init; }

    public long CachedInputTokens { get; init; }

    public long CacheWriteTokens { get; init; }

    public long OutputTokens { get; init; }

    public long TotalTokens => InputTokens + OutputTokens;

    public int Requests { get; init; }

    /// <summary>Σcached/Σinput for the day; null when the day has no input tokens.</summary>
    public double? CacheHitRate { get; init; }

    /// <summary>Day cost (USD); null when any record of the day is unpriced.</summary>
    public decimal? Cost { get; init; }
}

/// <summary>Aggregated totals over the requested window (macOS formula parity).</summary>
public sealed class UsageSummary
{
    public static readonly UsageSummary Empty = new(0, 0, 0, new UsageTokens(),
        null, 0m, new Dictionary<string, decimal?>(), Array.Empty<DailyUsageRow>());

    public UsageSummary(int recordCount, int estimatedRecordCount, int pricedRecordCount, UsageTokens tokens,
        double? weightedCacheHitRate, decimal? totalEstimatedCost,
        IReadOnlyDictionary<string, decimal?> estimatedCostByModel, IReadOnlyList<DailyUsageRow> rows)
    {
        RecordCount = recordCount;
        EstimatedRecordCount = estimatedRecordCount;
        PricedRecordCount = pricedRecordCount;
        Tokens = tokens;
        WeightedCacheHitRate = weightedCacheHitRate;
        TotalEstimatedCost = totalEstimatedCost;
        EstimatedCostByModel = estimatedCostByModel;
        Rows = rows;
    }

    public int RecordCount { get; }

    /// <summary>Records whose tokens came from a cumulative delta (quality != "exact").</summary>
    public int EstimatedRecordCount { get; }

    /// <summary>Records covered by a fully priced model (cacheWrite priced when used).</summary>
    public int PricedRecordCount { get; }

    public UsageTokens Tokens { get; }

    public long TotalInputTokens => Tokens.Input;

    public long TotalCachedInputTokens => Tokens.Cached;

    public long TotalCacheWriteTokens => Tokens.CacheWrite;

    public long TotalOutputTokens => Tokens.Output;

    public long TotalTokens => Tokens.Total;

    /// <summary>Token-weighted cache hit rate Σcached/Σinput (input already contains cached); null when Σinput == 0.</summary>
    public double? WeightedCacheHitRate { get; }

    /// <summary>Total cost; null as soon as any record is unpriced, 0 when there are no records.</summary>
    public decimal? TotalEstimatedCost { get; }

    /// <summary>Cost per model; null marks an unpriced model (no price row, or cacheWrite used without a rate).</summary>
    public IReadOnlyDictionary<string, decimal?> EstimatedCostByModel { get; }

    public IReadOnlyList<DailyUsageRow> Rows { get; }
}
