using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Providers.GlmMiniMax;

/// <summary>
/// GLM quota fetcher (spec §2.2/§2.3, task B.7). API-key mode GETs the open.bigmodel.cn
/// quota endpoint with a single Bearer; imported (cURL web session) mode GETs ApiUrl with
/// the full header set (defaults filled per §2.2 order). Missing reset data is never
/// fabricated: such windows get WindowSeconds = 0, ResetsAtUtc = default and a
/// "· no reset" Name annotation, so the snapshot layer skips pace for them.
/// </summary>
public sealed class GlmQuotaService
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30);
    public const string NoResetSuffix = " · no reset";

    private readonly GlmImportedCredential _credential;
    private readonly HttpClient _client;
    private readonly TimeSpan _timeout;

    public GlmQuotaService(GlmImportedCredential credential, HttpMessageHandler? handler = null, TimeSpan? timeout = null)
    {
        _credential = credential ?? throw new ArgumentNullException(nameof(credential));
        _client = new HttpClient(handler ?? new HttpClientHandler())
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        _timeout = timeout ?? DefaultTimeout;
    }

    /// <summary>API-key mode shorthand: open.bigmodel.cn endpoint + exactly one Bearer prefix.</summary>
    public static GlmQuotaService ForApiKey(string apiKey, HttpMessageHandler? handler = null, TimeSpan? timeout = null)
        => new(GlmImportedCredential.ForApiKey(apiKey), handler, timeout);

    public async Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, _credential.ApiUrl);
        ApplyHeaders(request, _credential);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(_timeout);
        HttpResponseMessage response;
        try
        {
            response = await _client.SendAsync(request, timeoutCts.Token).ConfigureAwait(false);
        }
        catch (HttpRequestException e)
        {
            return Failed("GLM 网络请求失败 / GLM network request failed: " + e.Message);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return Failed("GLM 请求超时 / GLM request timed out.");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return Failed($"GLM HTTP {(int)response.StatusCode}");
            }

            string body;
            try
            {
                body = await response.Content.ReadAsStringAsync(timeoutCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                return Failed("GLM 请求超时 / GLM request timed out.");
            }

            return ParseResponse(body, DateTimeOffset.UtcNow);
        }
    }

    /// <summary>Header application order per spec §2.2: user headers → defaults → org/project → cookie.</summary>
    public static void ApplyHeaders(HttpRequestMessage request, GlmImportedCredential credential)
    {
        foreach (var header in credential.Headers)
        {
            if (request.Headers.Contains(header.Key))
            {
                continue;
            }

            request.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }

        TryAddDefault(request, "Accept", "application/json, text/plain, */*");
        TryAddDefault(request, "Accept-Language", "zh");
        TryAddDefault(request, "Set-Language", "zh");
        if (!request.Headers.Contains("Authorization") && !string.IsNullOrWhiteSpace(credential.Authorization))
        {
            request.Headers.TryAddWithoutValidation("Authorization", credential.Authorization);
        }

        if (!string.IsNullOrWhiteSpace(credential.Organization))
        {
            TryAddDefault(request, "bigmodel-organization", credential.Organization);
        }

        if (!string.IsNullOrWhiteSpace(credential.Project))
        {
            TryAddDefault(request, "bigmodel-project", credential.Project);
        }

        if (!string.IsNullOrWhiteSpace(credential.Cookie))
        {
            request.Headers.TryAddWithoutValidation("Cookie", credential.Cookie);
        }
    }

    private static void TryAddDefault(HttpRequestMessage request, string name, string value)
    {
        if (!request.Headers.Contains(name))
        {
            request.Headers.TryAddWithoutValidation(name, value);
        }
    }

    /// <summary>Pure response parser over the quota JSON; exposed for fixture-based tests.</summary>
    public static ProviderSnapshot ParseResponse(string json, DateTimeOffset now)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(json ?? "");
        }
        catch (JsonException)
        {
            return Failed("GLM response was not valid JSON.");
        }

        var code = root.OptLong("code");
        var success = root?["success"]?.ToString() is { } successText && bool.TryParse(successText, out var flag) && flag;
        if (code != 200 || !success)
        {
            var message = root.OptString("msg");
            return Failed(string.IsNullOrWhiteSpace(message) ? "Unknown GLM API error." : message.Trim());
        }

        var data = root?["data"];
        var level = data.OptString("level");
        var limits = data?["limits"] as JsonArray;

        var windows = new List<QuotaWindowSample>();
        string? detailText = null;
        if (limits is not null)
        {
            foreach (var limit in limits)
            {
                var (window, detail) = NormalizeLimit(limit, now);
                if (window is null)
                {
                    continue;
                }

                windows.Add(window);
                detailText ??= detail;
            }
        }

        if (windows.Count == 0)
        {
            return Failed("GLM response contained no quota limits.");
        }

        // Menu order: 5h window first, then the rest.
        var ordered = windows
            .OrderByDescending(w => w.Role == QuotaWindowRole.Secondary)
            .ToList();

        return new ProviderSnapshot
        {
            Kind = ProviderKind.Glm,
            Status = ProviderStatus.Ok,
            LastUpdatedUtc = now,
            SubscribeTitle = string.IsNullOrWhiteSpace(level) ? null : level.Trim(),
            DetailText = detailText,
            Accounts = new[]
            {
                new ProviderAccountSnapshot
                {
                    AccountKey = "glm",
                    Label = "GLM",
                    SourceLabel = "GLM",
                    IsCurrent = true,
                    Windows = ordered,
                },
            },
        };
    }

    private static (QuotaWindowSample? window, string? detail) NormalizeLimit(JsonNode? limit, DateTimeOffset now)
    {
        if (limit is null)
        {
            return (null, null);
        }

        var type = limit.OptString("type") ?? "";
        var usage = limit.OptDouble("usage");
        var currentValue = limit.OptDouble("currentValue");
        var percentage = limit.OptDouble("percentage");
        var remaining = limit.OptDouble("remaining");
        var nextResetTime = limit.OptLong("nextResetTime");
        var unit = limit.OptLong("unit");
        var number = limit.OptLong("number");

        double usedPercent;
        double usedCount = 0;
        var countMode = false;
        if (usage is > 0 and < 2_000_000_000)
        {
            var total = Math.Round(usage.Value);
            if (total > 0)
            {
                countMode = true;
                if (currentValue.HasValue)
                {
                    // Server rounds currentValue/remaining independently; clamp both to [0, total].
                    usedCount = Math.Clamp(currentValue.Value, 0, total);
                }
                else
                {
                    var remainingClamped = remaining.HasValue
                        ? Math.Clamp(remaining.Value, 0, total)
                        : total;
                    usedCount = total - remainingClamped;
                }

                usedPercent = usedCount / total * 100;
            }
            else
            {
                usedPercent = 0;
            }
        }
        else
        {
            usedPercent = 0;
        }

        if (!countMode)
        {
            if (percentage.HasValue)
            {
                usedPercent = Math.Clamp(percentage.Value, 0, 100);
            }
            else
            {
                return (null, null);
            }
        }

        var name = $"{BaseName(type)} ({PeriodText(unit, number) ?? FallbackPeriod(type)})";
        var durationSeconds = DurationSeconds(unit, number, type);

        DateTimeOffset resetsAt;
        long windowSeconds;
        if (nextResetTime is > 0)
        {
            resetsAt = DateTimeOffset.FromUnixTimeMilliseconds(nextResetTime.Value);
            windowSeconds = durationSeconds;
        }
        else
        {
            // Never fabricate reset times: mark the window so the snapshot layer skips pace.
            resetsAt = default;
            windowSeconds = 0;
            name += NoResetSuffix;
        }

        var role = type == "CREDIT_LIMIT" && durationSeconds == 18000
            ? QuotaWindowRole.Secondary
            : QuotaWindowRole.Primary;

        var detail = BuildDetailText(percentage, countMode, usedCount, limit["usageDetails"] as JsonArray);
        return (new QuotaWindowSample
        {
            Role = role,
            Name = name,
            WindowSeconds = windowSeconds,
            UsedPercent = Math.Clamp(usedPercent, 0, 100),
            ResetsAtUtc = resetsAt,
            CapturedAtUtc = now,
            StartsAtUtc = null,
        }, detail);
    }

    private static string BaseName(string type) => type switch
    {
        "CREDIT_LIMIT" => "GLM Credits",
        "TOKENS_LIMIT" => "GLM Tokens",
        "TIME_LIMIT" => "GLM MCP/Search",
        _ => $"GLM {type}",
    };

    /// <summary>unit1→Nd, unit3→Nh, unit5→Nm, unit6→weekly/Nw; null when unit/number unknown.</summary>
    private static string? PeriodText(long? unit, long? number)
        => (unit, number) switch
        {
            (1, { } n) when n > 0 => $"{n}d",
            (3, { } n) when n > 0 => $"{n}h",
            (5, { } n) when n > 0 => $"{n}m",
            (6, 1) => "weekly",
            (6, { } n) when n > 0 => $"{n}w",
            _ => null,
        };

    private static string FallbackPeriod(string type) => type switch
    {
        "CREDIT_LIMIT" => "unknown",
        "TOKENS_LIMIT" => "5h",
        "TIME_LIMIT" => "month",
        _ => "unknown",
    };

    private static long DurationSeconds(long? unit, long? number, string type)
    {
        var multiplier = unit switch
        {
            1 => 86400L,
            3 => 3600L,
            5 => 60L,
            6 => 604800L,
            _ => 0L,
        };
        if (multiplier > 0 && number is > 0)
        {
            return multiplier * number.Value;
        }

        return type == "TOKENS_LIMIT" ? 18000 : 0;
    }

    /// <summary>detailText per spec §2.3: "X.X% used" / "N used" plus top-3 usageDetails.</summary>
    private static string? BuildDetailText(double? percentage, bool countMode, double usedCount, JsonArray? usageDetails)
    {
        var parts = new List<string>();
        if (percentage.HasValue)
        {
            parts.Add(percentage.Value.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture) + "% used");
        }
        else if (countMode)
        {
            parts.Add(Math.Round(usedCount).ToString("0", System.Globalization.CultureInfo.InvariantCulture) + " used");
        }

        if (usageDetails is { Count: > 0 })
        {
            var top = new List<(string code, double usage)>();
            foreach (var entry in usageDetails)
            {
                var code = entry.OptString("modelCode");
                var entryUsage = entry.OptDouble("usage");
                if (code is null || entryUsage is not > 0)
                {
                    continue;
                }

                top.Add((code, entryUsage.Value));
            }

            parts.AddRange(top.OrderByDescending(t => t.usage).Take(3).Select(t => $"{t.code}: {Math.Round(t.usage)}"));
        }

        return parts.Count > 0 ? string.Join(" · ", parts) : null;
    }

    internal static ProviderSnapshot Failed(string error)
        => new()
        {
            Kind = ProviderKind.Glm,
            Status = ProviderStatus.Failed,
            Error = error,
        };
}
