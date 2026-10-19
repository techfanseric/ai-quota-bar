using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Providers.Codex;

/// <summary>
/// Minimal unsigned JWT inspection: base64url-decodes the payload segment only.
/// Signatures are never verified (same as the macOS implementation).
/// </summary>
public static class Jwt
{
    /// <summary>Decodes the JWT payload and returns the "email" claim, or null when absent/invalid.</summary>
    public static string? TryExtractEmail(string? idToken)
    {
        var payloadJson = TryDecodePayload(idToken);
        if (payloadJson is null)
        {
            return null;
        }

        try
        {
            var payload = JsonNode.Parse(payloadJson);
            var email = payload?["email"]?.ToString();
            return string.IsNullOrWhiteSpace(email) ? null : email;
        }
        catch (Exception e) when (e is JsonException or FormatException)
        {
            return null;
        }
    }

    /// <summary>Decodes the JWT payload and returns the "exp" claim as a UTC instant, or null when absent/invalid.</summary>
    public static DateTimeOffset? TryExtractExpiry(string? jwt)
    {
        var payloadJson = TryDecodePayload(jwt);
        if (payloadJson is null)
        {
            return null;
        }

        try
        {
            var payload = JsonNode.Parse(payloadJson);
            if (payload?["exp"] is not JsonValue value || !value.TryGetValue<long>(out var exp))
            {
                return null;
            }

            return DateTimeOffset.FromUnixTimeSeconds(exp);
        }
        catch (Exception e) when (e is JsonException or FormatException or ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>Returns the decoded payload JSON, or null unless the token has three non-empty-looking segments.</summary>
    public static string? TryDecodePayload(string? jwt)
    {
        if (string.IsNullOrWhiteSpace(jwt))
        {
            return null;
        }

        var parts = jwt.Split('.');
        if (parts.Length != 3 || parts[0].Length == 0 || parts[1].Length == 0)
        {
            return null;
        }

        try
        {
            return Encoding.UTF8.GetString(Base64UrlDecode(parts[1]));
        }
        catch (FormatException)
        {
            return null;
        }
    }

    private static byte[] Base64UrlDecode(string input)
    {
        var builder = new StringBuilder(input.Length + 4)
            .Append(input)
            .Replace('-', '+')
            .Replace('_', '/');

        switch (builder.Length % 4)
        {
            case 2:
                builder.Append("==");
                break;
            case 3:
                builder.Append("=");
                break;
        }

        return Convert.FromBase64String(builder.ToString());
    }
}
