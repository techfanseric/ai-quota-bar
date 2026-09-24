// Swift 来源（纯决策提取，无单一 Swift 对应文件）：
// - AIQuotaBar/Services/Clash/ClashRouteViewModel.swift — attemptAutomaticRecovery(connectivityProbe:)
//   的前置门链（autoRecoveryEnabled → hasActiveFilter → filterErrorMessage → 忙碌/冷却 → suppressed）
//   与候选线路选取（filteredRoutes.filter(\.hasUsableDelay).prefix(3)，输入为测速后按延迟排序的列表）；
// - AIQuotaBar/App/StatusBarController.swift — handleConnectivityCheck()/beginAutomaticRecovery() 的
//   断网触发状态机：双域名（chatgpt.com / openai.com）探测**连续两次**不可达才触发、
//   一轮断网只触发一次（hasHandledCurrentOutage）、可达即重置（恢复即停）、恢复任务进行中不重入。
// 对应测试：windows/tests/AIQuotaBar.Providers.Tests/Clash/ClashRecoveryPolicyTests.cs
// 暂缓项：refresh/测速/逐候选切换 + connectivityProbe 的编排循环与 UI 状态展示
//（ClashRouteViewModel 的其余部分），见移植报告。

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

namespace AIQuotaBar.Providers.Clash;

/// <summary>Clash 自动恢复的纯决策策略：触发门槛、前置门链与候选线路排序。</summary>
public static class ClashRecoveryPolicy
{
    /// <summary>双域名探测需连续失败的最少次数（StatusBarController：consecutiveUnreachableChecks &gt;= 2）。</summary>
    public const int RequiredConsecutiveFailures = 2;

    /// <summary>自动恢复重试冷却（ClashRouteViewModel.recoveryCooldown = 10 分钟）。</summary>
    public static readonly TimeSpan RecoveryCooldown = TimeSpan.FromMinutes(10);

    /// <summary>每次恢复尝试的候选线路上限（attemptAutomaticRecovery 的 prefix(3)）。</summary>
    public const int MaximumCandidateCount = 3;

    /// <summary>断网触发判定：连续失败达标、本轮断网未处理过、且当前没有进行中的恢复任务。</summary>
    public static bool ShouldBeginRecovery(
        int consecutiveUnreachableChecks,
        bool hasHandledCurrentOutage,
        bool isRecoveryInProgress) =>
        consecutiveUnreachableChecks >= RequiredConsecutiveFailures &&
        !hasHandledCurrentOutage &&
        !isRecoveryInProgress;

    /// <summary>冷却判定：距上次尝试不足 RecoveryCooldown 时抑制（null 表示从未尝试过）。</summary>
    public static bool IsInCooldown(DateTimeOffset? lastRecoveryAttemptAt, DateTimeOffset now) =>
        lastRecoveryAttemptAt is { } lastAttempt && now - lastAttempt < RecoveryCooldown;

    /// <summary>
    /// attemptAutomaticRecovery 的前置门链（顺序与 Swift 一致）。
    /// 返回 null 表示全部通过、可以继续执行恢复流程；非 null 为应返回的 Outcome。
    /// </summary>
    public static ClashRecoveryOutcome? EvaluatePreconditions(
        bool isAutoRecoveryEnabled,
        bool hasActiveFilter,
        bool hasFilterError,
        bool isBusy,
        DateTimeOffset? lastRecoveryAttemptAt,
        DateTimeOffset now)
    {
        if (!isAutoRecoveryEnabled)
        {
            return new ClashRecoveryOutcome.NeedsAttention(ShouldTestWhenShown: true);
        }

        if (!hasActiveFilter)
        {
            return new ClashRecoveryOutcome.NeedsAttention(ShouldTestWhenShown: true);
        }

        if (hasFilterError)
        {
            return new ClashRecoveryOutcome.NeedsAttention(ShouldTestWhenShown: false);
        }

        if (isBusy)
        {
            return new ClashRecoveryOutcome.Suppressed();
        }

        if (IsInCooldown(lastRecoveryAttemptAt, now))
        {
            return new ClashRecoveryOutcome.Suppressed();
        }

        return null;
    }

    /// <summary>
    /// 候选线路：过滤结果中延迟可用者、按（测速后的）延迟升序取前 MaximumCandidateCount 条。
    /// 调用方须传入 ClashRouteSorter 排序后的 filteredRoutes（与 ViewModel 一致）。
    /// </summary>
    public static IReadOnlyList<ClashRoute> RankedRecoveryCandidates(IReadOnlyList<ClashRoute> filteredRoutes) =>
        filteredRoutes
            .Where(route => route.HasUsableDelay)
            .Take(MaximumCandidateCount)
            .ToList();

    /// <summary>
    /// StatusBarController.handleConnectivityCheck 的断网触发状态机：
    /// 不可达计数累计，可达即整体重置（恢复即停）；触发后 MarkHandled，
    /// 同一轮断网不再重复触发，直到探测恢复可达重新武装。
    /// </summary>
    public sealed class OutageGate
    {
        public int ConsecutiveUnreachableChecks { get; private set; }

        public bool HasHandledCurrentOutage { get; private set; }

        public bool IsRecoveryInProgress { get; set; }

        public void OnProbeCompleted(bool isReachable)
        {
            if (isReachable)
            {
                Reset();
                return;
            }

            ConsecutiveUnreachableChecks++;
        }

        /// <summary>可达、或探测暂停（provider 未配置/跟随模式下未运行）时清零。</summary>
        public void Reset()
        {
            ConsecutiveUnreachableChecks = 0;
            HasHandledCurrentOutage = false;
        }

        /// <summary>触发恢复前调用：本轮断网视为已处理。</summary>
        public void MarkHandled() => HasHandledCurrentOutage = true;

        public bool ShouldBeginRecovery() => ClashRecoveryPolicy.ShouldBeginRecovery(
            ConsecutiveUnreachableChecks,
            HasHandledCurrentOutage,
            IsRecoveryInProgress);
    }
}
