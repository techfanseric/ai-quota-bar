// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/CreditsModels.swift（struct CreditsSnapshot；
//   events 裁剪——Codex 管线从不填充事件列表，UsageFormatter 的 credits 事件展示属后续阶段）

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Parsing;

/// <summary>
/// Codex 积分余额快照（Swift: CreditsSnapshot 的 Codex 消费子集）。
/// </summary>
/// <param name="Remaining">余额（balance 缺失时的占位 0 不是“已花光”，配合 <paramref name="BalanceReadSucceeded"/> 区分）。</param>
/// <param name="UpdatedAt">快照时间。</param>
/// <param name="CreditLimit">可选月度限额。</param>
/// <param name="BalanceReadSucceeded">余额是否真实读到（false = 仅有限额/占位）。</param>
/// <param name="CreditsAvailable">服务端是否明确报告存在有限积分池；null = 未声明。</param>
/// <param name="BalanceIsWorkspace">余额是否来自共享工作区端点。</param>
public sealed record CodexCreditsSnapshot(
    double Remaining,
    DateTimeOffset UpdatedAt,
    CodexCreditLimitSnapshot? CreditLimit = null,
    bool BalanceReadSucceeded = true,
    bool? CreditsAvailable = null,
    bool BalanceIsWorkspace = false)
{
    /// <summary>Swift: hasWorkspaceBalance = balanceReadSucceeded &amp;&amp; balanceIsWorkspace。</summary>
    public bool HasWorkspaceBalance => BalanceReadSucceeded && BalanceIsWorkspace;

    /// <summary>
    /// Swift: displayRemaining —— 工作区余额优先；否则限额剩余；否则仅当余额真实读到才返回，
    /// 避免“未读占位 0”被当成真实零余额。
    /// </summary>
    public double? DisplayRemaining =>
        HasWorkspaceBalance
            ? Remaining
            : CreditLimit?.Remaining ?? (BalanceReadSucceeded ? Remaining : null);
}
