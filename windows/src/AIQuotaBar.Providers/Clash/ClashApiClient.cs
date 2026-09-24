// Swift 来源：AIQuotaBar/Services/Clash/ClashAPIClient.swift — struct ClashAPIClient + private ClashAPIErrorResponse（v1.28.1）
// 对应测试：windows/tests/AIQuotaBar.Providers.Tests/Clash/ClashApiClientTests.cs
// fixtures：windows/contracts/fixtures/clash/connections-response-mihomo.json（/version、/proxies、/rules
// 无录制样本，见 contracts/fixtures/README 缺口清单，测试以构造对象序列化喂入 FakeHandler）。
//
// 已暂缓：connectionSnapshots(intervalMilliseconds:)（WebSocket 流式 /connections），
// 其唯一消费方 ClashConnectionViewModel 属 UI 层暂缓项，随其落地时以 ClientWebSocket 移植。

#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// Clash / mihomo RESTful 控制客户端。传输可注入（构造函数接受 HttpMessageHandler，测试用 FakeHandler）；
/// 真实传输禁用代理与 Cookie（对应 Swift connectionProxyDictionary = [:]），请求超时 8s / 整体 10s。
/// 真实请求头：User-Agent "AIQuotaBar/ClashIntegration"；secret 非空时附 Authorization: Bearer。
/// 控制器仅允许回环地址——该安全校验在 ClashConfigurationDiscovery.ControllerUrl 中强制。
/// </summary>
public sealed class ClashApiClient : IDisposable
{
    private static readonly JsonSerializerOptions Json = QuotaJson.Default;

    private const string UserAgentHeaderValue = "AIQuotaBar/ClashIntegration";

    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(8);

    private static readonly TimeSpan ResourceTimeout = TimeSpan.FromSeconds(10);

    private static readonly Uri DefaultDelayTestTarget = new("https://chatgpt.com/");

    private readonly ClashControllerConfiguration _configuration;
    private readonly HttpClient _httpClient;

    public ClashApiClient(ClashControllerConfiguration configuration, HttpMessageHandler? messageHandler = null)
    {
        _configuration = configuration;
        var handler = messageHandler ?? new SocketsHttpHandler
        {
            UseProxy = false,
            UseCookies = false,
            ConnectTimeout = RequestTimeout,
        };
        _httpClient = new HttpClient(handler, disposeHandler: messageHandler is null)
        {
            Timeout = ResourceTimeout,
        };
    }

    public Task<ClashVersionResponse> GetVersionAsync(CancellationToken cancellationToken = default) =>
        GetAsync<ClashVersionResponse>(new[] { "version" }, cancellationToken);

    public Task<ClashConnectionsResponse> LoadConnectionsSnapshotAsync(CancellationToken cancellationToken = default) =>
        GetAsync<ClashConnectionsResponse>(new[] { "connections" }, cancellationToken);

    public async Task<ClashRouteSnapshot> LoadRouteSnapshotAsync(CancellationToken cancellationToken = default)
    {
        // Swift async let：/proxies 与 /rules 并发请求，随后合并解析。
        var proxiesTask = GetAsync<ClashProxiesResponse>(new[] { "proxies" }, cancellationToken);
        var rulesTask = GetAsync<ClashRulesResponse>(new[] { "rules" }, cancellationToken);
        var proxies = await proxiesTask.ConfigureAwait(false);
        var rules = await rulesTask.ConfigureAwait(false);

        var groupName = ClashOpenAIRouteResolver.ResolveGroupName(rules.Rules, proxies.Proxies);
        if (groupName is null ||
            !proxies.Proxies.TryGetValue(groupName, out var group) ||
            group.All is not { Count: > 0 })
        {
            throw new ClashIntegrationException(new ClashIntegrationError.StrategyGroupNotFound());
        }

        var routes = group.All
            .Select(name =>
            {
                proxies.Proxies.TryGetValue(name, out var proxy);
                return new ClashRoute(
                    Name: name,
                    Type: proxy?.Type ?? "Unknown",
                    Delay: proxy?.History is { Count: > 0 }
                        ? proxy.History[^1].Delay
                        : null,
                    IsSelected: name == group.Now);
            })
            .ToList();

        return new ClashRouteSnapshot(
            GroupName: groupName,
            SelectedRouteName: group.Now,
            Routes: ClashRouteSorter.Sorted(routes));
    }

