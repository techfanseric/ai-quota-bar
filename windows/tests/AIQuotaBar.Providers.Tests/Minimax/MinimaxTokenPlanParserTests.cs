// Swift 来源（断言基准）：.dependencies/codexbar/Tests/CodexBarTests/ProviderQuotaFixtureContractTests.swift:8-41
// —— MiniMax fixture preserves quota windows and plan / keeps windows when reset timestamps are absent。
// fixtures: token-plan-remains-normal.json / token-plan-remains-missing-reset.json。
// 字段语义：docs/api-field-mapping.md —— _usage_count 是剩余数量而非已用；5h=18000s、weekly=604800s。

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Minimax;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Minimax;

public sealed class MinimaxTokenPlanParserTests
{
    // codexbar 契约断言的 macOS 形态移植：primary usedPercent 4（= 100-96 剩余）、windowMinutes 300、
    // resetsAt = end_time；weekly 1 / 10080 / weekly_end_time。usedPercent 属 Core 计算（延后），
    // 此处钉住其输入：剩余百分比、窗口边界与毫秒时间戳。
    [Fact]
    public void TokenPlanRemainsNormal_PreservesQuotaWindowsAndPlan()
    {
        var usage = MinimaxTokenPlanParser.Parse(MinimaxFixtures.Load("token-plan-remains-normal.json"));

        Assert.Equal(UsageProvider.MiniMax, usage.Provider);
        Assert.Equal("Token Plan Plus", usage.SubscribeTitle);
        Assert.Null(usage.SubscribeEndTime); // 载荷无 current_subscribe_end_time_ts

        var model = Assert.Single(usage.Models);
        Assert.Equal("general", model.ModelName);
        // 百分比字符串双形态："96"/"99" → 96/99（0-100 剩余百分比）。
        Assert.Equal(96, model.CurrentIntervalRemainingPercent);
        Assert.Equal(99, model.WeeklyRemainingPercent);
        // count 车道为 0（Plus 计划走百分比模式），原样透传。
        Assert.Equal(0, model.CurrentIntervalTotal);
        Assert.Equal(0, model.CurrentIntervalRemaining);
        Assert.Equal(0, model.WeeklyTotal);
        Assert.Equal(0, model.WeeklyRemaining);
        // 5h 窗口（18000s）：start_time/end_time 毫秒时间戳 → windowMinutes 300 的输入边界。
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_780_279_200_000), model.StartTime);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_780_297_200_000), model.EndTime);
        Assert.Equal(TimeSpan.FromMinutes(300), model.EndTime - model.StartTime);
        // weekly 窗口（604800s = 10080min）。
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_780_243_200_000), model.WeeklyStartTime);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1_780_848_000_000), model.WeeklyEndTime);
        Assert.Equal(TimeSpan.FromMinutes(10_080), model.WeeklyEndTime - model.WeeklyStartTime);
        // remains_time 缺失 → 0；remains 是“仍有额度的模型数”（percent 96 > 0 → 1/1）。
        Assert.Equal(0, model.RemainsTimeMilliseconds);
        Assert.Equal(1, usage.Remains);
        Assert.Equal(1, usage.Total);
    }

    // codexbar 契约断言：无 start_time/end_time 时窗口语义仍在（300/10080 由 weekly/interval 车道表达），
    // resetsAt 为 null；此时百分比是数字类型（非字符串）——双形态都要兼容。
    [Fact]
    public void TokenPlanRemainsMissingReset_KeepsWindowsWhenResetTimestampsAbsent()
    {
        var usage = MinimaxTokenPlanParser.Parse(
            MinimaxFixtures.Load("token-plan-remains-missing-reset.json"));

        Assert.Equal("Token Plan Plus", usage.SubscribeTitle);

        var model = Assert.Single(usage.Models);
        Assert.Equal("general", model.ModelName);
        // 数字百分比双形态：75 / 60。
        Assert.Equal(75, model.CurrentIntervalRemainingPercent);
        Assert.Equal(60, model.WeeklyRemainingPercent);
        // _usage_count = 剩余（不是已用！）：25/40 是剩余量。
        Assert.Equal(100, model.CurrentIntervalTotal);
        Assert.Equal(25, model.CurrentIntervalRemaining);
        Assert.Equal(100, model.WeeklyTotal);
        Assert.Equal(40, model.WeeklyRemaining);
        // 无重置时间戳：起止时间为 null，remainsTime 0（不得伪造重置边界）。
        Assert.Null(model.StartTime);
        Assert.Null(model.EndTime);
        Assert.Null(model.WeeklyStartTime);
        Assert.Null(model.WeeklyEndTime);
        Assert.Equal(0, model.RemainsTimeMilliseconds);
        Assert.Equal(1, usage.Remains);
        Assert.Equal(1, usage.Total);
    }
}
