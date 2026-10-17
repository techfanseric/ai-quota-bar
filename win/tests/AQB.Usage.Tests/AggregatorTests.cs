using Xunit;

namespace AQB.Usage.Tests;

public class AggregatorTests
{
    private static readonly TimeZoneInfo UtcPlus8 = TimeZoneInfo.CreateCustomTimeZone(
        "utc+8", TimeSpan.FromHours(8), "utc+8", "utc+8");

    [Fact]
    public void WeightedCacheHitRateIsCachedOverInput()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 50, 0, 10, 0)),
            EventFactory.Event("2026-10-02T00:00:00Z", "m", new UsageTokens(900, 100, 0, 10, 0)),
        };

        var summary = UsageAggregator.Summarize(events);

        // (50 + 100) / (100 + 900), token weighted, input already contains cached.
        Assert.Equal(0.15, summary.WeightedCacheHitRate);
        Assert.Equal(1000, summary.TotalInputTokens);
        Assert.Equal(150, summary.TotalCachedInputTokens);
        Assert.Equal(20, summary.TotalOutputTokens);
        Assert.Equal(1020, summary.TotalTokens);
    }

    [Fact]
    public void EmptySummaryHasNullCacheHitRate()
    {
        var summary = UsageAggregator.Summarize(Array.Empty<LocalUsageEvent>());

        Assert.Null(summary.WeightedCacheHitRate);
        Assert.Equal(0, summary.RecordCount);
        Assert.Equal(0m, summary.TotalEstimatedCost);
        Assert.Empty(summary.Rows);
        Assert.Empty(summary.EstimatedCostByModel);
    }

    [Fact]
    public void DeduplicateKeepsNewestPerLimitAndSignature()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0), signature: "sig"),
            EventFactory.Event("2026-10-02T00:00:00Z", "m", new UsageTokens(300, 0, 0, 30, 0), signature: "sig"),
        };

        var summary = UsageAggregator.Summarize(events);

        Assert.Single(Deduplicated(events));
        Assert.Equal(1, summary.RecordCount);
        Assert.Equal(300, summary.TotalInputTokens);
    }

    [Fact]
    public void DifferentLimitIdsAreBothCounted()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0), limitId: "a", signature: "sig"),
            EventFactory.Event("2026-10-02T00:00:00Z", "m", new UsageTokens(300, 0, 0, 30, 0), limitId: "b", signature: "sig"),
        };

        Assert.Equal(2, Deduplicated(events).Count);
    }

    [Fact]
    public void EstimatedRecordsAreCounted()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0), quality: "exact"),
            EventFactory.Event("2026-10-02T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0), quality: "cumulative-delta"),
        };

        var summary = UsageAggregator.Summarize(events);

        Assert.Equal(2, summary.RecordCount);
        Assert.Equal(1, summary.EstimatedRecordCount);
    }

    [Fact]
    public void CostFormulaUsesDecimalPrecision()
    {
        // macOS spec vector: cacheHitRate = 0.09, cost = 0.00212 exactly.
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "gpt-x", new UsageTokens(100, 90, 10, 10, 0)),
            EventFactory.Event("2026-10-02T00:00:00Z", "gpt-x", new UsageTokens(900, 0, 0, 10, 0)),
        };
        var prices = new[] { EventFactory.Price("gpt-x", input: 2, cached: 1, cacheWrite: 3, output: 10) };

        var summary = UsageAggregator.Summarize(events, prices);

        Assert.Equal(0.09, summary.WeightedCacheHitRate);
        Assert.Equal(2, summary.PricedRecordCount);
        Assert.Equal(0.00212m, summary.TotalEstimatedCost);
        Assert.Equal(0.00212m, summary.EstimatedCostByModel["gpt-x"]);
    }

    [Fact]
    public void MissingPriceKeepsCostNull()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "gpt-x", new UsageTokens(100, 90, 10, 10, 0)),
        };

        var summary = UsageAggregator.Summarize(events); // default empty price table

        Assert.Null(summary.TotalEstimatedCost);
        Assert.Null(summary.EstimatedCostByModel["gpt-x"]);
        Assert.Equal(0, summary.PricedRecordCount);
    }

    [Fact]
    public void CacheWriteWithoutRateKeepsRecordUnpriced()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "gpt-x", new UsageTokens(100, 90, 10, 10, 0)),
            EventFactory.Event("2026-10-02T00:00:00Z", "gpt-x", new UsageTokens(100, 0, 0, 10, 0)),
        };
        var prices = new[] { EventFactory.Price("gpt-x", input: 2, cached: 1, cacheWrite: null, output: 10) };

        var summary = UsageAggregator.Summarize(events, prices);

        Assert.Null(summary.TotalEstimatedCost);
        Assert.Null(summary.EstimatedCostByModel["gpt-x"]);
        Assert.Equal(1, summary.PricedRecordCount); // only the cacheWrite-free record
    }

    [Fact]
    public void ModelMatchIsExactWithNoFuzzyFallback()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "gpt-5.3-codex-high", new UsageTokens(100, 0, 0, 10, 0)),
        };
        var prices = new[] { EventFactory.Price("gpt-5.3-codex", 2, 1, 3, 10) };

        var summary = UsageAggregator.Summarize(events, prices);

        Assert.Null(summary.TotalEstimatedCost);
        Assert.Null(summary.EstimatedCostByModel["gpt-5.3-codex-high"]);
        Assert.Equal(0, summary.PricedRecordCount);
    }

    [Fact]
    public void EffectiveIntervalIsHalfOpen()
    {
        var prices = new[]
        {
            EventFactory.Price("m", 2, 1, 3, 10, effectiveFrom: "2026-10-01T00:00:00Z", effectiveTo: "2026-10-02T00:00:00Z"),
        };
        var before = new[] { EventFactory.Event("2026-09-30T23:59:59.999Z", "m", new UsageTokens(100, 0, 0, 10, 0)) };
        var atStart = new[] { EventFactory.Event("2026-10-01T00:00:00.000Z", "m", new UsageTokens(100, 0, 0, 10, 0)) };
        var atEnd = new[] { EventFactory.Event("2026-10-02T00:00:00.000Z", "m", new UsageTokens(100, 0, 0, 10, 0)) };

        Assert.Null(UsageAggregator.Summarize(before, prices).TotalEstimatedCost);
        Assert.NotNull(UsageAggregator.Summarize(atStart, prices).TotalEstimatedCost);
        Assert.Null(UsageAggregator.Summarize(atEnd, prices).TotalEstimatedCost);
    }

    [Fact]
    public void WindowIsHalfOpenByStringComparison()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0)),
            EventFactory.Event("2026-10-01T12:00:00Z", "m", new UsageTokens(200, 0, 0, 10, 0)),
            EventFactory.Event("2026-10-02T00:00:00Z", "m", new UsageTokens(400, 0, 0, 10, 0)),
        };

        var summary = UsageAggregator.Summarize(events,
            from: DateTimeOffset.Parse("2026-10-01T00:00:00Z"),
            to: DateTimeOffset.Parse("2026-10-02T00:00:00Z"));

        Assert.Equal(2, summary.RecordCount);
        Assert.Equal(300, summary.TotalInputTokens);
    }

    [Fact]
    public void DailyRowsUseLocalCalendarDays()
    {
        // 15:59:59Z and 16:00:00Z fall on different local days in UTC+8.
        var events = new[]
        {
            EventFactory.Event("2026-10-15T15:59:59Z", "m", new UsageTokens(100, 10, 0, 10, 0)),
            EventFactory.Event("2026-10-15T16:00:00Z", "m", new UsageTokens(900, 90, 0, 10, 0)),
        };

        var summary = UsageAggregator.Summarize(events,
            from: DateTimeOffset.Parse("2026-10-14T16:00:00Z"),
            to: DateTimeOffset.Parse("2026-10-17T00:00:00Z"),
            timeZone: UtcPlus8);

        Assert.Equal(2, summary.Rows.Count);
        Assert.Equal("2026-10-15", summary.Rows[0].Date);
        Assert.Equal("2026-10-16", summary.Rows[1].Date);
        Assert.Equal(100, summary.Rows[0].InputTokens);
        Assert.Equal(900, summary.Rows[1].InputTokens);
        Assert.Equal(1, summary.Rows[0].Requests);
        Assert.Equal(0.1, summary.Rows[0].CacheHitRate);
    }

    [Fact]
    public void EmptyDaysProduceZeroRows()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0)),
            EventFactory.Event("2026-10-03T00:00:00Z", "m", new UsageTokens(200, 0, 0, 10, 0)),
        };
        var prices = new[] { EventFactory.Price("m", 2, 1, 3, 10) };

        var summary = UsageAggregator.Summarize(events, prices, timeZone: UtcPlus8);

        Assert.Equal(3, summary.Rows.Count);
        Assert.Equal(new[] { "2026-10-01", "2026-10-02", "2026-10-03" }, summary.Rows.Select(r => r.Date));
        Assert.Equal(0, summary.Rows[1].Requests);
        Assert.Equal(0, summary.Rows[1].InputTokens);
        Assert.Null(summary.Rows[1].CacheHitRate);
        Assert.Equal(0m, summary.Rows[1].Cost);      // empty bucket: zero, not null
        Assert.Equal(0.0003m, summary.Rows[0].Cost); // (100*2 + 10*10) / 1e6
        Assert.Equal(0.0005m, summary.Rows[2].Cost); // (200*2 + 10*10) / 1e6
    }

    [Fact]
    public void UnpricedDayHasNullCost()
    {
        var events = new[]
        {
            EventFactory.Event("2026-10-01T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0)),
            EventFactory.Event("2026-10-02T00:00:00Z", "m", new UsageTokens(100, 0, 0, 10, 0)),
        };
        var prices = new[] { EventFactory.Price("m", 2, 1, 3, 10, effectiveFrom: "2026-10-02T00:00:00Z") };

        var summary = UsageAggregator.Summarize(events, prices, timeZone: UtcPlus8);

        Assert.Null(summary.Rows[0].Cost);       // 10-01 has no effective price
        Assert.Equal(0.0003m, summary.Rows[1].Cost);
    }

    private static IReadOnlyList<LocalUsageEvent> Deduplicated(LocalUsageEvent[] events)
        => UsageAggregator.Deduplicate(events);
}
