using System.Net;
using AQB.Team;
using Xunit;

namespace AQB.Team.Tests;

public sealed class WatchAccountTests
{
    [Theory]
    [InlineData("ERIC@Example.com ", true)]          // normalized on validation
    [InlineData("eric@example.com", true)]
    [InlineData("e@x.io", true)]
    [InlineData("eric+tag@example.co.uk", true)]
    [InlineData("eric@localhost", false)]            // domain needs a dot
    [InlineData("eric@@example.com", false)]         // two ats
    [InlineData("@example.com", false)]              // empty local
    [InlineData(".eric@example.com", false)]         // leading dot
    [InlineData("eric..doe@example.com", false)]     // consecutive dots
    [InlineData("eric@example.com/", false)]         // pasted URL
    [InlineData("https://x.example.com/watch?email=a@b.co", false)]
    [InlineData("eric doe@example.com", false)]      // space not in atext
    [InlineData("", false)]
    [InlineData("eric@", false)]
    public void ValidationMatchesMacRules(string input, bool expected)
    {
        Assert.Equal(expected, WatchAccount.IsValidAccountName(input));
    }

    [Fact]
    public void NormalizeTrimsAndLowercases()
    {
        Assert.Equal("eric@example.com", WatchAccount.Normalize("  ERIC@Example.COM\n"));
    }

    [Fact]
    public void AccountKeyIsSha256OfNormalizedEmail()
    {
        Assert.Equal(
            AQB.Core.AccountFingerprint.WatchEmail("ERIC@Example.com "),
            WatchAccount.AccountKey("eric@example.com"));
        Assert.Null(WatchAccount.AccountKey("not-an-email"));
    }
}

public sealed class CodexWatchClientTests : IDisposable
{
    private readonly FakeHandler _handler = new();
    private readonly CodexWatchClient _client = new("publisher-1", "https://sync.example.com", null);

    public CodexWatchClientTests()
    {
        _client.Dispose();
    }

    [Fact]
    public async Task Publish_SendsFullReplaceBodyWithFixedMsDates()
    {
        var handler = new FakeHandler();
        using var client = new CodexWatchClient("publisher-1", "https://sync.example.com", handler);
        var resets = new DateTimeOffset(2026, 10, 18, 0, 0, 0, TimeSpan.Zero);
        var ok = await client.PublishAsync(new[]
        {
            new CodexWatchAccountSnapshot("eric@example.com", "pro", new[]
            {
                new CodexWatchWindow("5h", 74, resets, resets.AddMinutes(-5), resets.AddHours(-1)),
                new CodexWatchWindow("Weekly", 41, resets.AddDays(2), null, null),
            }),
        });
        Assert.True(ok);
        var request = handler.Requests.Single();
        Assert.Equal("POST", request.Method);
        Assert.Equal("https://sync.example.com/v1/watch/publish", request.Url);
        Assert.Equal("Bearer " + CodexWatchClient.ServiceToken, request.Authorization);
        Assert.Contains("\"publisher\":\"publisher-1\"", request.Body);
        Assert.Contains("\"account\":\"eric@example.com\"", request.Body);
        Assert.Contains("\"remainingPercent\":74", request.Body);
        Assert.Contains("\"resetsAt\":\"2026-10-18T00:00:00.000Z\"", request.Body);
        Assert.Contains("\"startsAt\":\"2026-10-17T23:00:00.000Z\"", request.Body);
        // Null dates stay nulls (full-replace semantics include absent values).
        Assert.Contains("\"sampledAt\":null", request.Body);
    }

