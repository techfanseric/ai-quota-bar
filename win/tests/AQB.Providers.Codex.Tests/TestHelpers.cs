using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AQB.Providers.Codex.Tests;

internal sealed record RecordedRequest(
    string Method,
    Uri Uri,
    IReadOnlyDictionary<string, string> Headers,
    string? Body)
{
    public string Header(string name) => Headers.TryGetValue(name, out var value) ? value : "";
}

/// <summary>Queue-based HttpMessageHandler: no real network, every request is recorded.</summary>
internal sealed class StubHttpHandler : HttpMessageHandler
{
    private readonly Queue<Func<HttpResponseMessage>> _responders = new();

    public List<RecordedRequest> Requests { get; } = new();

    public void Enqueue(Func<HttpResponseMessage> responder) => _responders.Enqueue(responder);

    public void EnqueueJson(string json, HttpStatusCode statusCode = HttpStatusCode.OK) =>
        Enqueue(() => new HttpResponseMessage(statusCode)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        });

    public void EnqueueStatus(HttpStatusCode statusCode) =>
        Enqueue(() => new HttpResponseMessage(statusCode));

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in request.Headers)
        {
            headers[header.Key] = string.Join(",", header.Value);
        }

        if (request.Content is not null)
        {
            foreach (var header in request.Content.Headers)
            {
                headers[header.Key] = string.Join(",", header.Value);
            }
        }

        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add(new RecordedRequest(request.Method.Method, request.RequestUri!, headers, body));

        if (_responders.Count == 0)
        {
            throw new InvalidOperationException("No stub response queued.");
        }

        return _responders.Dequeue()();
    }
}

internal static class TestJwts
{
    public static string Make(string payloadJson)
    {
        var header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
        return Segment(header) + "." + Segment(payloadJson) + ".c2lnbmF0dXJl";
    }

    public static string WithEmail(string email, string? sub = null)
    {
        var subPart = sub is null ? "" : ",\"sub\":\"" + sub + "\"";
        return Make("{\"email\":\"" + email + "\"" + subPart + "}");
    }

    private static string Segment(string json) =>
        Convert.ToBase64String(Encoding.UTF8.GetBytes(json)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

internal sealed class TempCodexHome : IDisposable
{
    public TempCodexHome()
    {
        Root = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            "aqb-codex-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Root);
    }

    public string Root { get; }

    public string AuthFilePath => System.IO.Path.Combine(Root, "auth.json");

    public string AccountsDirectory => System.IO.Path.Combine(Root, "accounts");

    public void WriteAuth(string json) => File.WriteAllText(AuthFilePath, json);

    public string ReadAuth() => File.ReadAllText(AuthFilePath);

    public string WritePoolAccount(string fileName, string json)
    {
        Directory.CreateDirectory(AccountsDirectory);
        var path = System.IO.Path.Combine(AccountsDirectory, fileName);
        File.WriteAllText(path, json);
        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Root, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}

internal static class AuthFiles
{
    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>Builds an auth.json-shaped document; null arguments are omitted entirely.</summary>
    public static string AuthJson(
        string? apiKey = null,
        string? authMode = null,
        string? accountId = "org-1",
        string? accessToken = "at-old",
        string? refreshToken = "rt-old",
        string? idToken = null,
        string? lastRefresh = "2026-01-01T00:00:00Z")
    {
        var root = new Dictionary<string, object?>
        {
            ["auth_mode"] = authMode,
            ["OPENAI_API_KEY"] = apiKey,
            ["tokens"] = new Dictionary<string, object?>
            {
                ["account_id"] = accountId,
                ["access_token"] = accessToken,
                ["refresh_token"] = refreshToken,
                ["id_token"] = idToken,
            },
            ["last_refresh"] = lastRefresh,
            ["favorite_color"] = "blue",
        };
        return JsonSerializer.Serialize(root, WriteOptions);
    }
}

internal static class UsageResponses
{
    public const string Normal = """
        {
          "account_id": "org-1",
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 35, "reset_at": 1788832800, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 0, "reset_at": 1789344000, "limit_window_seconds": 604800 }
          }
        }
        """;

    /// <summary>primary/secondary roles swapped: primary is weekly, secondary is 5h.</summary>
    public const string Swapped = """
        {
          "account_id": "org-1",
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1789344000, "limit_window_seconds": 604800 },
            "secondary_window": { "used_percent": 50, "reset_at": 1788832800, "limit_window_seconds": 18000 }
          }
        }
        """;

    public static string WithUsedPercents(double primaryUsed, double secondaryUsed)
    {
        var primary = primaryUsed.ToString("R", CultureInfo.InvariantCulture);
        var secondary = secondaryUsed.ToString("R", CultureInfo.InvariantCulture);
        return $$"""
        {
          "account_id": "org-1",
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": {{primary}}, "reset_at": 1788832800, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": {{secondary}}, "reset_at": 1789344000, "limit_window_seconds": 604800 }
          }
        }
        """;
    }
}
