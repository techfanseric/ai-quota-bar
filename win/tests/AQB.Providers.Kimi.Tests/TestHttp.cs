using System.Net;
using System.Text;

namespace AQB.Providers.Kimi.Tests;

internal sealed class RecordedRequest
{
    public HttpMethod Method { get; init; } = HttpMethod.Get;

    public Uri? Uri { get; init; }

    public Dictionary<string, string> Headers { get; init; } = new(StringComparer.OrdinalIgnoreCase);

    public string? Body { get; init; }

    public string Header(string name) => Headers.TryGetValue(name, out var value) ? value : "";
}

/// <summary>Stub handler: records every request, answers from a lambda — no real network.</summary>
internal sealed class StubHttpHandler : HttpMessageHandler
{
    private readonly Func<RecordedRequest, HttpResponseMessage> _respond;

    public List<RecordedRequest> Requests { get; } = new();

    public StubHttpHandler(Func<RecordedRequest, HttpResponseMessage> respond)
    {
        _respond = respond;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        string? body = null;
        if (request.Content is not null)
        {
            body = await request.Content.ReadAsStringAsync(cancellationToken);
        }

        var recorded = new RecordedRequest
        {
            Method = request.Method,
            Uri = request.RequestUri,
            Headers = request.Headers.ToDictionary(
                h => h.Key,
                h => string.Join(",", h.Value),
                StringComparer.OrdinalIgnoreCase),
            Body = body,
        };
        lock (Requests)
        {
            Requests.Add(recorded);
        }

        return _respond(recorded);
    }
}

internal static class TestHttp
{
    public static HttpResponseMessage JsonResponse(int statusCode, string json)
        => new((HttpStatusCode)statusCode)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

    public static HttpResponseMessage TextResponse(int statusCode, string text)
        => new((HttpStatusCode)statusCode)
        {
            Content = new StringContent(text),
        };

    public static string TempFile(string content)
    {
        var path = Path.Combine(Path.GetTempPath(), "aqb-kimi-tests-" + Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(path, content);
        return path;
    }
}
