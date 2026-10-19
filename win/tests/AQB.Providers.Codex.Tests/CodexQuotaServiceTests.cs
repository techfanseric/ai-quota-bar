using System.Net;
using System.Text;
using AQB.Core;
using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexQuotaServiceTests
{
    [Fact]
    public async Task WeeklyOnlyResponsePreservesAvailableQuota()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueJson("""
            {"plan_type":"free","rate_limit":{"primary_window":{
              "used_percent":17,"limit_window_seconds":604800,
              "reset_after_seconds":455261,"reset_at":1792882963
            },"secondary_window":null}}
            """);

        var snapshot = await new CodexQuotaService(handler, home.Root).FetchAsync();

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        var window = Assert.Single(Assert.Single(snapshot.Accounts).Windows);
        Assert.Equal(QuotaWindowRole.Secondary, window.Role);
        Assert.Equal("Weekly", window.Name);
        Assert.Equal(83, window.RemainingPercent);
    }

    [Fact]
    public async Task NoCredentialsYieldsOfflineSnapshot()
    {
        using var home = new TempCodexHome();
        var service = new CodexQuotaService(new StubHttpHandler(), home.Root);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderKind.Codex, snapshot.Kind);
        Assert.Equal(ProviderStatus.Offline, snapshot.Status);
        Assert.Equal("No Codex credentials", snapshot.Error);
        Assert.Empty(snapshot.Accounts);
    }

    [Fact]
    public async Task HappyPathBuildsSnapshotForOAuthAccount()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(idToken: TestJwts.WithEmail("eric@example.com")));
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var service = new CodexQuotaService(handler, home.Root);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderKind.Codex, snapshot.Kind);
        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Null(snapshot.Error);

        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal(AccountFingerprint.Codex("org-1"), account.AccountKey);
        Assert.Equal("eric@example.com", account.Label);
        Assert.True(account.IsCurrent);
        Assert.Equal("OAuth", account.SourceLabel);
        Assert.Equal("pro", account.PlanTitle);
        Assert.Equal(2, account.Windows.Count);
        Assert.Equal("5h", account.Windows[0].Name);
        Assert.Equal("Weekly", account.Windows[1].Name);

        var now = DateTimeOffset.UtcNow;
        Assert.InRange(snapshot.LastUpdatedUtc!.Value, now.AddSeconds(-5), now.AddSeconds(5));
    }

    [Fact]
    public async Task ApiKeyModeLabelsSourceAsApiKey()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(apiKey: "sk-x"));
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        var service = new CodexQuotaService(handler, home.Root);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Equal("API key", Assert.Single(snapshot.Accounts).SourceLabel);
    }

    [Fact]
    public async Task AccountSwitchedDuringFetchDiscardsResultAndRetriesOnce()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(accountId: "org-1"));
        var handler = new StubHttpHandler();

        HttpResponseMessage UsageResponse() => new(HttpStatusCode.OK)
        {
            Content = new StringContent(UsageResponses.Normal, Encoding.UTF8, "application/json"),
        };

        // First fetch: while the request is "in flight", codex switches auth.json to org-2.
        handler.Enqueue(() =>
        {
            home.WriteAuth(AuthFiles.AuthJson(accountId: "org-2", idToken: TestJwts.WithEmail("second@example.com")));
            return UsageResponse();
        });
        handler.EnqueueJson(UsageResponses.Normal);

        var service = new CodexQuotaService(handler, home.Root);
        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal(AccountFingerprint.Codex("org-2"), account.AccountKey);
        Assert.Equal("second@example.com", account.Label);

        // Exactly two usage fetches: the first (stale) result was discarded.
        Assert.Equal(2, handler.Requests.Count);
        Assert.All(handler.Requests, request => Assert.Equal("https://chatgpt.com/backend-api/wham/usage", request.Uri.ToString()));
    }

    [Fact]
    public async Task AccountSwitchingTwiceFails()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(accountId: "org-1"));
        var handler = new StubHttpHandler();
        handler.Enqueue(() =>
        {
            home.WriteAuth(AuthFiles.AuthJson(accountId: "org-2"));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(UsageResponses.Normal, Encoding.UTF8, "application/json"),
            };
        });
        handler.Enqueue(() =>
        {
            home.WriteAuth(AuthFiles.AuthJson(accountId: "org-3"));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(UsageResponses.Normal, Encoding.UTF8, "application/json"),
            };
        });

        var service = new CodexQuotaService(handler, home.Root);
        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.Equal("Codex account changed during fetch", snapshot.Error);
        Assert.Equal(2, handler.Requests.Count);
    }

    [Fact]
    public async Task ServerErrorYieldsFailedSnapshot()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.InternalServerError);
        var service = new CodexQuotaService(handler, home.Root);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.Contains("500", snapshot.Error);
    }

    [Fact]
    public async Task ExpiredTokenAfterRefreshAttemptYieldsOfflineSnapshot()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.Unauthorized); // usage -> 401
        handler.EnqueueStatus(HttpStatusCode.Unauthorized); // refresh -> 401
        var service = new CodexQuotaService(handler, home.Root);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Offline, snapshot.Status);
        Assert.Contains("codex", snapshot.Error);
    }
}
