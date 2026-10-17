using System.Net;
using System.Text.Json.Nodes;
using AQB.Core;
using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexUsageClientTests
{
    private static CodexAuthInfo MakeAuth(string accessToken = "at-1", string accountId = "org-1") => new()
    {
        AccountId = accountId,
        Email = "eric@example.com",
        HasApiKey = false,
        RawJson = AuthFiles.AuthJson(accessToken: accessToken, accountId: accountId),
    };

    [Fact]
    public async Task FetchParsesPrimaryAndSecondaryWindows()
    {
        using var home = new TempCodexHome();
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        var result = await client.FetchAsync(MakeAuth());

        Assert.Equal(2, result.Windows.Count);
        var five = result.Windows[0];
        Assert.Equal(QuotaWindowRole.Primary, five.Role);
        Assert.Equal("5h", five.Name);
        Assert.Equal(18000, five.WindowSeconds);
        Assert.Equal(35, five.UsedPercent);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1788832800), five.ResetsAtUtc);
        Assert.Null(five.StartsAtUtc); // window start is derived by Core, not the response

        var weekly = result.Windows[1];
        Assert.Equal(QuotaWindowRole.Secondary, weekly.Role);
        Assert.Equal("Weekly", weekly.Name);
        Assert.Equal(604800, weekly.WindowSeconds);
        Assert.Equal(0, weekly.UsedPercent);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1789344000), weekly.ResetsAtUtc);

        Assert.Equal("pro", result.PlanTitle);
        Assert.Equal("org-1", result.AccountId);

        // CapturedAt is the fetch moment, never reset_at (weekly resets lie in the future).
        var now = DateTimeOffset.UtcNow;
        Assert.InRange(result.CapturedAtUtc, now.AddSeconds(-5), now.AddSeconds(5));
        Assert.InRange(five.CapturedAtUtc, now.AddSeconds(-5), now.AddSeconds(5));
        Assert.NotEqual(weekly.ResetsAtUtc, result.CapturedAtUtc);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("GET", request.Method);
        Assert.Equal("https://chatgpt.com/backend-api/wham/usage", request.Uri.ToString());
        Assert.Equal("Bearer at-1", request.Header("Authorization"));
        Assert.Equal("org-1", request.Header("ChatGPT-Account-Id"));
    }

    [Fact]
    public async Task SwappedWindowRolesAreExchanged()
    {
        using var home = new TempCodexHome();
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Swapped);
        var client = new CodexUsageClient(handler, home.Root);

        var result = await client.FetchAsync(MakeAuth());

        Assert.Equal(2, result.Windows.Count);
        Assert.Equal(QuotaWindowRole.Primary, result.Windows[0].Role);
        Assert.Equal("5h", result.Windows[0].Name);
        Assert.Equal(50, result.Windows[0].UsedPercent);
        Assert.Equal(QuotaWindowRole.Secondary, result.Windows[1].Role);
        Assert.Equal("Weekly", result.Windows[1].Name);
        Assert.Equal(10, result.Windows[1].UsedPercent);
    }

    [Fact]
    public async Task UnauthorizedRefreshesOnceThenRetriesAndMergesAuthFile()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.Unauthorized);
        handler.EnqueueJson("{\"access_token\":\"at-new\"}");
        handler.EnqueueJson(UsageResponses.Normal);
        var client = new CodexUsageClient(handler, home.Root);

        var result = await client.FetchAsync(MakeAuth());

        Assert.Equal(2, result.Windows.Count);
        Assert.Equal(3, handler.Requests.Count);
        Assert.Equal("https://chatgpt.com/backend-api/wham/usage", handler.Requests[0].Uri.ToString());
        Assert.Equal("https://auth.openai.com/oauth/token", handler.Requests[1].Uri.ToString());
        Assert.Equal("https://chatgpt.com/backend-api/wham/usage", handler.Requests[2].Uri.ToString());
        Assert.Equal("Bearer at-new", handler.Requests[2].Header("Authorization"));

        // The refreshed auth is returned to the caller and merged into auth.json.
        Assert.Contains("at-new", result.Auth.RawJson);
        var root = JsonNode.Parse(home.ReadAuth())!.AsObject();
        Assert.Equal("at-new", (string?)root["tokens"]!["access_token"]);
        Assert.Equal("rt-old", (string?)root["tokens"]!["refresh_token"]);
        Assert.Equal("org-1", (string?)root["tokens"]!["account_id"]);
    }

    [Fact]
    public async Task UnauthorizedAfterRefreshThrowsRequiringRelogin()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.Unauthorized);
        handler.EnqueueJson("{\"access_token\":\"at-new\"}");
        handler.EnqueueStatus(HttpStatusCode.Unauthorized);
        var client = new CodexUsageClient(handler, home.Root);

        var ex = await Assert.ThrowsAsync<CodexAuthException>(() => client.FetchAsync(MakeAuth()));

        Assert.True(ex.RequiresRelogin);
        Assert.Equal(3, handler.Requests.Count);
    }

    [Fact]
    public async Task ApiKeyModeDoesNotRefreshOnUnauthorized()
    {
        using var home = new TempCodexHome();
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.Unauthorized);
        var client = new CodexUsageClient(handler, home.Root);
        var auth = new CodexAuthInfo
        {
            AccountId = "org-1",
            HasApiKey = true,
            RawJson = AuthFiles.AuthJson(apiKey: "sk-x"),
        };

        var ex = await Assert.ThrowsAsync<CodexAuthException>(() => client.FetchAsync(auth));

        Assert.False(ex.RequiresRelogin);
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task ServerErrorThrowsPlainCodexException()
    {
        using var home = new TempCodexHome();
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.InternalServerError);
        var client = new CodexUsageClient(handler, home.Root);

        var ex = await Assert.ThrowsAsync<CodexException>(() => client.FetchAsync(MakeAuth()));

        Assert.IsNotType<CodexAuthException>(ex);
        Assert.Contains("500", ex.Message);
    }

    [Fact]
    public async Task MissingAccessTokenThrowsBeforeAnyRequest()
    {
        using var home = new TempCodexHome();
        var handler = new StubHttpHandler();
        var client = new CodexUsageClient(handler, home.Root);
        var auth = new CodexAuthInfo
        {
            AccountId = "org-1",
            RawJson = AuthFiles.AuthJson(accessToken: null),
        };

        var ex = await Assert.ThrowsAsync<CodexAuthException>(() => client.FetchAsync(auth));

        Assert.True(ex.RequiresRelogin);
        Assert.Empty(handler.Requests);
    }
}

