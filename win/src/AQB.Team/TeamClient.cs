using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Team;

/// <summary>
/// HTTP client for the shared Cloudflare worker (create/join teams, report usage batches,
/// upload quota snapshots, handoff tickets). Retries 5xx at 1/4/16s; never retries 4xx.
/// </summary>
public sealed class TeamClient : IDisposable
{
    private readonly HttpClient _http;
    private readonly bool _ownHandler;

    public TeamClient(string endpointUrl, string deviceId, HttpMessageHandler? handler = null)
    {
        EndpointUrl = endpointUrl.TrimEnd('/');
        DeviceId = deviceId;
        _ownHandler = handler is null;
        _http = handler is null
            ? new HttpClient { Timeout = TimeSpan.FromSeconds(20) }
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(20) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("AIQuotaBar-Win/1.0");
    }

    public string EndpointUrl { get; }

    public string DeviceId { get; }

    public async Task<CreateTeamResult> CreateTeamAsync(string teamName, string loginPassword, CancellationToken cancellationToken = default)
    {
        using var response = await SendWithRetryAsync(
            "POST", "/v1/team/create", null, new Dictionary<string, object> { ["teamName"] = teamName }, cancellationToken);
        var body = await ReadJsonAsync(response, cancellationToken);
        RequireOk(body, response.StatusCode);
        return new CreateTeamResult
        {
            TeamId = body.GetString("teamID"),
            TeamName = body.GetString("teamName"),
            InviteCode = body.GetString("inviteCode"),
            LoginPassword = body.GetString("loginPassword"),
        };
    }

    public async Task<JoinResult> JoinTeamAsync(string inviteCode, string memberName, string memberPassphrase, CancellationToken cancellationToken = default)
    {
        var payload = new Dictionary<string, object>
        {
            ["inviteCode"] = inviteCode,
            ["memberName"] = memberName,
            ["deviceID"] = DeviceId,
        };
        if (!string.IsNullOrEmpty(memberPassphrase))
        {
            payload["memberPassphrase"] = memberPassphrase;
        }

        using var response = await SendWithRetryAsync("POST", "/v1/usage/join", null, payload, cancellationToken);
        var body = await ReadJsonAsync(response, cancellationToken);
        RequireOk(body, response.StatusCode);
        return new JoinResult
        {
            DeviceToken = body.GetString("token"),
            TeamId = body["identity"].GetString("team_id"),
            MemberId = body["identity"].GetString("member_id"),
            MemberName = body["identity"].GetString("member_name"),
            DeviceId = body["identity"].GetString("device_id"),
        };
    }

    public async Task<BatchReportResult> BatchReportAsync(TeamCredentials credentials, IReadOnlyList<UsageEvent> events, CancellationToken cancellationToken = default)
    {
        var merged = new BatchReportResult();
        const int batchSize = 50;
        for (var offset = 0; offset < events.Count; offset += batchSize)
        {
            var batch = events.Skip(offset).Take(batchSize).ToList();
            using var response = await SendWithRetryAsync(
                "POST", "/v1/usage/events/batch", credentials.DeviceToken, new Dictionary<string, object> { ["events"] = batch }, cancellationToken);
            var body = await ReadJsonAsync(response, cancellationToken);
            RequireOk(body, response.StatusCode);
            if (body["accepted"] is JsonArray accepted)
            {
                merged.Accepted.AddRange(accepted.Select(node => node!.ToString()));
            }

            if (body["rejected"] is JsonArray rejected)
            {
                foreach (var node in rejected)
                {
                    merged.Rejected.Add(new RejectedEvent
                    {
                        Id = node!.GetString("id"),
                        Reason = node.GetString("reason"),
                    });
                }
            }
        }

        return merged;
    }

    public async Task<int> UploadQuotaSamplesAsync(TeamCredentials credentials, QuotaSampleUpload upload, CancellationToken cancellationToken = default)
    {
        upload.DeviceId = credentials.DeviceId;
        if (string.IsNullOrEmpty(upload.SampledAt))
        {
            upload.SampledAt = TimeText.FixedIso(DateTimeOffset.UtcNow);
        }

        try
        {
            using var response = await SendWithRetryAsync("POST", "/v1/quota-samples", credentials.DeviceToken, upload, cancellationToken);
            var body = await ReadJsonAsync(response, cancellationToken);
            RequireOk(body, response.StatusCode);
            return (int)body.GetLong("inserted");
        }
        catch (TeamApiException e) when (e.StatusCode == 413)
        {
            throw new TeamApiException(413, "body_too_large", "Quota snapshot exceeds the 256 KiB limit; split the models across uploads.");
        }
    }

