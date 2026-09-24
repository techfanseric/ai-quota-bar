// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/CreditsModels.swift
//   （struct CodexRateLimitResetCredit：stableID 的域分隔 SHA-256 —— CryptoKit → System.Security.Cryptography）

#nullable enable

using System;
using System.Security.Cryptography;
using System.Text;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 一条 rate-limit 重置积分（Swift: CodexRateLimitResetCredit）。
/// Status 保留线上原串（Swift 枚举的 unknown(rawValue) 携带原值，等价为 string）。
/// Id 做 Swift stableID 同款域分隔 SHA-256（隐私：外发/持久化不携带服务方原始 ID）。
/// </summary>
public sealed record CodexRateLimitResetCredit(
    string Id,
    string ResetType,
    string Status,
    DateTimeOffset GrantedAt,
    DateTimeOffset? ExpiresAt,
    DateTimeOffset? RedeemStartedAt,
    DateTimeOffset? RedeemedAt,
    string? Title,
    string? Description)
{
    private const string StableIdPrefix = "codex-reset-credit-v1-";
    private const string StableIdDomain = "com.steipete.CodexBar.reset-credit-id.v1";

    public const string StatusAvailable = "available";
    public const string StatusRedeeming = "redeeming";
    public const string StatusRedeemed = "redeemed";
    public const string StatusExpired = "expired";

    public bool IsAvailable => Status == StatusAvailable;

    /// <summary>
    /// Swift: stableID(forProviderID:) —— "com.steipete.CodexBar.reset-credit-id.v1\0&lt;id&gt;"
    /// 的 SHA-256 十六进制（64 字符），加 "codex-reset-credit-v1-" 前缀。
    /// </summary>
    public static string StableIdFor(string providerId)
    {
        var payload = Encoding.UTF8.GetBytes($"{StableIdDomain}\0{providerId}");
        var digest = SHA256.HashData(payload);
        var builder = new StringBuilder(StableIdPrefix.Length + digest.Length * 2)
            .Append(StableIdPrefix);
        foreach (var b in digest)
        {
            builder.Append(b.ToString("x2"));
        }

        return builder.ToString();
    }

    /// <summary>Swift: isCanonicalStableID —— 已是稳定 ID 的值不再二次哈希。</summary>
    public static bool IsCanonicalStableId(string id)
    {
        if (!id.StartsWith(StableIdPrefix, StringComparison.Ordinal))
        {
            return false;
        }

        var digest = id.AsSpan(StableIdPrefix.Length);
        return digest.Length == 64 && IsLowercaseHex(digest);
    }

    private static bool IsLowercaseHex(ReadOnlySpan<char> value)
    {
        foreach (var c in value)
        {
            var isHex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
            if (!isHex)
            {
                return false;
            }
        }

        return true;
    }
}
