// Swift 来源：AIQuotaBar/Models/GLMResetAllowances.swift — static func request(for:)（端点允许清单）。
// 对应测试：AIQuotaBar/Tests/GLM/GLMResetAllowanceTests.swift:19-36
// （testRequestDoesNotSendCredentialsToUnverifiedHostsOrScopes）。
//
// Swift 返回 URLRequest?（nil = 凭据不满足允许清单，不发请求）；C# 侧 HttpClient 的请求消息不承载
// 超时/Cookie 策略，因此这里产出“请求计划”记录：URL、2 秒有界超时、仅 Authorization/Accept 两个头
// （Cookie 结构性缺席 —— 客户端按计划渲染时永不写入 Cookie 头，等价于 Swift 的 httpShouldHandleCookies=false）。

namespace AIQuotaBar.Providers.Glm;

/// <summary>reset-allowances 请求计划（Swift: GLMResetAllowances.request(for:) 的可断言投影）。</summary>
/// <param name="Url">固定个人作用域端点。</param>
/// <param name="Timeout">2 秒有界超时（Swift: timeoutInterval = 2）。</param>
/// <param name="Headers">仅 Authorization + Accept；凭据 Cookie / 组织 / 项目一律不得进入。</param>
public sealed record GlmResetAllowanceRequest(
    Uri Url,
    TimeSpan Timeout,
    IReadOnlyDictionary<string, string> Headers);

/// <summary>
/// 只有已验证的 CN 网页端点与个人作用域可以共享这批凭据（Swift 注释原意）。任何不满足条件返回 null。
/// </summary>
public static class GlmResetAllowanceRequestBuilder
{
    public static readonly Uri PersonalListUrl =
        new("https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL");

    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(2);

    public static GlmResetAllowanceRequest? TryBuild(GlmCredential credential)
    {
        if (!Uri.TryCreate(credential.ApiUrl, UriKind.Absolute, out var source))
        {
            return null;
        }
        if (!string.Equals(source.Scheme, "https", StringComparison.Ordinal))
        {
            return null;
        }
        // Swift: source.host == "bigmodel.cn"（大小写敏感）；host 需与配额端点完全一致。
        if (!string.Equals(source.Host, "bigmodel.cn", StringComparison.Ordinal))
        {
            return null;
        }
        // Swift: source.port == nil（不得显式带非默认端口）。
        if (!source.IsDefaultPort)
        {
            return null;
        }
        if (source.AbsolutePath != "/api/monitor/usage/quota/limit")
        {
            return null;
        }
        if (HasDisallowedTypeQueryParameter(source.Query))
        {
            return null;
        }
        if (!string.IsNullOrWhiteSpace(credential.Organization)
            || !string.IsNullOrWhiteSpace(credential.Project))
        {
            return null;
        }
        foreach (var (name, value) in credential.Headers)
        {
            // Swift: $0.key.lowercased() ∈ {bigmodel-organization, bigmodel-project} 且值非空白 → 拒绝。
            if ((string.Equals(name, "bigmodel-organization", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(name, "bigmodel-project", StringComparison.OrdinalIgnoreCase))
                && !string.IsNullOrWhiteSpace(value))
            {
                return null;
            }
        }

        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = credential.Authorization,
            ["Accept"] = "application/json",
        };
        return new GlmResetAllowanceRequest(PersonalListUrl, RequestTimeout, headers);
    }

    /// <summary>
    /// Swift: (source.queryItems ?? []).contains { $0.name == "type" && $0.value != "1" } ——
    /// type=1 或不带 type 可放行，其余（如 type=2）拒绝。简化解析：不做百分号解码（真实入参均为裸 ASCII）。
    /// </summary>
    private static bool HasDisallowedTypeQueryParameter(string? query)
    {
        if (string.IsNullOrEmpty(query))
        {
            return false;
        }
        var trimmed = query.StartsWith('?', StringComparison.Ordinal) ? query[1..] : query;
        if (trimmed.Length == 0)
        {
            return false;
        }
        foreach (var pair in trimmed.Split('&'))
        {
            if (pair.Length == 0)
            {
                continue;
            }
            var separator = pair.IndexOf('=');
            var name = separator < 0 ? pair : pair[..separator];
            var value = separator < 0 ? string.Empty : pair[(separator + 1)..];
            if (name == "type" && value != "1")
            {
                return true;
            }
        }
        return false;
    }
}
