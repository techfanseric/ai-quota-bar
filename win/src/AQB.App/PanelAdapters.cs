namespace AQB.App;

/// <summary>View-model seam between the Clash UI panels and the AQB.Clash library.</summary>
public sealed class RouteNodeView
{
    public string Name { get; init; } = "";

    public int? DelayMs { get; init; }

    public bool IsSelected { get; init; }

    public string? Badge { get; init; }
}

public sealed class SwitchHistoryView
{
    public string Group { get; init; } = "";

    public string From { get; init; } = "";

    public string To { get; init; } = "";

    public string AgeText { get; init; } = "";
}

public sealed class ConnectionView
{
    public string Host { get; init; } = "";

    public string Protocol { get; init; } = "";

    public string Route { get; init; } = "";

    public double AgeMinutes { get; init; }

    public string SpeedText { get; init; } = "";
}

public interface IClashPanelAdapter
{
    string? GroupName { get; }

    event Action? StateChanged;

    Task<List<RouteNodeView>> GetNodesAsync();

    Task RefreshNodesAsync();

    Task TestGroupAsync();

    Task<bool> SwitchAsync(string nodeName);

    IReadOnlyList<SwitchHistoryView> History { get; }

    void SetFilter(string text, bool useRegex, bool valid);

    bool FilterActive { get; }

    bool AutoRecoveryEnabled { get; set; }

    string? StatusLine { get; }
}

public interface IConnectionViewAdapter
{
    event Action? StateChanged;

    int OpenAiCount { get; }

    double UploadBps { get; }

    double DownloadBps { get; }

    IReadOnlyList<ConnectionView> Connections { get; }

    /// <summary>60 one-minute cells; each value is the max connection age observed in that minute.</summary>
    IReadOnlyList<double?> MinuteAges { get; }

    /// <summary>Raises the sampling rate to 1s while a viewer is open.</summary>
    void SetLive(bool live);
}
