using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Providers.GlmMiniMax;

/// <summary>
/// Available GLM personal-plan reset tickets (spec §2.5). Count of usable five-hour/week
/// resets plus the earliest expiry among them. Requests are strictly gated to verified
/// hosts (personal scope only) and every failure is silent (null) — allowances never
/// affect the quota fetch.
/// </summary>
public sealed record GlmResetAllowances(
    int FiveHourAvailable,
    int WeekAvailable,
    DateTimeOffset? NearestExpiryUtc)
{
    public int TotalAvailable => FiveHourAvailable + WeekAvailable;

    public const string Endpoint = "https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL";

    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(2);

    /// <summary>
    /// Sends the request only when the credential is a personal-scope web session: https,
    /// host exactly bigmodel.cn (no port), path exactly /api/monitor/usage/quota/limit,
    /// no type!=1 query parameter, and no organization/project (field and header both).
    /// Only the Authorization header travels on the request.
    /// </summary>
    public static async Task<GlmResetAllowances?> TryFetchAsync(
        GlmImportedCredential credential,
        HttpMessageHandler? handler = null,
        CancellationToken cancellationToken = default)
    {
        if (!ShouldRequest(credential))
        {
            return null;
        }

        try
        {
            using var client = new HttpClient(handler ?? new HttpClientHandler())
            {
                Timeout = Timeout.InfiniteTimeSpan,
            };
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.TryAddWithoutValidation("Authorization", credential.Authorization ?? "");

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(RequestTimeout);
            using var response = await client.SendAsync(request, timeoutCts.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var body = await response.Content.ReadAsStringAsync(timeoutCts.Token).ConfigureAwait(false);
            return Parse(body);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Silent by contract (spec §2.5): failures never surface.
            return null;
        }
    }

    /// <summary>Pure gate check — exposed for tests without any HTTP traffic.</summary>
    public static bool ShouldRequest(GlmImportedCredential credential)
    {
        if (!Uri.TryCreate(credential.ApiUrl, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps)
        {
            return false;
        }

        if (!string.Equals(uri.Host, "bigmodel.cn", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (uri.Port != 443)
        {
            return false;
        }

        if (!string.Equals(uri.AbsolutePath, "/api/monitor/usage/quota/limit", StringComparison.Ordinal))
        {
            return false;
        }

        var query = uri.Query.TrimStart('?');
        if (query.Length > 0)
        {
            foreach (var part in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var pair = part.Split('=', 2);
                if (pair[0] == "type" && (pair.Length < 2 || pair[1] != "1"))
                {
                    return false;
                }
            }
        }

        if (!string.IsNullOrEmpty(credential.Organization) || !string.IsNullOrEmpty(credential.Project))
        {
            return false;
        }

        if (credential.Headers.TryGetValue("bigmodel-organization", out var organization) && !string.IsNullOrEmpty(organization))
        {
            return false;
        }

        if (credential.Headers.TryGetValue("bigmodel-project", out var project) && !string.IsNullOrEmpty(project))
        {
            return false;
        }

        return true;
    }

    /// <summary>Pure parser: code 200 + success + PERSONAL + non-null fiveHourResets/weekResets.</summary>
    public static GlmResetAllowances? Parse(string json)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json ?? "");
        }
        catch (JsonException)
        {
            return null;
        }

        if (root.OptLong("code") != 200)
        {
            return null;
        }

        if (root?["success"]?.ToString() is not { } successText || !bool.TryParse(successText, out var success) || !success)
        {
            return null;
        }

        var data = root?["data"];
        if (data.OptString("targetType") != "PERSONAL")
        {
            return null;
        }

        var fiveHour = data?["fiveHourResets"] as JsonArray;
        var week = data?["weekResets"] as JsonArray;
        if (fiveHour is null || week is null)
        {
            return null;
        }

        var fiveHourAvailable = CountAvailable(fiveHour, out var nearest1);
        var weekAvailable = CountAvailable(week, out var nearest2);
        var candidates = new[] { nearest1, nearest2 }.Where(t => t.HasValue).Select(t => t!.Value).ToList();
        return new GlmResetAllowances(
            fiveHourAvailable,
            weekAvailable,
            candidates.Count > 0 ? candidates.Min() : null);
    }

    private static int CountAvailable(JsonArray resets, out DateTimeOffset? nearestExpiry)
    {
        nearestExpiry = null;
        var count = 0;
        foreach (var entry in resets)
        {
            var available = entry?["available"]?.ToString() is { } text && bool.TryParse(text, out var flag) && flag;
            if (!available)
            {
                continue;
            }

            count++;
            var expireText = entry.OptString("expireTime");
            if (expireText is not null && ShanghaiTime.TryParseStrict(expireText, out var parsed))
            {
                if (nearestExpiry is null || parsed < nearestExpiry)
                {
                    nearestExpiry = parsed;
                }
            }
        }

        return count;
    }
}
