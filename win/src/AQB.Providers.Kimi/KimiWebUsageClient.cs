using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Providers.Kimi;

/// <summary>Parsed Kimi web quota result: 5h + weekly coding windows plus the monthly "Total usage" window.</summary>
public sealed class KimiWebUsageResult
{
    /// <summary>Short window from limits[] where window == 300 minutes (secondary).</summary>
    public QuotaWindowSample? FiveHour { get; init; }

    /// <summary>Weekly FEATURE_CODING window from the top-level detail (primary, 7d).</summary>
    public QuotaWindowSample? Weekly { get; init; }

    /// <summary>kimi-monthly "Total usage" window from GetSubscriptionStats. StartsAtUtc is always null
    /// (never inferred); the monthly cycle window is derived by the snapshot layer instead.</summary>
    public QuotaWindowSample? MonthlyTotal { get; init; }

    public string Origin { get; init; } = "";

    public DateTimeOffset CapturedAtUtc { get; init; }

    public string? SubscribeTitle { get; init; }

    public DateTimeOffset? SubscribeEndUtc { get; init; }

    /// <summary>Display order per spec §1.8: short window, weekly, extras.</summary>
    public IReadOnlyList<QuotaWindowSample> Windows
    {
        get
        {
            var list = new List<QuotaWindowSample>(3);
            if (FiveHour is not null)
            {
                list.Add(FiveHour);
            }

            if (Weekly is not null)
            {
                list.Add(Weekly);
            }

            if (MonthlyTotal is not null)
            {
                list.Add(MonthlyTotal);
            }

            return list;
        }
    }
}

/// <summary>
/// Kimi web/desktop quota client (spec §1.7). Two Connect-protocol JSON POSTs against the
/// session origin: GetUsages (main, 3s timeout) and the optional GetSubscriptionStats
/// (membership, 3s, failures swallowed). Redirects are disabled so a 30x can never carry
/// the Authorization/Cookie headers to another host; any 3xx surfaces as "Kimi HTTP &lt;code&gt;".
/// </summary>
public sealed class KimiWebUsageClient : IDisposable
{
    public const string UsagePath = "/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages";
    public const string SubscriptionStatsPath = "/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats";

    /// <summary>Task-mandated 3s per-request timeout (macOS used 20s; see win-migration task A.1).</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(3);

    private readonly HttpClient _client;
    private readonly TimeSpan _timeout;

