using AQB.Core;
using Xunit;

namespace AQB.Usage.Tests;

public class LocalUsageServiceTests
{
    private static LocalUsageService Service(TempDir dir, IEnumerable<UsagePrice>? prices = null)
        => new(
            codexHome: Path.Combine(dir.Root, "codex"),
            dataDir: Path.Combine(dir.Root, "appdata"),
            prices: prices);

    private static string Line(string s) => s + "\n";

    private static string Ts(DateTimeOffset moment) => TimeText.FixedIso(moment);

    [Fact]
    public void ScanAggregatesAndCachesToLocalUsageJson()
    {
        using var dir = new TempDir();
        dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(Ts(DateTimeOffset.UtcNow.AddDays(-1)), "s"))
            + Line(Rollout.TokenCount(Ts(DateTimeOffset.UtcNow.AddDays(-1).AddMinutes(1)), "gpt-x",
                last: new UsageTokens(100, 50, 0, 10, 0))));

        var service = Service(dir);
        var result = service.Scan();

        Assert.Equal(1, result.FilesParsed);
        Assert.Equal(1, result.Summary.RecordCount);
        Assert.Equal(100, result.Summary.TotalInputTokens);
        Assert.Equal(0.5, result.Summary.WeightedCacheHitRate);
        Assert.True(File.Exists(service.CachePath));

        // The summary is served from the cache even after the source tree disappears.
        Directory.Delete(Path.Combine(dir.Root, "codex"), true);
        var cached = service.GetSummary();
        Assert.Equal(1, cached.RecordCount);
        Assert.Equal(100, cached.TotalInputTokens);
    }

    [Fact]
    public void PricesAreInjectableAndDefaultToEmpty()
    {
        using var dir = new TempDir();
        var moment = DateTimeOffset.UtcNow.AddDays(-1);
        dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(Ts(moment), "s"))
            + Line(Rollout.TokenCount(Ts(moment.AddMinutes(1)), "gpt-x", last: new UsageTokens(100, 0, 0, 10, 0))));

        var service = Service(dir);
        service.Scan();
        Assert.Null(service.GetSummary().TotalEstimatedCost);

        service.SetPrices(new[] { EventFactory.Price("gpt-x", 2, 1, 3, 10) });
        Assert.Equal(0.0003m, service.GetSummary().TotalEstimatedCost);

        service.LoadPricesFromJson("""
            [{"model":"gpt-x","version":"v","source":"s","effectiveFrom":"2020-01-01T00:00:00Z",
              "input":1,"cached":0.5,"cacheWrite":null,"output":5}]
            """);
        Assert.Equal(0.00015m, service.GetSummary().TotalEstimatedCost);
    }

    [Fact]
    public void InvalidPriceTableIsRejected()
    {
        using var dir = new TempDir();
        var service = Service(dir);

        Assert.Throws<ArgumentException>(() => service.LoadPricesFromJson("""
            [{"model":"m","version":"v","source":"s","effectiveFrom":"2020-01-01T00:00:00Z",
              "input":1,"cached":0.5,"output":5},
             {"model":"m","version":"v2","source":"s","effectiveFrom":"2021-01-01T00:00:00Z",
              "input":2,"cached":0.5,"output":5}]
            """));
    }

    [Fact]
    public void GetSummaryRespectsLookbackWindow()
    {
        using var dir = new TempDir();
        var recent = DateTimeOffset.UtcNow.AddDays(-1);
        var old = DateTimeOffset.UtcNow.AddDays(-36);
        dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(Ts(old), "s"))
            + Line(Rollout.TokenCount(Ts(old.AddMinutes(1)), "gpt-x", last: new UsageTokens(100, 0, 0, 10, 0), limitId: "a"))
            + Line(Rollout.TokenCount(Ts(recent), "gpt-x", last: new UsageTokens(300, 0, 0, 30, 0), limitId: "b")));

        var service = Service(dir);
        service.Scan();

        Assert.Equal(1, service.GetSummary(35).RecordCount);
        Assert.Equal(300, service.GetSummary(35).TotalInputTokens);
        Assert.Equal(2, service.GetSummary(40).RecordCount);
    }

    [Fact]
    public void PruneKeepsThirtyNineAndBoundaryDropsFortyOne()
    {
        using var dir = new TempDir();
        var now = DateTimeOffset.Parse("2026-10-17T12:00:00Z");
        dir.WriteFile(@"codex\sessions\a.jsonl",
            Line(Rollout.Meta(Ts(now.AddDays(-41)), "s"))
            + Line(Rollout.TokenCount(Ts(now.AddDays(-41).AddMinutes(1)), "m", last: new UsageTokens(11, 0, 0, 1, 0), limitId: "a"))
            + Line(Rollout.TokenCount(Ts(now.AddDays(-40)), "m", last: new UsageTokens(40, 0, 0, 4, 0), limitId: "b"))
            + Line(Rollout.TokenCount(Ts(now.AddDays(-39).AddMinutes(1)), "m", last: new UsageTokens(39, 0, 0, 3, 0), limitId: "c")));

        var service = Service(dir);
        var result = service.Scan(now);

        // 41 days old: pruned; exactly 40 days old (boundary, not strictly older) and 39: kept.
        Assert.Equal(2, service.LoadEvents().Count);
        Assert.Equal(new long[] { 39, 40 }, service.LoadEvents().Select(e => e.Tokens.Input).OrderBy(x => x).ToArray());
        Assert.Equal(1, result.PrunedEvents);

        // Nothing else is prunable at the same instant.
        Assert.Equal(0, service.PruneOldEvents(CodexSessionScanner.RecordRetentionDays, now));
    }

    [Fact]
    public void BoundPendingRecordsAreNeverPruned()
    {
        using var dir = new TempDir();
        var now = DateTimeOffset.Parse("2026-10-17T12:00:00Z");
        var old = TimeText.FixedIso(now.AddDays(-90));
        var service = Service(dir);
        service.Scan(now); // creates the cache file

        // Simulate cached records with team-reporting delivery state (90 days old).
        var events = new List<LocalUsageEvent>
        {
            EventFactory.Event(old, "m", new UsageTokens(90, 0, 0, 9, 0)) with
            {
                Binding = "team-1",
                Delivery = "pending",
            },
            EventFactory.Event(old, "m", new UsageTokens(91, 0, 0, 9, 0)) with
            {
                Delivery = "sent",
            },
            EventFactory.Event(old, "m", new UsageTokens(92, 0, 0, 9, 0)),
        };
        File.WriteAllText(service.CachePath, System.Text.Json.JsonSerializer.Serialize(
            new CacheShape { Events = events }, new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web)));

        var pruned = service.PruneOldEvents(CodexSessionScanner.RecordRetentionDays, now);

        // bound+pending survives; sent and unbound are expendable.
        Assert.Equal(2, pruned);
        var remaining = service.LoadEvents();
        var kept = Assert.Single(remaining);
        Assert.Equal(90, kept.Tokens.Input);
        Assert.Equal("team-1", kept.Binding);
    }

    private sealed class CacheShape
    {
        public List<LocalUsageEvent> Events { get; set; } = new();
    }

    [Fact]
    public void ScanIsIncrementalAcrossRuns()
    {
        using var dir = new TempDir();
        var path = @"codex\sessions\a.jsonl";
        var moment = DateTimeOffset.UtcNow.AddDays(-1);
        dir.WriteFile(path,
            Line(Rollout.Meta(Ts(moment), "s"))
            + Line(Rollout.TokenCount(Ts(moment.AddMinutes(1)), "m", last: new UsageTokens(100, 0, 0, 10, 0))));

        var service = Service(dir);
        var first = service.Scan();
        Assert.Equal(1, first.FilesParsed);

        var second = service.Scan();
        Assert.Equal(0, second.FilesParsed);
        Assert.Equal(1, second.FilesSkipped);

        dir.AppendFile(path, Line(Rollout.TokenCount(Ts(moment.AddMinutes(2)), "m", last: new UsageTokens(200, 0, 0, 20, 0))));
        var third = service.Scan();
        Assert.Equal(1, third.FilesParsed);
        Assert.Equal(2, third.Summary.RecordCount);
    }

    [Fact]
    public void DeferredSessionsAreReportedButNotCounted()
    {
        using var dir = new TempDir();
        var moment = DateTimeOffset.UtcNow.AddDays(-1);
        dir.WriteFile(@"codex\sessions\child.jsonl",
            Line(Rollout.Meta(Ts(moment), "child", forkedFrom: "missing"))
            + Line(Rollout.TokenCount(Ts(moment.AddMinutes(1)), "m", last: new UsageTokens(100, 0, 0, 10, 0))));

        var service = Service(dir);
        var result = service.Scan();

        Assert.Equal(1, result.DeferredSessions);
        Assert.Equal(0, result.Summary.RecordCount);
        Assert.Contains("child", result.DeferredSessionIds);
    }
}