    public Task<IReadOnlyDictionary<string, int>> TestGroupAsync(
        string groupName,
        Uri? targetUrl = null,
        int timeoutMilliseconds = 5_000,
        CancellationToken cancellationToken = default)
    {
        var queryItems = new[]
        {
            new KeyValuePair<string, string>("url", (targetUrl ?? DefaultDelayTestTarget).AbsoluteUri),
            new KeyValuePair<string, string>("timeout", timeoutMilliseconds.ToString(CultureInfo.InvariantCulture)),
            new KeyValuePair<string, string>("expected", "200-499"),
        };
        return GetAsync<IReadOnlyDictionary<string, int>>(
            new[] { "group", groupName, "delay" },
            cancellationToken,
            queryItems);
    }

    public async Task SelectRouteAsync(
        string routeName,
        string groupName,
        CancellationToken cancellationToken = default)
    {
        var request = MakeRequest(HttpMethod.Put, new[] { "proxies", groupName });
        var body = JsonSerializer.Serialize(new RouteSelection(routeName), Json);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");

        _ = await PerformAsync(request, cancellationToken).ConfigureAwait(false);
    }

    public void Dispose() => _httpClient.Dispose();

    private async Task<T> GetAsync<T>(
        string[] pathComponents,
        CancellationToken cancellationToken,
        KeyValuePair<string, string>[]? queryItems = null)
    {
        var request = MakeRequest(HttpMethod.Get, pathComponents, queryItems);
        var data = await PerformAsync(request, cancellationToken).ConfigureAwait(false);

        T? decoded;
        try
        {
            decoded = JsonSerializer.Deserialize<T>(data, Json);
        }
        catch (JsonException)
        {
            throw new ClashIntegrationException(new ClashIntegrationError.IncompatibleResponse());
        }

        return decoded ?? throw new ClashIntegrationException(new ClashIntegrationError.IncompatibleResponse());
    }

    private HttpRequestMessage MakeRequest(
        HttpMethod method,
        string[] pathComponents,
        KeyValuePair<string, string>[]? queryItems = null)
    {
        var requestUrl = BuildRequestUri(pathComponents, queryItems)
            ?? throw new ClashIntegrationException(
                new ClashIntegrationError.InvalidControllerAddress(_configuration.BaseUrl.ToString()));

        var request = new HttpRequestMessage(method, requestUrl);
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgentHeaderValue);
        if (_configuration.Secret.Length > 0)
        {
            request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {_configuration.Secret}");
        }

        return request;
    }

    private Uri? BuildRequestUri(string[] pathComponents, KeyValuePair<string, string>[]? queryItems)
    {
        var builder = new StringBuilder(_configuration.BaseUrl.AbsoluteUri.TrimEnd('/'));
        foreach (var component in pathComponents)
        {
            builder.Append('/').Append(Uri.EscapeDataString(component));
        }

        if (queryItems is { Length: > 0 })
        {
            builder.Append('?');
            for (var index = 0; index < queryItems.Length; index++)
            {
                if (index > 0)
                {
                    builder.Append('&');
                }

                builder
                    .Append(Uri.EscapeDataString(queryItems[index].Key))
                    .Append('=')
                    .Append(Uri.EscapeDataString(queryItems[index].Value));
            }
        }

        return Uri.TryCreate(builder.ToString(), UriKind.Absolute, out var uri) ? uri : null;
    }

    private async Task<byte[]> PerformAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _httpClient
                .SendAsync(request, cancellationToken)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
                var message = DecodeFailureMessage(body)
                    ?? response.ReasonPhrase
                    ?? string.Empty;
                throw new ClashIntegrationException(
                    new ClashIntegrationError.ApiFailure((int)response.StatusCode, message));
            }

            return await response.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ClashIntegrationException)
        {
            throw;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // 调用方主动取消：原样上抛（Swift 端无 CancellationToken 概念，此为 .NET 端语义）。
            throw;
        }
        catch (OperationCanceledException)
        {
            // HttpClient.Timeout（整体 10s）到点：映射为控制器不可用。
            throw new ClashIntegrationException(new ClashIntegrationError.ControllerUnavailable());
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException)
        {
            throw new ClashIntegrationException(new ClashIntegrationError.ControllerUnavailable());
        }
    }

    private static string? DecodeFailureMessage(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind == JsonValueKind.Object &&
                document.RootElement.TryGetProperty("message", out var message) &&
                message.ValueKind == JsonValueKind.String)
            {
                return message.GetString();
            }
        }
        catch (JsonException)
        {
            // 非 JSON 错误体：回退 HTTP ReasonPhrase。
        }

        return null;
    }

    private sealed record RouteSelection(string Name);
}
