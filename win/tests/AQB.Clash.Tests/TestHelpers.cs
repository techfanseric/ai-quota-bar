using System.Net;
using System.Text;

namespace AQB.Clash.Tests;

/// <summary>A request captured before HttpClient disposes the content.</summary>
public sealed record CapturedRequest(string Method, Uri Url, string? Body, IReadOnlyDictionary<string, string> Headers);

public sealed class FakeHttpMessageHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _responder;

    public FakeHttpMessageHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> responder)
        => _responder = responder;

    public List<CapturedRequest> Requests { get; } = new();

    public static HttpResponseMessage Json(int statusCode, string json)
        => new((HttpStatusCode)statusCode) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    public static HttpResponseMessage Empty(int statusCode) => new((HttpStatusCode)statusCode);

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        string? body = null;
        if (request.Content is not null)
        {
            body = await request.Content.ReadAsStringAsync(cancellationToken);
        }

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var header in request.Headers.Concat(request.Content?.Headers ?? Enumerable.Empty<KeyValuePair<string, IEnumerable<string>>>()))
        {
            headers[header.Key] = string.Join(",", header.Value);
        }

        Requests.Add(new CapturedRequest(request.Method.Method, request.RequestUri!, body, headers));
        return await _responder(request, cancellationToken);
    }

    public static Task<HttpResponseMessage> Throw(HttpRequestMessage request, CancellationToken cancellationToken)
        => throw new HttpRequestException("simulated transport failure");
}
