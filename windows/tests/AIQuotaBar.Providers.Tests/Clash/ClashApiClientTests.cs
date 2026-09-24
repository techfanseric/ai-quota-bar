// Swift 来源：无（Windows 端新增——Swift 端 ClashAPIClient 无独立单测，请求构造/错误映射/
// 响应解析行为经此处 FakeHandler 注入验证；/connections 响应用契约 fixture，/version、/proxies、
// /rules 无录制样本，以构造对象序列化喂入，见 contracts/fixtures/README 缺口清单）。
// fixtures：connections-response-mihomo.json。

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashApiClientTests
{
    private static readonly ClashControllerConfiguration Configuration = new(
        BaseUrl: new Uri("http://127.0.0.1:9097"),
        Secret: "fixture-secret",
        ClientName: "Mihomo",
        ConfigUrl: new Uri("http://127.0.0.1:9097/config"));

    // ---------------------------------------------------------------- happy paths

    [Fact]
    public async Task GetVersionAsyncSendsRealHeadersAndParsesResponse()
    {
        var handler = new FakeHandler(_ => Ok(JsonSerializer.Serialize(
            new ClashVersionResponse(Meta: true, Version: "mihomo v1.19.10"), QuotaJson.Default)));
        using var client = new ClashApiClient(Configuration, handler);

        var version = await client.GetVersionAsync();

        Assert.Equal("mihomo v1.19.10", version.Version);
        Assert.True(version.Meta ?? false, "meta 应解码为 true");

        Assert.Equal(1, handler.Requests.Count);
        var request = handler.Requests[0];
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("http://127.0.0.1:9097/version", request.RequestUri!.ToString());
        // 应然：真实请求头 User-Agent + Bearer secret（实然缺失即失败）。
        Assert.Equal("AIQuotaBar/ClashIntegration", request.Headers.GetValues("User-Agent").Single());
        Assert.Equal("Bearer fixture-secret", request.Headers.GetValues("Authorization").Single());
    }

    [Fact]
    public async Task EmptySecretOmitsAuthorizationHeader()
    {
        var configuration = Configuration with { Secret = string.Empty };
        var handler = new FakeHandler(_ => Ok("{\"version\":\"v1\"}"));
        using var client = new ClashApiClient(configuration, handler);

        await client.GetVersionAsync();

        var request = handler.Requests[0];
        Assert.False(
            request.Headers.Contains("Authorization"),
            "secret 为空时不应发送 Authorization 头");
    }

    [Fact]
    public async Task LoadConnectionsSnapshotAsyncParsesMihomoFixture()
    {
        var handler = new FakeHandler(_ => Ok(Fixtures.ReadClashFixture("connections-response-mihomo.json")));
        using var client = new ClashApiClient(Configuration, handler);

        var response = await client.LoadConnectionsSnapshotAsync();

        Assert.Equal("http://127.0.0.1:9097/connections", handler.Requests[0].RequestUri!.ToString());
        Assert.Equal(1234L, response.DownloadTotal);
        Assert.Equal(567L, response.UploadTotal);
        Assert.Equal("api.openai.com", response.Connections[0].Metadata.Host);
        Assert.Equal("openai.com", response.Connections[0].RulePayload);
        Assert.NotNull(ClashConnectionDateParser.Date(response.Connections[0].Start));
    }

    [Fact]
    public async Task SelectRouteAsyncPutsJsonBody()
    {
        var handler = new FakeHandler(_ => Ok("{}"));
        using var client = new ClashApiClient(Configuration, handler);

        await client.SelectRouteAsync(routeName: "🇯🇵 Japan Tokyo 03", groupName: "AI group");

        var request = handler.Requests[0];
        Assert.Equal(HttpMethod.Put, request.Method);
        Assert.Equal("/proxies/AI%20group", request.RequestUri!.AbsolutePath);
        Assert.Equal("application/json", request.Content!.Headers.ContentType!.MediaType);
        Assert.Equal(
            "{\"name\":\"🇯🇵 Japan Tokyo 03\"}",
            await request.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task TestGroupAsyncBuildsDelayQueryAndParsesDelays()
    {
        var handler = new FakeHandler(_ => Ok("{\"🇯🇵 Tokyo 01\": 82, \"SG-Singapore-01\": 61}"));
        using var client = new ClashApiClient(Configuration, handler);

        var delays = await client.TestGroupAsync("AI group");

        var request = handler.Requests[0];
        Assert.Equal("/group/AI%20group/delay", request.RequestUri!.AbsolutePath);
        Assert.Equal(
            "?url=https%3A%2F%2Fchatgpt.com%2F&timeout=5000&expected=200-499",
            request.RequestUri!.Query);
        Assert.Equal(82, delays["🇯🇵 Tokyo 01"]);
        Assert.Equal(61, delays["SG-Singapore-01"]);
    }

    [Fact]
    public async Task LoadRouteSnapshotAsyncResolvesGroupSortsAndFlagsSelection()
    {
        var proxies = new ClashProxiesResponse(new Dictionary<string, ClashProxy>
        {
            ["AI"] = new(
                Name: "AI",
                Type: "Selector",
                Now: "JP 01",
                All: new[] { "JP 01", "SG 01", "US 01" },
                History: null),
            ["JP 01"] = new(
                Name: "JP 01",
                Type: "Hysteria2",
                Now: null,
                All: null,
                History: new[] { new ClashProxyHistory(Time: null, Delay: 82) }),
            ["SG 01"] = new(
                Name: "SG 01",
                Type: "Vless",
                Now: null,
                All: null,
                History: new[] { new ClashProxyHistory(Time: null, Delay: 61) }),
            // US 01 故意缺代理条目：应回退 Type="Unknown"、无延迟。
        });
        var rules = new ClashRulesResponse(new[] { new ClashRule("RuleSet", "ai", "AI") });
        var handler = new FakeHandler(request =>
            request.RequestUri!.AbsolutePath.EndsWith("/proxies", StringComparison.Ordinal)
                ? Ok(JsonSerializer.Serialize(proxies, QuotaJson.Default))
                : Ok(JsonSerializer.Serialize(rules, QuotaJson.Default)));
        using var client = new ClashApiClient(Configuration, handler);

        var snapshot = await client.LoadRouteSnapshotAsync();

        // 应然：/proxies 与 /rules 各取一次。
        Assert.Equal(2, handler.Requests.Count);
        Assert.Equal("AI", snapshot.GroupName);
        Assert.Equal("JP 01", snapshot.SelectedRouteName);
        Assert.Equal(new[] { "SG 01", "JP 01", "US 01" }, snapshot.Routes.Select(route => route.Name).ToArray());
        Assert.True(snapshot.Routes[1].IsSelected, "当前选中项应带 IsSelected 标记");
        Assert.Equal("Unknown", snapshot.Routes[2].Type);
        Assert.Null(snapshot.Routes[2].Delay);
    }

    // ---------------------------------------------------------------- error mapping

    [Fact]
    public async Task ApiFailureSurfacesStatusCodeAndMessage()
    {
        var handler = new FakeHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound)
        {
            Content = new StringContent("{\"message\":\"proxy not found\"}", Encoding.UTF8, "application/json"),
        });
        using var client = new ClashApiClient(Configuration, handler);

        var exception = await Assert.ThrowsAsync<ClashIntegrationException>(
            () => client.SelectRouteAsync(routeName: "JP 01", groupName: "missing"));

        Assert.Equal(new ClashIntegrationError.ApiFailure(404, "proxy not found"), exception.Error);
    }

    [Fact]
    public async Task TransportFailureMapsToControllerUnavailable()
    {
        var handler = new FakeHandler(_ => throw new HttpRequestException("connection refused"));
        using var client = new ClashApiClient(Configuration, handler);

        var exception = await Assert.ThrowsAsync<ClashIntegrationException>(() => client.GetVersionAsync());

        Assert.Equal(new ClashIntegrationError.ControllerUnavailable(), exception.Error);
    }

    [Fact]
    public async Task InvalidJsonMapsToIncompatibleResponse()
    {
        var handler = new FakeHandler(_ => Ok("<html>not json</html>"));
        using var client = new ClashApiClient(Configuration, handler);

        var exception = await Assert.ThrowsAsync<ClashIntegrationException>(() => client.GetVersionAsync());

        Assert.Equal(new ClashIntegrationError.IncompatibleResponse(), exception.Error);
    }

    [Fact]
    public async Task LoadRouteSnapshotWithoutOpenAIGroupThrowsStrategyGroupNotFound()
    {
        var proxies = new ClashProxiesResponse(new Dictionary<string, ClashProxy>
        {
            ["Manual"] = new(
                Name: "Manual",
                Type: "Selector",
                Now: "Node",
                All: new[] { "Node" },
                History: null),
        });
        var rules = new ClashRulesResponse(new[] { new ClashRule("RuleSet", "private_domain", "Manual") });
        var handler = new FakeHandler(request =>
            request.RequestUri!.AbsolutePath.EndsWith("/proxies", StringComparison.Ordinal)
                ? Ok(JsonSerializer.Serialize(proxies, QuotaJson.Default))
                : Ok(JsonSerializer.Serialize(rules, QuotaJson.Default)));
        using var client = new ClashApiClient(Configuration, handler);

        var exception = await Assert.ThrowsAsync<ClashIntegrationException>(() => client.LoadRouteSnapshotAsync());

        Assert.Equal(new ClashIntegrationError.StrategyGroupNotFound(), exception.Error);
    }

    // ---------------------------------------------------------------- helpers

    private static HttpResponseMessage Ok(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private sealed class FakeHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;
        private readonly object _gate = new();

        public FakeHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) =>
            _responder = responder;

        public List<HttpRequestMessage> Requests { get; } = new();

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            // LoadRouteSnapshotAsync 会并发取 /proxies 与 /rules，记录需加锁。
            lock (_gate)
            {
                Requests.Add(request);
            }

            return Task.FromResult(_responder(request));
        }
    }
}
