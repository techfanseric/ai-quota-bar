// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuthUsageFetcher.swift
//   的 HTTP 抓取环节（resolveUsageURL 的路径拼接与请求头）——URL/头/端点按 Win-CodexBar
//   rust/src/providers/codex/api.rs 实证（fetch_usage_once：GET {base}/wham/usage，
//   Authorization Bearer + User-Agent "CodexBar" + Accept + ChatGPT-Account-Id）。
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexUsageClientTests.cs
//
// 分层说明：本类型只做传输（拉原始 JSON 与错误分类）；解码在 CodexUsageParser，
// auth.json 读取 / 刷新编排在 CodexQuotaService。HttpClient 注入式（GlmClient 同风格），
// 无全局状态，本类型不释放它。

#nullable enable

using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace AIQuotaBar.Providers.Codex;

/// <summary>
/// Codex usage 端点客户端（Swift: CodexOAuthUsageFetcher 的网络环节）。默认端点
/// https://chatgpt.com/backend-api/wham/usage，OAuth 与 API key 同路径（Bearer 头形态）。
/// </summary>
public sealed class CodexUsageClient
{
    /// <summary>Win-CodexBar 实证的默认后端基址（chatgpt.com backend-api）。</summary>
    public const string DefaultBaseUrl = "https://chatgpt.com/backend-api";

    /// <summary>usage 端点路径（Win-CodexBar: USAGE_PATH）。</summary>
    public const string UsagePath = "/wham/usage";

    /// <summary>
    /// User-Agent 沿用 Win-CodexBar 实证值 "CodexBar"（同源 Swift codexbar 客户端），
    /// chatgpt.com 后端对该值无过滤；换成自造 UA 属未实证行为。
    /// </summary>
    public const string UserAgent = "CodexBar";

    private static readonly TimeSpan UsageTimeout = TimeSpan.FromSeconds(30);

    /// <summary>错误体摘录上限：chatgpt.com 错误页可能是长 HTML，只保留开头用于诊断。</summary>
    private const int ErrorBodyExcerptLength = 200;

    private readonly HttpClient _httpClient;
    private readonly string _baseUrl;

    /// <param name="httpClient">调用方持有的 HttpClient（应用层单例语义）。</param>
    /// <param name="baseUrl">后端基址覆盖（测试指向本地桩）；空白回落 <see cref="DefaultBaseUrl"/>。</param>
    public CodexUsageClient(HttpClient httpClient, string? baseUrl = null)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _baseUrl = string.IsNullOrWhiteSpace(baseUrl) ? DefaultBaseUrl : baseUrl.TrimEnd('/');
    }

    /// <summary>
    /// GET {BaseUrl}/wham/usage，返回原始响应体（解析归 CodexUsageParser）。
    /// 401 → <see cref="CodexUsageError.AuthRequired"/>（附 re-login 提示）；
    /// 其余非 2xx → ApiError（附响应体摘录）；传输失败/超时 → NetworkError；调用方取消原样传播。
    /// </summary>
    /// <param name="accessToken">Bearer token（OAuth access_token 或 API key）。</param>
    /// <param name="accountId">tokens.account_id；非空白时附 ChatGPT-Account-Id 头（可空）。</param>
    public async Task<string> FetchUsageJsonAsync(
        string accessToken,
        string? accountId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(accessToken))
        {
            throw new CodexUsageException(CodexUsageError.NotConfigured, "Codex access token 为空（未配置）。");
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, _baseUrl + UsagePath);
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {accessToken}");
        request.Headers.TryAddWithoutValidation("User-Agent", UserAgent);
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        if (!string.IsNullOrWhiteSpace(accountId))
        {
            request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", accountId);
        }

        using var response = await SendWithTimeoutAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            ThrowForStatus((int)response.StatusCode, body);
        }

        return body;
    }

    private static void ThrowForStatus(int statusCode, string body)
    {
        if (statusCode == 401)
        {
            // Win-CodexBar: authenticated_http_error —— 401 折叠为 AuthRequired 并给 re-login 提示。
            throw new CodexUsageException(
                CodexUsageError.AuthRequired,
                $"Codex API rejected the access token (HTTP 401). Run `codex login` to sign in again.",
                statusCode: statusCode);
        }

        var detail = body.Length == 0
            ? $"HTTP {statusCode}"
            : body.Length > ErrorBodyExcerptLength ? body[..ErrorBodyExcerptLength] : body;
        throw new CodexUsageException(CodexUsageError.ApiError, detail, statusCode: statusCode);
    }

    private async Task<HttpResponseMessage> SendWithTimeoutAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(UsageTimeout);
        try
        {
            return await _httpClient.SendAsync(request, timeoutSource.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException
            && !cancellationToken.IsCancellationRequested)
        {
            // 传输失败 / 30s 超时 → NetworkError；用户主动取消原样上抛（GlmClient 同语义）。
            throw new CodexUsageException(CodexUsageError.NetworkError, ex.Message, innerException: ex);
        }
    }
}
