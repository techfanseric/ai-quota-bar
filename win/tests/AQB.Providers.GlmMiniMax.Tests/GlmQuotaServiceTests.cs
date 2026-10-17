using AQB.Core;
using Xunit;

namespace AQB.Providers.GlmMiniMax.Tests;

public class GlmQuotaServiceTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 17, 8, 0, 0, TimeSpan.Zero);

    private const string SpecFixture = """
        {
          "code": 200, "success": true, "msg": null,
          "data": { "level": "lite", "limits": [
            { "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
              "usage": 2000, "currentValue": 0, "remaining": 2000, "percentage": 0 },
            { "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
              "usage": 10000, "currentValue": 514, "remaining": 9485, "percentage": 5,
              "nextResetTime": 1789647732997 }
          ] }
        }
        """;

    [Fact]
    public async Task ApiKeyModeHitsOpenEndpointWithSingleBearer()
    {
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(200, SpecFixture));
        var service = GlmQuotaService.ForApiKey("glm-key-1", handler);

        var snapshot = await service.FetchAsync();

        var request = Assert.Single(handler.Requests);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("https://open.bigmodel.cn/api/monitor/usage/quota/limit", request.Uri!.ToString());
        Assert.Equal("Bearer glm-key-1", request.Header("Authorization"));
        Assert.Equal("zh", request.Header("Accept-Language"));
        Assert.Equal("zh", request.Header("Set-Language"));
        // HttpHeaders normalizes list separators without spaces.
        Assert.Equal("application/json,text/plain,*/*", request.Header("Accept").Replace(" ", ""));
        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Equal("lite", snapshot.SubscribeTitle);
    }

    [Fact]
    public async Task ImportedModeSendsAllHeadersAndCookie()
    {
        var credential = GlmCredentialParser.ParseCurl(
            "curl 'https://bigmodel.cn/api/monitor/usage/quota/limit' -H 'authorization: Bearer webtok' -H 'x-trace: t1' -b 'bigmodel_token_production=tok'");
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(200, SpecFixture));
        var service = new GlmQuotaService(credential, handler);

        await service.FetchAsync();

        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://bigmodel.cn/api/monitor/usage/quota/limit", request.Uri!.ToString());
        Assert.Equal("Bearer webtok", request.Header("Authorization"));
        Assert.Equal("t1", request.Header("x-trace"));
        Assert.Equal("bigmodel_token_production=tok", request.Header("Cookie"));
    }

    [Fact]
    public void ParsesSpecFixtureWithoutFabricatingResetTimes()
    {
        var snapshot = GlmQuotaService.ParseResponse(SpecFixture, Now);

        Assert.Equal(ProviderStatus.Ok, snapshot.Status);
        Assert.Equal("lite", snapshot.SubscribeTitle);
        var account = Assert.Single(snapshot.Accounts);
        Assert.Equal(2, account.Windows.Count);

        // 5h window first (secondary): no nextResetTime → no fabricated times, Name annotated.
        var fiveHour = account.Windows[0];
        Assert.Equal(QuotaWindowRole.Secondary, fiveHour.Role);
        Assert.Equal("GLM Credits (5h) · no reset", fiveHour.Name);
        Assert.Equal(0, fiveHour.WindowSeconds);
        Assert.Equal(default(DateTimeOffset), fiveHour.ResetsAtUtc);
        Assert.Equal(0, fiveHour.UsedPercent, 5);
        // Zero-length window means pace is skipped by the snapshot layer.
        Assert.Null(PaceMath.Compute(fiveHour, Now));

        // Weekly window: reset from the ms timestamp, start derived as reset - 7d.
        var weekly = account.Windows[1];
        Assert.Equal(QuotaWindowRole.Primary, weekly.Role);
        Assert.Equal("GLM Credits (weekly)", weekly.Name);
        Assert.Equal(604800, weekly.WindowSeconds);
        var reset = DateTimeOffset.FromUnixTimeMilliseconds(1789647732997);
        Assert.Equal(reset, weekly.ResetsAtUtc);
        Assert.Equal(reset.AddSeconds(-604800), weekly.WindowStartUtc);
        Assert.Equal(5.14, weekly.UsedPercent, 2); // currentValue 514 of usage 10000
        Assert.NotNull(snapshot.DetailText);
    }

    [Fact]
    public void PercentageOnlyEntryFallsBackToPercentage()
    {
        var json = """
            {"code": 200, "success": true, "data": {"level": "lite", "limits": [
              {"type": "TOKENS_LIMIT", "percentage": "12.5", "nextResetTime": 1789647732997}]}}
            """;
        var snapshot = GlmQuotaService.ParseResponse(json, Now);
        var window = Assert.Single(Assert.Single(snapshot.Accounts).Windows);

        Assert.Equal("GLM Tokens (5h)", window.Name);
        Assert.Equal(12.5, window.UsedPercent, 3);
        Assert.Equal(18000, window.WindowSeconds); // TOKENS_LIMIT duration fallback
        // Shared model rounds 100 - 12.5 = 87.5 away from zero → 88.
        Assert.Equal(88, window.RemainingPercent);
    }

    [Fact]
    public void ServerRemainingIsUsedWhenCurrentValueMissing()
    {
        var json = """
            {"code": 200, "success": true, "data": {"limits": [
              {"type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "remaining": 25}]}}
            """;
        var window = Assert.Single(Assert.Single(GlmQuotaService.ParseResponse(json, Now).Accounts).Windows);
        Assert.Equal(75, window.UsedPercent, 3);
    }

    [Fact]
    public void OutOfRangeValuesAreClamped()
    {
        // currentValue above total → 100%; negative remaining without currentValue → clamped to 0 → 100% used.
        var over = """
            {"code": 200, "success": true, "data": {"limits": [
              {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 100, "currentValue": 150, "remaining": -5}]}}
            """;
        var window = Assert.Single(Assert.Single(GlmQuotaService.ParseResponse(over, Now).Accounts).Windows);
        Assert.Equal(100, window.UsedPercent, 3);

        var noCurrentValue = """
            {"code": 200, "success": true, "data": {"limits": [
              {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 100, "remaining": -5}]}}
            """;
        var window2 = Assert.Single(Assert.Single(GlmQuotaService.ParseResponse(noCurrentValue, Now).Accounts).Windows);
        Assert.Equal(100, window2.UsedPercent, 3);
    }

    [Theory]
    [InlineData(1, 2, "2d")]
    [InlineData(5, 30, "30m")]
    [InlineData(6, 2, "2w")]
    [InlineData(3, 5, "5h")]
    public void PeriodNamingPerUnit(long unit, long number, string period)
    {
        var json = "{\"code\": 200, \"success\": true, \"data\": {\"limits\": [{\"type\": \"CREDIT_LIMIT\", \"unit\": "
            + unit + ", \"number\": " + number + ", \"usage\": 10, \"currentValue\": 1}]}}";
        var window = Assert.Single(Assert.Single(GlmQuotaService.ParseResponse(json, Now).Accounts).Windows);
        Assert.Equal($"GLM Credits ({period}) · no reset", window.Name);
    }

    [Fact]
    public void FallbackPeriodNaming()
    {
        var json = """
            {"code": 200, "success": true, "data": {"limits": [
              {"type": "CREDIT_LIMIT", "usage": 10, "currentValue": 1},
              {"type": "TIME_LIMIT", "usage": 10, "currentValue": 1},
              {"type": "MYSTERY_LIMIT", "usage": 10, "currentValue": 1}]}}
            """;
        var names = Assert.Single(GlmQuotaService.ParseResponse(json, Now).Accounts).Windows.Select(w => w.Name).ToArray();
        Assert.Equal(new[] { "GLM Credits (unknown) · no reset", "GLM MCP/Search (month) · no reset", "GLM MYSTERY_LIMIT (unknown) · no reset" }, names);
    }

    [Fact]
    public void UsageDetailsTopThreeAppearInDetailText()
    {
        var json = """
            {"code": 200, "success": true, "data": {"limits": [
              {"type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 100, "currentValue": 6, "percentage": 6,
               "usageDetails": [
                 {"modelCode": "glm-4.7", "usage": 5}, {"modelCode": "glm-4.6", "usage": 4},
                 {"modelCode": "glm-4.5", "usage": 3}, {"modelCode": "glm-4.4", "usage": 2}]}]}}
            """;
        var snapshot = GlmQuotaService.ParseResponse(json, Now);
        Assert.NotNull(snapshot.DetailText);
        Assert.Contains("6% used", snapshot.DetailText);
        Assert.Contains("glm-4.7: 5", snapshot.DetailText);
        Assert.Contains("glm-4.5: 3", snapshot.DetailText);
        Assert.DoesNotContain("glm-4.4", snapshot.DetailText); // top 3 only
    }

    [Theory]
    [InlineData("""{"code": 401, "success": false, "msg": "unauthorized"}""", "unauthorized")]
    [InlineData("""{"code": 200, "success": false, "msg": null}""", "Unknown GLM API error.")]
    public void ApiLevelFailuresProduceFailedSnapshots(string json, string expectedErrorPart)
    {
        var snapshot = GlmQuotaService.ParseResponse(json, Now);
        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.Contains(expectedErrorPart, snapshot.Error);
    }

    [Fact]
    public void EmptyOrUnusableLimitsFail()
    {
        Assert.Equal(ProviderStatus.Failed, GlmQuotaService.ParseResponse("""{"code": 200, "success": true, "data": {"limits": []}}""", Now).Status);
        var unusable = """{"code": 200, "success": true, "data": {"limits": [{"type": "CREDIT_LIMIT", "usage": 0}]}}""";
        Assert.Equal(ProviderStatus.Failed, GlmQuotaService.ParseResponse(unusable, Now).Status);
        Assert.Equal(ProviderStatus.Failed, GlmQuotaService.ParseResponse("not json", Now).Status);
    }

    [Fact]
    public async Task HttpAndNetworkFailuresReturnFailedSnapshot()
    {
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(500, "{}"));
        var service = GlmQuotaService.ForApiKey("k", handler);
        var snapshot = await service.FetchAsync();
        Assert.Equal(ProviderStatus.Failed, snapshot.Status);
        Assert.Equal("GLM HTTP 500", snapshot.Error);

        var throwing = new StubHttpHandler(_ => throw new HttpRequestException("boom"));
        var service2 = GlmQuotaService.ForApiKey("k", throwing);
        var snapshot2 = await service2.FetchAsync();
        Assert.Equal(ProviderStatus.Failed, snapshot2.Status);
    }
}
