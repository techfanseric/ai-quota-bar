using AQB.Core;
using Xunit;

namespace AQB.Core.Tests;

public class PaceMathTests
{
    private static readonly DateTimeOffset Start = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void OnTrack_WhenDeltaWithin2Points()
    {
        // 5h window, halfway elapsed -> expected 50. actual 50.5 -> delta -0.5
        var pace = PaceMath.Compute(Start, Start.AddHours(5), Start.AddHours(2.5), 50.5);
        Assert.NotNull(pace);
        Assert.Equal(PaceBucket.OnTrack, pace!.Bucket);
        Assert.False(pace.IsReserve);
        Assert.Equal(-0.5, pace.DeltaPercent, 5);
    }

    [Theory]
    [InlineData(2.0, PaceBucket.OnTrack)]
    [InlineData(2.5, PaceBucket.Slightly)]
    [InlineData(6.0, PaceBucket.Slightly)]
    [InlineData(6.5, PaceBucket.Notable)]
    [InlineData(12.0, PaceBucket.Notable)]
    [InlineData(12.5, PaceBucket.Far)]
    public void BucketThresholds(double deltaMagnitude, PaceBucket expected)
    {
        // expected = elapsedRatio*100 = 50 at halfway; choose actual = 50 - deltaMagnitude.
        var pace = PaceMath.Compute(Start, Start.AddHours(5), Start.AddHours(2.5), 50 - deltaMagnitude);
        Assert.Equal(expected, pace!.Bucket);
        Assert.Equal(deltaMagnitude, pace.DeltaPercent, 5);
        Assert.True(pace.IsReserve);
    }

    [Fact]
    public void DirtyDataGuard_ElapsedZeroWithUsage_ReturnsNull()
    {
        Assert.Null(PaceMath.Compute(Start, Start.AddHours(5), Start, 10));
        // No usage yet is fine.
        Assert.NotNull(PaceMath.Compute(Start, Start.AddHours(5), Start, 0));
    }

    [Fact]
    public void ElapsedRatioIsClampedToOne()
    {
        var pace = PaceMath.Compute(Start, Start.AddHours(5), Start.AddHours(50), 90);
        Assert.Equal(1.0, pace!.ElapsedRatio);
        Assert.Equal(10, pace.DeltaPercent, 5);
    }

    [Fact]
    public void ZeroOrNegativeDuration_ReturnsNull()
    {
        Assert.Null(PaceMath.Compute(Start, Start, Start, 10));
        Assert.Null(PaceMath.Compute(Start, Start.AddSeconds(-1), Start, 10));
    }
}
