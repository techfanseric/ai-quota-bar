using System.Net;
using AQB.Core;
using AQB.Team;
using Xunit;

namespace AQB.Team.Tests;

public sealed class TeamCredentialsCodecTests
{
    [Fact]
    public void RoundTripKeepsAllFields()
    {
        var credentials = new TeamCredentials
        {
            DeviceToken = "aqu_" + new string('a', 64),
            TeamId = "tabcd1234efab5678",
            MemberId = "m1",
            MemberName = "eric",
            DeviceId = "device-1",
            TeamName = "team",
        };
        var decoded = TeamCredentialsCodec.Decode(TeamCredentialsCodec.Encode(credentials));
        Assert.NotNull(decoded);
        Assert.Equal(credentials.DeviceToken, decoded!.DeviceToken);
        Assert.Equal(credentials.TeamId, decoded.TeamId);
        Assert.Equal(credentials.MemberName, decoded.MemberName);
    }

    [Fact]
    public void CorruptJsonReturnsNull()
    {
        Assert.Null(TeamCredentialsCodec.Decode("{not json"));
    }
}

public sealed class TeamClientTests : IDisposable
{
    private readonly RecordingHandler _handler = new();
    private readonly TeamClient _client;

    public TeamClientTests()
    {
        _client = new TeamClient("https://sync.example.com/", "device-1", _handler);
    }

    [Fact]
    public async Task JoinTeam_SendsExactFieldsAndParsesIdentity()
    {
        _handler.RespondWith("""{"ok":true,"token":"aqu_0123456789abcdef","identity":{"team_id":"tabcd1234efab5678","device_id":"device-1","member_id":"m9","member_name":"eric"}}""");
        var result = await _client.JoinTeamAsync("INVITE123", "eric", "pass");
        var request = _handler.Requests.Single();
        Assert.Equal("POST", request.Method);
        Assert.Equal("https://sync.example.com/v1/usage/join", request.Url);
        Assert.Null(request.Authorization);
        Assert.Contains("\"inviteCode\":\"INVITE123\"", request.Body);
        Assert.Contains("\"memberName\":\"eric\"", request.Body);
        Assert.Contains("\"deviceID\":\"device-1\"", request.Body);
        Assert.Contains("\"memberPassphrase\":\"pass\"", request.Body);
        Assert.Equal("aqu_0123456789abcdef", result.DeviceToken);
        Assert.Equal("tabcd1234efab5678", result.TeamId);
        Assert.Equal("m9", result.MemberId);
    }

    [Fact]
    public async Task CreateTeam_ReturnsOneTimeSecrets()
    {
        _handler.RespondWith("""{"ok":true,"teamID":"tabcd1234efab5678","teamName":"core","inviteCode":"ABCDEFGH","loginPassword":"pw123"}""");
        var result = await _client.CreateTeamAsync("core", "pw123");
        var request = _handler.Requests.Single();
        Assert.Equal("https://sync.example.com/v1/team/create", request.Url);
        Assert.Equal("tabcd1234efab5678", result.TeamId);
        Assert.Equal("ABCDEFGH", result.InviteCode);
        Assert.Equal("pw123", result.LoginPassword);
    }

    [Fact]
    public async Task BatchReport_SendsBearerAndSplitsAt50()
    {
        _handler.RespondWith("""{"ok":true,"accepted":["e1","e2"],"rejected":[{"id":"e3","reason":"content_conflict"}]}""");
        var events = Enumerable.Range(1, 101).Select(i => new UsageEvent { Id = "e" + i, Model = "gpt-5", Tokens = new UsageEventTokens { Input = 10, Output = 5 } }).ToList();
        var result = await _client.BatchReportAsync(new TeamCredentials { DeviceToken = "aqu_tok", DeviceId = "device-1" }, events);
        Assert.Equal(3, _handler.Requests.Count);
        Assert.All(_handler.Requests, r => Assert.Equal("Bearer aqu_tok", r.Authorization));
        Assert.Contains("\"events\":[", _handler.Requests[0].Body);
        // Each of the three responses accepted e1,e2 and rejected e3.
        Assert.Equal(6, result.Accepted.Count);
        Assert.Equal(3, result.Rejected.Count);
        Assert.All(result.Rejected, r => Assert.Equal("content_conflict", r.Reason));
    }

