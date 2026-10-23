using AQB.Core;

namespace AQB.App;

/// <summary>Mutable bridge between background library loops and the UI (read on the UI thread).</summary>
public sealed class HostState
{
    private readonly object _gate = new();

    private (string? Group, string? Selected, int? DelayMs) _route = (null, null, null);
    private (int Count, double UploadBps, double DownloadBps) _connection = (0, 0, 0);
    private (string Status, int Tasks, string Providers) _protection = ("inactive", 0, "");

    public (string? Group, string? Selected, int? DelayMs) Route
    {
        get { lock (_gate) return _route; }
        set { lock (_gate) _route = value; }
    }

    public (int Count, double UploadBps, double DownloadBps) Connection
    {
        get { lock (_gate) return _connection; }
        set { lock (_gate) _connection = value; }
    }

    public (string Status, int Tasks, string Providers) Protection
    {
        get { lock (_gate) return _protection; }
        set { lock (_gate) _protection = value; }
    }

    public volatile int CodexTasks;

    public volatile int KimiTasks;

    public volatile int GlmTasks;

    public volatile int MiniMaxTasks;

    public volatile bool DashboardRunning;

    public volatile int DashboardPort;

    /// <summary>Watched-account rows for the control center (email → status/quota).</summary>
    public volatile IReadOnlyList<WatchedRowView> WatchedRows = Array.Empty<WatchedRowView>();
    public volatile IReadOnlyDictionary<string, AQB.Team.CodexWatchReadCount> WatchReadCounts =
        new Dictionary<string, AQB.Team.CodexWatchReadCount>();

    /// <summary>Newer product release discovered by /v1/app-update (null = none).</summary>
    public volatile AppUpdateBannerView? UpdateInfo;

    /// <summary>Rolling quota history feeding the control-center sparklines.</summary>
    public QuotaHistoryStore? History { get; set; }

    /// <summary>Latest local usage summary for the control-center card (null until first scan).</summary>
    public volatile UsageSummaryView? Usage;
}

public sealed record UsageSummaryView(
    string TodayTokensText,
    string TotalTokensText,
    string CacheHitRateText,
    string? CostText);

public sealed record WatchedRowView(
    string Email,
    string StatusText,
    int? RemainingPercent,
    string? WindowName,
    string? ResetsAtText,
    long ReadCount,
    string? QuotaSummary = null,
    DateTimeOffset? PublishedAt = null);

public sealed record AppUpdateBannerView(string Version, string? ReleaseUrl);
