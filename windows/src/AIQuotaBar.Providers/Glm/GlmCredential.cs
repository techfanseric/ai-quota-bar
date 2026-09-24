// Swift 来源：AIQuotaBar/Services/GLMCredential.swift — struct GLMCredential（整文件；本文件含数据形状、
// storageString / editableString 两个编码出口，粘贴解析在 GlmCredentialParser.cs）。
// 对应测试：AIQuotaBar/Tests/GLM/GLMUsageTests.swift:107-144（API key / cURL / 存储与可编辑串往返）。
//
// 线上键与 Swift Codable 一致：apiURL（保留大小写钉死，camelCase 策略会产生 "apiUrl"，必须显式
// [JsonPropertyName]）、authorization、organization / project / cookie（nil 省略）、headers。

using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Providers.Glm;

/// <summary>
/// GLM 凭据（Swift: GLMCredential）。三种来源形态由 <see cref="GlmCredentialParser"/> 归一：
/// API Key（Bearer + open.bigmodel.cn）、网页 cURL 粘贴（bigmodel.cn + Cookie / 组织 / 项目）、
/// 钥匙串里已存的 JSON（storageString）。
/// </summary>
public sealed record GlmCredential
{
    private static readonly IReadOnlyDictionary<string, string> EmptyHeaders =
        new Dictionary<string, string>();

    /// <summary>Swift: JSONEncoder/JSONDecoder 默认 camelCase + nil 字段省略（encodeIfPresent）。</summary>
    internal static readonly JsonSerializerOptions StorageJsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public GlmCredential(
        string apiUrl,
        string authorization,
        string? organization = null,
        string? project = null,
        string? cookie = null,
        IReadOnlyDictionary<string, string>? headers = null)
    {
        ApiUrl = apiUrl;
        Authorization = authorization;
        Organization = organization;
        Project = project;
        Cookie = cookie;
        Headers = headers ?? EmptyHeaders;
    }

    /// <summary>配额端点（Swift: apiURL）。API Key 形态为 open.bigmodel.cn，网页会话为 bigmodel.cn。</summary>
    [JsonPropertyName("apiURL")]
    public string ApiUrl { get; init; }

    /// <summary>授权值（Swift: authorization）。API Key 形态为 "Bearer &lt;key&gt;"，网页会话为原始令牌。</summary>
    public string Authorization { get; init; }

    /// <summary>网页会话组织头（Swift: organization，可空）。</summary>
    public string? Organization { get; init; }

    /// <summary>网页会话项目头（Swift: project，可空）。</summary>
    public string? Project { get; init; }

    /// <summary>网页会话 Cookie（Swift: cookie，可空）。</summary>
    public string? Cookie { get; init; }

    /// <summary>cURL 解析得到的小写头表（Swift: headers，默认 [:]）。</summary>
    public IReadOnlyDictionary<string, string> Headers { get; init; }

    /// <summary>
    /// 钥匙串存储形态（Swift: storageString）：JSON 编码，失败时回退裸 authorization
    /// （Swift `try? ... ?? authorization` 的兜底分支）。
    /// [JsonIgnore]：线上只有六个数据字段（对齐 Swift Codable 键集）；若不排除，序列化 this 时
    /// STJ 会访问本计算属性 → getter 再次 Serialize(this) → 无限递归 StackOverflow（不可捕获）。
    /// </summary>
    [JsonIgnore]
    public string StorageString
    {
        get
        {
            try
            {
                return JsonSerializer.Serialize(this, StorageJsonOptions);
            }
            catch (JsonException)
            {
                return Authorization;
            }
        }
    }

    /// <summary>
    /// 可编辑文本形态（Swift: editableString）：纯 API Key 凭据直接给 token；
    /// 网页凭据渲染回 cURL 命令，把存储 JSON 藏在编辑器外但保留 web 请求上下文。
    /// [JsonIgnore]：同上，不得进入存储 JSON。
    /// </summary>
    [JsonIgnore]
    public string EditableString
    {
        get
        {
            if (ApiUrl == GlmCredentialParser.ApiKeyUrl
                && Headers.Count == 0
                && Organization is null
                && Project is null
                && Cookie is null)
            {
                return Authorization.ToLowerInvariant().StartsWith("bearer ", StringComparison.Ordinal)
                    ? Authorization["bearer ".Length..]
                    : Authorization;
            }

            var requestHeaders = new Dictionary<string, string>(Headers, StringComparer.Ordinal);
            requestHeaders["authorization"] = Authorization;
            if (Organization is { } organization)
            {
                requestHeaders["bigmodel-organization"] = organization;
            }
            if (Project is { } project)
            {
                requestHeaders["bigmodel-project"] = project;
            }

            var parts = new List<string> { "curl", Quote(ApiUrl) };
            foreach (var name in requestHeaders.Keys.Order(StringComparer.Ordinal))
            {
                parts.Add("-H");
                parts.Add(Quote($"{name}: {requestHeaders[name]}"));
            }
            if (Cookie is { } cookie)
            {
                parts.Add("-b");
                parts.Add(Quote(cookie));
            }
            return string.Join(" ", parts);

            static string Quote(string value) => "'" + value.Replace("'", "'\\''") + "'";
        }
    }

    /// <summary>
    /// record 合成的 ToString 会打印全部属性（含上面两个计算属性，xUnit/TRX 字符串化对象即触发
    /// StorageString 递归）——覆写为不触碰计算属性、也不泄露凭据的安全形式。
    /// </summary>
    public override string ToString() => $"GlmCredential({ApiUrl})";
}
