using Xunit;

namespace AQB.Providers.Codex.Tests;

/// <summary>
/// macOS-parity proactive refresh: exp within 5 minutes (or past) → refresh before the
/// usage request; no exp claim → last_refresh older than 8 days; API key mode never.
/// </summary>
public class ProactiveRefreshTests
{
    private static string JwtWithExpiry(DateTimeOffset expiry) =>
        TestJwts.Make("{\"exp\":" + expiry.ToUnixTimeSeconds() + "}");

    private static string IsoUtc(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'");

    private static CodexAuthInfo MakeAuth(string rawJson, bool hasApiKey = false) => new()
    {
        AccountId = "org-1",
        Email = "eric@example.com",
        HasApiKey = hasApiKey,
        RawJson = rawJson,
    };

    [Fact]
    public async Task AccessTokenInsideExpiryMarginRefreshesBeforeUsageRequest()
    {
        using var home = new TempCodexHome();
        var raw = AuthFiles.AuthJson(accessToken: JwtWithExpiry(DateTimeOffset.UtcNow.AddMinutes(-1)));
        home.WriteAuth(raw);
        var handler = new StubHttpHandler();
        handler.EnqueueJson("{\"access_token\":\"at-new\"}");
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        var result = await client.FetchAsync(MakeAuth(raw));

        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("POST", handler.Requests[0].Method);
        Assert.Equal("https://auth.openai.com/oauth/token", handler.Requests[0].Uri.ToString());
        Assert.Equal("GET", handler.Requests[1].Method);
        Assert.Equal("Bearer at-new", handler.Requests[1].Header("Authorization"));
        Assert.Equal(2, result.Windows.Count);
        Assert.Contains("at-new", home.ReadAuth());
    }

    [Fact]
    public async Task FreshAccessTokenSkipsProactiveRefresh()
    {
        using var home = new TempCodexHome();
        var raw = AuthFiles.AuthJson(accessToken: JwtWithExpiry(DateTimeOffset.UtcNow.AddHours(1)));
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        await client.FetchAsync(MakeAuth(raw));

        var request = Assert.Single(handler.Requests);
        Assert.Equal("GET", request.Method);
    }

    [Fact]
    public async Task NoExpClaimWithStaleLastRefreshRefreshes()
    {
        using var home = new TempCodexHome();
        var raw = AuthFiles.AuthJson(
            accessToken: "at-1",
            lastRefresh: IsoUtc(DateTimeOffset.UtcNow.AddDays(-9)));
        home.WriteAuth(raw);
        var handler = new StubHttpHandler();
        handler.EnqueueJson("{\"access_token\":\"at-new\"}");
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        await client.FetchAsync(MakeAuth(raw));

        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("POST", handler.Requests[0].Method);
        Assert.Equal("https://auth.openai.com/oauth/token", handler.Requests[0].Uri.ToString());
        Assert.Equal("Bearer at-new", handler.Requests[1].Header("Authorization"));
    }

    [Fact]
    public async Task NoExpClaimWithFreshLastRefreshSkipsRefresh()
    {
        using var home = new TempCodexHome();
        var raw = AuthFiles.AuthJson(
            accessToken: "at-1",
            lastRefresh: IsoUtc(DateTimeOffset.UtcNow.AddHours(-1)));
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        await client.FetchAsync(MakeAuth(raw));

        var request = Assert.Single(handler.Requests);
        Assert.Equal("GET", request.Method);
    }

    [Fact]
    public async Task ProactiveRefreshFailureFallsThroughToTheStaleToken()
    {
        using var home = new TempCodexHome();
        var expiring = JwtWithExpiry(DateTimeOffset.UtcNow.AddMinutes(-1));
        var raw = AuthFiles.AuthJson(accessToken: expiring);
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(System.Net.HttpStatusCode.InternalServerError);
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        var result = await client.FetchAsync(MakeAuth(raw));

        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("https://auth.openai.com/oauth/token", handler.Requests[0].Uri.ToString());
        Assert.Equal("GET", handler.Requests[1].Method);
        // The stale (expiring) access token still authenticates the request.
        Assert.Equal("Bearer " + expiring, handler.Requests[1].Header("Authorization"));
        Assert.Equal(2, result.Windows.Count);
    }

    [Fact]
    public async Task ApiKeyModeNeverRefreshesProactively()
    {
        using var home = new TempCodexHome();
        var raw = AuthFiles.AuthJson(
            apiKey: "sk-x",
            accessToken: JwtWithExpiry(DateTimeOffset.UtcNow.AddMinutes(-1)));
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        await client.FetchAsync(MakeAuth(raw, hasApiKey: true));

        var request = Assert.Single(handler.Requests);
        Assert.Equal("GET", request.Method);
    }
}
