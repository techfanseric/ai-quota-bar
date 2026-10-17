using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Providers.Codex;

/// <summary>Parsed view of ~/.codex/auth.json usable for quota fetching.</summary>
public sealed record CodexAuthInfo
{
    /// <summary>tokens.account_id — required; without it the file is unusable.</summary>
    public required string AccountId { get; init; }

    /// <summary>From the id_token JWT "email" claim; null when the token is absent or has no email.</summary>
    public string? Email { get; init; }

    /// <summary>True when a top-level OPENAI_API_KEY is present (highest-priority auth mode).</summary>
    public bool HasApiKey { get; init; }

    /// <summary>The exact file content; used by the token refresher for merge writes.</summary>
    public string RawJson { get; init; } = "";
}

public readonly record struct CodexFileStamp(DateTime LastWriteTimeUtc, long Length);

/// <summary>
/// Reads ~/.codex/auth.json with torn-read protection: Codex atomically replaces this file, so the
/// mtime + size are compared before and after every read; on mismatch the file is re-read exactly once.
/// Unusable files (missing, torn, oversized, JSON garbage, missing account_id) yield null, never throw.
/// </summary>
public class CodexAuthStore
{
    /// <summary>Auth files larger than 256 KiB are rejected outright (same bound as the macOS reader).</summary>
    public const long MaxFileBytes = 262144;

    private readonly string _authFilePath;

    public CodexAuthStore(string? codexHome = null)
    {
        CodexHome = CodexPaths.ResolveHome(codexHome);
        _authFilePath = Path.Combine(CodexHome, "auth.json");
    }

    public string CodexHome { get; }

    public string AuthFilePath => _authFilePath;

    /// <summary>
    /// Classification order (fixed): OPENAI_API_KEY non-empty → API key mode (account_id still
    /// required); auth_mode present and != "chatgpt" → unusable; tokens.account_id missing/empty →
    /// unusable; otherwise chatgpt login with optional email from the id_token JWT.
    /// </summary>
    public CodexAuthInfo? Load()
    {
        var raw = ReadStable(_authFilePath);
        return raw is null ? null : Interpret(raw);
    }

    internal static CodexAuthInfo? Interpret(string rawJson)
    {
        JsonObject root;
        try
        {
            if (JsonNode.Parse(rawJson) is not JsonObject parsed)
            {
                return null;
            }

            root = parsed;
        }
        catch (Exception e) when (e is JsonException or ArgumentException)
        {
            return null;
        }

        var hasApiKey = !string.IsNullOrWhiteSpace(root.GetString("OPENAI_API_KEY"));
        if (!hasApiKey)
        {
            var authMode = root.GetString("auth_mode");
            if (authMode.Length > 0 && !authMode.Equals("chatgpt", StringComparison.Ordinal))
            {
                return null;
            }
        }

        var tokens = root["tokens"] as JsonObject;
        var accountId = FirstNonEmptyString(tokens, "account_id", "accountId");
        if (accountId is null)
        {
            return null;
        }

        var idToken = FirstNonEmptyString(tokens, "id_token", "idToken");
        return new CodexAuthInfo
        {
            AccountId = accountId,
            Email = Jwt.TryExtractEmail(idToken),
            HasApiKey = hasApiKey,
            RawJson = rawJson,
        };
    }

    /// <summary>
    /// Torn-read safe read: stats before and after each read; accepts the content only when both
    /// stamps match (and the size is in range). Retries once on mismatch, then gives up.
    /// </summary>
    internal string? ReadStable(string path)
    {
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var before = TryStat(path);
            if (before is null)
            {
                return null;
            }

            if (before.Value.Length <= 0 || before.Value.Length > MaxFileBytes)
            {
                return null;
            }

            var content = TryReadAllText(path);
            if (content is null)
            {
                return null;
            }

            var after = TryStat(path);
            if (after is null)
            {
                return null;
            }

            if (after.Value == before.Value)
            {
                return content;
            }
        }

        return null;
    }

    /// <summary>Extracts the first non-empty token string (snake_case or camelCase variants) from raw auth JSON.</summary>
    internal static string? PeekToken(string rawJson, params string[] keys)
    {
        try
        {
            var root = JsonNode.Parse(rawJson) as JsonObject;
            return FirstNonEmptyString(root?["tokens"] as JsonObject, keys);
        }
        catch (Exception e) when (e is JsonException or ArgumentException)
        {
            return null;
        }
    }

    private static string? FirstNonEmptyString(JsonObject? obj, params string[] keys)
    {
        if (obj is null)
        {
            return null;
        }

        foreach (var key in keys)
        {
            if (obj.TryGetPropertyValue(key, out var value)
                && value is JsonValue jsonValue
                && jsonValue.TryGetValue<string>(out var text)
                && !string.IsNullOrWhiteSpace(text))
            {
                return text;
            }
        }

        return null;
    }

    protected virtual CodexFileStamp? TryStat(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists ? new CodexFileStamp(info.LastWriteTimeUtc, info.Length) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    protected virtual string? TryReadAllText(string path)
    {
        try
        {
            return File.ReadAllText(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
