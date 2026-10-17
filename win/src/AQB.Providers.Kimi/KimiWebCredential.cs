using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace AQB.Providers.Kimi;

/// <summary>
/// A Kimi web session credential: the kimi-auth token (JWT for logged-in sessions,
/// raw API key in API-key mode) plus the site origin it belongs to.
/// </summary>
public sealed record KimiWebCredential(string Token, string Origin)
{
    public static readonly IReadOnlyList<string> AllowedOrigins = new[]
    {
        "https://www.kimi.com",
        "https://www.kimi.ai",
    };

    /// <summary>API-key mode: the key is used as the Bearer token against www.kimi.com.</summary>
    public static KimiWebCredential ForApiKey(string apiKey)
        => new(apiKey, AllowedOrigins[0]);

    /// <summary>
    /// Spec §1.3 validated(): origin must exactly match the whitelist, token must be
    /// non-empty without whitespace, and a JWT exp (when the token parses as a JWT)
    /// must be in the future. Throws <see cref="KimiSessionException"/>.
    /// </summary>
    public void ValidateWebSession(DateTimeOffset? nowUtc = null)
    {
        if (string.IsNullOrWhiteSpace(Token))
        {
            throw new KimiSessionException(
                KimiSessionErrorKind.Missing,
                "Kimi 凭据缺失 / Kimi credential is missing.");
        }

        if (Token.Any(char.IsWhiteSpace))
        {
            // Message must not leak the token value.
            throw new KimiSessionException(
                KimiSessionErrorKind.InvalidStore,
                "Kimi 凭据格式无效 / Kimi credential is malformed.");
        }

        if (!AllowedOrigins.Contains(Origin))
        {
            throw new KimiSessionException(
                KimiSessionErrorKind.UnsupportedOrigin,
                $"Kimi 登录站点不受支持 / Unsupported Kimi origin.");
        }

        if (TryGetJwtExpiry(Token, out var expiry) && expiry <= (nowUtc ?? DateTimeOffset.UtcNow))
        {
            throw new KimiSessionException(
                KimiSessionErrorKind.Expired,
                "Kimi 会话已过期,请重新登录 / Kimi session expired, please sign in again.");
        }
    }

    /// <summary>"Kimi · &lt;sub&gt;" per spec §1.3, or plain "Kimi" when the JWT has no sub.</summary>
    public string AccountLabel()
        => TryGetJwtClaim(Token, "sub", out var sub) && !string.IsNullOrWhiteSpace(sub)
            ? $"Kimi · {sub}"
            : "Kimi";

    /// <summary>Manual base64url JWT payload decode (spec §1.3). Never throws.</summary>
    public static bool TryGetJwtClaim(string token, string claim, out string? value)
    {
        value = null;
        if (!TryGetJwtPayload(token, out var payload) || payload is null)
        {
            return false;
        }

        var node = payload[claim];
        if (node is null)
        {
            return false;
        }

        value = node.ToString();
        return true;
    }

    public static bool TryGetJwtExpiry(string token, out DateTimeOffset expiry)
    {
        expiry = default;
        if (!TryGetJwtClaim(token, "exp", out var expText) ||
            !long.TryParse(expText, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds))
        {
            return false;
        }

        expiry = DateTimeOffset.FromUnixTimeSeconds(seconds);
        return true;
    }

    private static bool TryGetJwtPayload(string token, out JsonNode? payload)
    {
        payload = null;
        var parts = token.Split('.');
        if (parts.Length != 3)
        {
            return false;
        }

        try
        {
            var segment = parts[1].Replace('-', '+').Replace('_', '/');
            switch (segment.Length % 4)
            {
                case 2: segment += "=="; break;
                case 3: segment += "="; break;
            }

            var bytes = Convert.FromBase64String(segment);
            payload = JsonNode.Parse(Encoding.UTF8.GetString(bytes));
            return payload is not null;
        }
        catch
        {
            return false;
        }
    }
}
