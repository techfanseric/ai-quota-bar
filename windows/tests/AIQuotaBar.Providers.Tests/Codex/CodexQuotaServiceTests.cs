// Swift 来源：无直接对应（macOS 侧编排在 CodexUsageService + ProviderFetchContext，未随 W1 移植）；
//   行为参照 Win-CodexBar rust/src/providers/codex/api.rs fetch_usage：load_credentials（auth.json
//   缺失 → "Run codex login" 指引）→ fetch_usage_once（Bearer + ChatGPT-Account-Id 拉取），
//   刷新语义来自 codexbar CodexTokenRefresher（过期 → 刷新 → 回写）。
// fixtures：usage-response-oauth-windows.json（成功响应体）、auth-json-oauth.json（刷新响应体
//   的 tokens 子对象，与 CodexOAuthRefresherTests 同法派生）、auth-json-pat.json（PAT-only auth.json）。
// 全链注入：auth.json 指向临时 CODEX_HOME，刷新与 usage 各自 StubHandler（无真实网络）。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Codex;
using AIQuotaBar.Providers.Codex.Credentials;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexQuotaServiceTests : IDisposable
{
    private const string UsageBaseUrl = "http://codex-usage.test";

    private readonly CodexHome _home = new();

    public void Dispose() => _home.Dispose();

    // ------------------------------------------------------------------
    // 全链：codex home → usage（无需刷新）。
    // ------------------------------------------------------------------

    [Fact]
    public async Task FreshTokenFetchesUsageWithoutRefresh()
    {
        var accessToken = MakeJwt(ExpiresAt(secondsFromNow: 3600));
        _home.WriteAuthJson(OAuthAuthJson(accessToken));
        var refresh = NeverCalledHandler("token 未过期不得发起刷新请求");
        var usage = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, UsageFixture()));
        var service = MakeService(refresh, usage);

        var result = await service.FetchFromCodexHomeAsync();

        Assert.Equal(UsageProvider.Codex, result.Provider);
        Assert.Equal(2, result.Models.Count);
        Assert.Equal("5h", result.Models[0].ModelName);
        Assert.Equal(78, result.Models[0].CurrentIntervalRemaining); // 100 - used_percent 22
        Assert.Equal("Weekly", result.Models[1].ModelName);
        Assert.Equal(57, result.Models[1].CurrentIntervalRemaining); // 100 - used_percent 43
        Assert.Equal(2, result.Remains);
        Assert.Equal(2, result.Total);

        var request = usage.SingleRequest();
        Assert.Equal("Bearer " + accessToken, request.Header("Authorization"));
        Assert.Equal("acct-test", request.Header("ChatGPT-Account-Id"));
    }

    // ------------------------------------------------------------------
    // 刷新链：过期 → 刷新 → 回写 → 以新 token 拉取。
    // ------------------------------------------------------------------

    [Fact]
    public async Task ExpiredTokenRefreshesSavesAndFetchesWithRotatedToken()
    {
        _home.WriteAuthJson(OAuthAuthJson(MakeJwt(ExpiresAt(secondsFromNow: -60))));
        var refresh = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, RotatedRefreshBody()));
        var usage = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, UsageFixture()));
        var service = MakeService(refresh, usage);

        var result = await service.FetchFromCodexHomeAsync();

        Assert.Equal(UsageProvider.Codex, result.Provider);
        Assert.Equal(2, result.Models.Count);

        // 刷新请求发往 auth.openai.com/oauth/token（W1 CodexOAuthRefresher 实证端点）。
        var refreshRequest = refresh.SingleRequest();
        Assert.Equal(CodexOAuthRefresher.RefreshEndpoint, refreshRequest.Uri);

        // usage 用轮换后的 access token。
        Assert.Equal("Bearer rotated-access", usage.SingleRequest().Header("Authorization"));

        // 刷新结果回写 auth.json（合并语义保留 account_id）。
        var saved = (JsonObject)JsonNode.Parse(_home.ReadAuthJson())!;
        var savedTokens = (JsonObject)saved["tokens"]!;
        Assert.Equal("rotated-access", (string?)savedTokens["access_token"]);
        Assert.Equal("rotated-refresh", (string?)savedTokens["refresh_token"]);
        Assert.Equal("acct-test", (string?)savedTokens["account_id"]);
    }

    [Fact]
    public async Task RefreshFailureDegradesToStaleToken()
    {
        var accessToken = MakeJwt(ExpiresAt(secondsFromNow: -60));
        _home.WriteAuthJson(OAuthAuthJson(accessToken));
        var refresh = new RecordingHandler(
            _ => JsonResponse(HttpStatusCode.BadRequest, "{\"error\":\"invalid_grant\"}"));
        var usage = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, UsageFixture()));
        var service = MakeService(refresh, usage);

        // 刷新失败（revoked 分类）降级：沿用旧 access token 继续拉取，本次仍出数。
        var result = await service.FetchFromCodexHomeAsync();

        Assert.Equal(UsageProvider.Codex, result.Provider);
        Assert.Equal(2, result.Models.Count);
        Assert.Equal(1, refresh.Requests.Count);
        Assert.Equal("Bearer " + accessToken, usage.SingleRequest().Header("Authorization"));
    }

    [Fact]
    public async Task RefreshFailureThenAuthRejectionSurfacesLoginHint()
    {
        _home.WriteAuthJson(OAuthAuthJson(MakeJwt(ExpiresAt(secondsFromNow: -60))));
        var refresh = new RecordingHandler(
            _ => JsonResponse(HttpStatusCode.BadRequest, "{\"error\":\"invalid_grant\"}"));
        var usage = new RecordingHandler(_ => JsonResponse(HttpStatusCode.Unauthorized, "refused"));
        var service = MakeService(refresh, usage);

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => service.FetchFromCodexHomeAsync());

        Assert.Equal(CodexUsageError.AuthRequired, exception.Kind);
        Assert.Contains("codex login", exception.Message);
    }

    [Fact]
    public async Task RefreshSaveFailureStillUsesRotatedToken()
    {
        _home.WriteAuthJson(OAuthAuthJson(MakeJwt(ExpiresAt(secondsFromNow: -60))));
        _home.MarkAuthJsonReadOnly();
        var refresh = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, RotatedRefreshBody()));
        var usage = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, UsageFixture()));
        var service = MakeService(refresh, usage);

        // 回写失败（auth.json 只读）不阻断：本次仍用轮换 token 拉取，磁盘留旧值。
        var result = await service.FetchFromCodexHomeAsync();

        Assert.Equal(UsageProvider.Codex, result.Provider);
        Assert.Equal("Bearer rotated-access", usage.SingleRequest().Header("Authorization"));
        var saved = (JsonObject)JsonNode.Parse(_home.ReadAuthJson())!;
        Assert.NotEqual("rotated-access", (string?)((JsonObject)saved["tokens"]!)["access_token"]);
    }

    // ------------------------------------------------------------------
    // auth.json 读取失败形态。
    // ------------------------------------------------------------------

    [Fact]
    public async Task MissingAuthJsonSurfacesSignInGuidance()
    {
        var service = MakeService(
            NeverCalledHandler("无凭据不得刷新"), NeverCalledHandler("无凭据不得拉取"));

        var exception = await Assert.ThrowsAsync<CodexCredentialException>(
            () => service.FetchFromCodexHomeAsync());

        Assert.Equal(CodexCredentialError.NotFound, exception.Error);
        Assert.Contains("codex login", exception.Message);
    }

    [Fact]
    public async Task PatOnlyAuthJsonSurfacesMissingTokens()
    {
        _home.WriteAuthJson(CodexFixtures.Read("auth-json-pat.json"));
        var service = MakeService(
            NeverCalledHandler("PAT 形态不得刷新"), NeverCalledHandler("PAT 形态不得拉取"));

        var exception = await Assert.ThrowsAsync<CodexCredentialException>(
            () => service.FetchFromCodexHomeAsync());

        Assert.Equal(CodexCredentialError.MissingTokens, exception.Error);
    }

    // ------------------------------------------------------------------
    // 调用方自带 API key（Credential Manager 路径）。
    // ------------------------------------------------------------------

    [Fact]
    public async Task ApiKeyFetchesDirectlyWithoutRefresh()
    {
        var refresh = NeverCalledHandler("API key 无需刷新");
        var usage = new RecordingHandler(_ => JsonResponse(HttpStatusCode.OK, UsageFixture()));
        var service = MakeService(refresh, usage);

        var result = await service.FetchWithApiKeyAsync("  sk-test-123  ");

        Assert.Equal(UsageProvider.Codex, result.Provider);
        Assert.Equal(2, result.Models.Count);
        Assert.Equal("Bearer sk-test-123", usage.SingleRequest().Header("Authorization"));
    }

    [Fact]
    public async Task BlankApiKeyThrowsNotConfigured()
    {
        var service = MakeService(
            NeverCalledHandler("空 key 不得刷新"), NeverCalledHandler("空 key 不得拉取"));

        var exception = await Assert.ThrowsAsync<CodexUsageException>(
            () => service.FetchWithApiKeyAsync("   "));

        Assert.Equal(CodexUsageError.NotConfigured, exception.Kind);
    }

    // ------------------------------------------------------------------
    // 辅助。
    // ------------------------------------------------------------------

    private CodexQuotaService MakeService(RecordingHandler refresh, RecordingHandler usage) =>
        new(
            new CodexAuthStore(_home.Environment),
            new CodexOAuthRefresher(new HttpClient(refresh)),
            new CodexUsageClient(new HttpClient(usage), UsageBaseUrl));

    private static RecordingHandler NeverCalledHandler(string reason) =>
        new(_ => throw new InvalidOperationException(reason));

    private static string UsageFixture() => CodexFixtures.Read("usage-response-oauth-windows.json");

    /// <summary>刷新成功响应体：fixtures auth-json-oauth.json 的 tokens 子对象（与 refresh 响应同键形），
    /// 轮换 access/refresh 值以区分新旧 token（CodexOAuthRefresherTests 同法派生）。</summary>
    private static string RotatedRefreshBody()
    {
        var root = (JsonObject)JsonNode.Parse(CodexFixtures.Read("auth-json-oauth.json"))!;
        var tokens = (JsonObject)root["tokens"]!;
        tokens["access_token"] = "rotated-access";
        tokens["refresh_token"] = "rotated-refresh";
        return tokens.ToJsonString();
    }

    private static string OAuthAuthJson(string accessToken) =>
        new JsonObject
        {
            ["tokens"] = new JsonObject
            {
                ["access_token"] = accessToken,
                ["refresh_token"] = "old-refresh",
                ["account_id"] = "acct-test",
            },
        }.ToJsonString();

    /// <summary>合成 JWT（仅 exp 声明）——CodexAuthStore.ExpirationFromJWT 只认三段式 + 整数 exp。</summary>
    private static string MakeJwt(long expiresAtUnixSeconds) =>
        $"{Base64UrlEncode("{\"alg\":\"RS256\",\"typ\":\"JWT\"}")}"
        + $".{Base64UrlEncode($"{{\"exp\":{expiresAtUnixSeconds}}}")}"
        + ".signature";

    private static long ExpiresAt(int secondsFromNow) =>
        DateTimeOffset.UtcNow.AddSeconds(secondsFromNow).ToUnixTimeSeconds();

    private static string Base64UrlEncode(string json)
    {
        var base64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(json));
        return base64.TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    private static HttpResponseMessage JsonResponse(HttpStatusCode statusCode, string json) =>
        new(statusCode)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

    /// <summary>临时 CODEX_HOME（auth.json 落盘用），Dispose 时清只读属性并递归删除。</summary>
    private sealed class CodexHome : IDisposable
    {
        public CodexHome() =>
            RootPath = Path.Combine(Path.GetTempPath(), "aqb-codex-home-" + Guid.NewGuid().ToString("N"));

        public string RootPath { get; }

        public string AuthJsonPath => Path.Combine(RootPath, "auth.json");

        public ICodexEnvironment Environment => new FixedEnvironment(RootPath);

        public void WriteAuthJson(string json)
        {
            System.IO.Directory.CreateDirectory(RootPath);
            File.WriteAllText(AuthJsonPath, json);
        }

        public string ReadAuthJson() => File.ReadAllText(AuthJsonPath);

        public void MarkAuthJsonReadOnly() => File.SetAttributes(AuthJsonPath, FileAttributes.ReadOnly);

        public void Dispose()
        {
            if (File.Exists(AuthJsonPath) &&
                File.GetAttributes(AuthJsonPath).HasFlag(FileAttributes.ReadOnly))
            {
                File.SetAttributes(AuthJsonPath, FileAttributes.Normal);
            }

            try
            {
                System.IO.Directory.Delete(RootPath, recursive: true);
            }
            catch (IOException)
            {
                // 临时目录清理失败不影响测试结果。
            }
        }
    }

    private sealed class FixedEnvironment : ICodexEnvironment
    {
        public FixedEnvironment(string codexHomeDirectory) => CodexHomeDirectory = codexHomeDirectory;

        public string CodexHomeDirectory { get; }
    }

    /// <summary>
    /// 记录请求（方法/URI/头快照——HttpRequestMessage 在 Send 返回后会被 HttpClient 处置，
    /// 故在调用时复制）并按脚本应答。
    /// </summary>
    private sealed class RecordingHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _respond;

        public RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) =>
            _respond = respond;

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
