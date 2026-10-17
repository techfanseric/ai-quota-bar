using Xunit;

namespace AQB.Clash.Tests;

public class ClashSwitchHistoryTests
{
    private static readonly DateTimeOffset Base = new(2026, 7, 29, 7, 0, 0, TimeSpan.Zero);

    [Fact]
    public void KeepsOnlyThreeMostRecentSwitches()
    {
        var history = new ClashSwitchHistory();

        for (var i = 1; i <= 4; i++)
        {
            history.Record("AI", "Route " + (i - 1), "Route " + i, delayMs: i * 10, atUtc: Base.AddMinutes(i));
        }

        Assert.Equal(3, history.Records.Count);
        Assert.Equal(new[] { "Route 4", "Route 3", "Route 2" }, history.Records.Select(record => record.ToName));
        Assert.Equal(new[] { "Route 3", "Route 2", "Route 1" }, history.Records.Select(record => record.FromName));
        Assert.All(history.Records, record => Assert.Equal("AI", record.GroupName));
        Assert.Equal(40, history.Records[0].DelayMs);
    }

    [Fact]
    public void DoesNotRecordNoOpSwitch()
    {
        var history = new ClashSwitchHistory();
        history.Record("AI", "A", "B", atUtc: Base);

        history.Record("AI", "B", "B", atUtc: Base.AddMinutes(1));

        Assert.Single(history.Records);
        Assert.Equal("B", history.Records[0].ToName);
    }

    [Fact]
    public void InitialRecordsAreSortedAndTruncated()
    {
        var history = new ClashSwitchHistory(new[]
        {
            new ClashSwitchRecord { GroupName = "G", FromName = "A", ToName = "B", AtUtc = Base },
            new ClashSwitchRecord { GroupName = "G", FromName = "B", ToName = "C", AtUtc = Base.AddMinutes(2) },
            new ClashSwitchRecord { GroupName = "G", FromName = "C", ToName = "D", AtUtc = Base.AddMinutes(4) },
            new ClashSwitchRecord { GroupName = "G", FromName = "D", ToName = "E", AtUtc = Base.AddMinutes(6) },
        });

        Assert.Equal(new[] { "E", "D", "C" }, history.Records.Select(record => record.ToName));
    }

    [Fact]
    public void RecordsExternalChangeWhenSelectionDiffersFromLastTarget()
    {
        var history = new ClashSwitchHistory();
        history.Record("AI", "A", "B", atUtc: Base);

        var recorded = history.TryRecordExternalChange("AI", "C", observedAtUtc: Base.AddMinutes(5));

        Assert.True(recorded);
        Assert.Equal("C", history.Records[0].ToName);
        Assert.Equal("B", history.Records[0].FromName);
    }

    [Fact]
    public void ExternalChangeInsideEchoWindowIsIgnored()
    {
        var history = new ClashSwitchHistory();
        history.Record("AI", "A", "B", atUtc: Base);

        var recorded = history.TryRecordExternalChange("AI", "C", observedAtUtc: Base.AddSeconds(3));

        Assert.False(recorded);
        Assert.Single(history.Records);
    }

    [Fact]
    public void ExternalChangeMatchingLastTargetIsIgnored()
    {
        var history = new ClashSwitchHistory();
        history.Record("AI", "A", "B", atUtc: Base);

        var recorded = history.TryRecordExternalChange("AI", "B", observedAtUtc: Base.AddMinutes(5));

        Assert.False(recorded);
    }

    [Fact]
    public void ExternalChangeWithEmptyHistoryIsIgnored()
    {
        var history = new ClashSwitchHistory();

        Assert.False(history.TryRecordExternalChange("AI", "B", observedAtUtc: Base));
        Assert.Empty(history.Records);
    }
}

public class ClashSwitchTimeFormatTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 17, 15, 0, 0, DateTimeOffset.Now.Offset);

    [Fact]
    public void UsesRelativeTextWithinTheFirstHour()
    {
        Assert.Equal("now", ClashSwitchTimeFormat.Format(Now.AddSeconds(-59), Now));
        Assert.Equal("1m ago", ClashSwitchTimeFormat.Format(Now.AddSeconds(-60), Now));
        Assert.Equal("59m ago", ClashSwitchTimeFormat.Format(Now.AddSeconds(-(59 * 60 + 59)), Now));
    }

    [Fact]
    public void UsesChineseRelativeText()
    {
        Assert.Equal("刚刚", ClashSwitchTimeFormat.Format(Now.AddSeconds(-5), Now, chinese: true));
        Assert.Equal("1 分钟前", ClashSwitchTimeFormat.Format(Now.AddMinutes(-1), Now, chinese: true));
        Assert.Equal("59 分钟前", ClashSwitchTimeFormat.Format(Now.AddSeconds(-(59 * 60 + 59)), Now, chinese: true));
    }

    [Fact]
    public void ShowsClockTimeOnTheSameDay()
    {
        var switchedAt = Now.AddHours(-2);

        var text = ClashSwitchTimeFormat.Format(switchedAt, Now);

        Assert.Equal(switchedAt.LocalDateTime.ToString("HH:mm", System.Globalization.CultureInfo.InvariantCulture), text);
    }

    [Fact]
    public void ShowsMonthDayAndTimeAcrossDays()
    {
        var switchedAt = Now.AddDays(-2);

        var text = ClashSwitchTimeFormat.Format(switchedAt, Now);

        Assert.Equal(
            switchedAt.LocalDateTime.ToString("MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture),
            text);
    }

    [Fact]
    public void FutureTimestampsClampToNow()
    {
        Assert.Equal("now", ClashSwitchTimeFormat.Format(Now.AddSeconds(30), Now));
        Assert.Equal("刚刚", ClashSwitchTimeFormat.Format(Now.AddMinutes(5), Now, chinese: true));
    }
}
