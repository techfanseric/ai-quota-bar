// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/ProviderIdentitySnapshot.swift

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 一次抓取内的账号身份（Swift: ProviderIdentitySnapshot）。providerId 保留线上原串
/// （如 "codex" / "synthetic"），不做枚举归一。
/// </summary>
public sealed record CodexProviderIdentity(
    string? ProviderId,
    string? AccountEmail,
    string? AccountOrganization,
    string? LoginMethod,
    string? AccountId = null);
