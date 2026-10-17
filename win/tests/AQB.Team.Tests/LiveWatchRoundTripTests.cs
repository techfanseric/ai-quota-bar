using AQB.Team;
using Xunit;

namespace AQB.Team.Tests;

/// <summary>
/// Live round-trip against the production worker (publish → fetch → read counts → cancel).
/// Skipped by default; opt in with AQB_LIVE_WATCH=1. Uses a reserved example.com address
/// and a throwaway publisher id, and finishes by un-sharing (empty publish deletes the rows).
/// </summary>
public sealed class LiveWatchRoundTripTests
{
    private static bool Enabled => Environment.GetEnvironmentVariable("AQB_LIVE_WATCH") == "1";

    [Fact]
    public async Task Publish_Fetch_Reads_Cancel_RoundTrip()
    {
        if (!Enabled)
        {
            return; // opt-in live test; runs as a trivial pass by default
        }

        var publisher = "win-live-test-" + Guid.NewGuid().ToString("N")[..8];
        var email = "win-migration-check@example.com";
        var now = DateTimeOffset.UtcNow;
        using var client = new CodexWatchClient(publisher);

        // 1. Publish a two-window snapshot.
        var published = await client.PublishAsync(new[]
        {
            new CodexWatchAccountSnapshot(email, "pro", new[]
            {
                new CodexWatchWindow("5h", 74, now.AddHours(2), now, now.AddHours(-3)),
                new CodexWatchWindow("Weekly", 41, now.AddDays(3), now, now.AddDays(-4)),
            }),
        });
        Assert.True(published, "publish must succeed against the real worker");

        // 2. Fetch it back.
        var fetched = await client.FetchAsync(email);
        Assert.Equal(WatchFetchStatus.Available, fetched.Status);
        var snapshot = fetched.Snapshot!;
        Assert.Equal(email, snapshot.Account);
        Assert.Equal("pro", snapshot.Plan);
        Assert.Equal(2, snapshot.Windows.Count);
        Assert.Equal(74, snapshot.Windows.First(w => w.Name == "5h").RemainingPercent);
        Assert.Equal(41, snapshot.Windows.First(w => w.Name == "Weekly").RemainingPercent);
        Assert.NotNull(snapshot.PublishedAt);

        // 3. Our fetch must have incremented the shared account's read counter.
        var counts = await client.FetchReadCountsAsync(new[] { email });
        Assert.True(counts.TryGetValue(email, out var read));
        Assert.True(read!.ReadCount >= 1, $"read_count should be >= 1, got {read.ReadCount}");

        // 4. Cancel sharing (empty publish = full revoke).
        Assert.True(await client.PublishAsync(Array.Empty<CodexWatchAccountSnapshot>()));
        var afterCancel = await client.FetchAsync(email);
        Assert.Equal(WatchFetchStatus.NotShared, afterCancel.Status);
    }
}
