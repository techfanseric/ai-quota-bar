// Swift 来源：AIQuotaBar/Models/UsageData.swift — struct UsageData / struct ModelUsageData
// 的全部计算属性与 with* 派生方法（百分比、可用性/百分比模式判定、pace/reserve/deficit 数学、
// 排序、窗口分类、withModels/withDetailSource 系列、parsedDetail 解析）。
// 契约本体（Contracts/UsageData.cs 的 record）已冻结形状，此处一律以扩展方法实现，不改 record。
// 命名映射：Swift 计算属性 → C# 扩展方法（C# 无扩展属性）；Swift private 计算属性
// currentIntervalPaceWindow 在此提升为 internal，供 pace 数学复用。
// 对应测试：无（Swift 端无 UsageData 计算属性的独立测试文件；数值经
// ModelUtilizationCycleMergerTests / GLM / Kimi 等 mapper 测试间接覆盖）。
// 未移植（展示/本地化，属 App 层）：estimateDaysRemaining（Swift private 占位）、
// currentIntervalRemainingText / currentIntervalUsageRatioText / resetTimeText /
// formattedMenuBarText / formattedStatusBarLine / displayName。

#nullable enable

using System;
using System.Collections.Generic;
using System.Linq;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// UsageData / ModelUsageData 的纯计算逻辑（Swift 计算属性族的扩展方法形态）。
/// 字段语义提醒：CurrentIntervalRemaining / WeeklyRemaining 是 API 返回的【剩余】量
/// （Swift 字段名 currentIntervalUsed/weeklyUsed 是历史误称），"已用 = 总量 - 剩余"。
/// </summary>
public static class UsageDataCalculations
{
    // ------------------------------------------------------------------ UsageData 级别

    /// <summary>整体剩余百分比（0-100；total ≤ 0 时 0）。Swift: percentageRemaining。</summary>
    public static double PercentageRemaining(this UsageData data) =>
        data.Total > 0 ? (double)data.Remains / data.Total * 100 : 0;

    /// <summary>Swift: modelCount。</summary>
    public static int ModelCount(this UsageData data) => data.Models.Count;

    /// <summary>当前周期仍有配额的 model 数。Swift: readyModelsCount。</summary>
    public static int ReadyModelsCount(this UsageData data) =>
        data.Models.Count(static model => model.IsCurrentIntervalAvailable());

    /// <summary>当前周期已耗尽的 model 数。Swift: exhaustedModelsCount。</summary>
    public static int ExhaustedModelsCount(this UsageData data) =>
        data.Models.Count(static model => !model.IsCurrentIntervalAvailable());

    /// <summary>周配额从未使用的 model 数（已用为 0 = 没用过）。Swift: weeklyFullModelsCount。</summary>
    public static int WeeklyFullModelsCount(this UsageData data) =>
        data.Models.Count(static model => model.IsWeeklyFull());

    /// <summary>
    /// 仍可用且当前周期剩余百分比 ≤ threshold 的 model 数。Swift: lowModelsCount(threshold:)。
    /// </summary>
    public static int LowModelsCount(this UsageData data, double threshold) =>
        data.Models.Count(model =>
            model.IsCurrentIntervalAvailable() && model.CurrentIntervalPercentageRemaining() <= threshold);

    /// <summary>
    /// 排序后的 model 行：不可用(0) → 低于告警阈值(1) → 正常(2)，同级按剩余百分比升序、
    /// 再按 model 名。Swift: sortedModels(warningThreshold:)（sortWeight 的三元组字典序）。
    /// </summary>
    public static IReadOnlyList<ModelUsageData> SortedModels(this UsageData data, double warningThreshold) =>
        data.Models
            .Select(model => (Model: model, Weight: SortWeight(model, warningThreshold)))
            .OrderBy(static entry => entry.Weight.Severity)
            .ThenBy(static entry => entry.Weight.PercentageRemaining)
            .ThenBy(static entry => entry.Model.ModelName, StringComparer.Ordinal)
            .Select(static entry => entry.Model)
            .ToList();

