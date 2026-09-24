// Swift 来源：AIQuotaBar/Services/Clash/ClashModels.swift — enum ClashRecoveryOutcome（v1.28.1）
// 对应测试：windows/tests/AIQuotaBar.Providers.Tests/Clash/ClashRecoveryPolicyTests.cs
//
// Swift 的关联值枚举在 C# 以封闭 record 层级表达（需继承，故非 sealed 根类型——
// 见 coding-conventions §5「需继承时显式打开并注释理由」）。

#nullable enable

namespace AIQuotaBar.Providers.Clash;

/// <summary>
/// 自动恢复尝试的三种结局：成功恢复（携带结果）、被抑制（冷却/忙碌，无需提示）、
/// 需要用户关注（ShouldTestWhenShown 决定弹出面板时是否自动测速）。
/// </summary>
public abstract record ClashRecoveryOutcome
{
    protected ClashRecoveryOutcome() { }

    public sealed record Recovered(ClashRecoveryResult Result) : ClashRecoveryOutcome;

    public sealed record Suppressed : ClashRecoveryOutcome;

    public sealed record NeedsAttention(bool ShouldTestWhenShown) : ClashRecoveryOutcome;
}
