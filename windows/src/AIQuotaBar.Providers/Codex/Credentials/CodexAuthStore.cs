// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （CodexOAuthCredentialsStore：parse/parsePAT/tokenCredentials/patCredentials/apiKeyCredentials/
//    accountIDFromJWT/expirationFromJWT/save —— 逐分支镜像，契约样本：
//    windows/contracts/fixtures/codex/auth-json-oauth.json、auth-json-pat.json）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexAuthStoreTests.cs
//
// Windows 差异（相对 macOS）：
// - 不做 Keychain：macOS 上 CodexBar 对托管账号使用 Keychain/托管 Codex home；Windows 上
//   %CODEX_HOME%\auth.json 即凭据源，加密存储（DPAPI/凭据管理器）属后续 Platform 阶段。
// - 不做外部源回退（legacy ~/.config/codex、OpenCode auth.json）：CodexCredentialSource 保留
//   枚举位用于刷新回写判定，但本 store 只读 CODEX_HOME。
// - 文件写入不做 chmod 600（Windows ACL 由后续 Platform 层统一处理）。

#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// 读取/解析/回写 %CODEX_HOME%\auth.json（Swift: CodexOAuthCredentialsStore）。
/// 通过 <see cref="ICodexEnvironment"/> 注入路径解析，便于测试指向临时目录。
/// </summary>
public sealed class CodexAuthStore
{
    private const string AuthFileName = "auth.json";

    /// <summary>JWT exp 声明的合法秒级范围（Swift: codexJWTExpirationRange，Chrono 0.4 可表示范围）。</summary>
    private const long JwtExpirationMinSeconds = -8_334_601_228_800;
    private const long JwtExpirationMaxSeconds = 8_210_266_876_799;

    private readonly ICodexEnvironment _environment;

    public CodexAuthStore(ICodexEnvironment environment)
    {
        _environment = environment ?? throw new ArgumentNullException(nameof(environment));
    }

    /// <summary>auth.json 的绝对路径（CODEX_HOME 覆盖 → %USERPROFILE%\.codex）。</summary>
    public string AuthFilePath => Path.Combine(_environment.CodexHomeDirectory, AuthFileName);

    /// <summary>读取并按 OAuth/API-key 形态解析 auth.json（Swift: load / parse(data:)）。</summary>
    public async Task<CodexOAuthCredentials> LoadOAuthAsync(CancellationToken cancellationToken = default)
    {
        var json = await ReadAuthJsonAsync(cancellationToken).ConfigureAwait(false);
        return Parse(json);
    }

    /// <summary>读取并按 PAT 形态解析 auth.json（Swift: loadPAT / parsePAT(data:)）。</summary>
    public async Task<CodexPatCredentials> LoadPatAsync(CancellationToken cancellationToken = default)
    {
        var json = await ReadAuthJsonAsync(cancellationToken).ConfigureAwait(false);
        return ParsePat(json);
    }

    /// <summary>
    /// 解析 OAuth / API-key 凭据。优先级：OPENAI_API_KEY（非空白）→ tokens.access_token/refresh_token
    /// （snake_case，兼容 camelCase 变体）。两者皆缺 → <see cref="CodexCredentialError.MissingTokens"/>
    /// （纯 PAT 文件落在这里，Swift 测试 `OAuth parse ignores a PAT-only auth file`）。
    /// </summary>
    public static CodexOAuthCredentials Parse(string json)
    {
        var root = DecodeObject(json);

        if (ApiKeyCredentials(root) is { } apiKey)
        {
            return apiKey;
        }

        if (TokenCredentials(root) is { } tokens)
        {
            return tokens;
        }

        throw new CodexCredentialException(CodexCredentialError.MissingTokens);
    }

    /// <summary>
    /// 仅按 tokens 形态解析（Swift: loadOAuthTokens / parseOAuthTokens）——重置积分等“必须拿
    /// 到 OAuth tokens”的调用点用它，忽略同文件中并存的 OPENAI_API_KEY
    /// （Swift 测试 `reset-credit token load ignores an API key beside O auth tokens`）。
    /// </summary>
    public static CodexOAuthCredentials ParseOAuthTokens(string json)
    {
        var root = DecodeObject(json);

        if (TokenCredentials(root) is { } tokens)
        {
            return tokens;
        }

        throw new CodexCredentialException(CodexCredentialError.MissingTokens);
    }

    /// <summary>
    /// 解析 PAT 凭据：personal_access_token（snake_case，兼容 camelCase）；空白视为缺失
    /// （Swift 测试 `blank personal access token is missing`）。
    /// </summary>
    public static CodexPatCredentials ParsePat(string json)
    {
        var root = DecodeObject(json);

        var token =
            NonEmpty(StringValue(root, "personal_access_token", "personalAccessToken"));
        if (token is null)
        {
            throw new CodexCredentialException(CodexCredentialError.MissingTokens);
        }

        return new CodexPatCredentials(token);
    }

