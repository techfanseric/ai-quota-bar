// Swift 来源：无（Windows 端新增——钉住从 ClashRouteViewModel.attemptAutomaticRecovery 与
// StatusBarController.handleConnectivityCheck/beginAutomaticRecovery 提取出的纯决策值：
// 双域名连续两次失败才触发、恢复即停、10 分钟冷却、过滤线路按延迟取前三）。

#nullable enable

using System;
using System.Linq;
using AIQuotaBar.Providers.Clash;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Clash;

public sealed class ClashRecoveryPolicyTests
{
    // ---------------------------------------------------------------- outage gate

    [Fact]
    public void ShouldBeginRecoveryRequiresTwoConsecutiveFailures()
    {
        var gate = new ClashRecoveryPolicy.OutageGate();

        gate.OnProbeCompleted(isReachable: false);
        Assert.False(gate.ShouldBeginRecovery(), "仅一次不可达不应触发（应然：连续两次）");

        gate.OnProbeCompleted(isReachable: false);
        Assert.True(gate.ShouldBeginRecovery(), "连续两次不可达应触发自动恢复");
    }

    [Fact]
    public void ReachableProbeResetsGateAndRearms()
    {
        var gate = new ClashRecoveryPolicy.OutageGate();

        gate.OnProbeCompleted(isReachable: false);
        gate.OnProbeCompleted(isReachable: false);
        Assert.True(gate.ShouldBeginRecovery());

        // 恢复即停：可达即清零，同一轮断网不再触发。
        gate.MarkHandled();
        gate.OnProbeCompleted(isReachable: false);
        Assert.False(gate.ShouldBeginRecovery(), "已处理过的本轮断网不应重复触发");

        gate.OnProbeCompleted(isReachable: true);
        Assert.Equal(0, gate.ConsecutiveUnreachableChecks);
        Assert.False(gate.HasHandledCurrentOutage);

        // 可达重置后重新武装：再连续两次失败可再次触发。
        gate.OnProbeCompleted(isReachable: false);
        gate.OnProbeCompleted(isReachable: false);
        Assert.True(gate.ShouldBeginRecovery(), "可达重置后应重新允许触发");
    }

    [Fact]
    public void ShouldBeginRecoverySuppressedWhileInProgress()
    {
        var gate = new ClashRecoveryPolicy.OutageGate();

        gate.OnProbeCompleted(isReachable: false);
        gate.OnProbeCompleted(isReachable: false);
        gate.IsRecoveryInProgress = true;

        Assert.False(gate.ShouldBeginRecovery(), "恢复任务进行中不应重入");
    }

    [Fact]
    public void ShouldBeginRecoveryPureFormMirrorsGateState()
    {
        Assert.False(ClashRecoveryPolicy.ShouldBeginRecovery(
            consecutiveUnreachableChecks: 1, hasHandledCurrentOutage: false, isRecoveryInProgress: false));
        Assert.True(ClashRecoveryPolicy.ShouldBeginRecovery(
            consecutiveUnreachableChecks: 2, hasHandledCurrentOutage: false, isRecoveryInProgress: false));
        Assert.False(ClashRecoveryPolicy.ShouldBeginRecovery(
            consecutiveUnreachableChecks: 3, hasHandledCurrentOutage: true, isRecoveryInProgress: false));
        Assert.False(ClashRecoveryPolicy.ShouldBeginRecovery(
            consecutiveUnreachableChecks: 3, hasHandledCurrentOutage: false, isRecoveryInProgress: true));
    }

    // ---------------------------------------------------------------- cooldown

    [Fact]
    public void CooldownSuppressesAttemptsInsideTenMinutes()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

