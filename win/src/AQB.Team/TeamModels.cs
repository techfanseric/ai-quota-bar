using System.Text.Json;
using System.Text.Json.Serialization;
using AQB.Core;

namespace AQB.Team;

/// <summary>Device credentials minted by /v1/usage/join (token starts with "aqu_").</summary>
public sealed class TeamCredentials
{
    public string DeviceToken { get; set; } = "";

    public string TeamId { get; set; } = "";

    public string MemberId { get; set; } = "";

    public string MemberName { get; set; } = "";

    public string DeviceId { get; set; } = "";

    public string? TeamName { get; set; }
}

public static class TeamCredentialsCodec
{
    public static string Encode(TeamCredentials credentials)
        => JsonSerializer.Serialize(credentials, Json.SnakeCase);

    public static TeamCredentials? Decode(string json)
    {
        try
        {
            return JsonSerializer.Deserialize<TeamCredentials>(json, Json.SnakeCase);
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>One usage event as accepted by POST /v1/usage/events/batch (camelCase, exact fields).</summary>
public sealed class UsageEvent
{
    public string Id { get; set; } = "";

    public string OccurredAt { get; set; } = "";

    public string Model { get; set; } = "";

    public UsageEventTokens Tokens { get; set; } = new();

    /// <summary>exact | estimated.</summary>
    public string Quality { get; set; } = "estimated";

    public string ParserVersion { get; set; } = "win-1";

    [JsonPropertyName("accountID")]
    public string? AccountId { get; set; }

    [JsonPropertyName("accountSource")]
    public string? AccountSource { get; set; }
}

public sealed class UsageEventTokens
{
    public long Input { get; set; }

    public long Cached { get; set; }

    public long CacheWrite { get; set; }

    public long Output { get; set; }

    public long Reasoning { get; set; }
}

/// <summary>Quota snapshot upload accepted by POST /v1/quota-samples.</summary>
public sealed class QuotaSampleUpload
{
    [JsonPropertyName("deviceID")]
    public string DeviceId { get; set; } = "";

    public string SampledAt { get; set; } = "";

    public List<QuotaSampleModel> Models { get; set; } = new();
}

public sealed class QuotaSampleModel
{
    public string Provider { get; set; } = "";

    public string AccountName { get; set; } = "";

    [JsonPropertyName("modelID")]
    public string ModelId { get; set; } = "";

    public string ModelName { get; set; } = "";

    /// <summary>Percent-mode upload (0-100); folds total to 100 server-side.</summary>
    public int? CurrentIntervalRemainingPercent { get; set; }

    public string? ResetStartTime { get; set; }

    public string? ResetEndTime { get; set; }

    public string? WeeklyStartTime { get; set; }

    public string? WeeklyEndTime { get; set; }
}

public sealed class JoinResult
{
    public string DeviceToken { get; set; } = "";

    public string TeamId { get; set; } = "";

    public string MemberId { get; set; } = "";

    public string MemberName { get; set; } = "";

    public string DeviceId { get; set; } = "";
}

/// <summary>Create-team result; the management password is returned exactly once.</summary>
public sealed class CreateTeamResult
{
    public string TeamId { get; set; } = "";

    public string TeamName { get; set; } = "";

    public string InviteCode { get; set; } = "";

    public string LoginPassword { get; set; } = "";
}

public sealed class HandoffTicket
{
    public string Ticket { get; set; } = "";

    public string Role { get; set; } = "";

    public int ExpiresIn { get; set; }
}

public sealed class BatchReportResult
{
    public List<string> Accepted { get; set; } = new();

    public List<RejectedEvent> Rejected { get; set; } = new();
}

public sealed class RejectedEvent
{
    public string Id { get; set; } = "";

    public string Reason { get; set; } = "";
}

/// <summary>Error carrying the worker's status code and machine-readable error code.</summary>
public sealed class TeamApiException : Exception
{
    public TeamApiException(int statusCode, string code, string message)
        : base($"[{statusCode}] {code}: {message}")
    {
        StatusCode = statusCode;
        Code = code;
    }

    public int StatusCode { get; }

    public string Code { get; }

    /// <summary>5xx and network-ish failures are retryable; 4xx (401/403/404/409/413/429) are not.</summary>
    public bool Retryable => StatusCode is >= 500 or 408 && Code != "d1_daily_limit_exceeded";
}
