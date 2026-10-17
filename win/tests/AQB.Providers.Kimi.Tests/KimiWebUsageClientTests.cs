using System.Text.Json;
using Xunit;

namespace AQB.Providers.Kimi.Tests;

public class KimiWebCredentialTests
{
    private static string MakeJwt(Dictionary<string, object> payload)
    {
        static string B64(byte[] bytes) =>
            Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

        var header = B64("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"u8.ToArray());
        var body = B64(JsonSerializer.SerializeToUtf8Bytes(payload));
        return header + "." + body + ".sig";
    }

    [Fact]
    public void RejectsUnsupportedOrigins()
    {
        foreach (var origin in new[] { "http://www.kimi.com", "https://evil.kimi.com", "https://www.kimi.com/path", "https://user@www.kimi.com" })
        {
            var credential = new KimiWebCredential("token", origin);
            var e = Assert.Throws<KimiSessionException>(() => credential.ValidateWebSession());
            Assert.Equal(KimiSessionErrorKind.UnsupportedOrigin, e.Kind);
        }

        // Exact whitelist entries pass.
        new KimiWebCredential("token", "https://www.kimi.com").ValidateWebSession();
        new KimiWebCredential("token", "https://www.kimi.ai").ValidateWebSession();
    }

    [Fact]
    public void RejectsWhitespaceOrEmptyTokenWithoutLeakingIt()
    {
        var e = Assert.Throws<KimiSessionException>(() => new KimiWebCredential("to ken", "https://www.kimi.com").ValidateWebSession());
        Assert.Equal(KimiSessionErrorKind.InvalidStore, e.Kind);
        Assert.DoesNotContain("to ken", e.Message);

        var missing = Assert.Throws<KimiSessionException>(() => new KimiWebCredential("", "https://www.kimi.com").ValidateWebSession());
        Assert.Equal(KimiSessionErrorKind.Missing, missing.Kind);
    }

    [Fact]
    public void RejectsExpiredJwt()
    {
        var token = MakeJwt(new Dictionary<string, object> { ["sub"] = "user-1", ["exp"] = 100 });
        var e = Assert.Throws<KimiSessionException>(() => new KimiWebCredential(token, "https://www.kimi.com").ValidateWebSession());
        Assert.Equal(KimiSessionErrorKind.Expired, e.Kind);

        var fresh = MakeJwt(new Dictionary<string, object>
        {
            ["sub"] = "user-2",
            ["exp"] = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds(),
        });
        var credential = new KimiWebCredential(fresh, "https://www.kimi.com");
        credential.ValidateWebSession();
        Assert.Equal("Kimi · user-2", credential.AccountLabel());
    }

    [Fact]
    public void NonJwtTokenHasPlainAccountLabel()
    {
        Assert.Equal("Kimi", new KimiWebCredential("opaque-api-key", "https://www.kimi.com").AccountLabel());
    }
}

