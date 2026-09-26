// Swift 来源：无直接对应（codexbar 的网络路径无 fixtures 样本，Win-CodexBar 的 mockito 用例
//   fetch_usage_attaches_reset_credits_from_http / authenticated_codex_http_distinguishes_401_from_403
//   是行为参照）。请求头/端点断言按 Win-CodexBar api.rs 实证（GET /wham/usage、Bearer、
//   ChatGPT-Account-Id、User-Agent "CodexBar"）；成功响应体取 fixtures/codex/usage-response-oauth-windows.json。

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Providers.Codex;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexUsageClientTests
{
    private const string TestBaseUrl = "http://codex-usage.test";

    [Fact]
    public async Task FetchSendsBearerAccountAndClientHeadersToUsageEndpoint()
    {
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.OK, "{}"));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        await client.FetchUsageJsonAsync("access-1", "acct-1");

        var request = handler.SingleRequest();
        Assert.Equal($"{TestBaseUrl}/wham/usage", request.Uri);
        Assert.Equal(HttpMethod.Get, request.Method);
        Assert.Equal("Bearer access-1", request.Header("Authorization"));
        Assert.Equal("acct-1", request.Header("ChatGPT-Account-Id"));
        Assert.Equal("application/json", request.Header("Accept"));
        Assert.Equal(CodexUsageClient.UserAgent, request.Header("User-Agent"));
    }

    [Fact]
    public async Task BlankAccountIdOmitsAccountHeader()
    {
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.OK, "{}"));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        await client.FetchUsageJsonAsync("access-1", "  ");

        var request = handler.SingleRequest();
        Assert.Null(request.Header("ChatGPT-Account-Id"));
    }

    [Fact]
    public async Task EmptyAccessTokenThrowsWithoutSending()
    {
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.OK, "{}"));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => client.FetchUsageJsonAsync(string.Empty, null));

        Assert.Equal(CodexUsageError.NotConfigured, exception.Kind);
        Assert.Equal(0, handler.Requests.Count);
    }

    [Fact]
    public async Task SuccessReturnsRawFixtureBody()
    {
        var body = CodexFixtures.Read("usage-response-oauth-windows.json");
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.OK, body));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        var json = await client.FetchUsageJsonAsync("access-1", null);

        Assert.Equal(body, json);
    }

    [Fact]
    public async Task UnauthorizedMapsToAuthRequiredWithLoginHint()
    {
        // Win-CodexBar：401 折叠为 AuthRequired 并给 re-login 提示（与 403 区分）。
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.Unauthorized, "fixture refusal"));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => client.FetchUsageJsonAsync("access-1", null));

        Assert.Equal(CodexUsageError.AuthRequired, exception.Kind);
        Assert.Equal(401, exception.StatusCode);
        Assert.Contains("codex login", exception.Message);
    }

    [Fact]
    public async Task ForbiddenKeepsBodyDetailAsApiError()
    {
        // Win-CodexBar：403 不是 AuthRequired，消息保留响应体供诊断。
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.Forbidden, "fixture refusal"));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => client.FetchUsageJsonAsync("access-1", null));

        Assert.Equal(CodexUsageError.ApiError, exception.Kind);
        Assert.Equal(403, exception.StatusCode);
        Assert.Contains("fixture refusal", exception.Message);
    }

    [Fact]
    public async Task EmptyErrorBodyFallsBackToStatusText()
    {
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.InternalServerError, string.Empty));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => client.FetchUsageJsonAsync("access-1", null));

        Assert.Equal(CodexUsageError.ApiError, exception.Kind);
        Assert.Equal("HTTP 500", exception.Message);
    }

    [Fact]
    public async Task TransportFailureMapsToNetworkError()
    {
        var handler = new RecordingHandler(_ => throw new HttpRequestException("connection refused"));
        var client = new CodexUsageClient(new HttpClient(handler), TestBaseUrl);

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => client.FetchUsageJsonAsync("access-1", null));

        Assert.Equal(CodexUsageError.NetworkError, exception.Kind);
        Assert.Null(exception.StatusCode);
    }

    [Fact]
    public async Task BlankBaseUrlFallsBackToProductionEndpoint()
    {
        var handler = new RecordingHandler(_ => Response(HttpStatusCode.OK, "{}"));
        var client = new CodexUsageClient(new HttpClient(handler), "  ");

        await client.FetchUsageJsonAsync("access-1", null);

        Assert.Equal(
            CodexUsageClient.DefaultBaseUrl + CodexUsageClient.UsagePath,
            handler.SingleRequest().Uri);
    }

    // ------------------------------------------------------------------
    // 辅助。
    // ------------------------------------------------------------------

    private static HttpResponseMessage Response(HttpStatusCode statusCode, string json) =>
        new(statusCode)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

    /// <summary>
    /// 记录请求（方法/URI/头快照——HttpRequestMessage 在 Send 返回后会被 HttpClient 处置，
    /// Content 不可再读，故在调用时复制）并按脚本应答。
    /// </summary>
    private sealed class RecordingHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _respond;

        public RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) => _respond = respond;

        public List<RecordedRequest> Requests { get; } = new();

        public RecordedRequest SingleRequest()
        {
            Assert.Single(Requests);
            return Requests[0];
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(new RecordedRequest(
                request.Method,
                request.RequestUri?.AbsoluteUri ?? string.Empty,
                request.Headers.ToDictionary(
                    header => header.Key,
                    header => string.Join(",", header.Value),
                    StringComparer.OrdinalIgnoreCase)));
            return Task.FromResult(_respond(request));
        }
    }

    public sealed record RecordedRequest(
        HttpMethod Method,
        string Uri,
        IReadOnlyDictionary<string, string> Headers)
    {
        public string? Header(string name) =>
            Headers.TryGetValue(name, out var value) ? value : null;
    }
}
