using System.Text.Json.Serialization;

namespace AQB.Core;

/// <summary>Quota thresholds mirrored from the macOS app: below 25% turns amber, below 10% turns red.</summary>
public static class QuotaThresholds
{
    public const double OrangeRemainingPercent = 25;
    public const double RedRemainingPercent = 10;
}

public enum ProviderStatus
{
    Idle = 0,
    Loading = 1,
    Ok = 2,
    Failed = 3,
    Offline = 4,
    Disabled = 5,
}

public enum QuotaWindowRole
{
    Primary = 0,
    Secondary = 1,
}

/// <summary>A single measured quota window (e.g. 5h or weekly).</summary>
public sealed class QuotaWindowSample
{
    public QuotaWindowRole Role { get; init; }

    /// <summary>Human-facing name, e.g. "5h", "Weekly", "Total usage".</summary>
    public string Name { get; init; } = "";

    /// <summary>Window length in seconds; 0 when unknown (monthly windows derive it from start/end instead).</summary>
    public long WindowSeconds { get; init; }

    /// <summary>Consumed percent of the window (0-100).</summary>
    public double UsedPercent { get; init; }

    public DateTimeOffset ResetsAtUtc { get; init; }

    public DateTimeOffset CapturedAtUtc { get; init; }

    /// <summary>Optional explicit window start; otherwise derived as ResetsAtUtc - WindowSeconds.</summary>
    public DateTimeOffset? StartsAtUtc { get; init; }

    [JsonIgnore]
    public DateTimeOffset WindowStartUtc => StartsAtUtc ?? (WindowSeconds > 0
        ? ResetsAtUtc.AddSeconds(-WindowSeconds)
        : ResetsAtUtc);

    [JsonIgnore]
    public double RemainingPercent => Math.Round(100 - UsedPercent, MidpointRounding.AwayFromZero);

    [JsonIgnore]
    public TimeSpan RemainingTime => ResetsAtUtc - CapturedAtUtc;

    public QuotaWindowSample WithRole(QuotaWindowRole role) => new()
    {
        Role = role,
        Name = Name,
        WindowSeconds = WindowSeconds,
        UsedPercent = UsedPercent,
        ResetsAtUtc = ResetsAtUtc,
        CapturedAtUtc = CapturedAtUtc,
        StartsAtUtc = StartsAtUtc,
    };
}

/// <summary>One account of a provider (Codex supports several; others have one).</summary>
public sealed class ProviderAccountSnapshot
{
    /// <summary>Stable opaque key (e.g. SHA-256 account fingerprint) — never contains the raw email.</summary>
    public string AccountKey { get; init; } = "";

    /// <summary>Display label, typically the account email. May be masked for remote surfaces.</summary>
    public string Label { get; init; } = "";

    public string SourceLabel { get; init; } = "";

    public bool IsCurrent { get; init; }

    public IReadOnlyList<QuotaWindowSample> Windows { get; init; } = Array.Empty<QuotaWindowSample>();

    public string? PlanTitle { get; init; }

    public string? SubscribeEndTimeText { get; init; }
}

public sealed class ProviderSnapshot
{
    public ProviderKind Kind { get; init; }

    public ProviderStatus Status { get; init; }

    public string? Error { get; init; }

    public DateTimeOffset? LastUpdatedUtc { get; init; }

    public IReadOnlyList<ProviderAccountSnapshot> Accounts { get; init; } = Array.Empty<ProviderAccountSnapshot>();

    public string? SubscribeTitle { get; init; }

    public string? SubscribeEndTimeText { get; init; }

    /// <summary>Optional note appended by the fetch pipeline (e.g. "GLM Credits (5h)").</summary>
    public string? DetailText { get; init; }

    public IReadOnlyList<ModelUsageSnapshot> Models { get; init; } = Array.Empty<ModelUsageSnapshot>();
}

/// <summary>Per-model usage breakdown (percent of window consumed by each model).</summary>
public sealed class ModelUsageSnapshot
{
    public string ModelName { get; init; } = "";

    public double UsedPercent { get; init; }

    public double? RemainingPercent { get; init; }
}
