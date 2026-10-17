using AQB.Core;
using Xunit;

namespace AQB.Core.Tests;

public class QuotaHistoryStoreTests : IDisposable
{
    private readonly string _path = Path.Combine(Path.GetTempPath(), "aqb-history-" + Guid.NewGuid().ToString("N") + ".json");

    [Fact]
    public void RecordAndReadBack()
    {
        var now = new DateTimeOffset(2026, 10, 18, 8, 0, 0, TimeSpan.Zero);
        using var store = new QuotaHistoryStore(_path);
        store.Record(Sample(remaining: 80), now);
        store.Record(Sample(remaining: 60), now.AddMinutes(5));
        store.Record(Sample(remaining: 40), now.AddMinutes(10));

        var series = store.GetSeries(ProviderKind.Glm, "5h");
        Assert.Equal(3, series.Count);
        Assert.Equal(80, series[0].RemainingPercent);
        Assert.Equal(40, series[^1].RemainingPercent);
    }

    [Fact]
    public void OneSamplePerMinuteDedupes()
    {
        var now = new DateTimeOffset(2026, 10, 18, 8, 0, 0, TimeSpan.Zero);
        using var store = new QuotaHistoryStore(_path);
        store.Record(Sample(remaining: 50), now);
        store.Record(Sample(remaining: 49), now.AddSeconds(30));
        Assert.Single(store.GetSeries(ProviderKind.Glm, "5h"));
    }

    [Fact]
    public void PersistsAcrossInstances()
    {
        var now = new DateTimeOffset(2026, 10, 18, 8, 0, 0, TimeSpan.Zero);
        var first = new QuotaHistoryStore(_path);
        first.Record(Sample(remaining: 70), now);
        first.Save();

        using var second = new QuotaHistoryStore(_path);
        var series = second.GetSeries(ProviderKind.Glm, "5h");
        Assert.Single(series);
        Assert.Equal(70, series[0].RemainingPercent);
    }

    [Fact]
    public void PrunesBeyondSevenDays()
    {
        var now = new DateTimeOffset(2026, 10, 18, 8, 0, 0, TimeSpan.Zero);
        using var store = new QuotaHistoryStore(_path);
        store.Record(Sample(remaining: 90), now.AddDays(-8));
        store.Record(Sample(remaining: 80), now);

        var series = store.GetSeries(ProviderKind.Glm, "5h", now);
        Assert.Single(series);
        Assert.Equal(80, series[0].RemainingPercent);
    }

    [Fact]
    public void CapsAtMaxPoints()
    {
        var now = new DateTimeOffset(2026, 10, 18, 8, 0, 0, TimeSpan.Zero);
        using var store = new QuotaHistoryStore(null);
        for (var i = 0; i <= QuotaHistoryStore.MaxPointsPerWindow + 50; i++)
        {
            store.Record(Sample(remaining: 100 - (i % 100)), now.AddMinutes(i));
        }

        var series = store.GetSeries(ProviderKind.Glm, "5h", now.AddMinutes(QuotaHistoryStore.MaxPointsPerWindow + 50));
        Assert.Equal(QuotaHistoryStore.MaxPointsPerWindow, series.Count);
    }

    [Fact]
    public void SeparateWindowsAndAccounts()
    {
        var now = new DateTimeOffset(2026, 10, 18, 8, 0, 0, TimeSpan.Zero);
        using var store = new QuotaHistoryStore(null);
        var glm = new ProviderSnapshot
        {
            Kind = ProviderKind.Glm,
            Status = ProviderStatus.Ok,
            Accounts = new List<ProviderAccountSnapshot>
            {
                new()
                {
                    AccountKey = "acc1",
                    Label = "a@b.c",
                    Windows = new List<QuotaWindowSample>
                    {
                        new() { Name = "5h", UsedPercent = 20, ResetsAtUtc = now.AddHours(2), CapturedAtUtc = now, WindowSeconds = 18000 },
                        new() { Name = "Weekly", UsedPercent = 40, ResetsAtUtc = now.AddDays(2), CapturedAtUtc = now, WindowSeconds = 604800 },
                    },
                },
            },
        };
        store.Record(new Dictionary<ProviderKind, ProviderSnapshot> { [ProviderKind.Glm] = glm }, now);
        Assert.Single(store.GetSeries(ProviderKind.Glm, "5h"));
        Assert.Single(store.GetSeries(ProviderKind.Glm, "Weekly"));
        Assert.Empty(store.GetSeries(ProviderKind.Codex, "5h"));
    }

    private static IReadOnlyDictionary<ProviderKind, ProviderSnapshot> Sample(double remaining) => new Dictionary<ProviderKind, ProviderSnapshot>
    {
        [ProviderKind.Glm] = new()
        {
            Kind = ProviderKind.Glm,
            Status = ProviderStatus.Ok,
            Accounts = new List<ProviderAccountSnapshot>
            {
                new()
                {
                    AccountKey = "acc1",
                    Label = "a@b.c",
                    Windows = new List<QuotaWindowSample>
                    {
                        new() { Name = "5h", UsedPercent = 100 - remaining, ResetsAtUtc = DateTimeOffset.UtcNow.AddHours(1), CapturedAtUtc = DateTimeOffset.UtcNow, WindowSeconds = 18000 },
                    },
                },
            },
        },
    };

    public void Dispose()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }
}
