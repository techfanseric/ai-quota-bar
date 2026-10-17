using System.Text.Json;
using AQB.Core;
using Xunit;

namespace AQB.Providers.Kimi.Tests;

public class KimiQuotaServiceTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "aqb-kimi-service-" + Guid.NewGuid().ToString("N"));

    private const string UsageJson = """
        {"usages": [{"scope": "FEATURE_CODING",
          "detail": {"limit": 100, "used": 40, "resetTime": "2026-10-18T11:22:56Z"},
          "limits": [{"detail": {"limit": 100, "remaining": 90, "resetTime": "2026-10-17T13:00:00Z"},
                      "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}}]}]}
        """;

    private const string StatsJson = """
        {"title": "Kimi Pro", "subscriptionBalance": {"amountUsedRatio": 0.3, "expireTime": "2026-11-16T11:22:56Z"}}
        """;

    private static string MakeJwt(string sub, long expSeconds)
    {
        static string B64(byte[] bytes) =>
            Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

        return B64("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"u8.ToArray()) + "." +
            B64(JsonSerializer.SerializeToUtf8Bytes(new { sub, exp = expSeconds })) + ".sig";
    }

    private KimiDesktopSessionReader ReaderFor(string token)
    {
        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "token-store.json");
        File.WriteAllText(path, "{\"origin\": \"https://www.kimi.com\", \"tokens\": {\"access_token\": \"" + token + "\"}}");
        return new KimiDesktopSessionReader(windowsStorePath: path, macStorePath: Path.Combine(_dir, "mac-missing.json"));
    }

    private static StubHttpHandler OkHandler(string usage = UsageJson, string stats = StatsJson)
        => new(request =>
        {
            if (request.Uri!.AbsolutePath.EndsWith("GetUsages"))
            {
                return TestHttp.JsonResponse(200, usage);
            }

            return TestHttp.JsonResponse(200, stats);
        });

    [Fact]
    public async Task ApiKeyModeUsesKeyAsBearer()
    {
        var handler = OkHandler();
        var service = new KimiQuotaService(apiKey: "key-abc", desktopReader: ReaderFor("desktop-token"), handler: handler, cliEnabled: false);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Equal(ProviderKind.Kimi, snapshot.Kind);
        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal("Kimi Code API", account.SourceLabel);
        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("Bearer key-abc", handler.Requests[0].Header("Authorization"));
        Assert.Equal("Kimi Pro", snapshot.SubscribeTitle);
        Assert.Equal("2026-11-16", snapshot.SubscribeEndTimeText);
        // Windows: 5h, 7d, Total usage (monthly from stats).
        Assert.Equal(new[] { "5h", "7d", "Total usage" }, account.Windows.Select(w => w.Name).ToArray());
    }

    [Fact]
    public async Task DesktopTokenUsedWhenNoApiKey()
    {
        var token = MakeJwt("user-9", DateTimeOffset.UtcNow.AddHours(2).ToUnixTimeSeconds());
        var handler = OkHandler();
        var service = new KimiQuotaService(
            desktopReader: ReaderFor(token),
            handler: handler,
            cliEnabled: false);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal("Kimi Desktop", account.SourceLabel);
        Assert.Equal("Kimi · user-9", account.Label);
        Assert.Equal("kimi-auth=" + token, handler.Requests[0].Header("Cookie"));
        Assert.Equal("Kimi Desktop · https://www.kimi.com", snapshot.DetailText);
    }

    [Fact]
    public async Task ExpiredDesktopSessionFallsThroughToNotConfigured()
    {
        var expired = MakeJwt("user-9", 100);
        var handler = OkHandler();
        var service = new KimiQuotaService(
            desktopReader: ReaderFor(expired),
            handler: handler,
            cliEnabled: false);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.NotNull(snapshot.Error);
        Assert.Contains("expired", snapshot.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task NothingConfiguredReportsNotConfigured()
    {
        var service = new KimiQuotaService(
            desktopReader: new KimiDesktopSessionReader(
                windowsStorePath: Path.Combine(_dir, "missing.json"),
                macStorePath: Path.Combine(_dir, "missing-mac.json")),
            cliEnabled: false);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.NotNull(snapshot.Error);
        Assert.Contains("not configured", snapshot.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ApiKeyFailureFallsBackToDesktop()
    {
        var usageCalls = 0;
        var handler = new StubHttpHandler(request =>
        {
            if (request.Uri!.AbsolutePath.EndsWith("GetUsages"))
            {
                // First call (API key) 500s, the retried desktop call succeeds.
                usageCalls++;
                return TestHttp.JsonResponse(usageCalls == 1 ? 500 : 200, UsageJson);
            }

            return TestHttp.JsonResponse(200, StatsJson);
        });

        var service = new KimiQuotaService(
            apiKey: "bad-key",
            desktopReader: ReaderFor("fresh-desktop-token"),
            handler: handler,
            cliEnabled: false);

        var snapshot = await service.FetchAsync();

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal("Kimi Desktop", account.SourceLabel);
        // API-key usage attempt (500) + desktop usage + desktop membership stats.
        Assert.Equal(3, handler.Requests.Count);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