        Assert.False(ClashRecoveryPolicy.IsInCooldown(lastRecoveryAttemptAt: null, now), "从未尝试过不冷却");
        Assert.True(
            ClashRecoveryPolicy.IsInCooldown(now.AddMinutes(-9), now),
            "9 分钟内应处于冷却（应然阈值 10 分钟）");
        Assert.False(
            ClashRecoveryPolicy.IsInCooldown(now.AddMinutes(-10), now),
            "恰好 10 分钟应解除冷却（严格小于才冷却）");
    }

    // ---------------------------------------------------------------- precondition gates

    [Fact]
    public void EvaluatePreconditionsNeedsAttentionWhenDisabledOrUnfiltered()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

        Assert.Equal(
            new ClashRecoveryOutcome.NeedsAttention(ShouldTestWhenShown: true),
            ClashRecoveryPolicy.EvaluatePreconditions(
                isAutoRecoveryEnabled: false, hasActiveFilter: true, hasFilterError: false,
                isBusy: false, lastRecoveryAttemptAt: null, now));
        Assert.Equal(
            new ClashRecoveryOutcome.NeedsAttention(ShouldTestWhenShown: true),
            ClashRecoveryPolicy.EvaluatePreconditions(
                isAutoRecoveryEnabled: true, hasActiveFilter: false, hasFilterError: false,
                isBusy: false, lastRecoveryAttemptAt: null, now));
    }

    [Fact]
    public void EvaluatePreconditionsNeedsAttentionWithoutTestWhenFilterInvalid()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

        // 正则非法：不自动测速，仅提示（Swift：needsAttention(shouldTestWhenShown: false)）。
        Assert.Equal(
            new ClashRecoveryOutcome.NeedsAttention(ShouldTestWhenShown: false),
            ClashRecoveryPolicy.EvaluatePreconditions(
                isAutoRecoveryEnabled: true, hasActiveFilter: true, hasFilterError: true,
                isBusy: false, lastRecoveryAttemptAt: null, now));
    }

    [Fact]
    public void EvaluatePreconditionsSuppressesWhenBusyOrCoolingDown()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

        Assert.Equal(
            new ClashRecoveryOutcome.Suppressed(),
            ClashRecoveryPolicy.EvaluatePreconditions(
                isAutoRecoveryEnabled: true, hasActiveFilter: true, hasFilterError: false,
                isBusy: true, lastRecoveryAttemptAt: null, now));
        Assert.Equal(
            new ClashRecoveryOutcome.Suppressed(),
            ClashRecoveryPolicy.EvaluatePreconditions(
                isAutoRecoveryEnabled: true, hasActiveFilter: true, hasFilterError: false,
                isBusy: false, lastRecoveryAttemptAt: now.AddMinutes(-1), now));
    }

    [Fact]
    public void EvaluatePreconditionsReturnsNullWhenAllGatesPass()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

        // null = 门链全部通过，调用方继续执行恢复流程（refresh → 测速 → 逐候选切换）。
        Assert.Null(ClashRecoveryPolicy.EvaluatePreconditions(
            isAutoRecoveryEnabled: true, hasActiveFilter: true, hasFilterError: false,
            isBusy: false, lastRecoveryAttemptAt: now.AddMinutes(-30), now));
    }

    // ---------------------------------------------------------------- candidates

    [Fact]
    public void RankedRecoveryCandidatesKeepLatencyOrderAndCapAtThree()
    {
        var routes = new[]
        {
            new ClashRoute("fast", "Vless", 61, IsSelected: false),
            new ClashRoute("timeout", "Vless", 0, IsSelected: false),
            new ClashRoute("mid", "Vless", 95, IsSelected: false),
            new ClashRoute("unknown", "Vless", null, IsSelected: false),
            new ClashRoute("fourth", "Vless", 120, IsSelected: false),
        };

        var candidates = ClashRecoveryPolicy.RankedRecoveryCandidates(routes);

        // 应然：只取延迟可用者、保持（测速后的）延迟升序、最多 3 条。
        Assert.Equal(new[] { "fast", "mid", "fourth" }, candidates.Select(route => route.Name).ToArray());
    }
}
