using System.Globalization;

namespace AQB.Clash;

/// <summary>One observed route switch inside a group (newest records first).</summary>
public sealed record ClashSwitchRecord
{
    public required string GroupName { get; init; }

    public string? FromName { get; init; }

    public required string ToName { get; init; }

    public required DateTimeOffset AtUtc { get; init; }

    /// <summary>Measured delay of the target route when known (e.g. after a speed test).</summary>
    public int? DelayMs { get; init; }
}

/// <summary>
/// Keeps the most recent route switches (capacity 3, newest first). Records own switches and
/// external changes observed through refreshes (current selection differs from the last record's
/// target while outside the echo window).
/// </summary>
public sealed class ClashSwitchHistory
{
    public const int Capacity = 3;

    /// <summary>Default window protecting against re-recording our own switch from a stale frame.</summary>
    public static readonly TimeSpan DefaultEchoWindow = TimeSpan.FromSeconds(10);

    private readonly List<ClashSwitchRecord> _records;

    public ClashSwitchHistory(IEnumerable<ClashSwitchRecord>? initial = null)
    {
        _records = (initial ?? Enumerable.Empty<ClashSwitchRecord>())
            .OrderByDescending(record => record.AtUtc)
            .Take(Capacity)
            .ToList();
    }

    public IReadOnlyList<ClashSwitchRecord> Records => _records;

    /// <summary>Records a switch; "from == to" is a no-op. Returns the current window.</summary>
    public IReadOnlyList<ClashSwitchRecord> Record(
        string groupName,
        string? fromName,
        string toName,
        int? delayMs = null,
        DateTimeOffset? atUtc = null)
    {
        if (fromName == toName)
        {
            return _records;
        }

        var record = new ClashSwitchRecord
        {
            GroupName = groupName,
            FromName = fromName,
            ToName = toName,
            AtUtc = atUtc ?? DateTimeOffset.UtcNow,
            DelayMs = delayMs,
        };
        _records.Insert(0, record);
        while (_records.Count > Capacity)
        {
            _records.RemoveAt(_records.Count - 1);
        }

        return _records;
    }

    /// <summary>
    /// Detects an external change: the controller's current selection differs from the last
    /// record's target and the last record is older than the echo window. Records it when detected.
    /// </summary>
    public bool TryRecordExternalChange(
        string groupName,
        string currentNow,
        DateTimeOffset observedAtUtc,
        TimeSpan? echoWindow = null)
    {
        if (_records.Count == 0)
        {
            return false;
        }

        var last = _records[0];
        if (currentNow == last.ToName)
        {
            return false;
        }

        var window = echoWindow ?? DefaultEchoWindow;
        if (observedAtUtc - last.AtUtc < window)
        {
            return false;
        }

        Record(groupName, last.ToName, currentNow, null, observedAtUtc);
        return true;
    }
}

/// <summary>Relative/absolute time labels for switch history rows.</summary>
public static class ClashSwitchTimeFormat
{
    /// <summary>
    /// "now"/"刚刚" under a minute, "Nm ago"/"N 分钟前" under an hour, same-day shows the local
    /// clock time, older shows "MM-dd HH:mm".
    /// </summary>
    public static string Format(DateTimeOffset switchedAt, DateTimeOffset now, bool chinese = false)
    {
        var elapsedSeconds = Math.Max(0, (now - switchedAt).TotalSeconds);
        if (elapsedSeconds < 60)
        {
            return chinese ? "刚刚" : "now";
        }

        if (elapsedSeconds < 3_600)
        {
            var minutes = Math.Max(1, (int)(elapsedSeconds / 60));
            return chinese ? $"{minutes} 分钟前" : $"{minutes}m ago";
        }

        var localSwitched = switchedAt.LocalDateTime;
        var localNow = now.LocalDateTime;
        if (localSwitched.Date == localNow.Date)
        {
            return localSwitched.ToString("HH:mm", CultureInfo.InvariantCulture);
        }

        return localSwitched.ToString("MM-dd HH:mm", CultureInfo.InvariantCulture);
    }
}