    /// <summary>
    /// 回写刷新后的 OAuth 凭据（Swift: save）。合并语义：保留文件中其余键（如 OPENAI_API_KEY、
    /// personal_access_token），仅替换 tokens 与 last_refresh；键按序输出（镜像 Swift sortedKeys）。
    /// 只读来源（legacy/OpenCode）拒绝写入。
    /// </summary>
    public async Task SaveAsync(CodexOAuthCredentials credentials, CancellationToken cancellationToken = default)
    {
        if (credentials.Source != CodexCredentialSource.CodexHome)
        {
            throw new CodexCredentialException(CodexCredentialError.ReadOnlySource);
        }

        var existing = new JsonObject();
        try
        {
            if (File.Exists(AuthFilePath))
            {
                var existingText = await File.ReadAllTextAsync(AuthFilePath, cancellationToken).ConfigureAwait(false);
                if (JsonNode.Parse(existingText) is JsonObject existingObject)
                {
                    existing = existingObject;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // 与现有文件合并不了就按新文件写（Swift 侧 try? 同语义）。
        }

        var tokens = new JsonObject
        {
            ["access_token"] = credentials.AccessToken,
            ["refresh_token"] = credentials.RefreshToken,
        };
        if (credentials.IdToken is not null)
        {
            tokens["id_token"] = credentials.IdToken;
        }
        if (credentials.AccountId is not null)
        {
            tokens["account_id"] = credentials.AccountId;
        }

        // 时间戳跟随凭据材料本身，避免“元数据刷新让旧 access token 看似新轮换”（Swift 注释同义）。
        if (credentials.LastRefresh is { } lastRefresh)
        {
            existing["last_refresh"] = lastRefresh.UtcDateTime.ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        }

        existing["tokens"] = tokens;

        var ordered = new JsonObject();
        // 用 Add（而非索引器）写回：索引器赋 null 会删除键，Add 保留 JSON null（如 OPENAI_API_KEY: null），
        // 镜像 Swift “合并既有字典”的语义。
        foreach (var pair in existing.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            ordered.Add(pair.Key, pair.Value?.DeepClone());
        }

        var serialized = ordered.ToJsonString(SerializedOptions);

        Directory.CreateDirectory(_environment.CodexHomeDirectory);
        await File.WriteAllTextAsync(AuthFilePath, serialized, cancellationToken).ConfigureAwait(false);
    }

    private static readonly JsonSerializerOptions SerializedOptions = new() { WriteIndented = true };

    private async Task<string> ReadAuthJsonAsync(CancellationToken cancellationToken)
    {
        try
        {
            // 一次性读而不是先探测存在性：Codex 以原子方式发布 auth.json，避免 TOCTOU 窗口
            // 并能区分“文件缺失”与“暂时不可读”（Swift 注释同义）。
            return await File.ReadAllTextAsync(AuthFilePath, cancellationToken).ConfigureAwait(false);
        }
        catch (FileNotFoundException)
        {
            throw new CodexCredentialException(CodexCredentialError.NotFound);
        }
        catch (DirectoryNotFoundException)
        {
            throw new CodexCredentialException(CodexCredentialError.NotFound);
        }
        catch (IOException)
        {
            throw new CodexCredentialException(CodexCredentialError.Unreadable);
        }
        catch (UnauthorizedAccessException)
        {
            throw new CodexCredentialException(CodexCredentialError.Unreadable);
        }
    }

    private static JsonObject DecodeObject(string json)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch (JsonException ex)
        {
            throw new CodexCredentialException(CodexCredentialError.DecodeFailed, ex.Message);
        }

        if (node is not JsonObject root)
        {
            throw new CodexCredentialException(CodexCredentialError.DecodeFailed, "Invalid JSON");
        }

        return root;
    }

    private static CodexOAuthCredentials? ApiKeyCredentials(JsonObject root)
    {
        if (StringOfValue(root["OPENAI_API_KEY"]) is not { } apiKey ||
            string.IsNullOrWhiteSpace(apiKey))
        {
            return null;
        }

        return new CodexOAuthCredentials(
            AccessToken: apiKey,
            RefreshToken: string.Empty,
            IdToken: null,
            AccountId: null,
            LastRefresh: null,
            ExpiresAt: null,
            Source: CodexCredentialSource.CodexHome,
            IsApiKey: true);
    }

    /// <summary>值为字符串才返回（Swift: as? String）；JSON null / 非字符串（数字等）→ null。</summary>
    private static string? StringOfValue(JsonNode? node) =>
        node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    private static CodexOAuthCredentials? TokenCredentials(JsonObject root)
    {
        if (root["tokens"] is not JsonObject tokens)
        {
            return null;
        }

        var accessToken = StringValue(tokens, "access_token", "accessToken");
        var refreshToken = StringValue(tokens, "refresh_token", "refreshToken");
        if (accessToken is null || accessToken.Length == 0 || refreshToken is null)
        {
            return null;
        }

        var idToken = StringValue(tokens, "id_token", "idToken");
        var accountId =
            NonEmpty(StringValue(tokens, "account_id", "accountId"))
            ?? AccountIdFromJwt(idToken, accessToken);
        var lastRefresh = ParseLastRefresh(root["last_refresh"]);
        var expiresAt = ExpirationFromJwt(accessToken);

        return new CodexOAuthCredentials(
            AccessToken: accessToken,
            RefreshToken: refreshToken,
            IdToken: idToken,
            AccountId: accountId,
            LastRefresh: lastRefresh,
            ExpiresAt: expiresAt,
            Source: CodexCredentialSource.CodexHome,
            IsApiKey: false);
    }

    private static DateTimeOffset? ParseLastRefresh(JsonNode? raw)
    {
        if (raw is not JsonValue value || !value.TryGetValue<string>(out var text) ||
            string.IsNullOrEmpty(text))
        {
            return null;
        }

        return ParseIso8601(text);
    }

    private static DateTimeOffset? ParseIso8601(string text)
    {
        if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
        {
            return parsed.ToUniversalTime();
        }

        return null;
    }

    private static string? StringValue(JsonObject obj, string snakeCaseKey, string camelCaseKey)
    {
        if (obj[snakeCaseKey] is JsonValue snake && snake.TryGetValue<string>(out var snakeText) &&
            snakeText.Length != 0)
        {
            return snakeText;
        }

        if (obj[camelCaseKey] is JsonValue camel && camel.TryGetValue<string>(out var camelText) &&
            camelText.Length != 0)
        {
            return camelText;
        }

        return null;
    }

    private static string? NonEmpty(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }

    /// <summary>
    /// Swift: accountIDFromJWT —— auth.json 可缺 tokens.account_id，从 id_token/access_token 的
    /// JWT payload 恢复：chatgpt_account_id → auth("https://api.openai.com/auth").chatgpt_account_id
    /// → organizations[0].id。畸形/非 JWT 一律返回 null（不当成凭据读取失败）。
    /// </summary>
    private static string? AccountIdFromJwt(string? idToken, string? accessToken)
    {
        foreach (var token in new[] { idToken, accessToken })
        {
            if (token is null)
            {
                continue;
            }

            if (JwtPayload(token) is not { } payload)
            {
                continue;
            }

            if (payload["chatgpt_account_id"] is JsonValue accountId &&
                accountId.TryGetValue<string>(out var rawId))
            {
                var trimmed = NonEmpty(rawId);
                if (trimmed is not null)
                {
                    return trimmed;
                }
            }

            if (payload["https://api.openai.com/auth"] is JsonObject auth &&
                auth["chatgpt_account_id"] is JsonValue authId &&
                authId.TryGetValue<string>(out var rawAuthId))
            {
                var trimmedAuth = NonEmpty(rawAuthId);
                if (trimmedAuth is not null)
                {
                    return trimmedAuth;
                }
            }

            if (payload["organizations"] is JsonArray organizations)
            {
                foreach (var organization in organizations)
                {
                    if (organization is JsonObject org &&
                        org["id"] is JsonValue orgId &&
                        orgId.TryGetValue<string>(out var rawOrgId))
                    {
                        var trimmedOrg = NonEmpty(rawOrgId);
                        if (trimmedOrg is not null)
                        {
                            return trimmedOrg;
                        }
                    }
                }
            }
        }

        return null;
    }

    /// <summary>Swift: expirationFromJWT —— 仅作调度提示（exp 声明，秒级，带值域校验）。</summary>
    private static DateTimeOffset? ExpirationFromJwt(string accessToken)
    {
        if (JwtPayload(accessToken) is not { } payload)
        {
            return null;
        }

        if (payload["exp"] is not JsonValue exp)
        {
            return null;
        }

        // 保留整数拼写：1.0 / 1e0 这类浮点写法不接受（Swift 逐 token 词法分析同语义）。
        if (!exp.TryGetValue<long>(out var seconds))
        {
            return null;
        }

        if (seconds < JwtExpirationMinSeconds || seconds > JwtExpirationMaxSeconds)
        {
            return null;
        }

        return DateTimeOffset.FromUnixTimeSeconds(seconds);
    }

    private static JsonObject? JwtPayload(string token)
    {
        var parts = token.Split('.');
        if (parts.Length != 3 || parts.Any(string.IsNullOrEmpty))
        {
            return null;
        }

        var payload = DecodeBase64Url(parts[1]);
        if (payload is null)
        {
            return null;
        }

        try
        {
            return JsonNode.Parse(payload) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? DecodeBase64Url(string encoded)
    {
        var builder = new StringBuilder(encoded)
            .Replace('-', '+')
            .Replace('_', '/');
        builder.Append('=', (4 - builder.Length % 4) % 4);
        try
        {
            var bytes = Convert.FromBase64String(builder.ToString());
            return Encoding.UTF8.GetString(bytes);
        }
        catch (FormatException)
        {
            return null;
        }
    }
}