    /// <summary>所有 model 中最早的 endTime。Swift: nextResetDate。</summary>
    public static DateTimeOffset? NextResetDate(this UsageData data)
    {
        var endTimes = data.Models.Select(static model => model.EndTime).OfType<DateTimeOffset>().ToList();
        return endTimes.Count > 0 ? endTimes.Min() : null;
    }

    /// <summary>排序后最紧急的 model（告警阈值固定 20）。Swift: mostUrgentModel。</summary>
    public static ModelUsageData? MostUrgentModel(this UsageData data)
    {
        var sorted = data.SortedModels(warningThreshold: 20);
        return sorted.Count > 0 ? sorted[0] : null;
    }

    /// <summary>
    /// 替换 models 并重算 remains（= 可用 model 数）与 total（= 新 model 数）；其余字段
    /// （timestamp / subscribeTitle 等）保持不变。Swift: withModels(_:)。
    /// </summary>
    public static UsageData WithModels(this UsageData data, IReadOnlyList<ModelUsageData> nextModels) => data with
    {
        Remains = nextModels.Count(static model => model.IsCurrentIntervalAvailable()),
        Total = nextModels.Count,
        Models = nextModels,
    };

    // ------------------------------------------------------------------ ModelUsageData：计数与百分比

    /// <summary>已用 = max(0, 总量 - 剩余)。Swift: currentIntervalUsedCount。</summary>
    public static int CurrentIntervalUsedCount(this ModelUsageData model) =>
        Math.Max(0, model.CurrentIntervalTotal - model.CurrentIntervalRemaining);

    /// <summary>周已用 = max(0, 周总量 - 周剩余)。Swift: weeklyUsedCount。</summary>
    public static int WeeklyUsedCount(this ModelUsageData model) =>
        Math.Max(0, model.WeeklyTotal - model.WeeklyRemaining);

    /// <summary>是否有周配额限制（API 给了周百分比，或周总量 &gt; 0）。Swift: hasWeeklyLimit。</summary>
    public static bool HasWeeklyLimit(this ModelUsageData model) =>
        model.WeeklyRemainingPercent != null || model.WeeklyTotal > 0;

    /// <summary>
    /// 周配额是否无限制（API 通过 status=3 或 total=0 + percent=100 表达；仅 MiniMax）。
    /// Swift: isWeeklyUnlimited。
    /// </summary>
    public static bool IsWeeklyUnlimited(this ModelUsageData model) =>
        model.Provider == UsageProvider.MiniMax &&
        model.WeeklyRemainingPercent is >= 100 &&
        model.WeeklyTotal <= 0;

    /// <summary>周剩余百分比的 Double 形态。Swift: weeklyRemainingPercentValue。</summary>
    public static double? WeeklyRemainingPercentValue(this ModelUsageData model) =>
        model.WeeklyRemainingPercent is { } percent ? percent : null;

    /// <summary>
    /// 当前周期是否有剩余：优先 API 百分比（&gt; 0），否则按剩余计数（&gt; 0）。
    /// Swift: isCurrentIntervalAvailable。
    /// </summary>
    public static bool IsCurrentIntervalAvailable(this ModelUsageData model) =>
        model.CurrentIntervalRemainingPercent is { } percent
            ? percent > 0
            : model.CurrentIntervalRemaining > 0;

    /// <summary>当前周期是否已耗尽（带 total &gt; 0 前置，避免无窗口行误判）。Swift: isExhaustedCurrentInterval。</summary>
    public static bool IsExhaustedCurrentInterval(this ModelUsageData model) =>
        model.CurrentIntervalRemainingPercent is { } percent
            ? percent <= 0
            : model.CurrentIntervalTotal > 0 && model.CurrentIntervalRemaining <= 0;

