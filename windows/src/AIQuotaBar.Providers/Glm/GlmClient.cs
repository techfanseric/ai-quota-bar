// Swift 来源：AIQuotaBar/Services/UsageService.swift — fetchGLMUsage(credentialInput:)、
// fetchGLMSubscriptionResetTime(credential:)、subscriptionURL(from:)、subscriptionResetDate(from:)、
// parseGLMDate(_:)、applyGLMHeaders(_:to:)、testGLMConnection(credentialInput:)；
// 订阅条目 DTO（GLMSubscriptionListResponse / GLMSubscriptionItem）见 AIQuotaBar/Models/UsageData.swift:759-770。
// 对应测试：AIQuotaBar/Tests/GLM/GLMUsageTests.swift:107-116（网络路径无 fixtures 样本；解析逻辑已由
// GlmQuotaParser / GlmResetAllowanceParser 的 fixtures 测试覆盖，/api/biz/subscription/list 亦无契约样本）。
// FetchCodingPlanBalanceAsync：Swift 来源：无（Windows 端新增）——ZCode 桌面客户端 coding-plan 余额端点
// 无 Swift 对应实现；形状契约见 GlmCodingPlanParser.cs 头注与 contracts/fixtures/glm/coding-plan-balance.real.json
// （[real-captured]，2026-09-27 ZCode 3.14.3 Windows 客户端日志录制，账号唯一 ID/logid 已脱敏）。

using System.Globalization;
using System.Text.Json;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// GLM 配额客户端（Swift: UsageService.fetchGLMUsage）。HttpClient 注入式、无全局状态；
/// 凭据解析 → 配额请求 → （仅旧版 TIME_LIMIT）订阅兜底 → （仅个人网页凭据）reset 权益增强。
/// </summary>
public sealed class GlmClient
{
    private static readonly TimeSpan QuotaTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan SubscriptionTimeout = TimeSpan.FromSeconds(15);

    /// <summary>
    /// ZCode 桌面客户端 coding-plan 余额端点（Windows 端新增）。响应契约已按 real fixture 校准
    /// （contracts/fixtures/glm/coding-plan-balance.real.json，[real-captured]）；直接调用的鉴权细节
    /// （Bearer 形态）待 mitm 抓包专项确认，当前以 authorization 原样透传。已知实证（2026-09-27）：
    /// 同一 JWT 认证可过（返回 400 参数错而非 401），api-key 则 401——服务端按 JWT 而非 API key 鉴权。
    /// </summary>
    public const string CodingPlanBalanceUrl = "https://zcode.z.ai/api/v1/zcode-plan/billing/balance";

    private static readonly string[] ShanghaiDateFormats =
    {
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    };
    private static readonly TimeSpan ShanghaiOffset = TimeSpan.FromHours(8);

    private readonly HttpClient _httpClient;