public class CodexUsageFormulaTests
{
    private static async Task<CodexUsageResult> ParseAsync(string body)
    {
        using var home = new TempCodexHome();
        var handler = new StubHttpHandler();
        handler.EnqueueJson(body);
        var client = new CodexUsageClient(handler, home.Root);
        return await client.FetchAsync(new CodexAuthInfo
        {
            AccountId = "org-1",
            RawJson = AuthFiles.AuthJson(),
        });
    }

    [Theory]
    [InlineData(0, 100)]
    [InlineData(35, 65)]
    [InlineData(35.5, 65)] // 100 - 35.5 = 64.5 -> rounds away from zero
    [InlineData(100, 0)]
    [InlineData(120, 0)] // clamped at parse time
    public async Task RemainingPercentIsRoundedFromUsedPercent(double used, double expectedRemaining)
    {
        var result = await ParseAsync(UsageResponses.WithUsedPercents(used, used));

        Assert.All(result.Windows, window => Assert.Equal(expectedRemaining, window.RemainingPercent));
    }

    [Fact]
    public async Task WindowStartIsResetMinusWindowSeconds()
    {
        var result = await ParseAsync(UsageResponses.Normal);

        var five = result.Windows[0];
        Assert.Equal(five.ResetsAtUtc.AddSeconds(-18000), five.WindowStartUtc);
        var weekly = result.Windows[1];
        Assert.Equal(weekly.ResetsAtUtc.AddSeconds(-604800), weekly.WindowStartUtc);
    }

    [Fact]
    public async Task WindowsAreOrderedFiveHourThenWeekly()
    {
        var result = await ParseAsync(UsageResponses.Swapped);

        Assert.Equal("5h", result.Windows[0].Name);
        Assert.Equal("Weekly", result.Windows[1].Name);
    }
}