    [Fact]
    public async Task QuotaUpload_SetsDeviceIdAndSampledAt()
    {
        _handler.RespondWith("""{"ok":true,"inserted":2,"retention_days":90}""");
        var inserted = await _client.UploadQuotaSamplesAsync(
            new TeamCredentials { DeviceToken = "aqu_tok", DeviceId = "device-1" },
            new QuotaSampleUpload
            {
                Models = { new QuotaSampleModel { Provider = "codex", AccountName = "e***@x.com", ModelId = "5h", ModelName = "5h", CurrentIntervalRemainingPercent = 74 } },
            });
        var request = _handler.Requests.Single();
        Assert.Equal("https://sync.example.com/v1/quota-samples", request.Url);
        Assert.Contains("\"deviceID\":\"device-1\"", request.Body);
        Assert.Contains("\"currentIntervalRemainingPercent\":74", request.Body);
        Assert.Contains("\"sampledAt\":\"", request.Body);
        Assert.Equal(2, inserted);
    }

    [Fact]
    public async Task Error4xx_ThrowsWithoutRetry()
    {
        _handler.RespondWith("""{"error":"invalid_credentials"}""", HttpStatusCode.Unauthorized);
        var exception = await Assert.ThrowsAsync<TeamApiException>(
            () => _client.LeaveTeamAsync(new TeamCredentials { DeviceToken = "aqu_bad", DeviceId = "d" }));
        Assert.Equal(401, exception.StatusCode);
        Assert.False(exception.Retryable);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public async Task ServerError_RetriesWithBackoffThenSucceeds()
    {
        _handler.RespondSequence(
            ("""{"error":"internal"}""", HttpStatusCode.InternalServerError),
            ("""{"ok":true}""", HttpStatusCode.OK));
        await _client.LeaveTeamAsync(new TeamCredentials { DeviceToken = "aqu_tok", DeviceId = "d" });
        Assert.Equal(2, _handler.Requests.Count);
    }

    [Fact]
    public async Task D1DailyLimit_DoesNotRetry()
    {
        _handler.RespondWith("""{"error":"d1_daily_limit_exceeded"}""", HttpStatusCode.ServiceUnavailable);
        var exception = await Assert.ThrowsAsync<TeamApiException>(
            () => _client.LeaveTeamAsync(new TeamCredentials { DeviceToken = "aqu_tok", DeviceId = "d" }));
        Assert.Equal("d1_daily_limit_exceeded", exception.Code);
        Assert.False(exception.Retryable);
        Assert.Single(_handler.Requests);
    }

    [Fact]
    public void HandoffUrl_PointsAtTeamConsole()
    {
        var url = _client.BuildConsoleHandoffUrl(new HandoffTicket { Ticket = "abc123", Role = "member" });
        Assert.Equal("https://sync.example.com/team?handoff=abc123", url);
    }

    public void Dispose() => _client.Dispose();

    private sealed class RecordedRequest
    {
        public string Method { get; init; } = "";

        public string Url { get; init; } = "";

        public string? Authorization { get; init; }

        public string Body { get; init; } = "";
    }

    private sealed class RecordingHandler : HttpMessageHandler
    {
        private readonly List<(string Body, HttpStatusCode Status)> _queue = new();
        private (string Body, HttpStatusCode Status)? _next;

        public List<RecordedRequest> Requests { get; } = new();

        public void RespondWith(string body, HttpStatusCode status = HttpStatusCode.OK) => _next = (body, status);

        public void RespondSequence(params (string Body, HttpStatusCode Status)[] responses) => _queue.AddRange(responses);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(new RecordedRequest
            {
                Method = request.Method.Method,
                Url = request.RequestUri!.ToString(),
                Authorization = request.Headers.Authorization?.ToString(),
                Body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken),
            });
            var (body, status) = _queue.Count > 0 ? TakeFirst(_queue) : _next ?? ("{}", HttpStatusCode.OK);
            return new HttpResponseMessage(status) { Content = new StringContent(body) };
        }

        private static (string Body, HttpStatusCode Status) TakeFirst(List<(string Body, HttpStatusCode Status)> queue)
        {
            var item = queue[0];
            queue.RemoveAt(0);
            return item;
        }
    }
}
