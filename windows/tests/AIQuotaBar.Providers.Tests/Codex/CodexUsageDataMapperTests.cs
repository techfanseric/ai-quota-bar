// Swift 来源：AIQuotaBar/Tests/Codex/CodexUsageDataMapperTests.swift（7 个用例逐条移植；
//   快照/窗口直接以代码构造——Swift 侧同样是结构体构造而非 API 样本，不属于 fixtures 管辖）。

#nullable enable

using System;
using System.Collections.Generic;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Codex.Parsing;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexUsageDataMapperTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 24, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void MapsPrimaryWindowTo5h()
    {
        var window = new CodexRateWindow(35, 300, new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero), null);
        var snapshot = MakeSnapshot(
            primary: window,
            identity: new CodexProviderIdentity("codex", "user@example.com", null, "pro"));

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits: null, sourceLabel: "oauth", now: Now);

        Assert.Equal(UsageProvider.Codex, data.Provider);
        var model = Assert.Single(data.Models);
        Assert.Equal("5h", model.ModelName);
        Assert.Equal("%", model.ValueSuffix);
        Assert.Equal(65, model.CurrentIntervalRemainingPercent);
        Assert.Equal("user@example.com", model.AccountName);
        Assert.Equal(0, model.WeeklyTotal);
        Assert.NotNull(model.EndTime);
    }

    [Fact]
    public void MapsSecondaryWindowToWeekly()
    {
        var window = new CodexRateWindow(0, 7 * 24 * 60, new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero), null);
        var snapshot = MakeSnapshot(secondary: window);

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits: null, sourceLabel: "codex-cli", now: Now);

        var model = Assert.Single(data.Models);
        Assert.Equal("Weekly", model.ModelName);
        Assert.Equal(100, model.CurrentIntervalRemainingPercent);
        Assert.Null(model.AccountName);
    }

    [Fact]
    public void MapsExtraRateWindows()
    {
        var extra = new CodexNamedRateWindow(
            "spark",
            "GPT-5.3-Codex-Spark",
            new CodexRateWindow(60, 60, new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero), null));
        var snapshot = MakeSnapshot(extraRateWindows: new[] { extra });

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits: null, sourceLabel: "oauth", now: Now);

        var model = Assert.Single(data.Models);
        Assert.Equal("GPT-5.3-Codex-Spark", model.ModelName);
        Assert.Equal(40, model.CurrentIntervalRemainingPercent);
    }

    [Fact]
    public void CodexSparkFiveHourUsesIndependentHistoryId()
    {
        // Swift: testCodexSparkFiveHourUsesIndependentHistoryID —— Swift 断言的
        // codexFiveHourCanonicalHistoryID / isCodexFiveHourHistoryWindow 是 App 侧窗口归类
        // 计算属性（后续 Core 任务）；此处钉住对应的 DisplayId（Swift `id`）形状。
        var extra = new CodexNamedRateWindow(
            "spark",
            "Codex Spark 5-hour",
            new CodexRateWindow(0, 300, new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero), null));
        var snapshot = MakeSnapshot(
            extraRateWindows: new[] { extra },
            identity: new CodexProviderIdentity("codex", "user@example.com", null, "pro"));

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits: null, sourceLabel: "oauth", now: Now);
        var model = data.Models[0];

        Assert.Equal(
            "codex:user@example.com:Codex Spark 5-hour",
            QuotaIdentity.DisplayId(model.Provider, model.AccountName, model.ModelName));
        Assert.Equal(
            "codex:user@example.com:codex spark 5-hour",
            QuotaIdentity.Key(model.Provider, model.AccountName, model.ModelName));
    }

    [Fact]
    public void MapsCreditsAsExtraModel()
    {
        var snapshot = MakeSnapshot();
        var credits = new CodexCreditsSnapshot(Remaining: 1234, UpdatedAt: Now);

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits, sourceLabel: "oauth", now: Now);

        var model = Assert.Single(data.Models);
        Assert.Equal("Credits", model.ModelName);
        Assert.Equal(1234, model.CurrentIntervalRemaining);
        Assert.Equal(1000, model.CurrentIntervalTotal);
        Assert.Equal("1K tokens", model.ProgressBarRightText);
        Assert.Equal(100, model.ProgressBarPercentOverride);
    }

    [Fact]
    public void MapsAllSectionsTogether()
    {
        var primary = new CodexRateWindow(35, 300, new DateTimeOffset(2023, 11, 14, 22, 13, 20, TimeSpan.Zero), null);
        var secondary = new CodexRateWindow(0, 7 * 24 * 60, new DateTimeOffset(2023, 11, 14, 22, 50, 0, TimeSpan.Zero), null);
        var extra = new CodexNamedRateWindow(
            "spark",
            "GPT-5.3-Codex-Spark",
            new CodexRateWindow(60, 60, new DateTimeOffset(2023, 11, 14, 22, 21, 40, TimeSpan.Zero), null));
        var credits = new CodexCreditsSnapshot(Remaining: 500, UpdatedAt: Now);
        var snapshot = MakeSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: new[] { extra },
            identity: new CodexProviderIdentity("codex", "user@example.com", null, "pro"));

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits, sourceLabel: "oauth", now: Now);

        Assert.Equal(4, data.Models.Count);
        Assert.Equal("5h", data.Models[0].ModelName);
        Assert.Equal("Weekly", data.Models[1].ModelName);
        Assert.Equal("GPT-5.3-Codex-Spark", data.Models[2].ModelName);
        Assert.Equal("Credits", data.Models[3].ModelName);
        Assert.Equal("user@example.com", data.Models[0].AccountName);
        // 5h 65 / Weekly 100 / Spark 40 有余量，Credits 500 也有 → remains 4。
        Assert.Equal(4, data.Remains);
        Assert.Equal(4, data.Total);
    }

    [Fact]
    public void EmptySnapshotProducesNotConfiguredPlaceholder()
    {
        var snapshot = MakeSnapshot();

        var data = CodexUsageDataMapper.MapToUsageData(snapshot, credits: null, sourceLabel: "oauth", now: Now);

        var model = Assert.Single(data.Models);
        Assert.Contains(
            "Codex not configured",
            model.DetailText,
            StringComparison.Ordinal);
        Assert.Equal(1, data.Total);
        Assert.Equal(0, data.Remains);
    }

    private static CodexUsageSnapshot MakeSnapshot(
        CodexRateWindow? primary = null,
        CodexRateWindow? secondary = null,
        IReadOnlyList<CodexNamedRateWindow>? extraRateWindows = null,
        CodexProviderIdentity? identity = null) =>
        new(
            Primary: primary,
            Secondary: secondary,
            Tertiary: null,
            ExtraRateWindows: extraRateWindows,
            ProviderCost: null,
            UpdatedAt: Now,
            Identity: identity,
            DataConfidence: CodexDataConfidence.Exact);
}