    [Fact]
    public async Task Publish_FailureReturnsFalseWithoutThrowing()
    {
        var handler = new FakeHandler { Status = HttpStatusCode.InternalServerError };
        using var client = new CodexWatchClient("publisher-1", "https://sync.example.com", handler);
        Assert.False(await client.PublishAsync(Array.Empty<CodexWatchAccountSnapshot>()));
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task Fetch_200DecodesSnapshotAndWeeklyStartDerivation()
    {
        var handler = new FakeHandler
        {
            Body = """
            {"ok":true,"account":"eric@example.com","plan":"pro","updated_at":"2026-10-17T10:00:00.000Z",
             "windows":[
               {"name":"5h","remainingPercent":74,"resetsAt":"2026-10-17T15:00:00.000Z","sampledAt":"2026-10-17T10:00:00.000Z","startsAt":"2026-10-17T10:00:00.000Z"},
               {"name":"Weekly","remainingPercent":41,"resetsAt":"2026-10-21T15:00:00.000Z","sampledAt":"2026-10-17T10:00:00.000Z"}
             ]}
            """,
        };
        using var client = new CodexWatchClient("publisher-1", "https://sync.example.com", handler);
        var result = await client.FetchAsync("ERIC@Example.com");
        Assert.Equal(WatchFetchStatus.Available, result.Status);
        var snapshot = result.Snapshot!;
        Assert.Equal("eric@example.com", snapshot.Account);
        Assert.Equal("pro", snapshot.Plan);
        Assert.Equal(2, snapshot.Windows.Count);
        // Weekly without startsAt: derived as resetsAt - 7d (in the past, so kept).
        Assert.Equal(snapshot.Windows[1].ResetsAt!.Value.AddDays(-7), snapshot.Windows[1].StartsAt);
    }

    [Fact]
    public async Task Fetch_FutureSampledAtFallsBackToPublishedAt()
    {
        var future = DateTimeOffset.UtcNow.AddHours(2);
        var handler = new FakeHandler
        {
            Body = $$"""
            {"account":"eric@example.com","updated_at":"2026-10-17T10:00:00.000Z",
             "windows":[{"name":"5h","remainingPercent":10,"sampledAt":"{{future.ToString("yyyy-MM-dd'T'HH:mm:ss.fffZ")}}"}]}
            """,
        };
        using var client = new CodexWatchClient("publisher-1", "https://sync.example.com", handler);
        var result = await client.FetchAsync("eric@example.com");
        Assert.Equal(WatchFetchStatus.Available, result.Status);
        Assert.Equal(
            new DateTimeOffset(2026, 10, 17, 10, 0, 0, TimeSpan.Zero),
            result.Snapshot!.Windows[0].SampledAt);
    }

    [Fact]
    public async Task Fetch_StatusMapping_404_410_Other()
    {
        using var notShared = new CodexWatchClient("p", "https://sync.example.com", new FakeHandler { Status = HttpStatusCode.NotFound });
        Assert.Equal(WatchFetchStatus.NotShared, (await notShared.FetchAsync("a@b.co")).Status);

        using var stale = new CodexWatchClient("p", "https://sync.example.com", new FakeHandler { Status = HttpStatusCode.Gone });
        var staleResult = await stale.FetchAsync("a@b.co");
        Assert.Equal(WatchFetchStatus.Stale, staleResult.Status);
        Assert.Empty(staleResult.Snapshot!.Windows);

        using var unreachable = new CodexWatchClient("p", "https://sync.example.com", new FakeHandler { Status = HttpStatusCode.BadGateway });
        Assert.Equal(WatchFetchStatus.Unreachable, (await unreachable.FetchAsync("a@b.co")).Status);

        using var invalid = new CodexWatchClient("p", "https://sync.example.com", new FakeHandler());
        Assert.Equal(WatchFetchStatus.NotShared, (await invalid.FetchAsync("https://x.com/?q=1")).Status);
    }

    [Fact]
    public async Task FetchReadCounts_MapsKeysBackToEmails()
    {
        var key = WatchAccount.AccountKey("eric@example.com")!;
        var otherKey = WatchAccount.AccountKey("someone@else.net")!;
        var handler = new FakeHandler
        {
            Body = $$"""{"accounts":[{"account_key":"{{key}}","read_count":3,"last_read_at":"2026-10-17T09:00:00.000Z","stale":false},{"account_key":"{{otherKey}}","read_count":1,"stale":true}]}""",
        };
        using var client = new CodexWatchClient("publisher-1", "https://sync.example.com", handler);
        var counts = await client.FetchReadCountsAsync(new[] { "ERIC@example.com", "not-an-email" });
        var request = handler.Requests.Single();
        Assert.Equal("https://sync.example.com/v1/watch/reads?publisher=publisher-1", request.Url);
        Assert.Single(counts);
        Assert.Equal(3, counts["eric@example.com"].ReadCount);
        Assert.False(counts["eric@example.com"].Stale);
    }

    [Fact]
    public async Task FetchReadCounts_EmptyInputSkipsNetwork()
    {
        var handler = new FakeHandler();
        using var client = new CodexWatchClient("p", "https://sync.example.com", handler);
        Assert.Empty(await client.FetchReadCountsAsync(Array.Empty<string>()));
        Assert.Empty(handler.Requests);
    }

    public void Dispose() => _handler.Dispose();

    private sealed class FakeHandler : HttpMessageHandler
    {
        public string Body { get; set; } = "{\"ok\":true}";

        public HttpStatusCode Status { get; set; } = HttpStatusCode.OK;

        public List<(string Method, string Url, string? Authorization, string Body)> Requests { get; } = new();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((
                request.Method.Method,
                request.RequestUri!.ToString(),
                request.Headers.Authorization?.ToString(),
                request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken)));
            return new HttpResponseMessage(Status) { Content = new StringContent(Body) };
        }
    }
}

public sealed class AppUpdateClientTests : IDisposable
{
    private readonly FakeHandler _handler = new();

    [Fact]
    public async Task Check_ParsesReleaseFields()
    {
        _handler.Body = """{"ok":true,"source":"github-proxy","version":"1.27.0","tag":"v1.27.0","release_url":"https://github.com/r/v1.27.0","download_url":"https://github.com/r/download/pkg","published_at":"2026-10-01T00:00:00.000Z"}""";
        using var client = new AppUpdateClient("https://sync.example.com", _handler);
        var info = await client.CheckAsync();
        Assert.NotNull(info);
        Assert.Equal("1.27.0", info!.Version);
        Assert.Equal("v1.27.0", info.Tag);
        Assert.Equal("https://github.com/r/v1.27.0", info.ReleaseUrl);
        Assert.Equal(new DateTimeOffset(2026, 10, 1, 0, 0, 0, TimeSpan.Zero), info.PublishedAt);
    }

    [Fact]
    public async Task Check_FailureOrNotOk_ReturnsNull()
    {
        _handler.Body = "{\"error\":\"boom\"}";
        using var client = new AppUpdateClient("https://sync.example.com", _handler);
        Assert.Null(await client.CheckAsync());
    }

    [Theory]
    [InlineData("v1.27.0", "1.26.9", true)]
    [InlineData("1.27.0", "1.27.0", false)]
    [InlineData("1.27", "1.26.9", true)]
    [InlineData("1.27.1", "1.27", true)]
    [InlineData("v1.10.0", "1.9.0", true)]
    [InlineData("garbage", "1.0.0", false)]
    [InlineData("1.27.0", "garbage", false)]
    public void VersionCompareSemantics(string candidate, string current, bool expected)
    {
        Assert.Equal(expected, AppUpdateClient.IsNewer(candidate, current));
    }

    public void Dispose() => _handler.Dispose();

    private sealed class FakeHandler : HttpMessageHandler
    {
        public string Body { get; set; } = "{\"ok\":true}";

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            => Task.FromResult<HttpResponseMessage>(new(HttpStatusCode.OK) { Content = new StringContent(Body) });
    }
}
