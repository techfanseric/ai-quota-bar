// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift
//   （struct CodexWorkspaceRemainingBalanceResponse；契约样本：workspace-remaining-balance-response.json）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// 工作区剩余积分端点（…/accounts/&lt;id&gt;/remaining_balance）响应。
/// balance 为数字或（trim 后）可解析字符串；非有限值（NaN/Infinity）与对象/布尔 → null；
/// 负数钳为 0（Swift: decoded.flatMap { $0.isFinite ? max(0, $0) : nil }）。
/// </summary>
public sealed record CodexWorkspaceRemainingBalance(double? Balance);
