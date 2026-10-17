using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Team;

/// <summary>
/// Client for the public /v1/watch/* endpoints (share-your-quota by email). The token is the
/// app's built-in public service token — it is not authentication; the real authorization is
/// the owner ticking specific emails in settings. Mirrors CodexWatchCloudClient.swift.
/// </summary>
public sealed class CodexWatchClient : IDisposable
{
    public const string DefaultEndpointUrl = "https://ai-quota-bar.pages.dev";

    public const string ServiceToken = "d7dac44143ffaa6e1fe1237add43723dcc10ce72330410483a49de8c8d62c038";

    private readonly HttpClient _http;

    public CodexWatchClient(string publisherId, string? endpointUrl = null, HttpMessageHandler? handler = null)
    {
        PublisherId = publisherId;
        var baseUrl = (endpointUrl ?? DefaultEndpointUrl).TrimEnd('/');
        _http = handler is null
            ? new HttpClient { Timeout = TimeSpan.FromSeconds(8) }
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(8) };
        _http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", ServiceToken);
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("AIQuotaBar");
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        BaseUrl = baseUrl;
    }

    public string PublisherId { get; }

    public string BaseUrl { get; }

    /// <summary>
    /// Publishes the locally ticked accounts. Full-replace semantics: an empty list cancels
    /// all sharing. Returns false on any failure (the caller then keeps the previous state).
    /// </summary>
    public async Task<bool> PublishAsync(IReadOnlyList<CodexWatchAccountSnapshot> snapshots, CancellationToken cancellationToken = default)
    {
        try
        {
            var body = new JsonObject
            {
                ["publisher"] = PublisherId,
                ["accounts"] = new JsonArray(
                    snapshots.Select(entry => (JsonNode)new JsonObject
                    {
                        ["account"] = entry.Account,
                        ["plan"] = entry.Plan is null ? null : JsonValue.Create(entry.Plan),
                        ["windows"] = new JsonArray(
                            entry.Windows.Select(window => (JsonNode)new JsonObject
                            {
                                ["name"] = window.Name,
                                ["remainingPercent"] = window.RemainingPercent,
                                ["resetsAt"] = ToJsonDate(window.ResetsAt),
                                ["sampledAt"] = ToJsonDate(window.SampledAt),
                                ["startsAt"] = ToJsonDate(window.StartsAt),
                            }).ToArray()),
                    }).ToArray()),
            };
            using var content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            using var response = await _http.PostAsync(BaseUrl + "/v1/watch/publish", content, cancellationToken);
            return response.IsSuccessStatusCode;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            return false;
        }
    }

    public async Task<WatchFetchResult> FetchAsync(string account, CancellationToken cancellationToken = default)
    {
        var normalized = WatchAccount.Normalize(account);
        if (!WatchAccount.IsValidAccountName(normalized))
        {
            return WatchFetchResult.NotShared();
        }

        try
        {
            using var response = await _http.GetAsync(
                BaseUrl + "/v1/watch/quota?email=" + Uri.EscapeDataString(normalized), cancellationToken);
            switch ((int)response.StatusCode)
            {
                case 200:
                    var payload = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
                    if (payload is null)
                    {
                        return WatchFetchResult.Unreachable("invalid_response");
                    }

                    return WatchFetchResult.Available(DecodeSnapshot(payload, normalized));

                case 404:
                    return WatchFetchResult.NotShared();

                case 410:
                    return WatchFetchResult.Stale(normalized);

                default:
                    return WatchFetchResult.Unreachable("http_" + (int)response.StatusCode);
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return WatchFetchResult.Unreachable("offline");
        }
    }

    /// <summary>Read counts for the given (shared) accounts, keyed by normalized email.</summary>
    public async Task<Dictionary<string, CodexWatchReadCount>> FetchReadCountsAsync(
        IReadOnlyList<string> accounts,
        CancellationToken cancellationToken = default)
    {
        var result = new Dictionary<string, CodexWatchReadCount>();
        if (accounts.Count == 0)
        {
            return result;
        }

        var wanted = new Dictionary<string, string>();
        foreach (var account in accounts)
        {
            if (WatchAccount.AccountKey(account) is { } key)
            {
                wanted[key] = WatchAccount.Normalize(account);
            }
        }

        if (wanted.Count == 0)
        {
            return result;
        }

        try
        {
            using var response = await _http.GetAsync(
                BaseUrl + "/v1/watch/reads?publisher=" + Uri.EscapeDataString(PublisherId), cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return result;
            }

            var payload = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            if (payload?["accounts"] is not JsonArray entries)
            {
                return result;
            }

            foreach (var entry in entries)
            {
                var key = entry.GetString("account_key");
                if (key is null || !wanted.TryGetValue(key, out var email))
                {
                    continue;
                }

                result[email] = new CodexWatchReadCount(
                    entry.GetLong("read_count"),
                    ParseDate(entry.GetString("last_read_at")),
                    entry.GetBool("stale"));
            }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            // Read counts are best-effort; failures leave the previous values.
        }

        return result;
    }

    internal static CodexWatchSnapshot DecodeSnapshot(JsonNode payload, string fallbackAccount)
    {
        var windows = new List<CodexWatchWindow>();
        if (payload["windows"] is JsonArray windowArray)
        {
            foreach (var window in windowArray)
            {
                var name = window.GetString("name");
                var remaining = (int)window.GetLong("remainingPercent");
                var resetsAt = ParseDate(window.GetString("resetsAt"));
                var sampledAt = ParseDate(window.GetString("sampledAt"));
                var startsAt = ParseDate(window.GetString("startsAt"));
                var now = DateTimeOffset.UtcNow;

                // Read-side defenses (mirror the macOS client):
                // 1. A future sampledAt is untrustworthy — fall back to publishedAt.
                if (sampledAt is { } sampled && sampled > now + TimeSpan.FromMinutes(1)
                    && ParseDate(payload.GetString("updated_at")) is { } published)
                {
                    sampledAt = published;
                }

                // 2. Missing startsAt on weekly windows is derived from resetsAt − 7d;
                //    a derived start in the future means bad data and is dropped.
                if (startsAt is null && resetsAt is { } reset
                    && (name?.Contains("weekly", StringComparison.OrdinalIgnoreCase) == true || name == "7d"))
                {
                    var derived = reset.AddDays(-7);
                    if (derived <= now)
                    {
                        startsAt = derived;
                    }
                }

                windows.Add(new CodexWatchWindow(name ?? "", remaining, resetsAt, sampledAt, startsAt));
            }
        }

        var account = payload.GetString("account");
        return new CodexWatchSnapshot(
            string.IsNullOrEmpty(account) ? fallbackAccount : account,
            payload["plan"] is null ? null : payload.GetString("plan"),
            windows,
            ParseDate(payload.GetString("updated_at")));
    }

    internal static string? ToJsonDate(DateTimeOffset? value) => value is { } date
        ? TimeText.FixedIso(date)
        : null;

    internal static DateTimeOffset? ParseDate(string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return null;
        }

        return TimeText.TryParseIso(value, out var parsed) ? parsed : null;
    }

    public void Dispose() => _http.Dispose();
}
