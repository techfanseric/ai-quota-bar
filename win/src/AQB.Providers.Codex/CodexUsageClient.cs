using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Providers.Codex;

public sealed class CodexUsageResult
{
    /// <summary>The auth used for the (possibly refreshed) successful request.</summary>
    public required CodexAuthInfo Auth { get; init; }

    public required IReadOnlyList<QuotaWindowSample> Windows { get; init; }

    public string? PlanTitle { get; init; }

    public string? AccountId { get; init; }

    /// <summary>Fetch wall-clock time (never reset_at; a weekly reset lies in the future).</summary>
    public DateTimeOffset CapturedAtUtc { get; init; }
}

/// <summary>
/// Fetches ChatGPT Codex rate limits: GET {base}/backend-api/wham/usage with a Bearer access
/// token and ChatGPT-Account-Id header. On 401 the token is refreshed once and the request
/// retried. Window roles are normalized: 18000s → primary "5h", 604800s → secondary "Weekly",
/// swapped/misplaced roles in the response are exchanged automatically.
/// </summary>
public sealed class CodexUsageClient
{
    public const string DefaultBaseUrl = "https://chatgpt.com";
    public const long PrimaryWindowSeconds = 18000;
    public const long WeeklyWindowSeconds = 604800;

    private readonly HttpClient _http;
    private readonly CodexTokenRefresher _refresher;

    public CodexUsageClient(HttpMessageHandler? handler = null, string? codexHome = null, string? baseUrl = null)
    {
        BaseUrl = NormalizeBaseUrl(string.IsNullOrWhiteSpace(baseUrl) ? DefaultBaseUrl : baseUrl);
        UsageUrl = BaseUrl.Contains("/backend-api", StringComparison.Ordinal)
            ? BaseUrl + "/wham/usage"
            : BaseUrl + "/backend-api/wham/usage";

        var effectiveHandler = handler ?? CodexHttp.CreateDefaultHandler();
        _http = new HttpClient(effectiveHandler, disposeHandler: false)
        {
            Timeout = TimeSpan.FromSeconds(30),
        };
        _refresher = new CodexTokenRefresher(effectiveHandler, codexHome);
    }

    public string BaseUrl { get; }

    public string UsageUrl { get; }

    public async Task<CodexUsageResult> FetchAsync(CodexAuthInfo auth, CancellationToken cancellationToken = default)
    {
        var (status, body) = await SendAsync(auth, cancellationToken).ConfigureAwait(false);
        if (status == HttpStatusCode.Unauthorized)
        {
            if (auth.HasApiKey)
            {
                // API key mode never refreshes tokens.
                throw new CodexAuthException("Codex usage request was unauthorized (401).");
            }

            auth = await _refresher.RefreshAsync(auth, cancellationToken).ConfigureAwait(false);
            (status, body) = await SendAsync(auth, cancellationToken).ConfigureAwait(false);
            if (status == HttpStatusCode.Unauthorized)
            {
                throw new CodexAuthException("Codex token expired — run codex to refresh", requiresRelogin: true);
            }
        }

        if ((int)status < 200 || (int)status >= 300)
        {
            throw new CodexException($"Codex usage request failed (HTTP {(int)status}).");
        }

        return Parse(auth, body);
    }

    private static string NormalizeBaseUrl(string baseUrl) => baseUrl.TrimEnd('/');

    private async Task<(HttpStatusCode Status, string Body)> SendAsync(CodexAuthInfo auth, CancellationToken cancellationToken)
    {
        var accessToken = CodexAuthStore.PeekToken(auth.RawJson, "access_token", "accessToken");
        if (accessToken is null)
        {
            throw new CodexAuthException(
                "Codex access token is missing — run codex to sign in.",
                requiresRelogin: true);
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.Add("ChatGPT-Account-Id", auth.AccountId);
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.Add("User-Agent", "AIQuotaBar");

        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        return (response.StatusCode, body);
    }

    internal static CodexUsageResult Parse(CodexAuthInfo auth, string body)
    {
        JsonObject root;
        try
        {
            if (JsonNode.Parse(body) is not JsonObject parsed)
            {
                throw new CodexException("Codex usage response is not a JSON object.");
            }

            root = parsed;
        }
        catch (Exception e) when (e is JsonException or ArgumentException)
        {
            throw new CodexException("Codex usage response is not valid JSON.");
        }

        var captured = DateTimeOffset.UtcNow;
        var rateLimit = root["rate_limit"] as JsonObject;
        var primary = ParseWindow(rateLimit?["primary_window"], QuotaWindowRole.Primary, captured);
        var secondary = ParseWindow(rateLimit?["secondary_window"], QuotaWindowRole.Secondary, captured);

        // Role normalization: the 5h window is always primary, weekly always secondary,
        // regardless of which slot the response put them in. Unknown windows keep their slot.
        QuotaWindowSample? fiveHour = null;
        QuotaWindowSample? weekly = null;
        var extras = new List<QuotaWindowSample>();
        foreach (var window in new[] { primary, secondary })
        {
            if (window is null)
            {
                continue;
            }

            if (window.WindowSeconds == PrimaryWindowSeconds && fiveHour is null)
            {
                fiveHour = window;
            }
            else if (window.WindowSeconds == WeeklyWindowSeconds && weekly is null)
            {
                weekly = window;
            }
            else
            {
                extras.Add(window);
            }
        }

        var windows = new List<QuotaWindowSample>();
        if (fiveHour is not null)
        {
            windows.Add(fiveHour);
        }

        if (weekly is not null)
        {
            windows.Add(weekly);
        }

        windows.AddRange(extras);

        var planType = root.GetString("plan_type");
        var accountId = root.GetString("account_id");

        return new CodexUsageResult
        {
            Auth = auth,
            Windows = windows,
            PlanTitle = string.IsNullOrWhiteSpace(planType) ? null : planType,
            AccountId = string.IsNullOrWhiteSpace(accountId) ? null : accountId,
            CapturedAtUtc = captured,
        };
    }

    private static QuotaWindowSample? ParseWindow(JsonNode? node, QuotaWindowRole fallbackRole, DateTimeOffset captured)
    {
        if (node is not JsonObject)
        {
            return null;
        }

        if (node["used_percent"] is null || node["reset_at"] is null)
        {
            return null;
        }

        var used = Math.Clamp(node.GetDouble("used_percent"), 0, 100);
        var windowSeconds = node.GetLong("limit_window_seconds", 0);
        var resetsAt = DateTimeOffset.FromUnixTimeSeconds(node.GetLong("reset_at"));

        var (role, name) = windowSeconds switch
        {
            PrimaryWindowSeconds => (QuotaWindowRole.Primary, "5h"),
            WeeklyWindowSeconds => (QuotaWindowRole.Secondary, "Weekly"),
            _ => (fallbackRole, FallbackWindowName(windowSeconds)),
        };

        return new QuotaWindowSample
        {
            Role = role,
            Name = name,
            WindowSeconds = windowSeconds,
            UsedPercent = used,
            ResetsAtUtc = resetsAt,
            CapturedAtUtc = captured,
        };
    }

    private static string FallbackWindowName(long seconds)
    {
        if (seconds > 0 && seconds % 3600 == 0)
        {
            return $"{seconds / 3600}h";
        }

        if (seconds > 0 && seconds % 60 == 0)
        {
            return $"{seconds / 60}m";
        }

        return "Window";
    }
}