    public async Task<HandoffTicket> RequestHandoffAsync(TeamCredentials credentials, string? managementPassword, CancellationToken cancellationToken = default)
    {
        var payload = new Dictionary<string, object>();
        if (!string.IsNullOrEmpty(managementPassword))
        {
            payload["managementPassword"] = managementPassword;
        }

        using var response = await SendWithRetryAsync("POST", "/v1/team/handoff", credentials.DeviceToken, payload, cancellationToken);
        var body = await ReadJsonAsync(response, cancellationToken);
        RequireOk(body, response.StatusCode);
        return new HandoffTicket
        {
            Ticket = body.GetString("ticket"),
            Role = body.GetString("role"),
            ExpiresIn = (int)body.GetLong("expiresIn", 120),
        };
    }

    /// <summary>URL the browser opens to redeem a handoff ticket into a team-console session.</summary>
    public string BuildConsoleHandoffUrl(HandoffTicket ticket)
        => $"{EndpointUrl}/team?handoff={Uri.EscapeDataString(ticket.Ticket)}";

    public async Task LeaveTeamAsync(TeamCredentials credentials, CancellationToken cancellationToken = default)
    {
        using var response = await SendWithRetryAsync("POST", "/v1/usage/leave", credentials.DeviceToken, new Dictionary<string, object>(), cancellationToken);
        var body = await ReadJsonAsync(response, cancellationToken);
        RequireOk(body, response.StatusCode);
    }

    private async Task<HttpResponseMessage> SendWithRetryAsync(
        string method, string path, string? bearer, object payload, CancellationToken cancellationToken)
    {
        var delays = new[] { 1, 4, 16 };
        for (var attempt = 0; ; attempt++)
        {
            using var request = new HttpRequestMessage(new HttpMethod(method), EndpointUrl + path);
            if (bearer is not null)
            {
                request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", bearer);
            }

            request.Content = new StringContent(JsonSerializer.Serialize(payload, Json.SnakeCase), Encoding.UTF8, "application/json");
            try
            {
                var response = await _http.SendAsync(request, cancellationToken);
                if (response.StatusCode is >= HttpStatusCode.InternalServerError or HttpStatusCode.RequestTimeout
                    && attempt < delays.Length)
                {
                    var code = await TryReadErrorCodeAsync(response, cancellationToken);
                    response.Dispose();
                    if (code == "d1_daily_limit_exceeded")
                    {
                        throw new TeamApiException(503, code, "Worker D1 daily limit reached; not retryable.");
                    }

                    await Task.Delay(TimeSpan.FromSeconds(delays[attempt]), cancellationToken);
                    continue;
                }

                return response;
            }
            catch (HttpRequestException e) when (attempt < delays.Length)
            {
                await Task.Delay(TimeSpan.FromSeconds(delays[attempt]), cancellationToken);
                _ = e;
            }
        }
    }

    private static async Task<string?> TryReadErrorCodeAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        try
        {
            var text = await response.Content.ReadAsStringAsync(cancellationToken);
            var node = JsonNode.Parse(text);
            return node?["error"]?.ToString();
        }
        catch
        {
            return null;
        }
    }

    private static async Task<JsonNode> ReadJsonAsync(HttpResponseMessage response, CancellationToken cancellationToken)
    {
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            throw new TeamApiException((int)response.StatusCode, "invalid_response", text.Trim()[..Math.Min(120, text.Trim().Length)]);
        }

        if (node is null)
        {
            throw new TeamApiException((int)response.StatusCode, "invalid_response", "empty body");
        }

        if (!response.IsSuccessStatusCode)
        {
            throw new TeamApiException((int)response.StatusCode, node.GetString("error", "error"), text.Trim()[..Math.Min(120, text.Trim().Length)]);
        }

        return node;
    }

    private static void RequireOk(JsonNode body, HttpStatusCode statusCode)
    {
        if (body.GetBool("ok") == false)
        {
            throw new TeamApiException((int)statusCode, body.GetString("error", "error"), "worker returned ok=false");
        }
    }

    public void Dispose() => _http.Dispose();
}