    public KimiWebUsageClient(HttpMessageHandler? handler = null, TimeSpan? timeout = null)
    {
        if (handler is HttpClientHandler httpClientHandler)
        {
            httpClientHandler.AllowAutoRedirect = false;
            httpClientHandler.UseCookies = false;
        }

        _client = new HttpClient(handler ?? new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseCookies = false,
        })
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        _timeout = timeout ?? DefaultTimeout;
    }

    public async Task<KimiWebUsageResult> FetchAsync(KimiWebCredential credential, CancellationToken cancellationToken = default)
    {
        credential.ValidateWebSession();

        var usageBody = await PostAsync(credential, UsagePath, "{\"scope\":[\"FEATURE_CODING\"]}", mustSucceed: true, cancellationToken)
            .ConfigureAwait(false) ?? throw new KimiWebException(KimiWebErrorKind.InvalidResponse, "Kimi usage response was empty.");

        string? statsBody = null;
        try
        {
            statsBody = await PostAsync(credential, SubscriptionStatsPath, "{}", mustSucceed: false, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Membership stats are optional and must never affect the main quota (spec §1.7).
        }

        return Parse(usageBody, statsBody, DateTimeOffset.UtcNow, credential.Origin);
    }

    public void Dispose() => _client.Dispose();

    private async Task<string?> PostAsync(
        KimiWebCredential credential,
        string path,
        string jsonBody,
        bool mustSucceed,
        CancellationToken cancellationToken)
    {
        var uri = new Uri(credential.Origin.TrimEnd('/') + path, UriKind.Absolute);
        using var request = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = new StringContent(jsonBody, Encoding.UTF8, "application/json"),
        };
        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + credential.Token);
        request.Headers.TryAddWithoutValidation("Cookie", "kimi-auth=" + credential.Token);
        request.Headers.TryAddWithoutValidation("Origin", credential.Origin);
        request.Headers.TryAddWithoutValidation("Referer", credential.Origin.TrimEnd('/') + "/code/console");
        request.Headers.TryAddWithoutValidation("connect-protocol-version", "1");

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_timeout);
        HttpResponseMessage response;
        try
        {
            response = await _client.SendAsync(request, timeoutCts.Token).ConfigureAwait(false);
        }
        catch (HttpRequestException e)
        {
            throw new KimiWebException(KimiWebErrorKind.NetworkError, "Kimi 网络请求失败 / Kimi network request failed.", e);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new KimiWebException(KimiWebErrorKind.NetworkError, "Kimi 请求超时 / Kimi request timed out.");
        }

        using (response)
        {
            var code = (int)response.StatusCode;
            if (code == 401 || code == 403)
            {
                // Never include the response body or auth headers in the message.
                throw new KimiWebException(
                    KimiWebErrorKind.SessionExpired,
                    "Kimi 会话已过期,请重新登录 / Kimi session expired, please sign in again.");
            }

            if (!response.IsSuccessStatusCode)
            {
                if (!mustSucceed)
                {
                    return null;
                }

                throw new KimiWebException(KimiWebErrorKind.HttpError, $"Kimi HTTP {code}");
            }

            return await response.Content.ReadAsStringAsync(timeoutCts.Token).ConfigureAwait(false);
        }
    }

    /// <summary>Pure parser over the two response bodies; exposed for fixture-based tests.</summary>
    public static KimiWebUsageResult Parse(string usageJson, string? statsJson, DateTimeOffset now, string origin = "")
    {
        JsonNode? usageRoot;
        try
        {
            usageRoot = JsonNode.Parse(usageJson ?? "");
        }
        catch (JsonException e)
        {
            throw new KimiWebException(KimiWebErrorKind.InvalidResponse, "Kimi usage response was not valid JSON.", e);
        }

        var coding = FindCodingUsage(usageRoot?["usages"] as JsonArray);
        var weekly = ParseWeeklyWindow(coding?["detail"], now);
        var fiveHour = ParseLimitsWindow(coding?["limits"] as JsonArray, now);

        JsonNode? statsRoot = null;
        try
        {
            statsRoot = statsJson is null ? null : JsonNode.Parse(statsJson);
        }
        catch (JsonException)
        {
            // Stats parsing failures must not affect the main quota (spec §1.7).
        }

        var monthly = ParseMonthlyWindow(statsRoot, now, out var subscribeEndUtc);

        if (weekly is null && fiveHour is null && monthly is null)
        {
            throw new KimiWebException(KimiWebErrorKind.InvalidResponse, "Kimi usage response contained no quota windows.");
        }

        return new KimiWebUsageResult
        {
            FiveHour = fiveHour,
            Weekly = weekly,
            MonthlyTotal = monthly,
            Origin = origin,
            CapturedAtUtc = now,
            SubscribeTitle = ParseSubscribeTitle(statsRoot),
            SubscribeEndUtc = subscribeEndUtc,
        };
    }

    /// <summary>ISO8601 with/without milliseconds — falls back to the general parser and
    /// truncates sub-millisecond precision (Kimi emits microseconds like .007158).</summary>
    private static bool TryParseIsoFlexible(string text, out DateTimeOffset value)
    {
        if (TimeText.TryParseIso(text, out value))
        {
            return true;
        }

        if (DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            value = new DateTimeOffset(parsed.UtcTicks - parsed.UtcTicks % TimeSpan.TicksPerMillisecond, TimeSpan.Zero);
            return true;
        }

        return false;
    }

    private static JsonNode? FindCodingUsage(JsonArray? usages)
    {
        if (usages is null)
        {
            return null;
        }

        foreach (var usage in usages)
        {
            if (usage.OptString("scope") == "FEATURE_CODING")
            {
                return usage;
            }
        }

        return null;
    }

    /// <summary>Spec §1.7: numeric fields tolerate string/number; total must be finite &gt; 0.</summary>
    private static bool TryParseDetail(JsonNode? detail, DateTimeOffset now, out double usedPercent, out DateTimeOffset resetsAt)
    {
        usedPercent = 0;
        resetsAt = now;
        if (detail is null)
        {
            return false;
        }

        var limit = detail.OptDouble("limit");
        if (limit is null || limit <= 0)
        {
            return false;
        }

        var total = limit.Value;
        var used = detail.OptDouble("used");
        if (used is null || used < 0)
        {
            var remaining = detail.OptDouble("remaining");
            if (remaining is null || remaining < 0 || remaining > total)
            {
                return false;
            }

            used = total - remaining;
        }

        var resetTime = detail.OptString("resetTime");
        if (resetTime is not null && TryParseIsoFlexible(resetTime, out var parsed))
        {
            resetsAt = parsed;
        }

        usedPercent = Math.Min(100, used.Value / total * 100);
        return true;
    }

    private static QuotaWindowSample? ParseWeeklyWindow(JsonNode? detail, DateTimeOffset now)
    {
        if (!TryParseDetail(detail, now, out var usedPercent, out var resetsAt))
        {
            return null;
        }

        return new QuotaWindowSample
        {
            Role = QuotaWindowRole.Primary,
            Name = "7d",
            WindowSeconds = 10080 * 60L,
            UsedPercent = usedPercent,
            ResetsAtUtc = resetsAt,
            CapturedAtUtc = now,
            StartsAtUtc = null,
        };
    }

    /// <summary>Short window: first limits[] entry with window == 300 minutes, else the first entry.</summary>
    private static QuotaWindowSample? ParseLimitsWindow(JsonArray? limits, DateTimeOffset now)
    {
        if (limits is null || limits.Count == 0)
        {
            return null;
        }

        JsonNode? chosen = null;
        foreach (var entry in limits)
        {
            if (WindowMinutes(entry?["window"]) == 300)
            {
                chosen = entry;
                break;
            }
        }

        chosen ??= limits[0];

        var minutes = WindowMinutes(chosen?["window"]);
        var name = minutes is null
            ? "Rate limit" // unknown time unit degrades the model name (spec §1.7)
            : minutes.Value % 60 == 0 ? $"{minutes.Value / 60}h" : $"{minutes.Value}m";

        if (!TryParseDetail(chosen?["detail"], now, out var usedPercent, out var resetsAt))
        {
            return null;
        }

        return new QuotaWindowSample
        {
            Role = QuotaWindowRole.Secondary,
            Name = name,
            WindowSeconds = minutes.HasValue ? minutes.Value * 60L : 0,
            UsedPercent = usedPercent,
            ResetsAtUtc = resetsAt,
            CapturedAtUtc = now,
            StartsAtUtc = null,
        };
    }

    /// <summary>TIME_UNIT_MINUTE=1, TIME_UNIT_HOUR=60, TIME_UNIT_DAY=1440; anything else is unknown.</summary>
    private static int? WindowMinutes(JsonNode? window)
    {
        var duration = window.OptDouble("duration");
        if (duration is null || duration <= 0)
        {
            return null;
        }

        var factor = window.OptString("timeUnit") switch
        {
            "TIME_UNIT_MINUTE" => 1,
            "TIME_UNIT_HOUR" => 60,
            "TIME_UNIT_DAY" => 1440,
            _ => (int?)null,
        };
        if (factor is null)
        {
            return null;
        }

        var minutes = duration.Value * factor.Value;
        return minutes >= 1 && Math.Abs(minutes - Math.Round(minutes)) < 1e-9 ? (int)Math.Round(minutes) : null;
    }

    /// <summary>
    /// Monthly "Total usage" window from subscriptionBalance (spec §1.7): accepts feature == null or
    /// FEATURE_OMNI, type == null or SUBSCRIPTION, amountUsedRatio finite &gt;= 0. StartsAtUtc stays null
    /// (the monthly cycle start is derived by the snapshot layer, never fabricated here).
    /// </summary>
    private static QuotaWindowSample? ParseMonthlyWindow(JsonNode? statsRoot, DateTimeOffset now, out DateTimeOffset? subscribeEndUtc)
    {
        subscribeEndUtc = null;
        if (statsRoot is null)
        {
            return null;
        }

        var balanceNode = statsRoot["subscriptionBalance"];
        var balances = balanceNode is JsonArray array ? array : (IEnumerable<JsonNode?>)new[] { balanceNode };
        foreach (var balance in balances)
        {
            if (balance is null)
            {
                continue;
            }

            var expireText = balance.OptString("expireTime");
            if (expireText is not null && TryParseIsoFlexible(expireText, out var expire) && subscribeEndUtc is null)
            {
                subscribeEndUtc = expire;
            }

            var feature = balance.OptString("feature");
            if (feature is not null && feature != "FEATURE_OMNI")
            {
                continue;
            }

            var type = balance.OptString("type");
            if (type is not null && type != "SUBSCRIPTION")
            {
                continue;
            }

            var ratio = balance.OptDouble("amountUsedRatio");
            if (ratio is null || ratio < 0)
            {
                continue;
            }

            return new QuotaWindowSample
            {
                Role = QuotaWindowRole.Primary,
                Name = "Total usage",
                WindowSeconds = 0,
                UsedPercent = Math.Min(1, ratio.Value) * 100,
                ResetsAtUtc = subscribeEndUtc ?? now,
                CapturedAtUtc = now,
                StartsAtUtc = null,
            };
        }

        return null;
    }

    private static string? ParseSubscribeTitle(JsonNode? statsRoot)
    {
        if (statsRoot is null)
        {
            return null;
        }

        var candidates = new[]
        {
            statsRoot.OptString("title"),
            statsRoot["subscription"].OptString("title"),
            statsRoot["subscription"].OptString("name"),
            statsRoot["plan"].OptString("title"),
            statsRoot["plan"].OptString("name"),
            statsRoot.OptString("level"),
        };
        return candidates.FirstOrDefault(c => !string.IsNullOrWhiteSpace(c))?.Trim();
    }
}
