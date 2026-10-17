using System.Text.Json;
using AQB.Core;

namespace AQB.Usage;

/// <summary>Outcome of one facade scan: summary plus scan/prune statistics.</summary>
public sealed record LocalUsageScanResult
{
    public required UsageSummary Summary { get; init; }

    public int FilesParsed { get; init; }

    public int FilesSkipped { get; init; }

    public int FilesSeen { get; init; }

    public int DeferredSessions { get; init; }

    public required IReadOnlySet<string> DeferredSessionIds { get; init; }

    public int Issues { get; init; }

    public int PrunedEvents { get; init; }
}

/// <summary>
/// Facade over the scanner and aggregator: Scan() runs an incremental scan,
/// prunes expendable records, persists the event cache to
/// %APPDATA%\AIQuotaBar\local-usage.json and returns the 35-day summary.
/// GetSummary(lookbackDays) recomputes windows from the cached events.
/// </summary>
public sealed class LocalUsageService
{
    public const int DefaultLookbackDays = 35;
    public const int MaxLookbackDays = 366;
    public const string CacheFileName = "local-usage.json";

    private static readonly JsonSerializerOptions CacheJson = new(Json.SnakeCase);

    private readonly CodexSessionScanner _scanner;

    public LocalUsageService(string? codexHome = null, string? dataDir = null, IEnumerable<UsagePrice>? prices = null)
    {
        DataDir = dataDir is { Length: > 0 } dir ? dir : UsagePaths.DefaultDataDir;
        _scanner = new CodexSessionScanner(codexHome, Path.Combine(DataDir, CodexSessionScanner.StampsFileName));
        Prices = prices is null ? Array.Empty<UsagePrice>() : prices.ToList();
    }

    public string DataDir { get; }

    public string CachePath => Path.Combine(DataDir, CacheFileName);

    public IReadOnlyList<UsagePrice> Prices { get; private set; }

    public void SetPrices(IEnumerable<UsagePrice> prices)
    {
        var list = prices.ToList();
        UsagePrice.Validate(list);
        Prices = list;
    }

    /// <summary>Replaces the price table from a JSON array (validated; throws ArgumentException when invalid).</summary>
    public void LoadPricesFromJson(string json) => Prices = UsagePrice.ParseTable(json);

    /// <summary>Incremental scan + aggregation; persists the event cache and prunes old records.</summary>
    public LocalUsageScanResult Scan(DateTimeOffset? now = null)
    {
        var moment = now ?? DateTimeOffset.UtcNow;
        var scan = _scanner.Scan();
        var events = scan.Events;
        var pruned = PruneList(events, CodexSessionScanner.RecordRetentionDays, moment, out var retained);
        WriteCache(new UsageCache
        {
            ScannedAt = TimeText.FixedIso(moment),
            Events = retained,
            DeferredSessionIds = scan.DeferredSessionIds.ToList(),
            Issues = scan.Issues,
        });
        return new LocalUsageScanResult
        {
            Summary = BuildSummary(retained, DefaultLookbackDays, TimeZoneInfo.Local, moment),
            FilesParsed = scan.FilesParsed,
            FilesSkipped = scan.FilesSkipped,
            FilesSeen = scan.FilesSeen,
            DeferredSessions = scan.DeferredSessions,
            DeferredSessionIds = scan.DeferredSessionIds,
            Issues = scan.Issues,
            PrunedEvents = pruned,
        };
    }

    /// <summary>Summary over the last <paramref name="lookbackDays"/> local days (default 35), from the cache.</summary>
    public UsageSummary GetSummary(int lookbackDays = DefaultLookbackDays, TimeZoneInfo? timeZone = null)
        => BuildSummary(LoadEvents(), lookbackDays, timeZone ?? TimeZoneInfo.Local, DateTimeOffset.UtcNow);

    /// <summary>
    /// Prunes expendable cached records older than the retention window: only records that are
    /// delivered ("sent") or unbound are removable; bound pending records are never deleted.
    /// Returns the number of pruned events.
    /// </summary>
    public int PruneOldEvents(int retentionDays = CodexSessionScanner.RecordRetentionDays, DateTimeOffset? now = null)
    {
        var cache = ReadCache();
        if (cache is null)
        {
            return 0;
        }

        var pruned = PruneList(cache.Events, retentionDays, now ?? DateTimeOffset.UtcNow, out var retained);
        if (pruned > 0)
        {
            cache.Events = retained;
            WriteCache(cache);
        }

        return pruned;
    }

    /// <summary>Cached events (empty when no scan has run yet).</summary>
    public IReadOnlyList<LocalUsageEvent> LoadEvents() => ReadCache()?.Events ?? new List<LocalUsageEvent>();

    internal static int PruneList(
        IReadOnlyList<LocalUsageEvent> events, int retentionDays, DateTimeOffset now,
        out List<LocalUsageEvent> retained)
    {
        var cutoff = TimeText.FixedIso(now - TimeSpan.FromDays(retentionDays));
        retained = new List<LocalUsageEvent>(events.Count);
        var pruned = 0;
        foreach (var e in events)
        {
            // Strictly older than the cutoff, and only expendable delivery states.
            if (string.CompareOrdinal(e.OccurredAt, cutoff) < 0
                && (string.Equals(e.Delivery, "sent", StringComparison.Ordinal) || e.Binding is null))
            {
                pruned++;
                continue;
            }

            retained.Add(e);
        }

        return pruned;
    }

    private UsageSummary BuildSummary(
        IReadOnlyList<LocalUsageEvent> events, int lookbackDays, TimeZoneInfo zone, DateTimeOffset now)
    {
        var days = Math.Clamp(lookbackDays, 1, MaxLookbackDays);
        var localNow = TimeZoneInfo.ConvertTime(now, zone);
        var startDate = localNow.Date.AddDays(-(days - 1));
        var from = new DateTimeOffset(startDate, zone.GetUtcOffset(startDate));
        return UsageAggregator.Summarize(events, Prices, from, now.AddSeconds(1), zone);
    }

    private UsageCache? ReadCache()
    {
        var node = Json.TryReadFile(CachePath);
        if (node is null)
        {
            return null;
        }

        try
        {
            return node.Deserialize<UsageCache>(CacheJson);
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or NotSupportedException)
        {
            return null;
        }
    }

    private void WriteCache(UsageCache cache)
    {
        try
        {
            Json.AtomicWrite(CachePath, JsonSerializer.Serialize(cache, CacheJson));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Best effort: summaries fall back to an empty cache until the next scan.
        }
    }

    private sealed class UsageCache
    {
        public int Version { get; set; } = 1;

        public string ScannedAt { get; set; } = "";

        public List<LocalUsageEvent> Events { get; set; } = new();

        public List<string> DeferredSessionIds { get; set; } = new();

        public int Issues { get; set; }
    }
}
