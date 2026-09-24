// Origin: AIQuotaBar/Models/UsageProvider.swift — enum UsageProvider (+ raw-value/parse helpers,
// the cloud "chatgpt" alias mapping, and the account-identity key formats defined as computed
// properties on ModelUsageData in AIQuotaBar/Models/UsageData.swift: `id`, `normalizedAccountName`,
// `quotaIdentityKey`).
//
// Deferred (presentation / platform concerns, not contract data shape):
//   - displayName-based UI ordering (leftClickMenuDefaultOrder)
//   - keychainAccount / usesCurlCredential / legacyChatGPTKeychainAccount / storageKey
//     (Keychain-backed storage selection belongs to the Windows Platform layer)

#nullable enable

using System;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// Quota provider. Wire format is the lowercase Swift raw value: "minimax" / "glm" / "codex" / "kimi".
/// </summary>
public enum UsageProvider
{
    MiniMax,
    Glm,
    Codex,
    Kimi,
}

/// <summary>Static helpers for <see cref="UsageProvider"/>. Pure mappings, no reflection.</summary>
public static class UsageProviders
{
    /// <summary>
    /// Iteration order used by the Swift app (allCases override):
    /// miniMax, codex, kimi, glm. Note this differs from the enum member declaration order.
    /// </summary>
    public static readonly UsageProvider[] All =
    {
        UsageProvider.MiniMax, UsageProvider.Codex, UsageProvider.Kimi, UsageProvider.Glm,
    };

    /// <summary>Swift rawValue ("minimax"/"glm"/"codex"/"kimi") — the JSON wire value.</summary>
    public static string RawValue(this UsageProvider provider) => provider switch
    {
        UsageProvider.MiniMax => "minimax",
        UsageProvider.Glm => "glm",
        UsageProvider.Codex => "codex",
        UsageProvider.Kimi => "kimi",
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, null),
    };

    /// <summary>Stable presentation label (Swift: displayName). Pure string mapping.</summary>
    public static string DisplayName(this UsageProvider provider) => provider switch
    {
        UsageProvider.MiniMax => "MiniMax",
        UsageProvider.Glm => "GLM",
        UsageProvider.Codex => "Codex",
        UsageProvider.Kimi => "Kimi",
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, null),
    };

    /// <summary>Case-sensitive raw-value lookup (Swift: UsageProvider(rawValue:)). Null when unknown.</summary>
    public static UsageProvider? FromRawValue(string? raw) => raw switch
    {
        "minimax" => UsageProvider.MiniMax,
        "glm" => UsageProvider.Glm,
        "codex" => UsageProvider.Codex,
        "kimi" => UsageProvider.Kimi,
        _ => null,
    };

    /// <summary>
    /// Cloud-side provider lookup (Swift: UsageProvider.cloudProvider(rawValue:)).
    /// Trims whitespace, lowercases, and maps the legacy "chatgpt" alias to Codex.
    /// </summary>
    public static UsageProvider? FromCloudRawValue(string? raw)
    {
        if (raw is null)
        {
            return null;
        }

        var normalized = raw.Trim().ToLowerInvariant();
        if (normalized == "chatgpt")
        {
            return UsageProvider.Codex;
        }

        return FromRawValue(normalized);
    }
}

/// <summary>
/// Account identity inside one provider (Swift: ModelUsageData.provider + accountName).
/// Multi-account providers (Codex) tag every model row with an account email; single-account
/// providers leave <see cref="AccountName"/> null.
/// </summary>
public sealed record ProviderAccountIdentity(UsageProvider Provider, string? AccountName)
{
    /// <summary>
    /// Swift: normalizedAccountName — trimmed + lowercased, empty string when null.
    /// Used as the account segment of quota identity keys and cloud account grouping.
    /// </summary>
    public string NormalizedAccountName => ProviderAccounts.Normalize(AccountName);
}

/// <summary>Account-name normalization shared by identity keys and cloud grouping.</summary>
public static class ProviderAccounts
{
    /// <summary>Trim + lowercase; null/empty collapse to "" (Swift: normalizedAccountName).</summary>
    public static string Normalize(string? accountName) =>
        (accountName ?? string.Empty).Trim().ToLowerInvariant();
}

/// <summary>
/// The string keys used to address one provider+account+model quota row.
/// These key formats are part of the data contract: ModelQuotaSampleStore persists sample
/// dictionaries keyed by them, ModelUtilizationHistoryStore persists history dictionaries keyed
/// by them, and CloudSyncService groups remote rows by them.
/// </summary>
public static class QuotaIdentity
{
    /// <summary>
    /// Swift: ModelUsageData.quotaIdentityKey — "provider:normalizedAccount:normalizedModel"
    /// (account and model trimmed + lowercased). Canonical identity for dedup/grouping.
    /// </summary>
    public static string Key(UsageProvider provider, string? accountName, string modelName) => string.Join(
        ":",
        provider.RawValue(),
        ProviderAccounts.Normalize(accountName),
        (modelName ?? string.Empty).Trim().ToLowerInvariant());

    /// <summary>
    /// Swift: ModelUsageData.id — "provider:accountName:modelName" with the RAW (unnormalized)
    /// account/model names; "provider:modelName" when the account is null/empty.
    /// Identifiable/ForEach identity, not the normalized grouping key.
    /// </summary>
    public static string DisplayId(UsageProvider provider, string? accountName, string modelName)
    {
        if (string.IsNullOrEmpty(accountName))
        {
            return $"{provider.RawValue()}:{modelName}";
        }

        return $"{provider.RawValue()}:{accountName}:{modelName}";
    }
}

/// <summary>
/// Serializes <see cref="UsageProvider"/> as the lowercase Swift raw value. Hand-written on
/// purpose: JsonStringEnumConverter would emit the C# member name ("MiniMax"), and camelCase
/// policy would produce "miniMax" — neither matches the wire format.
/// </summary>
public sealed class UsageProviderJsonConverter : JsonConverter<UsageProvider>
{
    public static UsageProviderJsonConverter Instance { get; } = new();

    public override UsageProvider Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var raw = reader.GetString();
        var provider = UsageProviders.FromRawValue(raw);
        if (provider is null)
        {
            throw new JsonException(
                $"Unknown UsageProvider raw value '{raw}'. Expected one of: codex/kimi/glm/minimax.");
        }

        return provider.Value;
    }

    public override void Write(Utf8JsonWriter writer, UsageProvider value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value.RawValue());
    }
}