    public GlmClient(HttpClient httpClient) =>
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));

    public async Task<UsageData> FetchUsageAsync(
        string credentialInput,
        CancellationToken cancellationToken = default)
    {
        var credential = GlmCredentialParser.Parse(credentialInput);
        if (!Uri.TryCreate(credential.ApiUrl, UriKind.Absolute, out var quotaUrl))
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.InvalidUri, $"GLM 凭据中的 API URL 无法解析：{credential.ApiUrl}");
        }

        var json = await GetJsonAsync(
            quotaUrl, request => ApplyHeaders(request, credential), QuotaTimeout, cancellationToken)
            .ConfigureAwait(false);

        // Only legacy MCP quotas need the web subscription fallback. API keys and credit windows use
        // the quota response alone, including absent reset times.（Swift 注释原意）
        DateTimeOffset? subscriptionResetTime = null;
        if (GlmQuotaParser.RequiresLegacySubscriptionReset(json)
            && string.Equals(quotaUrl.Host, "bigmodel.cn", StringComparison.Ordinal))
        {
            subscriptionResetTime = await FetchSubscriptionResetTimeAsync(credential, cancellationToken)
                .ConfigureAwait(false);
        }

        var usage = GlmQuotaParser.Parse(json, subscriptionResetTime);

        var resetRequest = GlmResetAllowanceRequestBuilder.TryBuild(credential);
        if (resetRequest is not null)
        {
            // Optional, bounded, and independent of the authoritative quota response（Swift 注释原意）。
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, resetRequest.Url);
                foreach (var (name, value) in resetRequest.Headers)
                {
                    request.Headers.TryAddWithoutValidation(name, value);
                }
                using var response = await SendWithTimeoutAsync(
                    request, resetRequest.Timeout, cancellationToken).ConfigureAwait(false);
                if ((int)response.StatusCode == 200)
                {
                    var body = await response.Content.ReadAsStringAsync(cancellationToken)
                        .ConfigureAwait(false);
                    var allowances = GlmResetAllowanceParser.TryParse(body);
                    if (allowances is not null)
                    {
                        usage = usage with { GlmResetAllowances = allowances };
                    }
                }
            }
            catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException or GlmUsageException)
            {
                // Swift try? ... —— reset 权益失败（含 2s 超时，以及 SendWithTimeoutAsync
                // 已包装出的 GlmUsageException(NetworkError)）不得影响主额度。
            }
        }

        return usage;
    }

    /// <summary>Swift: testGLMConnection —— 完整拉一次配额即视为连通；错误向上抛。</summary>
    public async Task<bool> TestConnectionAsync(string credentialInput, CancellationToken cancellationToken = default)
    {
        _ = await FetchUsageAsync(credentialInput, cancellationToken).ConfigureAwait(false);
        return true;
    }

    /// <summary>
    /// ZCode 桌面客户端 coding-plan 余额（Windows 端新增，无 Swift 对应）：GET
    /// https://zcode.z.ai/api/v1/zcode-plan/billing/balance，Bearer JWT（凭据存 ~/.zcode/v2/credentials.json）。
    /// 复用 GetJsonAsync / 超时 / 错误映射风格；解析见 <see cref="GlmCodingPlanParser"/>。
    /// 鉴权形态：契约已按 real fixture 校准；直接调用的鉴权细节（Bearer 形态）待 mitm 抓包专项确认，
    /// 当前以 authorization 原样透传（裸 JWT 归一为恰好一次 Bearer 前缀）。已知实证（2026-09-27）：
    /// 同一 JWT 认证可过（返回 400 参数错而非 401），api-key 则 401。
    /// </summary>
    /// <param name="jwt">coding-plan JWT。裸 token 与已带 Bearer 前缀都归一为恰好一次 Bearer
    /// （对齐 GlmCredentialParser 对裸 API Key 的归一语义）。</param>
    /// <exception cref="GlmUsageException">NotConfigured：空 JWT；ApiError：非 2xx 或信封 code != 0；NetworkError：传输失败 / 超时。</exception>
    public async Task<UsageData> FetchCodingPlanBalanceAsync(
        string jwt,
        CancellationToken cancellationToken = default)
    {
        var trimmed = jwt.Trim();
        if (trimmed.Length == 0)
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.NotConfigured, "GLM coding-plan JWT 为空（未配置）。");
        }

        var lowercased = trimmed.ToLowerInvariant();
        var bearer = lowercased.StartsWith("bearer ", StringComparison.Ordinal)
            ? trimmed
            : $"Bearer {trimmed}";

        var json = await GetJsonAsync(
            new Uri(CodingPlanBalanceUrl),
            request =>
            {
                request.Headers.TryAddWithoutValidation("Authorization", bearer);
                request.Headers.TryAddWithoutValidation("Accept", "application/json");
            },
            QuotaTimeout,
            cancellationToken).ConfigureAwait(false);

        return GlmCodingPlanParser.Parse(json);
    }

    private async Task<string> GetJsonAsync(
        Uri url,
        Action<HttpRequestMessage> configureRequest,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        configureRequest(request);
        using var response = await SendWithTimeoutAsync(request, timeout, cancellationToken)
            .ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var message = body.Length > 0 ? body : $"HTTP {(int)response.StatusCode}";
            throw new GlmUsageException(GlmUsageErrorKind.ApiError, message);
        }
        return body;
    }

    private async Task<HttpResponseMessage> SendWithTimeoutAsync(
        HttpRequestMessage request,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutSource.CancelAfter(timeout);
        try
        {
            return await _httpClient.SendAsync(request, timeoutSource.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException
            && !cancellationToken.IsCancellationRequested)
        {
            // 传输失败 / 请求超时（Swift timeoutInterval）→ networkError；用户主动取消则原样上抛。
            throw new GlmUsageException(GlmUsageErrorKind.NetworkError, ex.Message, ex);
        }
    }

    /// <summary>
    /// Swift: fetchGLMSubscriptionResetTime —— 旧版 TIME_LIMIT 缺 reset 时的 /api/biz/subscription/list
    /// 兜底。任何失败都返回 null（Swift 调用方以 try? 包裹）。
    /// </summary>
    private async Task<DateTimeOffset?> FetchSubscriptionResetTimeAsync(
        GlmCredential credential,
        CancellationToken cancellationToken)
    {
        var subscriptionUrl = SubscriptionUrlFrom(credential.ApiUrl);
        if (subscriptionUrl is null)
        {
            return null;
        }
        string json;
        try
        {
            json = await GetJsonAsync(
                subscriptionUrl,
                request => ApplyHeaders(request, credential),
                SubscriptionTimeout,
                cancellationToken).ConfigureAwait(false);
        }
        catch (GlmUsageException)
        {
            return null; // 非 2xx / 网络失败 → nil（Swift guard 非 2xx return nil / try? 兜底）
        }
        return ParseSubscriptionResetTime(json);
    }

    /// <summary>Swift: subscriptionURL(from:) —— 同 origin、路径换成 /api/biz/subscription/list、去查询串。</summary>
    private static Uri? SubscriptionUrlFrom(string quotaUrl)
    {
        if (!Uri.TryCreate(quotaUrl, UriKind.Absolute, out var url))
        {
            return null;
        }
        var builder = new UriBuilder(url)
        {
            Path = "/api/biz/subscription/list",
            Query = null,
            Fragment = string.Empty,
        };
        return builder.Uri;
    }

    private static DateTimeOffset? ParseSubscriptionResetTime(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("code", out var codeElement)
                || codeElement.ValueKind != JsonValueKind.Number
                || !codeElement.TryGetInt32(out var code)
                || !root.TryGetProperty("success", out var successElement)
                || (successElement.ValueKind != JsonValueKind.True
                    && successElement.ValueKind != JsonValueKind.False)
                || code != 200
                || !successElement.GetBoolean())
            {
                return null;
            }

            var dates = new List<DateTimeOffset>();
            if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in data.EnumerateArray())
                {
                    var date = SubscriptionResetDate(item);
                    if (date is { } value)
                    {
                        dates.Add(value);
                    }
                }
            }
            if (dates.Count == 0)
            {
                return null;
            }

            // Swift min(by:) 折叠：优先未来里最近的重置；全是过去时取最晚的过去时间。
            var best = dates[0];
            var now = DateTimeOffset.UtcNow;
            foreach (var candidate in dates)
            {
                if (IsEarlierForReset(candidate, best, now))
                {
                    best = candidate;
                }
            }
            return best;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static bool IsEarlierForReset(DateTimeOffset lhs, DateTimeOffset rhs, DateTimeOffset now)
    {
        var lhsInterval = (lhs - now).TotalSeconds;
        var rhsInterval = (rhs - now).TotalSeconds;
        if (lhsInterval >= 0 && rhsInterval >= 0)
        {
            return lhsInterval < rhsInterval;
        }
        return lhs > rhs;
    }

    /// <summary>Swift: subscriptionResetDate(from:) —— nextRenewTime 优先，否则取 valid 后三段（日期部分）。</summary>
    private static DateTimeOffset? SubscriptionResetDate(JsonElement item)
    {
        if (item.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        if (item.TryGetProperty("nextRenewTime", out var nextRenewTimeElement)
            && nextRenewTimeElement.ValueKind == JsonValueKind.String
            && ParseGlmDate(nextRenewTimeElement.GetString()!) is { } nextRenewTime)
        {
            return nextRenewTime;
        }
        if (item.TryGetProperty("valid", out var validElement)
            && validElement.ValueKind == JsonValueKind.String
            && validElement.GetString() is { } valid)
        {
            var parts = valid.Split('-');
            if (parts.Length >= 6)
            {
                return ParseGlmDate(string.Join("-", parts[^3..]));
            }
        }
        return null;
    }

    /// <summary>Swift: parseGLMDate —— 上海时区三种格式，失败再按毫秒时间戳。</summary>
    private static DateTimeOffset? ParseGlmDate(string text)
    {
        var trimmed = text.Trim();
        foreach (var format in ShanghaiDateFormats)
        {
            if (DateTime.TryParseExact(
                    trimmed, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var wallClock))
            {
                return new DateTimeOffset(wallClock, ShanghaiOffset);
            }
        }
        if (long.TryParse(trimmed, NumberStyles.Integer, CultureInfo.InvariantCulture, out var milliseconds))
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds);
        }
        return null;
    }

    /// <summary>Swift: applyGLMHeaders(_:to:) —— 凭据头优先，缺省头补齐，组织/项目/Cookie 收尾。</summary>
    private static void ApplyHeaders(HttpRequestMessage request, GlmCredential credential)
    {
        foreach (var (name, value) in credential.Headers)
        {
            request.Headers.TryAddWithoutValidation(name, value);
        }
        // HTTP 头名大小写不敏感：缺省判断用 OrdinalIgnoreCase，避免凭据头表里存了 "Accept" 之类
        // 混合大小写键时重复补一份缺省头（Swift 字典下标是精确匹配，此处有意收紧）。
        if (!HasHeader(credential.Headers, "accept"))
        {
            request.Headers.TryAddWithoutValidation("Accept", "application/json, text/plain, */*");
        }
        if (!HasHeader(credential.Headers, "content-type"))
        {
            request.Headers.TryAddWithoutValidation("Content-Type", "application/json");
        }
        if (!HasHeader(credential.Headers, "authorization"))
        {
            request.Headers.TryAddWithoutValidation("Authorization", credential.Authorization);
        }
        if (!HasHeader(credential.Headers, "accept-language"))
        {
            request.Headers.TryAddWithoutValidation("Accept-Language", "zh");
        }
        if (!HasHeader(credential.Headers, "set-language"))
        {
            request.Headers.TryAddWithoutValidation("Set-Language", "zh");
        }
        if (!string.IsNullOrEmpty(credential.Organization))
        {
            request.Headers.TryAddWithoutValidation("bigmodel-organization", credential.Organization);
        }
        if (!string.IsNullOrEmpty(credential.Project))
        {
            request.Headers.TryAddWithoutValidation("bigmodel-project", credential.Project);
        }
        if (!string.IsNullOrEmpty(credential.Cookie))
        {
            request.Headers.TryAddWithoutValidation("Cookie", credential.Cookie);
        }
    }

    private static bool HasHeader(IReadOnlyDictionary<string, string> headers, string name) =>
        headers.Keys.Any(key => string.Equals(key, name, StringComparison.OrdinalIgnoreCase));
}
