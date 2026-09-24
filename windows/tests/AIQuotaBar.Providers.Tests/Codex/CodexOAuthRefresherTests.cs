// Swift 来源：.dependencies/codexbar/Tests/CodexBarTests/CodexOAuthTests.swift
//   （non 401 invalid grant refresh failure is treated as revoked / non auth refresh failure remains
//   invalid response）+ CodexTokenRefresher.swift 的请求构造与 200 响应合并语义。
// fixtures：成功响应体取自 auth-json-oauth.json 的 tokens 子对象（与 refresh 响应同键形）。
// TODO(fixture-pending)：auth.openai.com/oauth/token 的成功/错误响应尚无录制样本
// （见 windows/contracts/fixtures/MANIFEST.md 缺口），错误分类用例暂以最小内联错误体驱动，
// 补录后应替换为 fixtures 加载。

#nullable enable

using System;
using System.Net;
using System.Net.Http;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Providers.Codex.Credentials;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexOAuthRefresherTests
{
    private static CodexOAuthCredentials MakeCredentials() => new(
        AccessToken: "old-access",
        RefreshToken: "old-refresh",
        IdToken: "old-id",
        AccountId: "account-123",
        LastRefresh: null);

    [Fact]
    public async Task BuildRefreshRequestPostsClientCredentialsAndScope()
    {
        using var request = CodexOAuthRefresher.BuildRefreshRequest("refresh-token");

        Assert.Equal("https://auth.openai.com/oauth/token", request.RequestUri?.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("application/json", request.Content?.Headers.ContentType?.MediaType);

        var bodyJson = await request.Content!.ReadAsStringAsync();
        var body = JsonNode.Parse(bodyJson) as JsonObject;
        Assert.NotNull(body);
        Assert.Equal(CodexOAuthRefresher.ClientId, (string?)body!["client_id"]);
        Assert.Equal("refresh_token", (string?)body["grant_type"]);
        Assert.Equal("refresh-token", (string?)body["refresh_token"]);
        Assert.Equal("openid profile email", (string?)body["scope"]);
    }

    [Fact]
    public async Task EmptyRefreshTokenReturnsCredentialsUnchanged()
    {
        var credentials = MakeCredentials() with { RefreshToken = string.Empty };
        var handler = new StubHandler(_ => throw new InvalidOperationException("空 refresh token 不得发起 HTTP 请求"));
        var refresher = new CodexOAuthRefresher(new HttpClient(handler));

        var refreshed = await refresher.RefreshAsync(credentials);

        Assert.Same(credentials, refreshed);
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task RefreshParsesRotatedTokensFromResponse()
    {
        // 成功响应体来自 auth-json-oauth.json 的 tokens 子对象（access/refresh/id 同键形）。
        var responseBody = ExtractTokensObject("auth-json-oauth.json");
        var handler = new StubHandler(_ => Response(HttpStatusCode.OK, responseBody));
        var refresher = new CodexOAuthRefresher(new HttpClient(handler));

        var refreshed = await refresher.RefreshAsync(MakeCredentials());

        Assert.Equal("access-token", refreshed.AccessToken);
        Assert.Equal("refresh-token", refreshed.RefreshToken);
        Assert.Equal("id-token", refreshed.IdToken);
        Assert.Equal("account-123", refreshed.AccountId);
        Assert.NotNull(refreshed.LastRefresh);
        Assert.Equal(1, handler.CallCount);
    }

    [Fact]
    public async Task RefreshFallsBackToOldTokensForPartialResponse()
    {
        var responseBody = TransformTokensObject("auth-json-oauth.json", tokens => tokens.Remove("refresh_token"));
        var handler = new StubHandler(_ => Response(HttpStatusCode.OK, responseBody));
        var refresher = new CodexOAuthRefresher(new HttpClient(handler));

        var refreshed = await refresher.RefreshAsync(MakeCredentials());

        Assert.Equal("access-token", refreshed.AccessToken);
        Assert.Equal("old-refresh", refreshed.RefreshToken);
    }

    [Fact]
    public async Task RefreshMapsHttpFailureToNetworkError()
    {
        var handler = new StubHandler(_ => throw new HttpRequestException("connection refused"));
        var refresher = new CodexOAuthRefresher(new HttpClient(handler));

        var exception = await Assert.ThrowsAsync<CodexOAuthRefreshException>(
            () => refresher.RefreshAsync(MakeCredentials()));

        Assert.Equal(CodexOAuthRefreshError.NetworkError, exception.Error);
    }

    // ------------------------------------------------------------------
    // 失败分类（Swift: refreshFailureError / extractErrorCode）。
    // ------------------------------------------------------------------

    [Theory]
    [InlineData("{\"error\":\"invalid_grant\"}", 400, CodexOAuthRefreshError.Revoked)]
    [InlineData("{\"error\":\"refresh_token_expired\"}", 400, CodexOAuthRefreshError.Expired)]
    [InlineData("{\"error\":\"refresh_token_reused\"}", 400, CodexOAuthRefreshError.Reused)]
    [InlineData("{\"code\":\"refresh_token_invalidated\"}", 400, CodexOAuthRefreshError.Revoked)]
    [InlineData("{}", 401, CodexOAuthRefreshError.Expired)]
    // TODO(fixture-pending)：错误体为最小内联 JSON（无录制样本）；补录后改 fixture 驱动。
    public void ClassifyFailureMapsErrorCodes(string json, int statusCode, CodexOAuthRefreshError expected)
    {
        var (error, _) = CodexOAuthRefresher.ClassifyFailure(statusCode, json);

        Assert.Equal(expected, error);
    }

    [Fact]
    public void NonAuthRefreshFailureRemainsInvalidResponse()
    {
        // Swift: non auth refresh failure remains invalid response —— invalid_request 归
        // InvalidResponse 且携带 "Status 400"。
        var (error, message) = CodexOAuthRefresher.ClassifyFailure(400, "{\"error\":\"invalid_request\"}");

        Assert.Equal(CodexOAuthRefreshError.InvalidResponse, error);
        Assert.Equal("Status 400", message);
    }

    [Fact]
    public void NestedErrorCodeObjectTakesPrecedence()
    {
        var (error, _) = CodexOAuthRefresher.ClassifyFailure(
            400, "{\"error\":{\"code\":\"invalid_grant\"}}");

        Assert.Equal(CodexOAuthRefreshError.Revoked, error);
    }

    // ------------------------------------------------------------------
    // 辅助。
    // ------------------------------------------------------------------

    private static string ExtractTokensObject(string fixtureName) =>
        TransformTokensObject(fixtureName, _ => { });

    private static string TransformTokensObject(string fixtureName, Action<JsonObject> mutate)
    {
        var root = JsonNode.Parse(CodexFixtures.Read(fixtureName)) as JsonObject
            ?? throw new InvalidOperationException($"Fixture {fixtureName} 不是 JSON 对象");
        var tokens = root["tokens"] as JsonObject
            ?? throw new InvalidOperationException($"Fixture {fixtureName} 缺 tokens 对象");
        mutate(tokens);
        return tokens.ToJsonString();
    }

    private static StubResponse Response(HttpStatusCode statusCode, string json) =>
        new(statusCode, json);

    private sealed record StubResponse(HttpStatusCode StatusCode, string Json);

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, StubResponse> _respond;

        public int CallCount { get; private set; }

        public StubHandler(Func<HttpRequestMessage, StubResponse> respond) => _respond = respond;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            CallCount++;
            var stub = _respond(request);
            var response = new HttpResponseMessage(stub.StatusCode)
            {
                Content = new StringContent(stub.Json, System.Text.Encoding.UTF8, "application/json"),
            };
            return Task.FromResult(response);
        }
    }
}
