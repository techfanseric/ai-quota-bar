using System.Text;

namespace AQB.Providers.GlmMiniMax;

public sealed class GlmCredentialException : Exception
{
    public GlmCredentialException(string message) : base(message)
    {
    }
}

/// <summary>
/// A normalized GLM credential (spec §2.1): either an API-key entry (open.bigmodel.cn quota
/// endpoint + single Bearer) or a parsed web-session cURL (ApiUrl + full header set).
/// </summary>
public sealed record GlmImportedCredential
{
    public string ApiUrl { get; init; }

    public string? Authorization { get; init; }

    public string? Cookie { get; init; }

    public string? Organization { get; init; }

    public string? Project { get; init; }

    /// <summary>Every header carried by the parsed cURL (names lowercased), including authorization/org/project.</summary>
    public IReadOnlyDictionary<string, string> Headers { get; init; } = new Dictionary<string, string>();

    public GlmImportedCredential(
        string apiUrl,
        string? authorization = null,
        string? cookie = null,
        string? organization = null,
        string? project = null,
        IReadOnlyDictionary<string, string>? headers = null)
    {
        ApiUrl = apiUrl;
        Authorization = authorization;
        Cookie = cookie;
        Organization = organization;
        Project = project;
        Headers = headers ?? new Dictionary<string, string>();
    }

    /// <summary>API-key mode (spec §2.1a): bare key or "Bearer &lt;key&gt;", exactly one Bearer prefix.</summary>
    public static GlmImportedCredential ForApiKey(string apiKey)
    {
        var key = apiKey?.Trim() ?? "";
        if (key.Length == 0)
        {
            throw new GlmCredentialException("Missing GLM API key.");
        }

        var authorization = key.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? key : "Bearer " + key;
        return new GlmImportedCredential(GlmCredentialParser.ApiKeyEndpoint, authorization);
    }

    /// <summary>
    /// Rebuilds a pasteable cURL (spec §2.1 editableString): headers sorted by name, single quotes
    /// with '\'' escaping, cookie appended via -b. Round-trips through <see cref="GlmCredentialParser.ParseCurl"/>.
    /// </summary>
    public string ToEditableCurl()
    {
        var sb = new StringBuilder("curl '").Append(EscapeSingleQuoted(ApiUrl)).Append('\'');
        foreach (var header in Headers.OrderBy(h => h.Key, StringComparer.Ordinal))
        {
            sb.Append(" -H '").Append(EscapeSingleQuoted(header.Key + ": " + header.Value)).Append('\'');
        }

        if (!string.IsNullOrEmpty(Cookie))
        {
            sb.Append(" -b '").Append(EscapeSingleQuoted(Cookie)).Append('\'');
        }

        return sb.ToString();
    }

    private static string EscapeSingleQuoted(string value)
        => value.Replace("'", "'\\''", StringComparison.Ordinal);
}

/// <summary>
/// Parses pasted cURL commands into <see cref="GlmImportedCredential"/> (spec §2.1b). Only parses —
/// never executes. Supports single/double quotes, ANSI-C $'…' quoting, backslash escapes and
/// backslash-newline continuations, glued -Hxxx forms, -b/--cookie.
/// </summary>
public static class GlmCredentialParser
{
    public const string ApiKeyEndpoint = "https://open.bigmodel.cn/api/monitor/usage/quota/limit";
    public const string DefaultWebEndpoint = "https://bigmodel.cn/api/monitor/usage/quota/limit";

    private const string AuthHeaderName = "authorization";
    private const string CookieHeaderName = "cookie";
    private const string OrganizationHeader = "bigmodel-organization";
    private const string ProjectHeader = "bigmodel-project";
    private const string TokenCookieName = "bigmodel_token_production";

