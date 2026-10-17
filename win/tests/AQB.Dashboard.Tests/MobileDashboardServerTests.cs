using System.Net;
using System.Net.Http.Headers;
using System.Text;
using AQB.Core;
using AQB.Dashboard;
using Xunit;

namespace AQB.Dashboard.Tests;

public sealed class MobileDashboardServerTests : IDisposable
{
    private static readonly Func<int> FreePort = () =>
    {
        var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    };

    private readonly MobileDashboardServer _server;
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(5) };
    private readonly string _base;

    public MobileDashboardServerTests()
    {
        var port = FreePort();
        _server = new MobileDashboardServer(
            port,
            "test-token-0123456789abcdef",
            () => new DashboardSnapshot
            {
                GeneratedAt = TimeText.FixedIso(DateTimeOffset.UtcNow),
                Providers =
                {
                    new DashboardProvider
                    {
                        Kind = "codex",
                        Status = "ok",
                        Accounts = { new DashboardAccount { Label = "eric@example.com", IsCurrent = true, Windows = { new DashboardWindow { Name = "5h", UsedPercent = 25, RemainingPercent = 75 } } } },
                    },
                },
            },
            staticRoot: Path.Combine(Path.GetTempPath(), "aqb-test-static-" + Guid.NewGuid().ToString("N")));
        _server.Start();
        _base = $"http://127.0.0.1:{port}";
    }

    [Fact]
    public async Task Health_ReturnsOkJson()
    {
        using var response = await _http.GetAsync(_base + "/api/v1/health");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/json", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadAsStringAsync();
        Assert.Contains("\"status\":\"ok\"", body);
        Assert.Contains("\"schemaVersion\":2", body);
    }

    [Fact]
    public async Task Events_RequiresBearerToken()
    {
        using var noAuth = await _http.GetAsync(_base + "/api/v1/events");
        Assert.Equal(HttpStatusCode.Unauthorized, noAuth.StatusCode);

        using var request = new HttpRequestMessage(HttpMethod.Get, _base + "/api/v1/events");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "wrong-token");
        using var wrong = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.Unauthorized, wrong.StatusCode);
    }

    [Fact]
    public async Task Events_PushesMaskedSnapshot()
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, _base + "/api/v1/events");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", "test-token-0123456789abcdef");
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/event-stream", response.Content.Headers.ContentType?.MediaType);

        var stream = await response.Content.ReadAsStreamAsync();
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var sawEvent = false;
        var deadline = Task.Delay(TimeSpan.FromSeconds(5));
        while (!sawEvent)
        {
            var readTask = reader.ReadLineAsync();
            var finished = await Task.WhenAny(readTask, deadline);
            Assert.True(finished == readTask, "timed out waiting for SSE frame");
            var line = await readTask;
            if (line == "event: snapshot")
            {
                var dataLine = await reader.ReadLineAsync();
                Assert.NotNull(dataLine);
                Assert.StartsWith("data: ", dataLine);
                var payload = dataLine["data: ".Length..];
                Assert.Contains("\"label\":\"e***@example.com\"", payload);
                Assert.DoesNotContain("eric@example.com", payload);
                Assert.Contains("\"kind\":\"codex\"", payload);
                sawEvent = true;
            }
        }
    }

    [Fact]
    public async Task Post_IsRejected()
    {
        using var response = await _http.PostAsync(_base + "/api/v1/health", new StringContent("{}"));
        Assert.Equal(HttpStatusCode.MethodNotAllowed, response.StatusCode);
    }

    [Fact]
    public async Task UnknownPath_Is404()
    {
        using var response = await _http.GetAsync(_base + "/nope.js");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Static_ServesHtmlWithContentType()
    {
        var root = Path.Combine(Path.GetTempPath(), "aqb-static-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        await File.WriteAllTextAsync(Path.Combine(root, "index.html"), "<!doctype html><title>ok</title>");
        var port = FreePort();
        using var server = new MobileDashboardServer(port, "t", null, staticRoot: root);
        server.Start();
        using var response = await _http.GetAsync($"http://127.0.0.1:{port}/");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/html", response.Content.Headers.ContentType?.MediaType);
        var body = await response.Content.ReadAsStringAsync();
        Assert.Contains("ok", body);
    }

    [Fact]
    public async Task PathTraversal_NeverServesContent()
    {
        using var response = await _http.GetAsync(_base + "/..%5Csecrets.txt");
        // Either http.sys or our handler blocks it; the invariant is: no 200 with file content.
        Assert.NotEqual(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadAsStringAsync();
        Assert.DoesNotContain("secret", body, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void PairingCode_IsEightDigits()
    {
        var (code, expiresAt) = MobileDashboardServer.GeneratePairingCode();
        Assert.Matches("^[0-9]{8}$", code);
        Assert.True(expiresAt > DateTimeOffset.UtcNow.AddMinutes(4));
        Assert.True(expiresAt <= DateTimeOffset.UtcNow.AddMinutes(5));
    }

    public void Dispose()
    {
        _server.Dispose();
        _http.Dispose();
    }
}
