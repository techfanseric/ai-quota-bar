using System.Net;
using System.Text.Json;
using Xunit;

namespace AQB.Clash.Tests;

public class ClashClientTests
{
    private static ClashEndpoint Endpoint(string secret = "s3cret") => new()
    {
        BaseUrl = "http://127.0.0.1:9097",
        Secret = secret,
        SourceConfigPath = @"C:\fake\config.yaml",
        ClientName = "Clash Verge Rev",
    };

    [Fact]
    public async Task SendsBearerTokenAndUserAgent()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(200, "{ \"version\": \"v1.19.0\" }")));
        using var client = new ClashClient(Endpoint(), handler);

        await client.GetVersionAsync();

        var request = Assert.Single(handler.Requests);
        Assert.Equal("Bearer s3cret", request.Headers["Authorization"]);
        Assert.Equal(ClashClient.UserAgent, request.Headers["User-Agent"]);
        Assert.Equal("http://127.0.0.1:9097/version", request.Url.ToString());
    }

    [Fact]
    public async Task OmitsAuthorizationWhenSecretIsEmpty()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(200, "{ \"version\": \"v\" }")));
        using var client = new ClashClient(Endpoint(secret: ""), handler);

        await client.GetVersionAsync();

        var request = Assert.Single(handler.Requests);
        Assert.False(request.Headers.ContainsKey("Authorization"));
    }

    [Fact]
    public async Task ParsesVersionProxiesAndRules()
    {
        const string proxies = """
            { "proxies": {
                "AI": { "type": "Selector", "now": "JP 01", "all": ["JP 01"],
                        "history": [{ "time": "t1", "delay": 120 }] },
                "Auto": { "type": "URLTest", "now": null }
            } }
            """;
        const string rules = """
            { "rules": [ { "type": "DomainSuffix", "payload": "openai.com", "proxy": "AI" } ] }
            """;
        var handler = new FakeHttpMessageHandler((request, _) => Task.FromResult(
            request.RequestUri!.AbsolutePath switch
            {
                "/version" => FakeHttpMessageHandler.Json(200, "{ \"meta\": true, \"version\": \"v1\" }"),
                "/proxies" => FakeHttpMessageHandler.Json(200, proxies),
                "/rules" => FakeHttpMessageHandler.Json(200, rules),
                _ => FakeHttpMessageHandler.Json(404, "{}"),
            }));
        using var client = new ClashClient(Endpoint(), handler);

        var version = await client.GetVersionAsync();
        var parsedProxies = await client.GetProxiesAsync();
        var parsedRules = await client.GetRulesAsync();

        Assert.Equal("v1", version.Version);
        Assert.True(version.Meta);
        Assert.Equal(2, parsedProxies.Count);
        Assert.Equal("Selector", parsedProxies["AI"].Type);
        Assert.Equal("JP 01", parsedProxies["AI"].Now);
        Assert.Equal(120, parsedProxies["AI"].LatestDelay);
        Assert.Equal("URLTest", parsedProxies["Auto"].Type);
        Assert.Null(parsedProxies["Auto"].Now);

        var rule = Assert.Single(parsedRules);
        Assert.Equal("DomainSuffix", rule.Type);
        Assert.Equal("openai.com", rule.Payload);
        Assert.Equal("AI", rule.Proxy);
    }

    [Fact]
    public async Task GroupDelayEncodesGroupAndQueryParameters()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(200, "{ \"JP 01\": 72, \"JP 02\": 0 }")));
        using var client = new ClashClient(Endpoint(), handler);

        var delays = await client.TestGroupDelayAsync("AI Group 🇯🇵");

        var request = Assert.Single(handler.Requests);
        Assert.Equal(
            "http://127.0.0.1:9097/group/AI%20Group%20%F0%9F%87%AF%F0%9F%87%B5/delay?url=https%3A%2F%2Fchatgpt.com%2F&timeout=5000&expected=200-499",
            request.Url.Scheme + "://" + request.Url.Authority + request.Url.PathAndQuery);
        Assert.Equal(72, delays["JP 01"]);
        Assert.Equal(0, delays["JP 02"]);
    }

    [Fact]
    public async Task SelectProxyPutsJsonBodyAndAcceptsAny2xx()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Empty(204)));
        using var client = new ClashClient(Endpoint(), handler);

        await client.SelectProxyAsync("AI", "JP 01");

        var request = Assert.Single(handler.Requests);
        Assert.Equal("PUT", request.Method);
        Assert.Equal("http://127.0.0.1:9097/proxies/AI", request.Url.ToString());
        Assert.Contains("JP 01", request.Body);
        Assert.StartsWith("application/json", request.Headers["Content-Type"]);
    }

    [Fact]
    public async Task ApiFailureCarriesStatusAndServerMessage()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(400, "{ \"message\": \"Selector update error\" }")));
        using var client = new ClashClient(Endpoint(), handler);

        var error = await Assert.ThrowsAsync<ClashApiException>(() => client.SelectProxyAsync("AI", "Bad"));

        Assert.Equal(ClashApiException.ApiFailure, error.Reason);
        Assert.Equal(400, error.StatusCode);
        Assert.Equal("Selector update error", error.Message);
    }

    [Fact]
    public async Task TransportFailuresSurfaceAsControllerUnavailable()
    {
        var handler = new FakeHttpMessageHandler(FakeHttpMessageHandler.Throw);
        using var client = new ClashClient(Endpoint(), handler);

        var error = await Assert.ThrowsAsync<ClashApiException>(() => client.GetVersionAsync());

        Assert.Equal(ClashApiException.ControllerUnavailable, error.Reason);
        Assert.Equal(0, error.StatusCode);
    }

    [Fact]
    public async Task UnparsableBodySurfacesAsIncompatibleResponse()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(200, "not-json")));
        using var client = new ClashClient(Endpoint(), handler);

        var error = await Assert.ThrowsAsync<ClashApiException>(() => client.GetVersionAsync());

        Assert.Equal(ClashApiException.IncompatibleResponse, error.Reason);
    }

    [Fact]
    public void RejectsUnusableEndpoints()
    {
        var handler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(200, "{}")));

        Assert.Throws<ArgumentException>(() => new ClashClient(new ClashEndpoint
        {
            BaseUrl = "",
            SourceConfigPath = "",
            DisabledReason = ClashDiscoveryReasons.ConfigurationNotFound,
        }, handler));
    }
}
