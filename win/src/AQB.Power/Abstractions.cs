namespace AQB.Power;

/// <summary>
/// OS-level "keep awake" grant held while AI tasks run (power.md §1 / §4.1).
/// Implementations keep ES_SYSTEM_REQUIRED while held and add
/// ES_DISPLAY_REQUIRED (which also blocks the idle screensaver) when requested.
/// </summary>
public interface IPowerRequest : IDisposable
{
    bool IsHolding { get; }

    /// <summary>Acquires (or keeps) the system-required grant, plus display-required when <paramref name="keepDisplayAwake"/>.</summary>
    void Acquire(bool keepDisplayAwake);

    /// <summary>Adjusts only the display-required part of an already held grant (idempotent).</summary>
    void SetDisplayRequired(bool required);

    /// <summary>Fully releases the grant (system + display).</summary>
    void Release();
}

/// <summary>Battery/AC readings used by the low-battery safety net.</summary>
public interface IPowerState
{
    PowerStatusSnapshot Read();
}

/// <summary>
/// <paramref name="BatteryPercent"/> is null when unreadable; following the macOS
/// policy, unreadable percentages are treated as 0 by the low-battery rule, but the
/// rule only fires when a battery is known to exist and the machine is off AC.
/// </summary>
public sealed record PowerStatusSnapshot(int? BatteryPercent, bool HasBattery, bool OnAcPower);

/// <summary>Injectable clock; tests advance time manually instead of sleeping.</summary>
public interface IClock
{
    DateTimeOffset UtcNow { get; }
}

public sealed class SystemClock : IClock
{
    public static readonly SystemClock Instance = new();

    private SystemClock()
    {
    }

    public DateTimeOffset UtcNow => DateTimeOffset.UtcNow;
}
