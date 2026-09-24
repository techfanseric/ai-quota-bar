// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/ProviderIdentitySnapshot.swift（enum UsageDataConfidence）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>数据置信度（Swift: UsageDataConfidence）。线上为小写原串（"exact" 等）。</summary>
public enum CodexDataConfidence
{
    Exact,
    Estimated,
    PercentOnly,
    Unknown,
}
