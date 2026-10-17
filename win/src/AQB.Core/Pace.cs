namespace AQB.Core;

public enum PaceBucket
{
    /// <summary>|delta| &lt;= 2 percent points.</summary>
    OnTrack = 0,

    /// <summary>|delta| &lt;= 6 percent points.</summary>
    Slightly = 1,

    /// <summary>|delta| &lt;= 12 percent points.</summary>
    Notable = 2,

    /// <summary>|delta| &gt; 12 percent points.</summary>
    Far = 3,
}

/// <summary>
/// Reserve/deficit pace of a quota window, matching the macOS algorithm:
/// expected = elapsed/duration * 100, actual = used percent, delta = expected - actual.
/// Positive delta means usage is behind schedule, i.e. reserve remaining quota.
/// </summary>
public sealed class PaceResult
{
    public double ExpectedUsedPercent { get; init; }

    public double ActualUsedPercent { get; init; }

    /// <summary>expected - actual. Positive = reserve (green), negative = deficit (red).</summary>
    public double DeltaPercent { get; init; }

    public double ElapsedRatio { get; init; }

    public PaceBucket Bucket { get; init; }

    /// <summary>True when remaining quota is at or above the expected schedule point.</summary>
    public bool IsReserve => DeltaPercent >= 0;

    public bool IsFarOffSchedule => Bucket == PaceBucket.Far;
}

public static class PaceMath
{
    /// <summary>
    /// Mirrors UsagePace.historical: elapsed==0 with actual&gt;0 is treated as dirty data (null).
    /// The GLM rolling 5h window must never be passed here (caller's responsibility, per macOS rules).
    /// </summary>
    public static PaceResult? Compute(
        DateTimeOffset windowStartUtc,
        DateTimeOffset windowEndUtc,
        DateTimeOffset nowUtc,
        double usedPercent)
    {
        var duration = windowEndUtc - windowStartUtc;
        if (duration <= TimeSpan.Zero)
        {
            return null;
        }

        var elapsed = nowUtc - windowStartUtc;
        if (elapsed <= TimeSpan.Zero && usedPercent > 0)
        {
            return null;
        }

        var ratio = Math.Clamp(elapsed / duration, 0, 1);
        var expected = ratio * 100;
        var delta = expected - usedPercent;
        var magnitude = Math.Abs(delta);
        var bucket = magnitude switch
        {
            <= 2 => PaceBucket.OnTrack,
            <= 6 => PaceBucket.Slightly,
            <= 12 => PaceBucket.Notable,
            _ => PaceBucket.Far,
        };
        return new PaceResult
        {
            ExpectedUsedPercent = expected,
            ActualUsedPercent = usedPercent,
            DeltaPercent = delta,
            ElapsedRatio = ratio,
            Bucket = bucket,
        };
    }

    public static PaceResult? Compute(QuotaWindowSample window, DateTimeOffset nowUtc)
        => Compute(window.WindowStartUtc, window.ResetsAtUtc, nowUtc, window.UsedPercent);
}
