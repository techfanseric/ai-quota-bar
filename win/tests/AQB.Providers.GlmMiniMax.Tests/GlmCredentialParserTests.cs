using Xunit;

namespace AQB.Providers.GlmMiniMax.Tests;

public class GlmCredentialParserTests
{
    private const string FullCurl = """
        curl 'https://bigmodel.cn/api/monitor/usage/quota/limit?type=1' \
          -H 'accept: application/json, text/plain, */*' \
          -H 'authorization: Bearer eyJtoken' \
          -H 'bigmodel-organization: org-77' \
          -H 'bigmodel-project: proj-42' \
          -b 'bigmodel_token_production=tok123; other=x'
        """;

    [Fact]
    public void ParsesUrlAuthorizationOrgProjectAndCookie()
    {
        var credential = GlmCredentialParser.ParseCurl(FullCurl);

        Assert.Equal("https://bigmodel.cn/api/monitor/usage/quota/limit?type=1", credential.ApiUrl);
        Assert.Equal("Bearer eyJtoken", credential.Authorization);
        Assert.Equal("org-77", credential.Organization);
        Assert.Equal("proj-42", credential.Project);
        Assert.Equal("bigmodel_token_production=tok123; other=x", credential.Cookie);
        Assert.Equal("application/json, text/plain, */*", credential.Headers["accept"]);
        Assert.Equal("Bearer eyJtoken", credential.Headers["authorization"]);
    }

    [Fact]
    public void DerivesAuthorizationFromCookieWhenHeaderMissing()
    {
        var credential = GlmCredentialParser.ParseCurl(
            "curl 'https://bigmodel.cn/api/monitor/usage/quota/limit' -b 'foo=bar; bigmodel_token_production=tok456; baz=qux'");
        Assert.Equal("tok456", credential.Authorization);
    }

    [Fact]
    public void MissingAuthorizationThrows()
    {
        var e = Assert.Throws<GlmCredentialException>(
            () => GlmCredentialParser.ParseCurl("curl 'https://bigmodel.cn/x' -H 'accept: application/json'"));
        Assert.Equal("Missing GLM authorization header in curl command.", e.Message);
    }

    [Fact]
    public void DefaultsUrlWhenMissing()
    {
        var credential = GlmCredentialParser.ParseCurl("curl -H 'authorization: Bearer x'");
        Assert.Equal(GlmCredentialParser.DefaultWebEndpoint, credential.ApiUrl);
    }

    [Fact]
    public void HandlesGluedDoubleQuotedAndAnsiCForms()
    {
        var credential = GlmCredentialParser.ParseCurl(
            "curl \"https://bigmodel.cn/api/monitor/usage/quota/limit\" -H'x-custom: 1' -H \"authorization: Bearer abc\" -b $'bigmodel_token_production=t$9; a=b'");
        Assert.Equal("Bearer abc", credential.Authorization);
        Assert.Equal("1", credential.Headers["x-custom"]);
        Assert.Equal("bigmodel_token_production=t$9; a=b", credential.Cookie);
    }

    [Fact]
    public void EditableCurlRoundTrips()
    {
        var credential = GlmCredentialParser.ParseCurl(FullCurl);
        var rebuilt = GlmCredentialParser.ParseCurl(credential.ToEditableCurl());

        Assert.Equal(credential.ApiUrl, rebuilt.ApiUrl);
        Assert.Equal(credential.Authorization, rebuilt.Authorization);
        Assert.Equal(credential.Cookie, rebuilt.Cookie);
        Assert.Equal(credential.Organization, rebuilt.Organization);
        Assert.Equal(credential.Project, rebuilt.Project);
        Assert.Equal(
            credential.Headers.OrderBy(h => h.Key, StringComparer.Ordinal).Select(h => h.Key + "=" + h.Value),
            rebuilt.Headers.OrderBy(h => h.Key, StringComparer.Ordinal).Select(h => h.Key + "=" + h.Value));
    }

    [Fact]
    public void EditableCurlEscapesSingleQuotesInCookie()
    {
        var credential = GlmCredentialParser.ParseCurl(
            "curl 'https://bigmodel.cn/api/monitor/usage/quota/limit' -b \"bigmodel_token_production=to'ken\"");
        var rebuilt = GlmCredentialParser.ParseCurl(credential.ToEditableCurl());
        Assert.Equal("to'ken", GlmCredentialParser.ExtractCookieValue(rebuilt.Cookie, "bigmodel_token_production"));
        Assert.Equal(credential.Cookie, rebuilt.Cookie);
    }

    [Fact]
    public void ParseDispatchesApiKeyMode()
    {
        var bare = GlmCredentialParser.Parse("sk-glmlive-123");
        Assert.Equal(GlmCredentialParser.ApiKeyEndpoint, bare.ApiUrl);
        Assert.Equal("Bearer sk-glmlive-123", bare.Authorization);
        Assert.Null(bare.Cookie);

        var bearer = GlmCredentialParser.Parse("Bearer sk-glmlive-123");
        Assert.Equal("Bearer sk-glmlive-123", bearer.Authorization); // exactly one Bearer
    }

    [Fact]
    public void ParseEmptyThrows()
    {
        Assert.Throws<GlmCredentialException>(() => GlmCredentialParser.Parse("   "));
    }

    [Theory]
    [InlineData("a=1; b=2", "b", "2")]
    [InlineData("b=2", "missing", null)]
    [InlineData("empty=", "empty", null)]
    [InlineData("eq=a=b", "eq", "a=b")]
    public void ExtractCookieValueCases(string cookie, string name, string? expected)
    {
        Assert.Equal(expected, GlmCredentialParser.ExtractCookieValue(cookie, name));
    }
}