    /// <summary>Dispatches: text containing "curl" is parsed as cURL, anything else as an API key.</summary>
    public static GlmImportedCredential Parse(string text)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length == 0)
        {
            throw new GlmCredentialException("Missing GLM credential.");
        }

        return trimmed.Contains("curl", StringComparison.OrdinalIgnoreCase)
            ? ParseCurl(trimmed)
            : GlmImportedCredential.ForApiKey(trimmed);
    }

    public static GlmImportedCredential ParseCurl(string curlText)
    {
        var tokens = Tokenize(curlText ?? "");

        string? url = null;
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? cookie = null;

        for (var i = 0; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (url is null &&
                (token.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
                 token.StartsWith("https://", StringComparison.OrdinalIgnoreCase)))
            {
                url = token;
                continue;
            }

            string? value = null;
            if (token is "-H" or "--header")
            {
                value = Next(tokens, ref i);
            }
            else if ((token.StartsWith("-H", StringComparison.Ordinal) && token.Length > 2) ||
                     (token.StartsWith("--header", StringComparison.Ordinal) && token.Length > 9))
            {
                value = token[(token.StartsWith("--header", StringComparison.Ordinal) ? 9 : 2)..];
            }
            else if (token is "-b" or "--cookie")
            {
                cookie = Next(tokens, ref i);
                continue;
            }
            else if ((token.StartsWith("-b", StringComparison.Ordinal) && token.Length > 2) ||
                     (token.StartsWith("--cookie", StringComparison.Ordinal) && token.Length > 8))
            {
                cookie = token[(token.StartsWith("--cookie", StringComparison.Ordinal) ? 8 : 2)..];
                continue;
            }

            if (value is null)
            {
                continue;
            }

            var separator = value.IndexOf(':');
            if (separator <= 0)
            {
                continue;
            }

            var name = value[..separator].Trim().ToLowerInvariant();
            var headerValue = value[(separator + 1)..].Trim();
            if (name.Length == 0)
            {
                continue;
            }

            if (name == CookieHeaderName)
            {
                cookie = headerValue;
            }

            headers[name] = headerValue;
        }

        url ??= DefaultWebEndpoint;

        var authorization = headers.TryGetValue(AuthHeaderName, out var authValue) && !string.IsNullOrWhiteSpace(authValue)
            ? authValue
            : ExtractCookieValue(cookie, TokenCookieName);
        if (string.IsNullOrWhiteSpace(authorization))
        {
            throw new GlmCredentialException("Missing GLM authorization header in curl command.");
        }

        headers[AuthHeaderName] = authorization;
        headers.TryGetValue(OrganizationHeader, out var organization);
        headers.TryGetValue(ProjectHeader, out var project);

        return new GlmImportedCredential(
            url,
            authorization,
            cookie,
            string.IsNullOrWhiteSpace(organization) ? null : organization,
            string.IsNullOrWhiteSpace(project) ? null : project,
            headers);
    }

    private static string? Next(List<string> tokens, ref int index)
        => ++index < tokens.Count ? tokens[index] : null;

    /// <summary>Extracts a named cookie value from a raw Cookie header string ("a=1; b=2").</summary>
    public static string? ExtractCookieValue(string? cookie, string name)
    {
        if (string.IsNullOrEmpty(cookie))
        {
            return null;
        }

        foreach (var part in cookie.Split(';'))
        {
            var pair = part.Trim();
            var equals = pair.IndexOf('=');
            if (equals <= 0)
            {
                continue;
            }

            if (pair[..equals].Trim().Equals(name, StringComparison.Ordinal))
            {
                var value = pair[(equals + 1)..].Trim();
                return value.Length == 0 ? null : value;
            }
        }

        return null;
    }

    /// <summary>POSIX-flavored shell tokenizer: whitespace splits, quotes group, backslash escapes.</summary>
    internal static List<string> Tokenize(string text)
    {
        // Fold backslash-newline continuations first.
        text = text.Replace("\\\r\n", "").Replace("\\\n", "");

        var tokens = new List<string>();
        var current = new StringBuilder();
        var hasToken = false;
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            if (char.IsWhiteSpace(c))
            {
                Flush(tokens, current, ref hasToken);
                i++;
                continue;
            }

            if (c == '\'')
            {
                hasToken = true;
                i++;
                while (i < text.Length && text[i] != '\'')
                {
                    current.Append(text[i]);
                    i++;
                }

                i++; // closing quote (or end of input)
                continue;
            }

            if (c == '"')
            {
                hasToken = true;
                i++;
                while (i < text.Length && text[i] != '"')
                {
                    if (text[i] == '\\' && i + 1 < text.Length && (text[i + 1] == '"' || text[i + 1] == '\\'))
                    {
                        current.Append(text[i + 1]);
                        i += 2;
                        continue;
                    }

                    current.Append(text[i]);
                    i++;
                }

                i++;
                continue;
            }

            if (c == '$' && i + 1 < text.Length && text[i + 1] == '\'')
            {
                // ANSI-C quoting ($'…'): expand the common escapes.
                hasToken = true;
                i += 2;
                while (i < text.Length && text[i] != '\'')
                {
                    if (text[i] == '\\' && i + 1 < text.Length)
                    {
                        var next = text[i + 1];
                        current.Append(next switch
                        {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            '\\' => '\\',
                            '\'' => '\'',
                            _ => next,
                        });
                        i += 2;
                        continue;
                    }

                    current.Append(text[i]);
                    i++;
                }

                i++;
                continue;
            }

            if (c == '\\' && i + 1 < text.Length)
            {
                current.Append(text[i + 1]);
                hasToken = true;
                i += 2;
                continue;
            }

            current.Append(c);
            hasToken = true;
            i++;
        }

        Flush(tokens, current, ref hasToken);
        return tokens;
    }

    private static void Flush(List<string> tokens, StringBuilder current, ref bool hasToken)
    {
        if (hasToken)
        {
            tokens.Add(current.ToString());
            current.Clear();
            hasToken = false;
        }
    }
}
