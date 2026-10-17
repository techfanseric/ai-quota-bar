namespace AQB.Power;

public enum ProtectionStatus
{
    Inactive = 0,
    Active = 1,
    Grace = 2,
    Suspended = 3,
    Released = 4,
}

/// <summary>
/// Derived state surfaced to the dashboard and tests (power.md §1.2 / §4.4).
/// <see cref="ActiveTaskCount"/> is capped at 99 and <see cref="ActiveProviders"/>
/// uses the first-appearance order, matching the macOS mobile summary semantics.
/// </summary>
public sealed record ProtectionSnapshot(
    ProtectionStatus Status,
    int ActiveTaskCount,
    bool KeepDisplayAwake,
    bool KeepDisplayAwakeEffective,
    IReadOnlyList<string> ActiveProviders,
    string? SuspendedReason)
{
    /// <summary>Lowercase wire form: inactive | active | grace | suspended | released.</summary>
    public string StatusText => Status switch
    {
        ProtectionStatus.Active => "active",
        ProtectionStatus.Grace => "grace",
        ProtectionStatus.Suspended => "suspended",
        ProtectionStatus.Released => "released",
        _ => "inactive",
    };

    public bool Equals(ProtectionSnapshot? other) =>
        other is not null
        && Status == other.Status
        && ActiveTaskCount == other.ActiveTaskCount
        && KeepDisplayAwake == other.KeepDisplayAwake
        && KeepDisplayAwakeEffective == other.KeepDisplayAwakeEffective
        && SuspendedReason == other.SuspendedReason
        && ActiveProviders.SequenceEqual(other.ActiveProviders);

    public override int GetHashCode() => HashCode.Combine(
        Status,
        ActiveTaskCount,
        KeepDisplayAwake,
        KeepDisplayAwakeEffective,
        SuspendedReason);
}
