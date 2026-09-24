// Origin: .dependencies/codexbar/Sources/CodexBarCore/UsagePace.swift — public struct UsagePace
// （仅移植 AIQuotaBar 用到的最小逻辑：Stage 分桶 stage(for:)、historical 工厂、
// safeSpeedMultiplier、0...100 clamp；以及 AIQuotaBar/Models/UsageData.swift 文件尾部
// extension UsagePace.Stage { isAhead } 的判定）。
// weekly(window:) / WorkdayProgress / wallClockInterval 依赖 codexbar 的 RateWindow 与
// 工作日日历切分，AIQuotaBar 未使用，不在 Core 移植范围（后续需要时再补）。
// 对应测试：无（AIQuotaBar/Tests 无独立 UsagePace 测试；数值经
// ModelUtilizationCycleMergerTests 与 UI 层测试间接覆盖）。

#nullable enable

using System;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 消耗节奏快照（Swift/codexbar: UsagePace）。delta = actual - expected，正数 = 用得比匀速快。
/// </summary>
/// <param name="Stage">
/// 按 |delta| 分桶：≤2 onTrack，≤6 slightly，≤12 ahead/behind，&gt;12 far。
/// 属性名与嵌套枚举同名（Swift: stage；C# "Color Color" 模式，合法且保持双端可检索）。
/// </param>
/// <param name="DeltaPercent">actualUsedPercent - expectedUsedPercent（钳制后相减）。</param>
/// <param name="ExpectedUsedPercent">匀速消耗下应有的已用百分比（0-100）。</param>
/// <param name="ActualUsedPercent">实际已用百分比（0-100）。</param>
/// <param name="EtaSeconds">按当前速率烧完的秒数；null 表示无法估算。</param>
/// <param name="WillLastToReset">按当前速率能否撑到重置。</param>
/// <param name="RunOutProbability">烧完概率（部分调用方传入）；null 表示未提供。</param>
/// <param name="SpeedMultiplierToReset">
/// 剩余容量 / 预计剩余用量（"还能再撑几倍"）；分子分母非正时为 null。
/// </param>
public sealed record UsagePace(
    Stage Stage,
    double DeltaPercent,
    double ExpectedUsedPercent,
    double ActualUsedPercent,
    double? EtaSeconds,
    bool WillLastToReset,
    double? RunOutProbability = null,
    double? SpeedMultiplierToReset = null)
{
    /// <summary>
    /// 节奏分桶（Swift: UsagePace.Stage）。ahead 系列 = 用得比匀速快，behind 系列 = 比匀速慢。
    /// </summary>
    public enum Stage
    {
        /// <summary>|delta| ≤ 2：节奏正常。</summary>
        OnTrack,

        /// <summary>2 &lt; delta ≤ 6：略快于匀速。</summary>
        SlightlyAhead,

        /// <summary>6 &lt; delta ≤ 12：快于匀速。</summary>
        Ahead,

        /// <summary>delta &gt; 12：远快于匀速。</summary>
        FarAhead,

        /// <summary>-6 &lt; delta ≤ -2：略慢于匀速。</summary>
        SlightlyBehind,

        /// <summary>-12 &lt; delta ≤ -6：慢于匀速。</summary>
        Behind,

        /// <summary>delta &lt; -12：远慢于匀速。</summary>
        FarBehind,
    }

    /// <summary>
    /// 由期望/实际已用百分比构造（Swift: UsagePace.historical(expectedUsedPercent:actualUsedPercent:...)）。
    /// 两端都钳制到 0-100 后再求 delta。
    /// </summary>
    public static UsagePace Historical(
        double expectedUsedPercent,
        double actualUsedPercent,
        double? etaSeconds,
        bool willLastToReset,
        double? runOutProbability,
        double? projectedRemainingUsage = null)
    {
        var expected = Math.Clamp(expectedUsedPercent, 0, 100);
        var actual = Math.Clamp(actualUsedPercent, 0, 100);
        var delta = actual - expected;
        return new UsagePace(
            Stage: StageFor(delta),
            DeltaPercent: delta,
            ExpectedUsedPercent: expected,
            ActualUsedPercent: actual,
            EtaSeconds: etaSeconds,
            WillLastToReset: willLastToReset,
            RunOutProbability: runOutProbability,
            SpeedMultiplierToReset: SafeSpeedMultiplier(100 - actual, projectedRemainingUsage));
    }

    /// <summary>
    /// 是否"用得比匀速慢"（Swift: extension UsagePace.Stage { isAhead }，AIQuotaBar/Models/UsageData.swift）。
    /// 与 codexbar paceOnTop 语义对齐：onTrack / behind 系列 → true（绿），
    /// ahead 系列 → false（红）。注意命名反直觉是 Swift 历史遗留：这里的 "ahead" 指配额
    /// 有余量（burn 得慢），沿用原名保证双端可检索。
    /// </summary>
    public static bool IsAhead(Stage stage) => stage switch
    {
        Stage.OnTrack or Stage.SlightlyBehind or Stage.Behind or Stage.FarBehind => true,
        Stage.SlightlyAhead or Stage.Ahead or Stage.FarAhead => false,
        _ => throw new ArgumentOutOfRangeException(nameof(stage), stage, null),
    };

    // Swift private static stage(for:) — 分桶阈值是行为契约，保持私有，经 Historical/Stages 使用。
    private static Stage StageFor(double delta)
    {
        var absDelta = Math.Abs(delta);
        if (absDelta <= 2)
        {
            return Stage.OnTrack;
        }

        if (absDelta <= 6)
        {
            return delta >= 0 ? Stage.SlightlyAhead : Stage.SlightlyBehind;
        }

        if (absDelta <= 12)
        {
            return delta >= 0 ? Stage.Ahead : Stage.Behind;
        }

        return delta >= 0 ? Stage.FarAhead : Stage.FarBehind;
    }

    private static double? SafeSpeedMultiplier(double remainingCapacity, double? projectedRemainingUsage)
    {
        if (remainingCapacity <= 0 || projectedRemainingUsage is not > 0)
        {
            return null;
        }

        var multiplier = remainingCapacity / projectedRemainingUsage.Value;
        return double.IsFinite(multiplier) ? multiplier : null;
    }
}
