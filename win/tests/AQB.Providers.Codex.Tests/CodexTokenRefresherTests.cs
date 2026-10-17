using System.Net;
using System.Text.Json.Nodes;
using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexTokenRefresherTests
{
    private static CodexAuthInfo Load(TempCodexHome home)
    {
        var info = new CodexAuthStore(home.Root).Load();
        Assert.NotNull(info);
        return info;
    }

    [Fact]
    public async Task RefreshPostsFormEncodedRequestAndMergesBackPreservingOtherKeys()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(idToken: TestJwts.WithEmail("eric@example.com")));

        var handler = new StubHttpHandler();
        // refresh_token missing from the response -> old value kept; id_token is a fresh JWT.
        var newIdToken = TestJwts.WithEmail("eric@example.com");
        handler.EnqueueJson("{\"access_token\":\"at-new\",\"id_token\":\"" + newIdToken + "\"}");
        var refresher = new CodexTokenRefresher(handler, home.Root);

        var refreshed = await refresher.RefreshAsync(Load(home));

        Assert.Equal("org-1", refreshed.AccountId);
        Assert.Equal("eric@example.com", refreshed.Email);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("POST", request.Method);
        Assert.Equal("https://auth.openai.com/oauth/token", request.Uri.ToString());
        Assert.Contains("application/x-www-form-urlencoded", request.Header("Content-Type"));
        Assert.Contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann", request.Body);
        Assert.Contains("grant_type=refresh_token", request.Body);
        Assert.Contains("refresh_token=rt-old", request.Body);
        Assert.Contains("scope=openid+profile+email", request.Body);

        // Merge write-back: tokens replaced, everything else preserved.
        var root = JsonNode.Parse(home.ReadAuth())!.AsObject();
        Assert.Equal("at-new", (string?)root["tokens"]!["access_token"]);
        Assert.Equal("rt-old", (string?)root["tokens"]!["refresh_token"]);
        Assert.Equal(newIdToken, (string?)root["tokens"]!["id_token"]);
        Assert.Equal("org-1", (string?)root["tokens"]!["account_id"]);
        Assert.Equal("blue", (string?)root["favorite_color"]);
        Assert.NotNull((string?)root["last_refresh"]);
        Assert.NotEqual("2026-01-01T00:00:00Z", (string?)root["last_refresh"]);
    }

    [Fact]
    public async Task RefreshUpdatesTheVariantKeyThatExists()
    {
        using var home = new TempCodexHome();
        home.WriteAuth("""
            {
              "tokens": {
                "account_id": "org-1",
                "accessToken": "at-old",
                "refreshToken": "rt-old"
              }
            }
            """);

        var handler = new StubHttpHandler();
        handler.EnqueueJson("{\"access_token\":\"at-new\",\"refresh_token\":\"rt-new\"}");
        var refresher = new CodexTokenRefresher(handler, home.Root);

        var refreshed = await refresher.RefreshAsync(Load(home));

        Assert.Equal("org-1", refreshed.AccountId);
        var root = JsonNode.Parse(home.ReadAuth())!.AsObject();
        Assert.Equal("at-new", (string?)root["tokens"]!["accessToken"]);
        Assert.Equal("rt-new", (string?)root["tokens"]!["refreshToken"]);
        Assert.Null(root["tokens"]!["access_token"]);
    }

    [Fact]
    public async Task Refresh401ThrowsRequiringReloginAndLeavesFileUntouched()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());

        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.Unauthorized);
        var refresher = new CodexTokenRefresher(handler, home.Root);

        var ex = await Assert.ThrowsAsync<CodexAuthException>(() => refresher.RefreshAsync(Load(home)));

        Assert.True(ex.RequiresRelogin);
        Assert.Contains("codex", ex.Message);
        Assert.DoesNotContain("at-new", home.ReadAuth());
    }

    [Fact]
    public async Task RefreshServerErrorThrowsWithoutReloginSemantics()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());

        var handler = new StubHttpHandler();
        handler.EnqueueStatus(HttpStatusCode.InternalServerError);
        var refresher = new CodexTokenRefresher(handler, home.Root);

        var ex = await Assert.ThrowsAsync<CodexAuthException>(() => refresher.RefreshAsync(Load(home)));

        Assert.False(ex.RequiresRelogin);
        Assert.Contains("500", ex.Message);
    }

    [Fact]
    public async Task MissingRefreshTokenThrowsWithoutAnyHttpRequest()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson(refreshToken: null));

        var handler = new StubHttpHandler();
        var refresher = new CodexTokenRefresher(handler, home.Root);

        var ex = await Assert.ThrowsAsync<CodexAuthException>(() => refresher.RefreshAsync(Load(home)));

        Assert.True(ex.RequiresRelogin);
        Assert.Empty(handler.Requests);
    }
}
