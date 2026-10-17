using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Providers.GlmMiniMax;

/// <summary>
/// MiniMax coding-plan quota fetcher (spec §3). Key semantics: every *_usage_count field
/// carries the REMAINING amount, not the used amount — used = total − usage_count, and the
/// *_remaining_percent fields are remaining percents passed through directly. The optional
/// subscription endpoint is best-effort (failures silent) and only fills
/// SubscribeTitle/SubscribeEndTimeText (end text only when current_subscribe_end_time_ts > 0).
/// </summary>
public sealed class MiniMaxQuotaService
{
    public const string RemainsEndpoint = "https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains";
    public const string SubscribeEndpoint =
        "https://www.minimaxi.com/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7";

    public static readonly TimeSpan RemainsTimeout = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan SubscribeTimeout = TimeSpan.FromSeconds(15);

    private readonly HttpClient _client;

    public MiniMaxQuotaService(HttpMessageHandler? handler = null)
    {
        _client = new HttpClient(handler ?? new HttpClientHandler())
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
    }

    public async Task<ProviderSnapshot> FetchAsync(string token, CancellationToken cancellationToken = default)
    {
        var trimmed = token?.Trim() ?? "";
        if (trimmed.Length == 0)
        {
            return Failed("MiniMax token is not configured.");
        }

        var authorization = trimmed.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)
            ? trimmed
            : "Bearer " + trimmed;

        string remainsBody;
        using (var response = await SendGetAsync(RemainsEndpoint, authorization, RemainsTimeout, cancellationToken).ConfigureAwait(false))
        {
            if (response is null)
            {
                return Failed("MiniMax 网络请求失败 / MiniMax network request failed.");
            }

            if (!response.IsSuccessStatusCode)
            {
                return Failed($"MiniMax HTTP {(int)response.StatusCode}");
            }

            remainsBody = await ReadBodyAsync(response, cancellationToken).ConfigureAwait(false) ?? "";
        }

        string? subscribeBody = null;
        try
        {
            using var subscribeResponse = await SendGetAsync(SubscribeEndpoint, authorization, SubscribeTimeout, cancellationToken).ConfigureAwait(false);
            if (subscribeResponse is not null && subscribeResponse.IsSuccessStatusCode)
            {
                subscribeBody = await ReadBodyAsync(subscribeResponse, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            // Subscription info is optional and silent (spec §3.2).
        }

        return ParseRemains(remainsBody, subscribeBody, DateTimeOffset.UtcNow);
    }

    private async Task<HttpResponseMessage?> SendGetAsync(
        string url, string authorization, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("Authorization", authorization);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout);
        try
        {
            return await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeoutCts.Token).ConfigureAwait(false);
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
    }

