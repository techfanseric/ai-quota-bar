// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/CreditsModels.swift
//   （struct CodexRateLimitResetCreditsSnapshot + CodexRateLimitResetCreditInventory 的排序语义）

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// rate-limit-reset-credits 端点快照（Swift: CodexRateLimitResetCreditsSnapshot）。
/// </summary>
/// <param name="Credits">全量积分（Id 已做 stableID 哈希）。</param>
/// <param name="AvailableCount">服务方报告的可用数（解析层拒绝负数）。</param>
/// <param name="UpdatedAt">快照时间。</param>
public sealed record CodexRateLimitResetCreditsSnapshot(
    IReadOnlyList<CodexRateLimitResetCredit> Credits,
    int AvailableCount,
    DateTimeOffset UpdatedAt)
{
    /// <summary>
    /// Swift: availableInventory(at:) —— available 状态且未过期（无过期时间视为可用），
    /// 有限过期时间升序在前、无过期时间在后；同过期时间以稳定 Id 升序决胜
    /// （Swift: sorted 的 fallthrough `lhs.id &lt; rhs.id`，CreditsModels.swift）。
    /// </summary>
    public IReadOnlyList<CodexRateLimitResetCredit> AvailableCredits(DateTimeOffset at) =>
        Credits
            .Where(credit => credit.IsAvailable && (credit.ExpiresAt is null || credit.ExpiresAt > at))
            .OrderBy(credit => credit.ExpiresAt is null ? 1 : 0)
            .ThenBy(credit => credit.ExpiresAt)
            .ThenBy(credit => credit.Id, StringComparer.Ordinal)
            .ToList();

    /// <summary>Swift: nextExpiringAvailableCredit。</summary>
    public CodexRateLimitResetCredit? NextExpiringAvailableCredit(DateTimeOffset at) =>
        AvailableCredits(at).FirstOrDefault(credit => credit.ExpiresAt is not null);
}
