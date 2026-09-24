// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/ProviderCostSnapshot.swift
//   （仅保留 Codex 管线与 usage-snapshot fixture 消费的字段；personalUsed/nextRegenAmount 裁剪）

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 花费/额度快照（Swift: ProviderCostSnapshot，Codex 消费子集）。
/// </summary>
public sealed record CodexProviderCostSnapshot(
    double Used,
    double Limit,
    string CurrencyCode,
    string? Period = null,
    DateTimeOffset? ResetsAt = null,
    double? Balance = null,
    DateTimeOffset? BalanceUpdatedAt = null,
    bool? BalanceIsWorkspace = null,
    DateTimeOffset UpdatedAt = default);