    /// <summary>当前周期剩余百分比（0-100）：优先 API 百分比，否则按 count 比例。Swift: currentIntervalPercentageRemaining。</summary>
    public static double CurrentIntervalPercentageRemaining(this ModelUsageData model)
    {
        if (model.CurrentIntervalRemainingPercent is { } percent)
        {
            return percent;
        }

        return model.CurrentIntervalTotal > 0
            ? (double)model.CurrentIntervalRemaining / model.CurrentIntervalTotal * 100
            : 0;
    }

    /// <summary>当前周期已用百分比（0-100）：优先 100 - API 百分比，否则按已用 count 比例。Swift: currentIntervalPercentageUsed。</summary>
    public static double CurrentIntervalPercentageUsed(this ModelUsageData model)
    {
        if (model.CurrentIntervalRemainingPercent is { } percent)
        {
            return Math.Max(0, 100 - percent);
        }

        return model.CurrentIntervalTotal > 0
            ? (double)model.CurrentIntervalUsedCount() / model.CurrentIntervalTotal * 100
            : 0;
    }

    /// <summary>
    /// 进度条实际宽度百分比：默认按"已用"，credits 反向语义走 override（钳到 0-100）。
    /// Swift: currentIntervalBarPercent。
    /// </summary>
    public static double CurrentIntervalBarPercent(this ModelUsageData model) =>
        model.ProgressBarPercentOverride is { } overridePercent
            ? Math.Clamp(overridePercent, 0, 100)
            : model.CurrentIntervalPercentageUsed();

    /// <summary>图表 Y 轴上限：有具体计数用计数，否则退到 0-100 百分比。Swift: currentIntervalYAxisMax。</summary>
    public static double CurrentIntervalYAxisMax(this ModelUsageData model)
    {
        if (model.CurrentIntervalTotal > 0)
        {
            return model.CurrentIntervalTotal;
        }

        return model.CurrentIntervalRemainingPercent != null ? 100 : 0;
    }

    /// <summary>
    /// 是否处于百分比模式：valueSuffix == "%"（codex/GLM 显式设置）或 API 直接给了剩余百分比
    /// （MiniMax；此时 count 字段常为 0 或不对齐，必须走 percent 渲染）。Swift: isCurrentIntervalPercentMode。
    /// </summary>
    public static bool IsCurrentIntervalPercentMode(this ModelUsageData model) =>
        model.ValueSuffix == "%" || model.CurrentIntervalRemainingPercent != null;

    /// <summary>周已用百分比（0-100）：优先 100 - API 周百分比，否则按 count 比例。Swift: weeklyPercentageUsed。</summary>
    public static double? WeeklyPercentageUsed(this ModelUsageData model)
    {
        if (model.WeeklyRemainingPercent is { } percent)
        {
            return Math.Max(0, 100 - percent);
        }

        return model.WeeklyTotal > 0
            ? (double)model.WeeklyUsedCount() / model.WeeklyTotal * 100
            : null;
    }

    /// <summary>周是否满的（已用为 0 = 没用过）。Swift: isWeeklyFull。</summary>
    public static bool IsWeeklyFull(this ModelUsageData model) =>
        model.HasWeeklyLimit() && model.WeeklyUsedCount() == 0;

    /// <summary>整个周期配额完全未动用。Swift: isFullQuotaUnused。</summary>
    public static bool IsFullQuotaUnused(this ModelUsageData model)
    {
        if (model.CurrentIntervalRemainingPercent is { } percent)
        {
            return percent >= 100;
        }

        return model.CurrentIntervalTotal > 0 &&
            model.CurrentIntervalRemaining >= model.CurrentIntervalTotal &&
            model.CurrentIntervalUsedCount() == 0;
    }

    // ------------------------------------------------------------------ ModelUsageData：窗口分类

    /// <summary>当前周期时长（end - start，允许负值）；缺任一边界为 null。Swift: currentIntervalDuration。</summary>
    public static TimeSpan? CurrentIntervalDuration(this ModelUsageData model) =>
        model.StartTime is { } start && model.EndTime is { } end ? end - start : null;