public class KimiWebUsageClientTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 17, 8, 0, 0, TimeSpan.Zero);
    private static readonly KimiWebCredential Credential = new("token-123", "https://www.kimi.com");

    private const string UsageJson = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": { "limit": "100", "used": "71", "resetTime": "2026-10-18T11:22:56Z" },
              "limits": [
                {
                  "detail": { "limit": 100, "remaining": "84", "resetTime": "2026-10-17T13:00:00Z" },
                  "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }
                }
              ]
            },
            { "scope": "FEATURE_OTHER", "detail": { "limit": 5, "used": 1 } }
          ]
        }
        """;

    private const string StatsJson = """
        {
          "title": "Kimi 会员",
          "subscriptionBalance": {
            "feature": null,
            "type": "SUBSCRIPTION",
            "amountUsedRatio": 0.42,
            "expireTime": "2026-11-16T11:22:56.007158Z"
          }
        }
        """;

    private static StubHttpHandler HandlerFor(
        int usageStatus = 200,
        string usageJson = UsageJson,
        int statsStatus = 200,
        string statsJson = StatsJson)
        => new(request =>
        {
            if (request.Uri!.AbsolutePath.EndsWith("GetUsages"))
            {
                return TestHttp.JsonResponse(usageStatus, usageJson);
            }

            return TestHttp.JsonResponse(statsStatus, statsJson);
        });

    [Fact]
    public async Task SendsConnectProtocolRequest()
    {
        var handler = HandlerFor();
        using var client = new KimiWebUsageClient(handler);
        await client.FetchAsync(Credential);

        // Main usage call followed by the optional membership stats call.
        Assert.Equal(2, handler.Requests.Count);
        var request = handler.Requests[0];
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("www.kimi.com", request.Uri!.Host);
        Assert.Equal("/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages", request.Uri.AbsolutePath);
        Assert.Equal("Bearer token-123", request.Header("Authorization"));
        Assert.Equal("kimi-auth=token-123", request.Header("Cookie"));
        Assert.Equal("https://www.kimi.com", request.Header("Origin"));
        Assert.Equal("https://www.kimi.com/code/console", request.Header("Referer"));
        Assert.Equal("1", request.Header("connect-protocol-version"));
        Assert.Contains("FEATURE_CODING", request.Body);
    }

    [Fact]
    public async Task ParsesThreeWindowsWithStringNumberTolerance()
    {
        var handler = HandlerFor();
        using var client = new KimiWebUsageClient(handler);
        var result = await client.FetchAsync(Credential);

        Assert.Equal(3, result.Windows.Count);

        Assert.Equal("5h", result.FiveHour!.Name);
        Assert.Equal(16, result.FiveHour.UsedPercent, 5); // remaining 84 of 100
        Assert.Equal(84, result.FiveHour.RemainingPercent);
        Assert.Equal(18000, result.FiveHour.WindowSeconds);
        Assert.Equal(new DateTimeOffset(2026, 10, 17, 13, 0, 0, TimeSpan.Zero), result.FiveHour.ResetsAtUtc);

        Assert.Equal("7d", result.Weekly!.Name);
        Assert.Equal(71, result.Weekly.UsedPercent, 5);
        Assert.Equal(604800, result.Weekly.WindowSeconds);

        Assert.Equal("Total usage", result.MonthlyTotal!.Name);
        Assert.Equal(42, result.MonthlyTotal.UsedPercent, 5);
        Assert.Equal(0, result.MonthlyTotal.WindowSeconds);
        // kimi-monthly never infers a start time (task A.1).
        Assert.Null(result.MonthlyTotal.StartsAtUtc);
        Assert.Equal(new DateTimeOffset(2026, 11, 16, 11, 22, 56, 007, TimeSpan.Zero), result.MonthlyTotal.ResetsAtUtc);

        Assert.Equal("Kimi 会员", result.SubscribeTitle);
        Assert.Equal(new DateTimeOffset(2026, 11, 16, 11, 22, 56, 7, TimeSpan.Zero), result.SubscribeEndUtc);
    }

    [Fact]
    public void MonthlyWindowSkippedWhenRatioMissingButWeeklyKept()
    {
        var result = KimiWebUsageClient.Parse(
            UsageJson,
            """{"subscriptionBalance": {"feature": "FEATURE_OTHER", "amountUsedRatio": 0.5}}""",
            Now);
        Assert.Null(result.MonthlyTotal);
        Assert.NotNull(result.Weekly);
    }

    [Fact]
    public void MembershipOnlyResponseStillYieldsMonthlyWindow()
    {
        var result = KimiWebUsageClient.Parse("""{"usages": []}""", StatsJson, Now);
        Assert.Null(result.Weekly);
        Assert.Null(result.FiveHour);
        Assert.NotNull(result.MonthlyTotal);
    }

    [Fact]
    public void MembershipFailureDoesNotAffectQuota()
    {
        var result = KimiWebUsageClient.Parse(UsageJson, "not-json", Now);
        Assert.NotNull(result.FiveHour);
        Assert.NotNull(result.Weekly);
        Assert.Null(result.MonthlyTotal);
        Assert.Null(result.SubscribeTitle);
    }

    [Fact]
    public void EmptyUsagesAndStatsThrowsInvalidResponse()
    {
        var e = Assert.Throws<KimiWebException>(() => KimiWebUsageClient.Parse("""{"usages": []}""", "{}", Now));
        Assert.Equal(KimiWebErrorKind.InvalidResponse, e.Kind);
    }

    [Fact]
    public void ZeroLimitThrowsInvalidResponse()
    {
        var e = Assert.Throws<KimiWebException>(
            () => KimiWebUsageClient.Parse(
                """{"usages": [{"scope": "FEATURE_CODING", "detail": {"limit": "0", "used": "0"}}]}""",
                null,
                Now));
        Assert.Equal(KimiWebErrorKind.InvalidResponse, e.Kind);
    }

    [Fact]
    public void UnknownTimeUnitDegradesToRateLimitName()
    {
        var usage = """
            {"usages": [{"scope": "FEATURE_CODING",
              "detail": {"limit": 100, "used": 10},
              "limits": [{"detail": {"limit": 100, "used": 20}, "window": {"duration": 2, "timeUnit": "TIME_UNIT_FORTNIGHT"}}]}]}
            """;
        var result = KimiWebUsageClient.Parse(usage, null, Now);
        Assert.Equal("Rate limit", result.FiveHour!.Name);
        Assert.Equal(0, result.FiveHour.WindowSeconds);
        Assert.Null(result.FiveHour.StartsAtUtc);
    }

    [Fact]
    public async Task UnauthorizedThrowsExpiredWithoutBodyLeak()
    {
        var handler = HandlerFor(usageStatus: 401, usageJson: "{\"secret\": \"sensitive-response\"}");
        using var client = new KimiWebUsageClient(handler);
        var e = await Assert.ThrowsAsync<KimiWebException>(() => client.FetchAsync(Credential));
        Assert.Equal(KimiWebErrorKind.SessionExpired, e.Kind);
        Assert.DoesNotContain("sensitive-response", e.Message);
    }

    [Theory]
    [InlineData(302)]
    [InlineData(500)]
    public async Task NonSuccessThrowsHttpErrorWithoutBody(int status)
    {
        var handler = HandlerFor(usageStatus: status, usageJson: "sensitive-response");
        using var client = new KimiWebUsageClient(handler);
        var e = await Assert.ThrowsAsync<KimiWebException>(() => client.FetchAsync(Credential));
        Assert.Equal(KimiWebErrorKind.HttpError, e.Kind);
        Assert.Equal($"Kimi HTTP {status}", e.Message);
        Assert.DoesNotContain("sensitive-response", e.Message);
        // Only the main endpoint is attempted; the optional membership call is not the failure surface.
        Assert.Single(handler.Requests);
    }

    [Fact]
    public async Task UnvalidatedCredentialRejectedBeforeRequest()
    {
        var handler = HandlerFor();
        using var client = new KimiWebUsageClient(handler);
        await Assert.ThrowsAsync<KimiSessionException>(
            () => client.FetchAsync(new KimiWebCredential("token-123", "https://evil.example.com")));
        Assert.Empty(handler.Requests);
    }
}
