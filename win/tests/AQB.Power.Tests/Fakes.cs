namespace AQB.Power.Tests;

public sealed class MutableClock : IClock
{
    private DateTimeOffset _now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public DateTimeOffset UtcNow => _now;

    public void Advance(TimeSpan span) => _now = _now.Add(span);

    public void Set(DateTimeOffset value) => _now = value;
}

public sealed class FakePowerState : IPowerState
{
    public PowerStatusSnapshot Snapshot { get; set; } = new(BatteryPercent: null, HasBattery: false, OnAcPower: false);

    public PowerStatusSnapshot Read() => Snapshot;
}

public sealed class FakePowerRequest : IPowerRequest
{
    private readonly object _gate = new();

    public List<string> Calls { get; } = new();

    public int ReleaseCount { get; private set; }

    public bool SystemHeld { get; private set; }

    public bool? DisplayRequired { get; private set; }

    public bool IsHolding => SystemHeld;

    public void Acquire(bool keepDisplayAwake)
    {
        lock (_gate)
        {
            Calls.Add("acquire:" + keepDisplayAwake);
            SystemHeld = true;
            DisplayRequired = keepDisplayAwake;
        }
    }

    public void SetDisplayRequired(bool required)
    {
        lock (_gate)
        {
            Calls.Add("display:" + required);
            DisplayRequired = required;
        }
    }

    public void Release()
    {
        lock (_gate)
        {
            Calls.Add("release");
            ReleaseCount++;
            SystemHeld = false;
            DisplayRequired = null;
        }
    }

    public void Dispose()
    {
    }
}
