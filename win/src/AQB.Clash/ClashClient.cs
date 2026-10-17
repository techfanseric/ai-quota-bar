using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Clash;

/// <summary>
/// REST client for the Clash/mihomo external controller. Bearer auth, fixed user agent,
/// 8 second timeout and system proxy bypass. Only loopback endpoints should be handed in.
/// </summary>
public sealed class ClashClient : IDisposable
{
    public const string UserAgent = "AIQuotaBar/1.0";

    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(8);

    private readonly HttpClient _http;
    private readonly Uri _baseUri;

    public string Secret { get; }

    public ClashClient(ClashEndpoint endpoint, HttpMessageHandler? handler = null)
    {
        if (!endpoint.IsUsable)
        {
            throw new ArgumentException(
                $"Clash endpoint is not usable: {endpoint.DisabledReason ?? "missing base URL"}",
                nameof(endpoint));
        }

        _baseUri = endpoint.BaseUri;
        Secret = endpoint.Secret ?? "";
        var inner = handler ?? new SocketsHttpHandler
        {
            UseProxy = false,
            UseCookies = false,
        };
        _http = new HttpClient(inner, disposeHandler: true)
        {
            Timeout = Timeout,
        };
        _http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", UserAgent);
        if (Secret.Length > 0)
        {
            _http.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", "Bearer " + Secret);
        }
    }

    /// <summary>GET /version — also used as the controller liveness probe.</summary>
    public async Task<ClashVersion> GetVersionAsync(CancellationToken cancellationToken = default)
    {
        var root = await GetJsonAsync(BuildUri("version"), cancellationToken);
        var version = root.GetString("version");
        if (string.IsNullOrEmpty(version))
        {
            throw new ClashApiException(ClashApiException.IncompatibleResponse, 0, "version missing");
        }

        return new ClashVersion
        {
            Meta = root?["meta"] is null ? null : root.GetBool("meta"),
            Version = version,
        };
    }

    /// <summary>GET /proxies — full proxy/group tree keyed by name.</summary>
    public async Task<IReadOnlyDictionary<string, ClashProxy>> GetProxiesAsync(CancellationToken cancellationToken = default)
    {
        var root = await GetJsonAsync(BuildUri("proxies"), cancellationToken);
        var proxiesNode = root?["proxies"] as JsonObject;
        var result = new Dictionary<string, ClashProxy>(StringComparer.Ordinal);
        if (proxiesNode is null)
        {
            return result;
        }

        foreach (var (name, node) in proxiesNode)
        {
            if (node is null)
            {
                continue;
            }

            result[name] = ParseProxy(node);
        }

        return result;
    }

    /// <summary>GET /rules — rule list in evaluation order.</summary>
    public async Task<IReadOnlyList<ClashRule>> GetRulesAsync(CancellationToken cancellationToken = default)
    {
        var root = await GetJsonAsync(BuildUri("rules"), cancellationToken);
        var rulesNode = root?["rules"] as JsonArray;
        var result = new List<ClashRule>();
        if (rulesNode is null)
        {
            return result;
        }

        foreach (var node in rulesNode)
        {
            if (node is null)
            {
                continue;
            }

            result.Add(new ClashRule
            {
                Type = node.GetString("type"),
                Payload = node.GetString("payload"),
                Proxy = node.GetString("proxy"),
            });
        }

        return result;
    }

    /// <summary>PUT /proxies/{group} with {"name": name}. Any 2xx counts as success.</summary>
    public async Task SelectProxyAsync(string group, string name, CancellationToken cancellationToken = default)
    {
        var uri = BuildUri("proxies/" + Uri.EscapeDataString(group));
        var body = new JsonObject { ["name"] = name };
        using var request = new HttpRequestMessage(HttpMethod.Put, uri)
        {
            Content = new StringContent(body.ToJsonString(Json.SnakeCase), Encoding.UTF8, "application/json"),
        };

        await SendAsync(request, cancellationToken);
    }

    /// <summary>GET /group/{group}/delay — group wide latency test. Missing nodes are absent from the result.</summary>
    public async Task<IReadOnlyDictionary<string, int>> TestGroupDelayAsync(
        string group,
        string url = "https://chatgpt.com/",
        int timeoutMs = 5000,
        string expected = "200-499",
        CancellationToken cancellationToken = default)
    {
        var path = "group/" + Uri.EscapeDataString(group) + "/delay";
        var query = "url=" + Uri.EscapeDataString(url)
            + "&timeout=" + timeoutMs
            + "&expected=" + Uri.EscapeDataString(expected);
        var root = await GetJsonAsync(BuildUri(path, query), cancellationToken);

        var result = new Dictionary<string, int>(StringComparer.Ordinal);
        if (root is JsonObject obj)
        {
            foreach (var (name, node) in obj)
            {
                if (node is null)
                {
                    continue;
                }

                result[name] = ToInt32(node);
            }
        }

        return result;
    }

    private static int ToInt32(JsonNode node)
    {
        try
        {
            return (int)node.GetValue<long>();
        }
        catch (Exception e) when (e is InvalidOperationException or FormatException)
        {
            return long.TryParse(node.ToString(), out var parsed) ? (int)parsed : 0;
        }
    }

    internal Uri BuildUri(string relativePath, string? query = null)
    {
        var builder = new UriBuilder(_baseUri)
        {
            Path = _baseUri.AbsolutePath.TrimEnd('/') + "/" + relativePath,
            Query = query ?? "",
        };
        return builder.Uri;
    }

    private static ClashProxy ParseProxy(JsonNode node)
    {
        IReadOnlyList<string>? all = null;
        if (node["all"] is JsonArray allArray)
        {
            all = allArray.Where(item => item is not null).Select(item => item!.ToString()).ToArray();
        }

        IReadOnlyList<ClashProxyHistory>? history = null;
        if (node["history"] is JsonArray historyArray)
        {
            history = historyArray
                .Where(item => item is not null)
                .Select(item => new ClashProxyHistory
                {
                    Time = item!["time"] is null ? null : item.GetString("time"),
                    Delay = (int)item!.GetLong("delay"),
                })
                .ToArray();
        }

        return new ClashProxy
        {
            Name = node["name"] is null ? null : node.GetString("name"),
            Type = node.GetString("type"),
            Now = node["now"] is null ? null : node.GetString("now"),
            All = all,
            History = history,
        };
    }

    private async Task<JsonNode?> GetJsonAsync(Uri uri, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        var content = await SendAsync(request, cancellationToken);
        try
        {
            return JsonNode.Parse(content);
        }
        catch (JsonException e)
        {
            throw new ClashApiException(ClashApiException.IncompatibleResponse, 0, e.Message);
        }
    }

    private async Task<string> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e) when (e is HttpRequestException or SocketException or OperationCanceledException)
        {
            throw new ClashApiException(ClashApiException.ControllerUnavailable, 0, e.Message);
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var message = await TryReadErrorMessageAsync(response, cancellationToken)
                    ?? $"HTTP {(int)response.StatusCode}";
                throw new ClashApiException(ClashApiException.ApiFailure, (int)response.StatusCode, message);
            }

            return await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private static async Task<string?> TryReadErrorMessageAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var node = JsonNode.Parse(body);
            var message = node?.GetString("message");
            return string.IsNullOrEmpty(message) ? null : message;
        }
        catch
        {
            return null;
        }
    }

    public void Dispose() => _http.Dispose();
}
