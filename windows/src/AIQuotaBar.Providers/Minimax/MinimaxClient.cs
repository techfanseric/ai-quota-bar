// Swift 来源（契约基准）：.dependencies/codexbar/Sources/CodexBarCore/Providers/MiniMax/
// MiniMaxUsageFetcher.swift — fetchUsage(apiToken:region:)（Global 被拒回退中国大陆）、
// fetchUsageOnce(apiToken:remainsURLs:)（token-plan 失败尝试 legacy coding-plan）、
// fetchAPIUsageOnce(...)（Bearer + accept/Content-Type + MM-API-Source 头、401/403 → invalidCredentials）。
// macOS 端对应：AIQuotaBar/Services/UsageService.swift — fetchMiniMaxUsage / testMiniMaxConnection。
// 对应测试：无 fixtures（网络路径）；解析已由 MinimaxTokenPlanParser 的 fixtures 测试覆盖。
//
// 暂缓项：codexbar 的 Cookie + HTML 抓取路径（fetchUsage(cookieHeader:...)，含 __NEXT_DATA__ / 多服务
// services[] / 账单历史分页）未移植 —— Windows 端先落地 API-token 主路径，Cookie 模式待样本补录后跟进。

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Minimax;

/// <summary>
/// MiniMax 用量客户端（codexbar: MiniMaxUsageFetcher.fetchUsage(apiToken:region:)）。HttpClient 注入式；
/// token-plan 端点失败时按 codexbar 规则尝试 legacy coding-plan 端点，Global 区域凭据被拒时回退中国大陆。
/// </summary>
public sealed class MinimaxClient
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(30);

    private readonly HttpClient _httpClient;
    private readonly MinimaxApiRegion _region;
    private readonly Uri _tokenPlanRemainsUrl;
    private readonly Uri _codingPlanRemainsUrl;

    public MinimaxClient(
        HttpClient httpClient,
        MinimaxApiRegion region = MinimaxApiRegion.Global,
        Uri? tokenPlanRemainsUrl = null,
        Uri? codingPlanRemainsUrl = null)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _region = region;
        _tokenPlanRemainsUrl = tokenPlanRemainsUrl ?? region.TokenPlanRemainsUrl();
        _codingPlanRemainsUrl = codingPlanRemainsUrl ?? region.CodingPlanRemainsUrl();
    }

    public async Task<UsageData> FetchUsageAsync(
        string apiToken,
        string? groupId = null,
        CancellationToken cancellationToken = default)
    {
        var cleaned = apiToken.Trim();
        if (cleaned.Length == 0)
        {
            throw new MinimaxUsageException(MinimaxUsageErrorKind.NotConfigured, "MiniMax API token 为空（未配置）。");
        }

        try
        {
            return await FetchFromEndpointsAsync(
                cleaned, _tokenPlanRemainsUrl, _codingPlanRemainsUrl, groupId, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (MinimaxUsageException ex) when (ex.Kind == MinimaxUsageErrorKind.InvalidCredentials
            && _region == MinimaxApiRegion.Global)
        {
            // 无持久化区域设置时默认 Global；token 被拒后回退中国大陆 host，避免升级回归既有配置
            // （codexbar: fetchUsage(apiToken:region:) 的 chinaMainland 重试，保留原 invalidCredentials）。
            try
            {
                return await FetchFromEndpointsAsync(
                    cleaned,
                    MinimaxApiRegion.ChinaMainland.TokenPlanRemainsUrl(),
                    MinimaxApiRegion.ChinaMainland.CodingPlanRemainsUrl(),
                    groupId,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (MinimaxUsageException)
            {
                throw new MinimaxUsageException(
                    MinimaxUsageErrorKind.InvalidCredentials, "MiniMax API token 无效或已过期。");
            }
        }
    }

    /// <summary>macOS: testMiniMaxConnection —— 解析失败 / API 错误返回 false；网络错误向上抛。</summary>
    public async Task<bool> TestConnectionAsync(string apiToken, CancellationToken cancellationToken = default)
    {
        try
        {
            _ = await FetchUsageAsync(apiToken, cancellationToken: cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (MinimaxUsageException ex) when (ex.Kind is MinimaxUsageErrorKind.InvalidCredentials
            or MinimaxUsageErrorKind.ApiError
            or MinimaxUsageErrorKind.InvalidResponse)
        {
            return false;
        }
    }

    /// <summary>codexbar: fetchUsageOnce —— 依次尝试 token-plan 与 legacy coding-plan 端点。</summary>
    private async Task<UsageData> FetchFromEndpointsAsync(
        string apiToken,
        Uri tokenPlanUrl,
        Uri codingPlanUrl,
        string? groupId,
        CancellationToken cancellationToken)
    {
        Exception? lastError = null;
        var tokenPlanCredentialFailure = false;
        var endpoints = new (Uri Url, bool IsTokenPlan)[]
        {
            (tokenPlanUrl, true),
            (codingPlanUrl, false),
        };
        foreach (var (url, isTokenPlan) in endpoints)
        {
            try
            {
                return await FetchOnceAsync(apiToken, url, groupId, cancellationToken).ConfigureAwait(false);
            }
            catch (MinimaxUsageException ex)
            {
                lastError = ex;
                // codexbar shouldTryNextEndpoint：invalidCredentials 仅 token-plan 首段可重试；
                // apiError 只在 HTTP 404/405 换端点；networkError / parseFailed 总是换端点。
                var canContinue = isTokenPlan && ex.Kind switch
                {
                    MinimaxUsageErrorKind.InvalidCredentials => true,
                    MinimaxUsageErrorKind.ApiError =>
                        ex.Message.Contains("HTTP 404", StringComparison.Ordinal)
                        || ex.Message.Contains("HTTP 405", StringComparison.Ordinal),
                    MinimaxUsageErrorKind.NetworkError or MinimaxUsageErrorKind.InvalidResponse => true,
                    _ => false,
                };
                if (!canContinue)
                {
                    if (tokenPlanCredentialFailure)
                    {
                        throw new MinimaxUsageException(
                            MinimaxUsageErrorKind.InvalidCredentials, "MiniMax API token 无效或已过期。");
                    }
                    throw;
                }
                if (ex.Kind == MinimaxUsageErrorKind.InvalidCredentials)
                {
                    tokenPlanCredentialFailure = true;
                }
            }
        }
        throw lastError ?? new MinimaxUsageException(
            MinimaxUsageErrorKind.InvalidResponse, "MiniMax 缺少可用的 remains 端点。");
    }

    /// <summary>codexbar: fetchAPIUsageOnce —— 单端点 GET + Bearer + 解析。</summary>
    private async Task<UsageData> FetchOnceAsync(
        string apiToken,
        Uri remainsUrl,
        string? groupId,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, AppendGroupId(remainsUrl, groupId));
        request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {apiToken}");
        request.Headers.TryAddWithoutValidation("accept", "application/json");
        request.Headers.TryAddWithoutValidation("Content-Type", "application/json");
        // codexbar 同名头的值为 "CodexBar"；Windows 端改用本应用名（标识头，无协议语义）。
        request.Headers.TryAddWithoutValidation("MM-API-Source", "AIQuotaBar");

        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(RequestTimeout);
        HttpResponseMessage response;
        try
        {
            response = await _httpClient.SendAsync(request, timeoutSource.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException
            && !cancellationToken.IsCancellationRequested)
        {
            throw new MinimaxUsageException(MinimaxUsageErrorKind.NetworkError, ex.Message, ex);
        }

        using (response)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var status = (int)response.StatusCode;
            if (status == 401 || status == 403)
            {
                throw new MinimaxUsageException(
                    MinimaxUsageErrorKind.InvalidCredentials, $"HTTP {status}");
            }
            if (status is < 200 or > 299)
            {
                throw new MinimaxUsageException(MinimaxUsageErrorKind.ApiError, $"HTTP {status}");
            }
            return MinimaxTokenPlanParser.Parse(body);
        }
    }

    /// <summary>codexbar: appendGroupID —— 追加 GroupId 查询参数（无则原样返回）。</summary>
    private static Uri AppendGroupId(Uri url, string? groupId)
    {
        if (string.IsNullOrEmpty(groupId))
        {
            return url;
        }
        var builder = new UriBuilder(url);
        var query = builder.Query.StartsWith('?', StringComparison.Ordinal)
            ? builder.Query[1..]
            : builder.Query;
        builder.Query = string.IsNullOrEmpty(query)
            ? $"GroupId={Uri.EscapeDataString(groupId)}"
            : $"{query}&GroupId={Uri.EscapeDataString(groupId)}";
        return builder.Uri;
    }
}
