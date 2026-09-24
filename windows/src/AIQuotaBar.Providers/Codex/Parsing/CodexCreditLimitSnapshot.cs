// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/CreditsModels.swift（struct CodexCreditLimitSnapshot）
//   与 Providers/Codex/CodexSpendControlLimitMapping.swift（codexCreditLimitSnapshot(updatedAt:)）

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// Codex 月度积分限额（Swift: CodexCreditLimitSnapshot）。构造时与 Swift init 同一钳制：
/// used/limit 取 max(0,·)，remaining = max(0, limit-used)，remainingPercent 钳到 [0,100]。
/// </summary>
public sealed record CodexCreditLimitSnapshot(
    string Title,
    double Used,
    double Limit,
    double Remaining,
    double RemainingPercent,
    DateTimeOffset? ResetsAt,
    DateTimeOffset UpdatedAt)
{
    public const string DefaultTitle = "Monthly credit limit";

    public CodexCreditLimitSnapshot(
        string? title,
        double used,
        double limit,
        double remainingPercent,
        DateTimeOffset? resetsAt,
        DateTimeOffset updatedAt)
        : this(
            NormalizeTitle(title),
            Math.Max(0, used),
            Math.Max(0, limit),
            Math.Max(0, Math.Max(0, limit) - Math.Max(0, used)),
            Math.Min(100, Math.Max(0, remainingPercent)),
            resetsAt,
            updatedAt)
    {
    }

    private static string NormalizeTitle(string? title)
    {
        var trimmed = title?.Trim();
        return string.IsNullOrEmpty(trimmed) ? DefaultTitle : trimmed;
    }
}