    /// <summary>
    /// GLM 可能在配额明确是 5h 窗口时仍缺 reset 元数据。Swift: isGLMFiveHourWindow。
    /// </summary>
    public static bool IsGlmFiveHourWindow(this ModelUsageData model) =>
        model.Provider == UsageProvider.Glm &&
        model.ModelName.Contains("5h", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Kimi 月计划（"Total usage"）：只带 endTime，没有周期开始时间。Swift: isKimiMonthlyTotalWindow。
    /// </summary>
    public static bool IsKimiMonthlyTotalWindow(this ModelUsageData model) =>
        model.Provider == UsageProvider.Kimi &&
        model.ModelName == "Total usage" &&
        model.StartTime == null &&
        model.EndTime != null;

    /// <summary>
    /// 展示用图表窗口：真实起止优先；GLM 5h 用 [now-5h, now] 滚动窗；Kimi 月计划按到期日
    /// 回推一个自然月；其余 null。展示窗口绝不发明 reset 日期。Swift: quotaChartWindow(now:)。
    /// </summary>
    public static (DateTimeOffset Start, DateTimeOffset End)? QuotaChartWindow(
        this ModelUsageData model,
        DateTimeOffset now)
    {
        if (model.StartTime is { } start && model.EndTime is { } end)
        {
            return (start, end);
        }

        if (model.IsGlmFiveHourWindow())
        {
            return (now.AddHours(-5), now);
        }

        if (model.IsKimiMonthlyTotalWindow() && model.EndTime is { } endTime)
        {
            // Swift: Calendar.date(byAdding: .month, value: -1, to: endTime)。
            return (endTime.AddMonths(-1), endTime);
        }

        return null;
    }

    /// <summary>是否短周期（&lt; 24h；GLM 5h 恒为短）。Swift: isShortCurrentInterval。</summary>
    public static bool IsShortCurrentInterval(this ModelUsageData model)
    {
        if (model.IsGlmFiveHourWindow())
        {
            return true;
        }

        return model.CurrentIntervalDuration() is { } duration && duration < QuotaWindow.OneDay;
    }

    /// <summary>Codex 5h 历史窗口：名字指明 5h 且实测时长落在 4.5h-5.5h。Swift: isCodexFiveHourHistoryWindow。</summary>
    public static bool IsCodexFiveHourHistoryWindow(this ModelUsageData model)
    {
        if (model.Provider != UsageProvider.Codex ||
            model.CurrentIntervalDuration() is not { } duration ||
            duration < TimeSpan.FromHours(4.5) ||
            duration > TimeSpan.FromHours(5.5))
        {
            return false;
        }

        var normalizedName = model.ModelName.ToLowerInvariant();
        return normalizedName == "5h" ||
            normalizedName.Contains("5-hour", StringComparison.Ordinal) ||
            normalizedName.Contains("5 hour", StringComparison.Ordinal);
    }

    /// <summary>
    /// Codex 长窗口是否够格做账号的 fallback 曲线（名字含 weekly，或时长 6-8 天）。
    /// Swift: isCodexWeeklyCurveWindow。
    /// </summary>
    public static bool IsCodexWeeklyCurveWindow(this ModelUsageData model)
    {
        if (model.Provider != UsageProvider.Codex ||
            model.ProgressBarPercentOverride != null ||
            model.CurrentIntervalDuration() is not { } duration ||
            duration <= QuotaWindow.OneDay)
        {
            return false;
        }

        if (model.ModelName.ToLowerInvariant().Contains("weekly", StringComparison.Ordinal))
        {
            return true;
        }

        return duration >= 6 * QuotaWindow.OneDay && duration <= 8 * QuotaWindow.OneDay;
    }

    /// <summary>给定时刻是否落在当前周期内；缺边界时视为包含。Swift: containsCurrentInterval(at:)。</summary>
    public static bool ContainsCurrentInterval(this ModelUsageData model, DateTimeOffset at) =>
        model.StartTime is { } start && model.EndTime is { } end
            ? start <= at && at <= end
            : true;

    /// <summary>Swift: isCodexSlidingFiveHourExtraWindow（历史遗留，恒 false）。</summary>
    public static bool IsCodexSlidingFiveHourExtraWindow(this ModelUsageData model) => false;

    /// <summary>
    /// Codex 5h 历史窗口的规范化 ID（provider[:account]:model，与 Swift id 同构，
    /// 即 QuotaIdentity.DisplayId）。Swift: codexFiveHourCanonicalHistoryID。
    /// </summary>
    public static string? CodexFiveHourCanonicalHistoryId(this ModelUsageData model)
    {
        if (model.Provider != UsageProvider.Codex || !model.IsCodexFiveHourHistoryWindow())
        {
            return null;
        }

        return QuotaIdentity.DisplayId(model.Provider, model.AccountName, model.ModelName);
    }

    // ------------------------------------------------------------------ ModelUsageData：节奏（pace）数学

    /// <summary>
    /// 节奏计算的周期窗口：优先真实起止时间；Kimi 月计划只有到期日，用回推一个自然月的
    /// 展示窗口估算节奏。GLM 5h 的滚动展示窗口不参与节奏（elapsed 恒等于满周期，没有意义）。
    /// Swift: private currentIntervalPaceWindow — 此处提升可见性供复用与测试。
    /// </summary>
    internal static (DateTimeOffset Start, DateTimeOffset End)? CurrentIntervalPaceWindow(
        this ModelUsageData model)
    {
        if (model.StartTime is { } start && model.EndTime is { } end)
        {
            return (start, end);
        }

        if (model.IsKimiMonthlyTotalWindow())
        {
            return model.QuotaChartWindow(DateTimeOffset.Now);
        }

        return null;
    }

    /// <summary>
    /// 当前周期已流逝比例（0-1）；null = 无法计算（credits 反向语义 / 缺周期窗口 / 时长非正）。
    /// Swift: currentIntervalElapsedRatio（now 可注入，便于测试）。
    /// </summary>
    public static double? CurrentIntervalElapsedRatio(this ModelUsageData model, DateTimeOffset now)
    {
        if (model.ProgressBarPercentOverride != null)
        {
            return null;
        }

        if (CurrentIntervalPaceWindow(model) is not { } window)
        {
            return null;
        }

        var duration = window.End - window.Start;
        if (duration <= TimeSpan.Zero)
        {
            return null;
        }

        var elapsed = now - window.Start;
        return Math.Clamp(elapsed / duration, 0, 1);
    }

    /// <summary>Swift: currentIntervalElapsedRatio（默认 now）。</summary>
    public static double? CurrentIntervalElapsedRatio(this ModelUsageData model) =>
        model.CurrentIntervalElapsedRatio(DateTimeOffset.Now);

    /// <summary>周已流逝比例（0-1）；null = 缺周起止时间。Swift: weeklyElapsedRatio。</summary>
    public static double? WeeklyElapsedRatio(this ModelUsageData model, DateTimeOffset now)
    {
        if (model.WeeklyStartTime is not { } start || model.WeeklyEndTime is not { } end)
        {
            return null;
        }

        var duration = end - start;
        if (duration <= TimeSpan.Zero)
        {
            return null;
        }

        var elapsed = now - start;
        return Math.Clamp(elapsed / duration, 0, 1);
    }

    /// <summary>Swift: weeklyElapsedRatio（默认 now）。</summary>
    public static double? WeeklyElapsedRatio(this ModelUsageData model) =>
        model.WeeklyElapsedRatio(DateTimeOffset.Now);

    /// <summary>匀速消耗下"周应有的已用百分比"（0-100）。Swift: weeklyPaceUsedPercent。</summary>
    public static double? WeeklyPaceUsedPercent(this ModelUsageData model, DateTimeOffset now) =>
        model.WeeklyElapsedRatio(now) is { } ratio ? ratio * 100 : null;

    /// <summary>匀速消耗下"当前应有的已用百分比"（0-100），柱图 pace 针位置。Swift: currentIntervalPaceUsedPercent。</summary>
    public static double? CurrentIntervalPaceUsedPercent(this ModelUsageData model, DateTimeOffset now) =>
        model.CurrentIntervalElapsedRatio(now) is { } ratio ? ratio * 100 : null;

    /// <summary>匀速消耗下"当前应有的剩余值"（与 Y 轴上限同量纲），面积图节奏参考线高度。Swift: currentIntervalPaceRemaining。</summary>
    public static double? CurrentIntervalPaceRemaining(this ModelUsageData model, DateTimeOffset now) =>
        model.CurrentIntervalElapsedRatio(now) is { } ratio
            ? model.CurrentIntervalYAxisMax() * (1 - ratio)
            : null;

    /// <summary>
    /// 对比匀速消耗的进度（"省"的方向为正）：paceUsed - actualUsed。
    /// 正 = 用得比匀速慢（ahead / 有储备，绿）；负 = 用得快（behind / 赤字，红）。
    /// Swift: currentIntervalPaceDeltaPercent。
    /// </summary>
    public static double? CurrentIntervalPaceDeltaPercent(this ModelUsageData model, DateTimeOffset now)
    {
        if (model.CurrentIntervalPaceUsedPercent(now) is not { } paceUsed)
        {
            return null;
        }

        return paceUsed - (100 - model.CurrentIntervalPercentageRemaining());
    }

    /// <summary>Swift: currentIntervalPaceDeltaPercent（默认 now）。</summary>
    public static double? CurrentIntervalPaceDeltaPercent(this ModelUsageData model) =>
        model.CurrentIntervalPaceDeltaPercent(DateTimeOffset.Now);

    /// <summary>
    /// 节奏快照：复用 codexbar 的 UsagePace.Stage 分桶（经 UsagePace.Historical）。
    /// null = 无法计算（credits 反向语义 / 缺周期窗口 / 时长非正 / 刚开始却已有消耗的脏数据）。
    /// Swift: currentIntervalPace。
    /// </summary>
    public static UsagePace? CurrentIntervalPace(this ModelUsageData model, DateTimeOffset now)
    {
        if (model.ProgressBarPercentOverride != null)
        {
            return null;
        }

        if (CurrentIntervalPaceWindow(model) is not { } window)
        {
            return null;
        }

        var duration = window.End - window.Start;
        if (duration <= TimeSpan.Zero)
        {
            return null;
        }

        var elapsed = Math.Clamp(now - window.Start, TimeSpan.Zero, duration);

        // codexbar 的 guard：elapsed == 0 且 actual > 0 时不计算（刚开始时已用 > 0 是脏数据）。
        var actual = model.CurrentIntervalPercentageUsed();
        if (elapsed == TimeSpan.Zero && actual > 0)
        {
            return null;
        }

        var expected = elapsed / duration * 100;
        return UsagePace.Historical(
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: null,
            willLastToReset: actual <= expected,
            runOutProbability: null);
    }

    /// <summary>Swift: currentIntervalPace（默认 now）。</summary>
    public static UsagePace? CurrentIntervalPace(this ModelUsageData model) =>
        model.CurrentIntervalPace(DateTimeOffset.Now);

    // ------------------------------------------------------------------ ModelUsageData：detailText 解析与派生

    /// <summary>
    /// 把 CodexUsageDataMapper 写入的 detailText（"Pro 20x · OAuth · resets 04/08 00:00"）
    /// 拆成三段：plan（"Pro 20x"）/ source（"OAuth"）/ rest（"resets ..." 等）。
    /// Swift: parsedDetail。
    /// </summary>
    public static (string? Plan, string? Source, string? Rest) ParsedDetail(this ModelUsageData model)
    {
        if (string.IsNullOrEmpty(model.DetailText))
        {
            return (null, null, null);
        }

        string? plan = null;
        string? source = null;
        var restParts = new List<string>();
        foreach (var part in model.DetailText.Split(" · ", StringSplitOptions.RemoveEmptyEntries))
        {
            if (part.StartsWith("resets ", StringComparison.Ordinal))
            {
                restParts.Add(part);
            }
            else if (plan == null && LooksLikeCodexPlanName(part))
            {
                plan = part;
            }
            else if (source == null)
            {
                source = part;
            }
            else
            {
                restParts.Add(part);
            }
        }

        return (plan, source, restParts.Count == 0 ? null : string.Join(" · ", restParts));
    }

    /// <summary>云同步补全数据里的噪声行：source 为 "Cloud" 的 codex "Credits" 行。Swift: isCloudNoiseModel。</summary>
    public static bool IsCloudNoiseModel(this ModelUsageData model)
    {
        if (model.ParsedDetail().Source != "Cloud")
        {
            return false;
        }

        if (model.Provider == UsageProvider.Codex)
        {
            return model.ModelName.ToLowerInvariant() == "credits";
        }

        return false;
    }

    /// <summary>
    /// 替换/注入 detailText 里的来源段（首个形如来源名的段；没有则插到 "resets ..." 段前或末尾）。
    /// Swift: withDetailSource(_:)。
    /// </summary>
    public static ModelUsageData WithDetailSource(this ModelUsageData model, string source) =>
        model with { DetailText = DetailTextWithSource(model.DetailText, source) };

    /// <summary>仅替换 accountName，其余字段（含 detailText）不变。Swift: withAccountName(_:)。</summary>
    public static ModelUsageData WithAccountName(this ModelUsageData model, string nextAccountName) =>
        model with { AccountName = nextAccountName };

    /// <summary>
    /// 排序权重（Swift private sortWeight）：(severity, 剩余百分比, modelName) 三元组字典序。
    /// severity：0 = 不可用，1 = 低于告警阈值，2 = 正常。
    /// </summary>
    private static (int Severity, double PercentageRemaining, string ModelName) SortWeight(
        ModelUsageData model,
        double warningThreshold)
    {
        var severity = !model.IsCurrentIntervalAvailable()
            ? 0
            : model.CurrentIntervalPercentageRemaining() <= warningThreshold ? 1 : 2;
        return (severity, model.CurrentIntervalPercentageRemaining(), model.ModelName);
    }

    // Swift private detailTextWithSource(_:)。
    private static string? DetailTextWithSource(string? detailText, string source)
    {
        if (string.IsNullOrEmpty(detailText))
        {
            return source;
        }

        var parts = detailText.Split(" · ", StringSplitOptions.RemoveEmptyEntries).ToList();
        var nextParts = new List<string>();
        var didReplaceSource = false;

        foreach (var part in parts)
        {
            if (!didReplaceSource && LooksLikeSourceName(part))
            {
                nextParts.Add(source);
                didReplaceSource = true;
            }
            else
            {
                nextParts.Add(part);
            }
        }

        if (!didReplaceSource)
        {
            var insertIndex = nextParts.FindIndex(part =>
                part.StartsWith("resets ", StringComparison.Ordinal));
            if (insertIndex < 0)
            {
                insertIndex = nextParts.Count;
            }

            nextParts.Insert(insertIndex, source);
        }

        return string.Join(" · ", nextParts);
    }

    // Swift private static looksLikeSourceName(_:)。
    private static bool LooksLikeSourceName(string part) => part.ToLowerInvariant() switch
    {
        "oauth" or "codex cli" or "openai web" or "cli" or "web" or "cloud" or "mix" => true,
        _ => false,
    };

    // Swift private static looksLikeCodexPlanName(_:)：覆盖 CodexPlanFormatting 的常见输出
    // Pro / Pro 20x / Pro 5x / Plus / Team / Enterprise。
    private static bool LooksLikeCodexPlanName(string part)
    {
        var lower = part.ToLowerInvariant();
        if (lower is "pro" or "plus" or "team" or "enterprise")
        {
            return true;
        }

        return lower.StartsWith("pro ", StringComparison.Ordinal) ||
            lower.StartsWith("pro_", StringComparison.Ordinal) ||
            lower.StartsWith("pro-", StringComparison.Ordinal);
    }
}
