using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;

using Xunit;

namespace AIQuotaBar.Core.Tests.Quota;

public sealed class UsageDataHeadlineTests
{
    [Fact]
    public void HeadlineRemainingPercentage_UsesLowestCountRatio()
    {
        var usage = Usage(
            Model("5h", remaining: 5_721, total: 12_000),
            Model("Monthly", remaining: 45_602, total: 60_000));

        Assert.Equal(47.675, usage.HeadlineRemainingPercentage(), precision: 3);
    }

    [Fact]
    public void HeadlineRemainingPercentage_UsesDirectPercentWhenCountsAreAbsent()
    {
        var usage = Usage(
            Model("MiniMax-1", remaining: 0, total: 0, directPercent: 98),
            Model("MiniMax-2", remaining: 0, total: 0, directPercent: 100));

        Assert.Equal(98, usage.HeadlineRemainingPercentage());
    }

    [Fact]
    public void HeadlineRemainingPercentage_UsesRemainingProgressOverride()
    {
        var usage = Usage(Model("Credits", remaining: 900, total: 1_000, overridePercent: 42));

        Assert.Equal(42, usage.HeadlineRemainingPercentage());
    }

    [Fact]
    public void HeadlineRemainingPercentage_FallsBackToAvailableModelRatio()
    {
        var usage = new UsageData(
            Provider: UsageProvider.Glm,
            Remains: 1,
            Total: 2,
            Timestamp: DateTimeOffset.UtcNow,
            Models: Array.Empty<ModelUsageData>(),
            SubscribeTitle: null,
            SubscribeEndTime: null,
            GlmResetAllowances: null);

        Assert.Equal(50, usage.HeadlineRemainingPercentage());
    }

    private static UsageData Usage(params ModelUsageData[] models) => new(
        Provider: UsageProvider.Glm,
        Remains: models.Length,
        Total: models.Length,
        Timestamp: DateTimeOffset.UtcNow,
        Models: models,
        SubscribeTitle: null,
        SubscribeEndTime: null,
        GlmResetAllowances: null);

    private static ModelUsageData Model(
        string name,
        int remaining,
        int total,
        int? directPercent = null,
        double? overridePercent = null) => new(
            Provider: UsageProvider.Glm,
            AccountName: null,
            ModelName: name,
            CurrentIntervalTotal: total,
            CurrentIntervalRemaining: remaining,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: 0,
            StartTime: null,
            EndTime: null,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: null,
            DetailText: null,
            CurrentIntervalRemainingPercent: directPercent,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: overridePercent,
            ProgressBarRightText: null,
            SampledAt: null);
}
