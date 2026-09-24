// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/UsageFetcher.swift（parseJWT）与
//   CodexReconciledState.swift（resolveAccountEmail / resolvePlan 对 payload 的读取）。
//   纯新增的 JWT payload 解析辅助（base64url + JSON），畸形 token 一律返回 null。

#nullable enable

using System;
using System.Text;
using System.Text.Json;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 尽力而为的 JWT payload 解析（internal）。不校验签名——仅用于读取身份声明
/// （email / chatgpt_plan_type 等），畸形或非 JWT 结构返回 null，绝不抛出。
/// </summary>
internal static class CodexJwt
{
    public static JsonElement? TryGetPayload(string? token)
    {
        if (token is null)
        {
            return null;
        }

        var parts = token.Split('.');
        if (parts.Length != 3 || parts[1].Length == 0)
        {
            return null;
        }

        var payloadJson = DecodeBase64Url(parts[1]);
        if (payloadJson is null)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(payloadJson);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            return document.RootElement.Clone();
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
            return Encoding.UTF8.GetString(Convert.FromBase64String(builder.ToString()));
        }
        catch (FormatException)
        {
            return null;
        }
    }
}
