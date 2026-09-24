// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexTokenRefresher.swift
//   （CodexTokenRefresher.refresh / refreshFailureError / extractErrorCode —— 请求构造、
//   响应解析与失败分类逐分支镜像；URLSession → HttpClient 注入）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexOAuthRefresherTests.cs

#nullable enable

using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// OAuth refresh token 刷新（Swift: CodexTokenRefresher）。POST auth.openai.com/oauth/token，
/// body 为 JSON（client_id / grant_type=refresh_token / refresh_token / scope）。
/// HttpClient 由调用方注入（应用层持有单例）；本类型不释放它。
/// </summary>
public sealed class CodexOAuthRefresher
{
    public const string RefreshEndpoint = "https://auth.openai.com/oauth/token";
    public const string ClientId = "app_EMoamEEZ73f0CkXaXp7hrann";

    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);

    /// <summary>字典键原样输出（refresh body 的键是 snake_case，不能走 camelCase 命名策略）。</summary>
    private static readonly JsonSerializerOptions BodyOptions = new();

    private readonly HttpClient _httpClient;

    public CodexOAuthRefresher(HttpClient httpClient)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
    }

    /// <summary>
    /// 刷新凭据。refresh_token 为空时原样返回（Swift 同语义——API key 模式直接放行）。
    /// 200 → 合并新旧 token（响应缺失的字段沿用旧值），lastRefresh 置当前时间；
    /// 非 200 → <see cref="ClassifyFailure"/>；网络/超时 → NetworkError；调用方取消原样传播。
    /// </summary>
    public async Task<CodexOAuthCredentials> RefreshAsync(
        CodexOAuthCredentials credentials,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(credentials.RefreshToken))
        {
            return credentials;
        }

        using var request = BuildRefreshRequest(credentials.RefreshToken);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(RequestTimeout);

        int statusCode;
        string body;
        try
        {
            using var response = await _httpClient.SendAsync(request, timeoutCts.Token).ConfigureAwait(false);
            statusCode = (int)response.StatusCode;
            body = await response.Content.ReadAsStringAsync(timeoutCts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException ex)
        {
            // 30 秒请求超时（Swift: timeoutInterval 30 → URLError(.timedOut) → networkError）。
            throw new CodexOAuthRefreshException(CodexOAuthRefreshError.NetworkError, "timed out", ex);
        }
        catch (HttpRequestException ex)
        {
            throw new CodexOAuthRefreshException(CodexOAuthRefreshError.NetworkError, ex.Message, ex);
        }

        if (statusCode != 200)
        {
            var (error, message) = ClassifyFailure(statusCode, body);
            throw new CodexOAuthRefreshException(error, message);
        }

        return ParseRefreshResponse(credentials, body, DateTimeOffset.UtcNow);
    }

    /// <summary>构造 refresh 请求（POST + application/json），供测试与上层复用。</summary>
    public static HttpRequestMessage BuildRefreshRequest(string refreshToken)
    {
        var body = new Dictionary<string, string>
        {
            ["client_id"] = ClientId,
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = refreshToken,
            ["scope"] = "openid profile email",
        };

        var request = new HttpRequestMessage(HttpMethod.Post, RefreshEndpoint);
        request.Content = new StringContent(
            JsonSerializer.Serialize(body, BodyOptions),
            Encoding.UTF8,
            "application/json");
        return request;
    }

    /// <summary>
    /// 解析 200 响应：access_token / refresh_token / id_token 缺失时沿用旧值，
    /// accountId 与来源保持不变，lastRefresh 置 <paramref name="now"/>（Swift: refresh 响应分支）。
    /// </summary>
    public static CodexOAuthCredentials ParseRefreshResponse(
        CodexOAuthCredentials credentials,
        string json,
        DateTimeOffset now)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch (JsonException ex)
        {
            throw new CodexOAuthRefreshException(CodexOAuthRefreshError.InvalidResponse, "Invalid JSON", ex);
        }

        if (node is not JsonObject root)
        {
            throw new CodexOAuthRefreshException(CodexOAuthRefreshError.InvalidResponse, "Invalid JSON");
        }

        var accessToken = StringOrNull(root["access_token"]) ?? credentials.AccessToken;
        var refreshToken = StringOrNull(root["refresh_token"]) ?? credentials.RefreshToken;
        var idToken = StringOrNull(root["id_token"]) ?? credentials.IdToken;

        return credentials with
        {
            AccessToken = accessToken,
            RefreshToken = refreshToken,
            IdToken = idToken,
            LastRefresh = now,
        };
    }

    /// <summary>
    /// 非 200 响应分类（Swift: refreshFailureError + extractErrorCode）。错误码来源优先级：
    /// error.code（对象）→ error（字符串）→ code（字符串）；refresh_token_expired → Expired、
    /// refresh_token_reused → Reused、invalid_grant / refresh_token_invalidated → Revoked；
    /// 无可识别错误码时 401 → Expired，其余 → InvalidResponse("Status &lt;code&gt;")。
    /// </summary>
    public static (CodexOAuthRefreshError Error, string Message) ClassifyFailure(int statusCode, string json)
    {
        var errorCode = ExtractErrorCode(json);
        if (errorCode is not null)
        {
            switch (errorCode.ToLowerInvariant())
            {
                case "refresh_token_expired":
                    return (CodexOAuthRefreshError.Expired, MessageFor(CodexOAuthRefreshError.Expired));
                case "refresh_token_reused":
                    return (CodexOAuthRefreshError.Reused, MessageFor(CodexOAuthRefreshError.Reused));
                case "invalid_grant":
                case "refresh_token_invalidated":
                    return (CodexOAuthRefreshError.Revoked, MessageFor(CodexOAuthRefreshError.Revoked));
            }
        }

        if (statusCode == 401)
        {
            return (CodexOAuthRefreshError.Expired, MessageFor(CodexOAuthRefreshError.Expired));
        }

        return (CodexOAuthRefreshError.InvalidResponse, $"Status {statusCode}");
    }

    private static string? ExtractErrorCode(string json)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            return null;
        }

        if (node is not JsonObject root)
        {
            return null;
        }

        if (root["error"] is JsonObject errorObject &&
            StringOrNull(errorObject["code"]) is { } objectCode)
        {
            return objectCode;
        }

        if (StringOrNull(root["error"]) is { } errorString)
        {
            return errorString;
        }

        return StringOrNull(root["code"]);
    }

    private static string? StringOrNull(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static string MessageFor(CodexOAuthRefreshError error) => error switch
    {
        CodexOAuthRefreshError.Expired =>
            "Refresh token expired. Please run `codex` to log in again.",
        CodexOAuthRefreshError.Revoked =>
            "Refresh token was revoked. Please run `codex` to log in again.",
        CodexOAuthRefreshError.Reused =>
            "Refresh token was already used. Please run `codex` to log in again.",
        CodexOAuthRefreshError.InvalidResponse =>
            "Invalid refresh response.",
        _ => "Network error during token refresh.",
    };
}
