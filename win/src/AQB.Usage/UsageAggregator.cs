using System.Globalization;
using AQB.Core;

namespace AQB.Usage;

/// <summary>
/// Deduplication and aggregation over resolved usage events. Formulas match the
/// macOS app exactly: weighted cache hit rate Σcached/Σinput (input already
/// contains cached), and Decimal cost with no fuzzy model fallback.
/// </summary>
public static class UsageAggregator
{
    private const string MinBound = "0001-01-01T00:00:00.000Z";
    private const string MaxBound = "9999-12-31T23:59:59.999Z";

    /// <summary>
    /// Keeps the newest occurrence per (LimitId, Signature) pair: one request may be
    /// re-reported across file copies or rescans; the latest snapshot is authoritative.
    /// </summary>
    public static IReadOnlyList<LocalUsageEvent> Deduplicate(IEnumerable<LocalUsageEvent> events)
    {
        var newest = new Dictionary<(string LimitId, string Signature), LocalUsageEvent>();
        foreach (var e in events)
        {
            var key = (e.LimitId, e.Signature);
            if (!newest.TryGetValue(key, out var existing)
                || string.CompareOrdinal(e.OccurredAt, existing.OccurredAt) >= 0)
            {
                newest[key] = e;
            }
        }

        return newest.Values
            .OrderBy(e => e.OccurredAt, StringComparer.Ordinal)
            .ThenBy(e => e.Id, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>
    /// Aggregates events over [from, to) (fixed-ISO string comparison, like macOS).
    /// Daily rows use local calendar day boundaries of <paramref name="timeZone"/>.
    /// </summary>
    public static UsageSummary Summarize(
        IEnumerable<LocalUsageEvent> events,
        IReadOnlyList<UsagePrice>? prices = null,
        DateTimeOffset? from = null,
        DateTimeOffset? to = null,
        TimeZoneInfo? timeZone = null)
    {
        prices ??= Array.Empty<UsagePrice>();
        var zone = timeZone ?? TimeZoneInfo.Local;
        var lower = from is { } start ? TimeText.FixedIso(start) : MinBound;
        var upper = to is { } end ? TimeText.FixedIso(end) : MaxBound;

        // Precompute normalized [from, to) bounds per model; match by ordinal string compare.
        var rates = new Dictionary<string, List<(int Index, string From, string To, UsagePrice Price)>>(StringComparer.Ordinal);
        for (var index = 0; index < prices.Count; index++)
        {
            var price = prices[index];
            var (priceFrom, priceTo) = price.Bounds();
            if (!rates.TryGetValue(price.NormalizedModel, out var list))
            {
                rates[price.NormalizedModel] = list = new List<(int, string, string, UsagePrice)>();
            }

            list.Add((index, priceFrom, priceTo, price));
        }

        var tokens = new UsageTokens();
        var recordCount = 0;
        var estimatedCount = 0;
        var pricedCount = 0;
        // Aggregate tokens per price segment first, then run Decimal arithmetic once.
        var pricedTokens = new Dictionary<int, UsageTokens>();
        var modelUnpriced = new HashSet<string>(StringComparer.Ordinal);
        var modelIndexes = new Dictionary<string, SortedSet<int>>(StringComparer.Ordinal);
        var days = new Dictionary<string, DayAccumulator>(StringComparer.Ordinal);
        var firstDate = (DateTime?)null;
        var lastDate = (DateTime?)null;

        foreach (var e in Deduplicate(events))
        {
            if (string.CompareOrdinal(e.OccurredAt, lower) < 0 || string.CompareOrdinal(e.OccurredAt, upper) >= 0)
            {
                continue;
            }

            recordCount++;
            tokens += e.Tokens;
            if (e.Quality != "exact")
            {
                estimatedCount++;
            }

            var priced = false;
            var priceIndex = -1;
            if (rates.TryGetValue(e.Model, out var candidates))
            {
                foreach (var rate in candidates)
                {
                    if (string.CompareOrdinal(e.OccurredAt, rate.From) >= 0
                        && string.CompareOrdinal(e.OccurredAt, rate.To) < 0)
                    {
                        // cacheWrite used without a rate keeps the record unpriced (null marker).
                        if (e.Tokens.CacheWrite == 0 || rate.Price.CacheWrite is not null)
                        {
                            priceIndex = rate.Index;
                        }

                        break;
                    }
                }
            }

            if (priceIndex >= 0)
            {
                pricedTokens[priceIndex] = pricedTokens.TryGetValue(priceIndex, out var sum)
                    ? sum + e.Tokens
                    : e.Tokens;
                pricedCount++;
                priced = true;
                if (!modelIndexes.TryGetValue(e.Model, out var indexes))
                {
                    modelIndexes[e.Model] = indexes = new SortedSet<int>();
                }

                indexes.Add(priceIndex);
            }

            if (!priced)
            {
                modelUnpriced.Add(e.Model);
            }

            if (!TimeText.TryParseIso(e.OccurredAt, out var moment))
            {
                continue;
            }

            var local = TimeZoneInfo.ConvertTime(moment, zone);
            var key = local.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            if (!days.TryGetValue(key, out var day))
            {
                days[key] = day = new DayAccumulator();
                var date = local.Date;
                firstDate = firstDate is null || date < firstDate ? date : firstDate;
                lastDate = lastDate is null || date > lastDate ? date : lastDate;
            }

            day.Tokens += e.Tokens;
            day.Requests++;
            if (priced)
            {
                day.PricedTokens[priceIndex] = day.PricedTokens.TryGetValue(priceIndex, out var daySum)
                    ? daySum + e.Tokens
                    : e.Tokens;
            }
            else
            {
                day.HasUnpriced = true;
            }
        }

        var costByModel = new Dictionary<string, decimal?>(StringComparer.Ordinal);
        foreach (var (model, indexes) in modelIndexes)
        {
            if (modelUnpriced.Contains(model))
            {
                costByModel[model] = null;
                continue;
            }

            var cost = 0m;
            foreach (var index in indexes)
            {
                cost += prices[index].Cost(pricedTokens[index]) ?? 0m;
            }

            costByModel[model] = cost;
        }

        foreach (var model in modelUnpriced)
        {
            costByModel.TryAdd(model, null);
        }

        var totalCost = recordCount > 0 ? (pricedCount == recordCount ? costByModel.Values.Sum(v => v ?? 0m) : (decimal?)null) : 0m;

        var rows = new List<DailyUsageRow>();
        if (firstDate is { } first && lastDate is { } last)
        {
            for (var date = first; date <= last; date = date.AddDays(1))
            {
                var key = date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                days.TryGetValue(key, out var day);
                var dayTokens = day?.Tokens ?? default;
                rows.Add(new DailyUsageRow
                {
                    Date = key,
                    InputTokens = dayTokens.Input,
                    CachedInputTokens = dayTokens.Cached,
                    CacheWriteTokens = dayTokens.CacheWrite,
                    OutputTokens = dayTokens.Output,
                    Requests = day?.Requests ?? 0,
                    CacheHitRate = dayTokens.Input > 0 ? (double)dayTokens.Cached / dayTokens.Input : null,
                    Cost = day is null ? 0m
                        : day.HasUnpriced ? null
                        : day.PricedTokens.Sum(p => prices[p.Key].Cost(p.Value) ?? 0m),
                });
            }
        }

        return new UsageSummary(
            recordCount,
            estimatedCount,
            pricedCount,
            tokens,
            tokens.Input > 0 ? (double)tokens.Cached / tokens.Input : null,
            totalCost,
            costByModel,
            rows);
    }

    private sealed class DayAccumulator
    {
        public UsageTokens Tokens;

        public int Requests;

        public bool HasUnpriced;

        public Dictionary<int, UsageTokens> PricedTokens { get; } = new();
    }
}