    private static async Task<string?> ReadBodyAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            return await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (HttpIOException)
        {
            return null;
        }
    }

    /// <summary>Pure parser over the two response bodies; exposed for fixture-based tests.</summary>
    public static ProviderSnapshot ParseRemains(string remainsJson, string? subscribeJson, DateTimeOffset now)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(remainsJson ?? "");
        }
        catch (JsonException)
        {
            return Failed("MiniMax response was not valid JSON.");
        }

        var statusCode = root?["base_resp"].OptLong("status_code");
        if (statusCode is not 0)
        {
            var statusMessage = root?["base_resp"].OptString("status_msg");
            return Failed(string.IsNullOrWhiteSpace(statusMessage)
                ? $"MiniMax API error {statusCode ?? -1}."
                : statusMessage.Trim());
        }

        var models = new List<ModelUsageSnapshot>();
        QuotaWindowSample? intervalWindow = null;
        QuotaWindowSample? weeklyWindow = null;

        if (root?["model_remains"] is JsonArray rows)
        {
            foreach (var row in rows)
            {
                var modelName = row.OptString("model_name");
                if (string.IsNullOrWhiteSpace(modelName))
                {
                    continue;
                }

                var intervalTotal = row.OptDouble("current_interval_total_count");
                var intervalRemainingCount = row.OptDouble("current_interval_usage_count");
                var intervalRemainingPercent = row.OptDouble("current_interval_remaining_percent");
                var intervalUsedPercent = ComputeUsedPercent(intervalTotal, intervalRemainingCount, intervalRemainingPercent);

                models.Add(new ModelUsageSnapshot
                {
                    ModelName = modelName.Trim(),
                    UsedPercent = intervalUsedPercent,
                    RemainingPercent = NormalizeRemainingPercent(intervalRemainingPercent, intervalTotal, intervalRemainingCount),
                });

                if (intervalWindow is null)
                {
                    intervalWindow = BuildWindow(
                        QuotaWindowRole.Secondary,
                        "5h",
                        intervalUsedPercent,
                        row.OptLong("start_time"),
                        row.OptLong("end_time"),
                        row.OptLong("remains_time"),
                        now);
                }

                if (weeklyWindow is null)
                {
                    var weeklyTotal = row.OptDouble("current_weekly_total_count");
                    var weeklyRemainingCount = row.OptDouble("current_weekly_usage_count");
                    var weeklyRemainingPercent = row.OptDouble("current_weekly_remaining_percent");
                    var weeklyUnlimited = weeklyRemainingPercent >= 100 && weeklyTotal <= 0;
                    var weeklyUsedPercent = weeklyUnlimited ? 0 : ComputeUsedPercent(weeklyTotal, weeklyRemainingCount, weeklyRemainingPercent);
                    weeklyWindow = BuildWindow(
                        QuotaWindowRole.Primary,
                        "Weekly",
                        weeklyUsedPercent,
                        row.OptLong("weekly_start_time"),
                        row.OptLong("weekly_end_time"),
                        row.OptLong("weekly_remains_time"),
                        now);
                }
            }
        }

        if (models.Count == 0)
        {
            return Failed("MiniMax response contained no model usage rows.");
        }

        var windows = new List<QuotaWindowSample>(2);
        if (intervalWindow is not null)
        {
            windows.Add(intervalWindow);
        }

        if (weeklyWindow is not null)
        {
            windows.Add(weeklyWindow);
        }

        string? subscribeTitle = null;
        string? subscribeEndTimeText = null;
        try
        {
            var subscribeRoot = subscribeJson is null ? null : JsonNode.Parse(subscribeJson);
            var current = subscribeRoot?["current_subscribe"];
            var title = current.OptString("current_subscribe_title");
            if (!string.IsNullOrWhiteSpace(title))
            {
                subscribeTitle = title.Trim();
            }

            var endTs = current.OptLong("current_subscribe_end_time_ts");
            if (endTs is > 0)
            {
                subscribeEndTimeText = GlmMiniMaxText.EndTimeText(DateTimeOffset.FromUnixTimeMilliseconds(endTs.Value));
            }
        }
        catch (JsonException)
        {
            // Subscription parsing failures are silent.
        }

        return new ProviderSnapshot
        {
            Kind = ProviderKind.MiniMax,
            Status = ProviderStatus.Ok,
            LastUpdatedUtc = now,
            SubscribeTitle = subscribeTitle,
            SubscribeEndTimeText = subscribeEndTimeText,
            Models = models,
            Accounts = new[]
            {
                new ProviderAccountSnapshot
                {
                    AccountKey = "minimax",
                    Label = "MiniMax",
                    SourceLabel = "MiniMax",
                    IsCurrent = true,
                    Windows = windows,
                },
            },
        };
    }

    /// <summary>used = total − usage_count, where usage_count holds the REMAINING amount (spec §3.1).</summary>
    internal static double ComputeUsedPercent(double? total, double? remainingCount, double? remainingPercent)
    {
        if (remainingPercent.HasValue)
        {
            return Math.Clamp(100 - Math.Clamp(remainingPercent.Value, 0, 100), 0, 100);
        }

        if (total is > 0 && remainingCount.HasValue)
        {
            var used = Math.Clamp(total.Value - Math.Clamp(remainingCount.Value, 0, total.Value), 0, total.Value);
            return used / total.Value * 100;
        }

        return 0;
    }

    private static double? NormalizeRemainingPercent(double? remainingPercent, double? total, double? remainingCount)
    {
        if (remainingPercent.HasValue)
        {
            return Math.Clamp(remainingPercent.Value, 0, 100);
        }

        if (total is > 0 && remainingCount.HasValue)
        {
            return Math.Clamp(remainingCount.Value / total.Value * 100, 0, 100);
        }

        return null;
    }

    /// <summary>Window times come from the API (ms); a lone remains_time only yields the reset instant.</summary>
    private static QuotaWindowSample? BuildWindow(
        QuotaWindowRole role,
        string name,
        double usedPercent,
        long? startMs,
        long? endMs,
        long? remainsMs,
        DateTimeOffset now)
    {
        if (startMs is > 0 && endMs > startMs)
        {
            var start = DateTimeOffset.FromUnixTimeMilliseconds(startMs.Value);
            var end = DateTimeOffset.FromUnixTimeMilliseconds(endMs.Value);
            return new QuotaWindowSample
            {
                Role = role,
                Name = name,
                WindowSeconds = (long)(end - start).TotalSeconds,
                UsedPercent = usedPercent,
                ResetsAtUtc = end,
                CapturedAtUtc = now,
                StartsAtUtc = start,
            };
        }

        if (remainsMs is > 0)
        {
            return new QuotaWindowSample
            {
                Role = role,
                Name = name,
                WindowSeconds = 0,
                UsedPercent = usedPercent,
                ResetsAtUtc = now.AddMilliseconds(remainsMs.Value),
                CapturedAtUtc = now,
                StartsAtUtc = null,
            };
        }

        return null;
    }

    internal static ProviderSnapshot Failed(string error)
        => new()
        {
            Kind = ProviderKind.MiniMax,
            Status = ProviderStatus.Failed,
            Error = error,
        };
}
