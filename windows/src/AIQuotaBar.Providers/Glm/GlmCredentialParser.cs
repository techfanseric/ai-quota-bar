// Swift 来源：AIQuotaBar/Services/GLMCredential.swift — static func parse(_:)、parseCurlCommand(_:)、
// parseHeader(_:into:cookie:)、cookieValue(named:in:)、shellTokens(from:)。
// 对应测试：AIQuotaBar/Tests/GLM/GLMUsageTests.swift:107-144（testAPIKeyUsesOpenAPIAndBearerExactlyOnce /
// testWebCurlPreservesAuthenticationAndLegacyStoredCredential / testEditableCredentialRoundTripPreservesWebContext）。

using System.Text;
using System.Text.Json;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// GLM 凭据粘贴解析（Swift: GLMCredential.parse）。输入优先级：钥匙串 JSON → cURL 命令 → 裸 API Key。
/// 应用只解析请求，不执行 cURL 命令（docs/glm-api-field-mapping.md）。
/// </summary>
public static class GlmCredentialParser
{
    /// <summary>Swift: GLMCredential.apiKeyURL — API Key 接入端点（open.bigmodel.cn）。</summary>
    public const string ApiKeyUrl = "https://open.bigmodel.cn/api/monitor/usage/quota/limit";

    /// <summary>Swift: GLMCredential.defaultAPIURL — 网页会话默认端点（bigmodel.cn）。</summary>
    public const string DefaultApiUrl = "https://bigmodel.cn/api/monitor/usage/quota/limit";

    /// <summary>Swift: UsageService.prepareCredentialForStorage(.glm) 的存储前归一入口。</summary>
    public static GlmCredential Parse(string input)
    {
        var trimmed = input.Trim();
        if (trimmed.Length == 0)
        {
            throw new GlmUsageException(GlmUsageErrorKind.NotConfigured, "GLM 凭据为空（未配置）。");
        }

        var stored = TryParseStoredCredential(trimmed);
        if (stored is not null)
        {
            return stored;
        }

        var lowercased = trimmed.ToLowerInvariant();
        if (lowercased.Contains("curl ", StringComparison.Ordinal)
            || lowercased.StartsWith("curl", StringComparison.Ordinal))
        {
            return ParseCurlCommand(trimmed);
        }

        return new GlmCredential(
            ApiKeyUrl,
            lowercased.StartsWith("bearer ", StringComparison.Ordinal) ? trimmed : $"Bearer {trimmed}");
    }

    /// <summary>
    /// 已存储的 JSON 凭据（storageString 形态）。Swift：try? decode 且 authorization 非空才算命中，
    /// 任何失败都静默落入下一种输入形态。
    /// </summary>
    private static GlmCredential? TryParseStoredCredential(string json)
    {
        GlmCredential? credential;
        try
        {
            credential = JsonSerializer.Deserialize<GlmCredential>(json, GlmCredential.StorageJsonOptions);
        }
        catch (JsonException)
        {
            return null;
        }

        if (credential is null)
        {
            return null;
        }
        if (string.IsNullOrEmpty(credential.Authorization) || credential.ApiUrl is null)
        {
            // Swift 只认 authorization 非空的解码结果；apiURL 在 Swift 侧为必填键（缺键即解码失败）。
            return null;
        }
        if (credential.Headers is null)
        {
            return credential with { Headers = new Dictionary<string, string>() };
        }
        return credential;
    }

    private static GlmCredential ParseCurlCommand(string command)
    {
        var tokens = ShellTokens(command);
        string? apiUrl = null;
        var headers = new Dictionary<string, string>();
        string? cookie = null;

        var index = 0;
        while (index < tokens.Count)
        {
            var token = tokens[index];
            if (token.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                || token.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            {
                apiUrl = token;
            }
            else if (token == "-H" || token == "--header")
            {
                index++;
                if (index < tokens.Count)
                {
                    ParseHeader(tokens[index], headers, ref cookie);
                }
            }
            else if (token.StartsWith("-H", StringComparison.Ordinal) && token.Length > 2)
            {
                ParseHeader(token[2..], headers, ref cookie);
            }
            else if (token == "-b" || token == "--cookie")
            {
                index++;
                if (index < tokens.Count)
                {
                    cookie = tokens[index];
                }
            }
            else if (token.StartsWith("-b", StringComparison.Ordinal) && token.Length > 2)
            {
                cookie = token[2..];
            }

            index++;
        }

        var authorization = headers.TryGetValue("authorization", out var headerValue)
            ? headerValue
            : CookieValue("bigmodel_token_production", cookie);
        if (string.IsNullOrWhiteSpace(authorization))
        {
            throw new GlmUsageException(
                GlmUsageErrorKind.ApiError,
                "Missing GLM authorization header in curl command.");
        }

        var resolvedUrl = apiUrl ?? DefaultApiUrl;
        if (!Uri.TryCreate(resolvedUrl, UriKind.Absolute, out _))
        {
            throw new GlmUsageException(GlmUsageErrorKind.InvalidUri, $"GLM cURL 命令中的 URL 无法解析：{resolvedUrl}");
        }

        return new GlmCredential(
            resolvedUrl,
            authorization,
            HeaderOrNull(headers, "bigmodel-organization"),
            HeaderOrNull(headers, "bigmodel-project"),
            cookie,
            headers);
    }

    private static void ParseHeader(
        string rawHeader,
        Dictionary<string, string> headers,
        ref string? cookie)
    {
        var separator = rawHeader.IndexOf(':');
        if (separator < 0)
        {
            return;
        }
        var name = rawHeader[..separator].Trim().ToLowerInvariant();
        var value = rawHeader[(separator + 1)..].Trim();
        if (name.Length == 0)
        {
            return;
        }
        if (name == "cookie")
        {
            cookie = value;
        }
        else
        {
            headers[name] = value;
        }
    }

    private static string? HeaderOrNull(Dictionary<string, string> headers, string name) =>
        headers.TryGetValue(name, out var value) ? value : null;

    private static string? CookieValue(string name, string? cookie)
    {
        if (cookie is null)
        {
            return null;
        }
        foreach (var part in cookie.Split(';'))
        {
            var trimmed = part.Trim();
            var separator = trimmed.IndexOf('=');
            if (separator < 0)
            {
                continue;
            }
            if (trimmed[..separator] == name)
            {
                return trimmed[(separator + 1)..];
            }
        }
        return null;
    }

    /// <summary>
    /// POSIX 风格分词（Swift: shellTokens(from:)）：单/双引号成对，反斜杠在双引号内与裸态转义下一字符，
    /// 行继续（反斜杠 + 换行）先替换为空格。
    /// </summary>
    private static List<string> ShellTokens(string command)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        char? quote = null;
        var text = command.Replace("\\\n", " ");

        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (quote is { } activeQuote)
            {
                if (character == activeQuote)
                {
                    quote = null;
                }
                else if (character == '\\' && activeQuote != '\'')
                {
                    if (++index < text.Length)
                    {
                        current.Append(text[index]);
                    }
                }
                else
                {
                    current.Append(character);
                }
                continue;
            }

            if (character == '\'' || character == '"')
            {
                quote = character;
            }
            else if (character == '\\')
            {
                if (++index < text.Length && text[index] != '\n')
                {
                    current.Append(text[index]);
                }
            }
            else if (char.IsWhiteSpace(character))
            {
                if (current.Length > 0)
                {
                    tokens.Add(current.ToString());
                    current.Clear();
                }
            }
            else
            {
                current.Append(character);
            }
        }

        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }
        return tokens;
    }
}
