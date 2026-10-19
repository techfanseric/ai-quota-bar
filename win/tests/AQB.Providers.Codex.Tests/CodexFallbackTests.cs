using System.Security.Authentication;
using System.Text.Json.Nodes;
using AQB.Core;
using Xunit;

namespace AQB.Providers.Codex.Tests;

public class CodexFallbackTests
{
    [Fact]
    public async Task TlsFailureFallsBackToCliAndLabelsSource()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.Enqueue(() => throw TlsError());
        var calls = 0;
        var service = new CodexQuotaService(handler, home.Root, (auth, token) =>
        {
            calls++;
            Assert.False(token.IsCancellationRequested);
            return Task.FromResult(CliResult(auth));
        });

        var snapshot = await service.FetchAsync();

        Assert.Equal(1, calls);
        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal("Codex CLI", account.SourceLabel);
        Assert.Equal(83, Assert.Single(account.Windows).RemainingPercent);
    }

    [Fact]
    public async Task FailedRefreshKeepsPreviousQuotaWithOriginalTimestamp()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        handler.Enqueue(() => throw TlsError());
        var service = new CodexQuotaService(handler, home.Root);

        var good = await service.FetchAsync();
        var failed = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, failed.Status);
        Assert.Equal(good.LastUpdatedUtc, failed.LastUpdatedUtc);
        Assert.Same(good.Accounts, failed.Accounts);
        Assert.Contains("certificate chain", failed.Error);
    }

    [Fact]
    public async Task SwitchedAccountDoesNotReusePreviousAccountsQuota()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.EnqueueJson(UsageResponses.Normal);
        handler.Enqueue(() => throw TlsError());
        var service = new CodexQuotaService(handler, home.Root);
        await service.FetchAsync();
        home.WriteAuth(AuthFiles.AuthJson(accountId: "other-account"));

        var failed = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, failed.Status);
        Assert.Empty(failed.Accounts);
    }

    [Fact]
    public async Task BothSourcesFailReportTlsCauseAndCliFailure()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        var handler = new StubHttpHandler();
        handler.Enqueue(() => throw TlsError());
        var service = new CodexQuotaService(handler, home.Root,
            (_, _) => throw new CodexException("CLI unavailable"));

        var failed = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, failed.Status);
        Assert.Contains("certificate chain", failed.Error);
        Assert.Contains("CLI unavailable", failed.Error);
    }

    [Fact]
    public async Task CancellationDoesNotLaunchCli()
    {
        using var home = new TempCodexHome();
        home.WriteAuth(AuthFiles.AuthJson());
        using var cancel = new CancellationTokenSource();
        var handler = new StubHttpHandler();
        handler.Enqueue(() => { cancel.Cancel(); throw new TaskCanceledException(); });
        var calls = 0;
        var service = new CodexQuotaService(handler, home.Root, (auth, _) =>
        {
            calls++;
            return Task.FromResult(CliResult(auth));
        });

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.FetchAsync(cancel.Token));
        Assert.Equal(0, calls);
    }

    [Fact]
    public void CliPrefersCodexBucketAndNormalizesWeeklyOnlyWindow()
    {
        var response = JsonNode.Parse("""
            {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1792882963}},
            "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1792882963}}}}
            """)!.AsObject();

        var result = CodexCliUsageClient.ParseResponse(new CodexAuthInfo { AccountId = "test" }, response);

        var window = Assert.Single(result.Windows);
        Assert.Equal("Weekly", window.Name);
        Assert.Equal(QuotaWindowRole.Secondary, window.Role);
        Assert.Equal(83, window.RemainingPercent);
    }

    [Fact]
    public void CliEmptyWindowsAreNotReportedAsSuccess()
    {
        Assert.Throws<CodexException>(() => CodexCliUsageClient.ParseResponse(
            new CodexAuthInfo { AccountId = "test" }, JsonNode.Parse("""{"rateLimits":{}}""")!.AsObject()));
    }

    private static HttpRequestException TlsError() => new("SSL connection could not be established",
        new AuthenticationException("certificate chain validation failed"));

    private static CodexUsageResult CliResult(CodexAuthInfo auth) => CodexCliUsageClient.ParseResponse(auth,
        JsonNode.Parse("""{"rateLimits":{"primary":{"usedPercent":17,"windowDurationMins":10080,"resetsAt":1792882963}}}""")!.AsObject());
}
