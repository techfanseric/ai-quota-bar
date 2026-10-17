using Xunit;

namespace AQB.Providers.GlmMiniMax.Tests;

public class GlmResetAllowancesTests
{
    private const string ValidJson = """
        {"code": 200, "success": true, "data": {
          "targetType": "PERSONAL",
          "fiveHourResets": [
            {"available": true, "expireTime": "2026-10-18 17:48:12"},
            {"available": false, "expireTime": "2026-11-01 10:00:00"}
          ],
          "weekResets": [
            {"available": true, "expireTime": "2026-10-20 09:00:00"}
          ]}}
        """;

    private static GlmImportedCredential PersonalWebCredential(string url = "https://bigmodel.cn/api/monitor/usage/quota/limit")
        => GlmCredentialParser.ParseCurl($"curl '{url}' -H 'authorization: Bearer personal'");

    [Fact]
    public void ParsesAvailableCountsAndNearestExpiryInShanghaiTime()
    {
        var allowances = GlmResetAllowances.Parse(ValidJson);

        Assert.NotNull(allowances);
        Assert.Equal(1, allowances!.FiveHourAvailable);
        Assert.Equal(1, allowances.WeekAvailable);
        Assert.Equal(2, allowances.TotalAvailable);
        // 2026-10-18 17:48:12 Asia/Shanghai == 2026-10-18T09:48:12Z.
        Assert.Equal(new DateTimeOffset(2026, 10, 18, 9, 48, 12, TimeSpan.Zero), allowances.NearestExpiryUtc);
    }

    [Theory]
    [InlineData("""{"code": 401, "success": false, "data": {"targetType": "PERSONAL", "fiveHourResets": [], "weekResets": []}}""")]
    [InlineData("""{"code": 200, "success": true, "data": {"targetType": "TEAM", "fiveHourResets": [], "weekResets": []}}""")]
    [InlineData("""{"code": 200, "success": true, "data": {"targetType": "PERSONAL"}}""")]
    [InlineData("not json")]
    public void InvalidResponsesReturnNull(string json)
    {
        Assert.Null(GlmResetAllowances.Parse(json));
    }

    [Theory]
    [InlineData("https://open.bigmodel.cn/api/monitor/usage/quota/limit")] // API-key endpoint host
    [InlineData("https://proxy.example.com/api/monitor/usage/quota/limit")] // foreign host
    [InlineData("http://bigmodel.cn/api/monitor/usage/quota/limit")]       // not https
    [InlineData("https://bigmodel.cn:8443/api/monitor/usage/quota/limit")] // non-default port
    [InlineData("https://bigmodel.cn/api/other/path")]                     // wrong path
    [InlineData("https://bigmodel.cn/api/monitor/usage/quota/limit?type=2")]
    public void GateRefusesUnverifiedHosts(string url)
    {
        Assert.False(GlmResetAllowances.ShouldRequest(PersonalWebCredential(url)));
    }

    [Fact]
    public void GateAcceptsPersonalScope()
    {
        Assert.True(GlmResetAllowances.ShouldRequest(PersonalWebCredential()));
        Assert.True(GlmResetAllowances.ShouldRequest(
            PersonalWebCredential("https://bigmodel.cn/api/monitor/usage/quota/limit?type=1")));
    }

    [Fact]
    public void GateRefusesOrganizationOrProjectCredentials()
    {
        var org = GlmCredentialParser.ParseCurl(
            "curl 'https://bigmodel.cn/api/monitor/usage/quota/limit' -H 'authorization: Bearer x' -H 'bigmodel-organization: org'");
        Assert.False(GlmResetAllowances.ShouldRequest(org));

        var project = new GlmImportedCredential(
            "https://bigmodel.cn/api/monitor/usage/quota/limit",
            authorization: "Bearer x",
            project: "p1");
        Assert.False(GlmResetAllowances.ShouldRequest(project));
    }

    [Fact]
    public async Task FetchSendsOnlyAuthorizationToVerifiedHost()
    {
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(200, ValidJson));
        var allowances = await GlmResetAllowances.TryFetchAsync(PersonalWebCredential(), handler);

        Assert.NotNull(allowances);
        Assert.Equal(1, allowances!.FiveHourAvailable);
        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL", request.Uri!.ToString());
        Assert.Equal("Bearer personal", request.Header("Authorization"));
        Assert.Equal("", request.Header("Cookie"));
        Assert.Equal("", request.Header("bigmodel-organization"));
    }

    [Fact]
    public async Task GatedCredentialNeverSends()
    {
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(200, ValidJson));
        var apiKeyCredential = GlmImportedCredential.ForApiKey("k");

        var allowances = await GlmResetAllowances.TryFetchAsync(apiKeyCredential, handler);

        Assert.Null(allowances);
        Assert.Empty(handler.Requests);
    }

    [Fact]
    public async Task HttpFailureIsSilent()
    {
        var handler = new StubHttpHandler(_ => TestHttp.JsonResponse(500, "{}"));
        Assert.Null(await GlmResetAllowances.TryFetchAsync(PersonalWebCredential(), handler));

        var throwing = new StubHttpHandler(_ => throw new HttpRequestException("boom"));
        Assert.Null(await GlmResetAllowances.TryFetchAsync(PersonalWebCredential(), throwing));
    }
}
