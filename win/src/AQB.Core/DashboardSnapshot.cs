namespace AQB.Core;

/// <summary>
/// Read-only status snapshot pushed to the mobile dashboard (SSE) — the Windows
/// counterpart of the macOS schemaVersion snapshot. Labels are masked by the server.
/// </summary>
public sealed class DashboardSnapshot
{
    public int SchemaVersion => 2;

    public string GeneratedAt { get; set; } = "";

    public string Product => "AIQuotaBar for Windows";

    public List<DashboardProvider> Providers { get; set; } = new();

    public DashboardTaskSummary? ActiveTasks { get; set; }

    public DashboardProtection? Protection { get; set; }

    public DashboardRoute? Route { get; set; }

    public DashboardConnection? Connection { get; set; }
}

public sealed class DashboardProvider
{
    public string Kind { get; set; } = "";

    public string Status { get; set; } = "";

    public string? Error { get; set; }

    public List<DashboardAccount> Accounts { get; set; } = new();

    public string? SubscribeTitle { get; set; }

    public string? SubscribeEndTimeText { get; set; }
}

public sealed class DashboardAccount
{
    public string Label { get; set; } = "";

    public bool IsCurrent { get; set; }

    public string? PlanTitle { get; set; }

    public List<DashboardWindow> Windows { get; set; } = new();
}

public sealed class DashboardWindow
{
    public string Name { get; set; } = "";

    public double UsedPercent { get; set; }

    public double RemainingPercent { get; set; }

    public string ResetsAt { get; set; } = "";

    public string RemainingTimeText { get; set; } = "";

    public double? PaceDeltaPercent { get; set; }

    public bool PaceIsReserve { get; set; }
}

public sealed class DashboardTaskSummary
{
    public int Codex { get; set; }

    public int Kimi { get; set; }

    public int Glm { get; set; }

    public int MiniMax { get; set; }

    public List<string> ActiveProviders { get; set; } = new();
}

public sealed class DashboardProtection
{
    public string Status { get; set; } = "inactive";

    public bool KeepDisplayAwake { get; set; }

    public int ActiveTaskCount { get; set; }
}

public sealed class DashboardRoute
{
    public string? Group { get; set; }

    public string? Selected { get; set; }

    public int? DelayMs { get; set; }
}

public sealed class DashboardConnection
{
    public int OpenAiConnectionCount { get; set; }

    public double UploadBps { get; set; }

    public double DownloadBps { get; set; }
}
