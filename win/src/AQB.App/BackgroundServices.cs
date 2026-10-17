using AQB.CodexTasks;
using AQB.Core;
using AQB.Dashboard;
using AQB.Power;
using AQB.Settings;
using AQB.Team;
using AQB.Usage;

namespace AQB.App;

/// <summary>
/// Composition root for background loops: task monitoring → sleep protection, local usage
/// scanning, team reporting, and the mobile dashboard server. UI reads <see cref="HostState"/>.
/// </summary>
public sealed class BackgroundServices : IDisposable
{
    private readonly AppSettings _settings;
    private readonly CredentialVault _vault;
    private readonly QuotaOrchestrator _orchestrator;
    private readonly HostState _state = new();
    private readonly CodexTaskMonitor _taskMonitor = new(new HookEventLog(), new CodexRolloutWatcher());
    private readonly SleepProtectionController _sleep = new();
    private readonly LocalUsageService _usage = new();
    private readonly ClosedLidModeController _closedLid = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly HashSet<string> _protectedTaskIds = new(StringComparer.Ordinal);
    private readonly object _gate = new();
    private readonly Dictionary<string, WatchFetchResult> _watchedResults = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, CodexWatchReadCount> _readCounts = new(StringComparer.OrdinalIgnoreCase);
    private MobileDashboardServer? _dashboard;
    private CodexWatchClient? _watchClient;
    private Task? _loop;
    private DateTimeOffset _nextWatchPoll = DateTimeOffset.MinValue;
    private DateTimeOffset _nextUpdateCheck = DateTimeOffset.MinValue;
    private bool _closedLidWarningLogged;
    private string? _currentVersion;

    public BackgroundServices(AppSettings settings, CredentialVault vault, QuotaOrchestrator orchestrator)
    {
        _settings = settings;
        _vault = vault;
        _orchestrator = orchestrator;
        Clash = new ClashHost(settings, _state);
        _currentVersion = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "1.0.0";
        _sleep.StatusChanged += OnProtectionStatusChanged;
    }

    public HostState State => _state;

    public ClashHost Clash { get; }

    public CodexTaskMonitor TaskMonitor => _taskMonitor;

    public SleepProtectionController SleepProtection => _sleep;

    public void Start()
    {
        ApplySettings();
        AppLog.Info($"Sleep protection enabled={_sleep.IsEnabled} (setting={_settings.CodexSleepProtectionEnabled})");
        Clash.Start();
        _taskMonitor.ActiveTasksChanged += OnTasksChanged;
        OnTasksChanged(this, _taskMonitor.ActiveTasks);
        _loop = Task.Run(() => LoopAsync(_cts.Token));
    }

    /// <summary>(Re)applies settings — safe to call after the settings dialog saves.</summary>
    public void ApplySettings()
    {
        if (_settings.CodexSleepProtectionEnabled)
        {
            _sleep.Enable();
        }
        else
        {
            _sleep.Disable();
        }

        _sleep.KeepDisplayAwake = _settings.CodexSleepProtectionKeepDisplayAwake;
        Clash.ApplySettings();
        _watchClient?.Dispose();
        _watchClient = new CodexWatchClient(_vault.GetOrCreateDeviceId(), _settings.CloudflareEndpointUrl);
        RestartDashboard();
    }

    private void OnProtectionStatusChanged(object? sender, ProtectionSnapshot snapshot)
    {
        // Closed-lid follows the sleep hold: rewrite LIDACTION once while tasks are running
        // and restore the original values as soon as the hold ends (Mac helper semantics).
        if (!_settings.CodexSleepProtectionAllowClosedLid)
        {
            _closedLid.Restore();
            return;
        }

        if (snapshot.Status is ProtectionStatus.Active or ProtectionStatus.Grace)
        {
            _closedLid.Acquire();
            if (_closedLid.Status == ClosedLidStatus.RequiresAdministrator && !_closedLidWarningLogged)
            {
                _closedLidWarningLogged = true;
                AppLog.Warn("Closed-lid mode needs administrator rights; run the app elevated once to enable it.");
            }
        }
        else
        {
            if (_closedLid.Restore() && _closedLid.Status == ClosedLidStatus.Restored)
            {
                AppLog.Info("Closed-lid mode restored the previous lid-close action.");
            }
        }
    }

    private void OnTasksChanged(object? sender, IReadOnlyList<CodexTaskInfo> tasks)
    {
        lock (_gate)
        {
            var running = tasks.Where(t => t.State == CodexTaskState.Running).Select(t => "codex:" + t.Id).ToHashSet(StringComparer.Ordinal);
            foreach (var id in _protectedTaskIds.Where(id => !running.Contains(id)))
            {
                AppLog.Info($"Sleep protection: end task {id}");
                try
                {
                    _sleep.EndTask(id, "codex");
                }
                catch (Exception e)
                {
                    AppLog.Error($"EndTask {id} threw: {e}");
                }
            }

            foreach (var id in running.Where(id => !_protectedTaskIds.Contains(id)))
            {
                AppLog.Info($"Sleep protection: begin task {id}");
                try
                {
                    _sleep.BeginTask(id, "codex");
                }
                catch (Exception e)
                {
                    AppLog.Error($"BeginTask {id} threw: {e}");
                }
            }

            _protectedTaskIds.Clear();
            _protectedTaskIds.UnionWith(running);
            _state.CodexTasks = running.Count;
            AppLog.Info($"Tasks changed: total={tasks.Count} running={running.Count} sources=[{string.Join(",", tasks.Select(t => t.Source + ":" + t.State))}]");
        }
    }

    private async Task LoopAsync(CancellationToken cancellationToken)
    {
        // Single 2s tick: PeriodicTimer forbids concurrent waits, so the slow
        // (10-minute) work is derived from a deadline check instead of a second timer.
        using var tick = new PeriodicTimer(TimeSpan.FromSeconds(2));
        var nextUsageScan = DateTimeOffset.MinValue;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await tick.WaitForNextTickAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            try
            {
                UpdateHostState();

                if (DateTimeOffset.UtcNow >= nextUsageScan)
                {
                    nextUsageScan = DateTimeOffset.UtcNow.AddMinutes(10);
                    await RunUsageAndTeamAsync(cancellationToken);
                }

                if (DateTimeOffset.UtcNow >= _nextWatchPoll)
                {
                    _nextWatchPoll = DateTimeOffset.UtcNow.AddMinutes(10);
                    await PollWatchAsync(cancellationToken);
                }

                if (DateTimeOffset.UtcNow >= _nextUpdateCheck)
                {
                    _nextUpdateCheck = DateTimeOffset.UtcNow.AddHours(24);
                    await CheckAppUpdateAsync(cancellationToken);
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception e)
            {
                // One bad tick must never kill the loop.
                AppLog.Warn("Background loop tick failed: " + e.Message);
            }
        }
    }

    private void UpdateHostState()
    {
        var snapshot = _sleep.Snapshot;
        if (snapshot.StatusText != _lastProtectionText)
        {
            _lastProtectionText = snapshot.StatusText;
            AppLog.Info($"Protection snapshot: {snapshot.StatusText}/{snapshot.ActiveTaskCount}");
        }

        _state.Protection = (snapshot.StatusText, Math.Min(snapshot.ActiveTaskCount, 99), string.Join(",", snapshot.ActiveProviders));
        _state.DashboardPort = _dashboard?.BoundPort ?? 0;
        _state.DashboardRunning = _dashboard is not null;
    }

    private string? _lastProtectionText;

    /// <summary>Publishes the ticked shared accounts and refreshes watched rows (every 10 minutes).</summary>
    private async Task PollWatchAsync(CancellationToken cancellationToken)
    {
        var client = _watchClient;
        if (client is null)
        {
            return;
        }

        await PublishWatchAsync(client, cancellationToken);
        await FetchWatchedAsync(client, cancellationToken);
    }

    private async Task PublishWatchAsync(CodexWatchClient client, CancellationToken cancellationToken)
    {
        var snapshots = new List<CodexWatchAccountSnapshot>();
        if (_settings.CodexWatchSharingEnabled)
        {
            var shared = _settings.CodexWatchSharedEmails
                .Select(WatchAccount.Normalize)
                .Where(WatchAccount.IsValidAccountName)
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (_orchestrator.Latest.TryGetValue(ProviderKind.Codex, out var codex) && codex.Status == ProviderStatus.Ok)
            {
                // Mac rule: never publish while local Codex data is missing, so a transient
                // outage cannot wipe sharing (full-replace semantics).
                foreach (var account in codex.Accounts)
                {
                    if (!WatchAccount.IsValidAccountName(account.Label) || !shared.Contains(WatchAccount.Normalize(account.Label)))
                    {
                        continue;
                    }

                    snapshots.Add(new CodexWatchAccountSnapshot(
                        WatchAccount.Normalize(account.Label),
                        account.PlanTitle,
                        account.Windows.Select(window => new CodexWatchWindow(
                            window.Name,
                            (int)Math.Clamp(window.RemainingPercent, 0, 100),
                            window.ResetsAtUtc > DateTimeOffset.MinValue ? window.ResetsAtUtc : null,
                            window.CapturedAtUtc,
                            window.WindowStartUtc)).ToList()));
                }
            }
            else
            {
                return;
            }
        }

        try
        {
            var published = await client.PublishAsync(snapshots, cancellationToken);
            if (!published && snapshots.Count > 0)
            {
                AppLog.Warn("CodexWatch publish failed; sharing state unchanged on the server.");
            }

            if (_settings.CodexWatchSharingEnabled && snapshots.Count > 0)
            {
                var counts = await client.FetchReadCountsAsync(snapshots.Select(s => s.Account).ToList(), cancellationToken);
                foreach (var (email, count) in counts)
                {
                    _readCounts[email] = count;
                }
            }
        }
        catch (Exception e)
        {
            AppLog.Warn("CodexWatch publish failed: " + e.Message);
        }
    }

    private async Task FetchWatchedAsync(CodexWatchClient client, CancellationToken cancellationToken)
    {
        var emails = _settings.CodexWatchWatchedEmails
            .Where(WatchAccount.IsValidAccountName)
            .Select(WatchAccount.Normalize)
            .Distinct()
            .ToList();
        if (emails.Count == 0)
        {
            _state.WatchedRows = Array.Empty<WatchedRowView>();
            return;
        }

        foreach (var email in emails)
        {
            var result = await client.FetchAsync(email, cancellationToken);
            _watchedResults[email] = result;
        }

        var rows = new List<WatchedRowView>();
        foreach (var email in emails)
        {
            if (!_watchedResults.TryGetValue(email, out var result))
            {
                continue;
            }

            _readCounts.TryGetValue(email, out var readCount);
            switch (result.Status)
            {
                case WatchFetchStatus.Available:
                {
                    var snapshot = result.Snapshot!;
                    var window = snapshot.Windows.FirstOrDefault();
                    rows.Add(new WatchedRowView(
                        email,
                        "available",
                        window?.RemainingPercent,
                        window?.Name,
                        window?.ResetsAt is { } reset ? TimeText.FormatRemaining(reset - DateTimeOffset.UtcNow) + " left" : null,
                        readCount?.ReadCount ?? 0));
                    break;
                }

                case WatchFetchStatus.Stale:
                    rows.Add(new WatchedRowView(email, "stale", null, null, null, readCount?.ReadCount ?? 0));
                    break;

                case WatchFetchStatus.NotShared:
                    rows.Add(new WatchedRowView(email, "not shared", null, null, null, readCount?.ReadCount ?? 0));
                    break;

                default:
                    rows.Add(new WatchedRowView(email, "unreachable", null, null, null, readCount?.ReadCount ?? 0));
                    break;
            }
        }

        _state.WatchedRows = rows;
        AppLog.Info($"CodexWatch poll: {rows.Count(r => r.StatusText == "available")}/{rows.Count} watched available; sharing={(_settings.CodexWatchSharingEnabled ? "on" : "off")}.");
    }

    private async Task CheckAppUpdateAsync(CancellationToken cancellationToken)
    {
        if (!_settings.AppUpdateCheckEnabled)
        {
            return;
        }

        try
        {
            using var client = new AppUpdateClient(_settings.CloudflareEndpointUrl);
            var info = await client.CheckAsync(cancellationToken);
            _settings.LastAppUpdateCheckAt = TimeText.FixedIso(DateTimeOffset.UtcNow);
            if (info is null || !AppUpdateClient.IsNewer(info.Version, _currentVersion ?? "0.0.0"))
            {
                return;
            }

            _state.UpdateInfo = new AppUpdateBannerView(info.Version, info.ReleaseUrl);
            if (!string.Equals(_settings.LastNotifiedUpdateVersion, info.Version, StringComparison.Ordinal))
            {
                _settings.LastNotifiedUpdateVersion = info.Version;
                _settings.Save();
                AppLog.Info($"Update available: {info.Version} ({info.ReleaseUrl})");
            }
        }
        catch (Exception e)
        {
            AppLog.Warn("App update check failed: " + e.Message);
        }
    }

    private async Task RunUsageAndTeamAsync(CancellationToken cancellationToken)
    {
        try
        {
            var scan = _usage.Scan();
            AppLog.Info($"Usage scan: {scan.FilesParsed} files parsed, {scan.Summary.TotalTokens} tokens, cache hit rate {scan.Summary.WeightedCacheHitRate:P1}.");
            await ReportToTeamAsync(scan, cancellationToken);
        }
        catch (Exception e)
        {
            AppLog.Warn("Usage scan failed: " + e.Message);
        }
    }

    private async Task ReportToTeamAsync(LocalUsageScanResult scan, CancellationToken cancellationToken)
    {
        if (!_settings.CloudSyncEnabled || !_settings.LocalUsageReporting)
        {
            return;
        }

        var credentials = TeamCredentialsCodec.Decode(_vault.Get("team.credentials") ?? "");
        if (credentials is null)
        {
            return;
        }

        try
        {
            var deviceId = _vault.GetOrCreateDeviceId();
            using var client = new TeamClient(_settings.CloudflareEndpointUrl, deviceId);
            var events = _usage.LoadEvents()
                .Where(e => e.Binding is null && e.Delivery is null)
                .Select(e => new UsageEvent
                {
                    Id = e.Id,
                    OccurredAt = e.OccurredAt,
                    Model = e.Model,
                    Tokens = new UsageEventTokens
                    {
                        Input = e.Tokens.Input,
                        Cached = e.Tokens.Cached,
                        CacheWrite = e.Tokens.CacheWrite,
                        Output = e.Tokens.Output,
                        Reasoning = e.Tokens.Reasoning,
                    },
                    Quality = e.Quality == "exact" ? "exact" : "estimated",
                })
                .Take(200)
                .ToList();
            if (events.Count > 0)
            {
                var result = await client.BatchReportAsync(credentials, events, cancellationToken);
                AppLog.Info($"Team report: {result.Accepted.Count} accepted, {result.Rejected.Count} rejected.");
            }

            await UploadQuotaSamplesAsync(client, credentials, cancellationToken);
        }
        catch (TeamApiException e)
        {
            AppLog.Warn($"Team report failed: {e.Message}");
        }
        catch (Exception e)
        {
            AppLog.Warn("Team report failed: " + e.Message);
        }
    }

    private async Task UploadQuotaSamplesAsync(TeamClient client, TeamCredentials credentials, CancellationToken cancellationToken)
    {
        var upload = new QuotaSampleUpload { DeviceId = credentials.DeviceId };
        foreach (var snapshot in _orchestrator.Latest.Values)
        {
            if (snapshot.Status != ProviderStatus.Ok)
            {
                continue;
            }

            foreach (var account in snapshot.Accounts)
            {
                foreach (var window in account.Windows)
                {
                    upload.Models.Add(new QuotaSampleModel
                    {
                        Provider = snapshot.Kind.WireName(),
                        AccountName = account.Label,
                        ModelId = window.Name,
                        ModelName = window.Name,
                        CurrentIntervalRemainingPercent = (int)Math.Clamp(window.RemainingPercent, 0, 100),
                        ResetEndTime = window.ResetsAtUtc > DateTimeOffset.MinValue ? TimeText.FixedIso(window.ResetsAtUtc) : null,
                    });
                }
            }
        }

        if (upload.Models.Count > 0)
        {
            await client.UploadQuotaSamplesAsync(credentials, upload, cancellationToken);
        }
    }

    private void RestartDashboard()
    {
        _dashboard?.Dispose();
        _dashboard = null;
        if (!_settings.MobileDashboardEnabled)
        {
            return;
        }

        var token = _vault.Get("mobileDashboard.accessToken");
        if (string.IsNullOrEmpty(token))
        {
            token = Convert.ToBase64String(Guid.NewGuid().ToByteArray()).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                + Convert.ToBase64String(Guid.NewGuid().ToByteArray()).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            _vault.Set("mobileDashboard.accessToken", token);
            _vault.Save();
        }

        try
        {
            _dashboard = new MobileDashboardServer(
                _settings.MobileDashboardPort,
                token,
                BuildDashboardSnapshot,
                staticRoot: Path.Combine(AppContext.BaseDirectory, "mobile-dashboard"),
                _settings.MobileDashboardMaskAccountNames);
            _dashboard.Start();
            AppLog.Info($"Mobile dashboard listening on port {_dashboard.BoundPort}.");
        }
        catch (Exception e)
        {
            AppLog.Warn("Mobile dashboard failed to start: " + e.Message);
            _dashboard?.Dispose();
            _dashboard = null;
        }
    }

    /// <summary>Builds the read-only mobile dashboard snapshot from the current app state.</summary>
    public DashboardSnapshot BuildDashboardSnapshot()
    {
        var snapshot = new DashboardSnapshot { GeneratedAt = TimeText.FixedIso(DateTimeOffset.UtcNow) };
        foreach (var (kind, provider) in _orchestrator.Latest)
        {
            if (_settings.FollowRunningApps && !_followVisible.Contains(kind.WireName()))
            {
                continue;
            }

            var section = new DashboardProvider
            {
                Kind = kind.WireName(),
                Status = provider.Status.ToString().ToLowerInvariant(),
                Error = provider.Error,
                SubscribeTitle = provider.SubscribeTitle,
                SubscribeEndTimeText = provider.SubscribeEndTimeText,
            };
            foreach (var account in provider.Accounts)
            {
                var accountView = new DashboardAccount
                {
                    Label = account.Label,
                    IsCurrent = account.IsCurrent,
                    PlanTitle = account.PlanTitle,
                };
                foreach (var window in account.Windows)
                {
                    var pace = PaceMath.Compute(window, DateTimeOffset.UtcNow);
                    accountView.Windows.Add(new DashboardWindow
                    {
                        Name = window.Name,
                        UsedPercent = window.UsedPercent,
                        RemainingPercent = window.RemainingPercent,
                        ResetsAt = window.ResetsAtUtc > DateTimeOffset.MinValue ? TimeText.FixedIso(window.ResetsAtUtc) : "",
                        RemainingTimeText = TimeText.FormatRemaining(window.ResetsAtUtc - DateTimeOffset.UtcNow),
                        PaceDeltaPercent = pace?.DeltaPercent,
                        PaceIsReserve = pace?.IsReserve ?? true,
                    });
                }

                section.Accounts.Add(accountView);
            }

            snapshot.Providers.Add(section);
        }

        snapshot.ActiveTasks = new DashboardTaskSummary
        {
            Codex = _state.CodexTasks,
            Kimi = _state.KimiTasks,
            Glm = _state.GlmTasks,
            MiniMax = _state.MiniMaxTasks,
            ActiveProviders = _state.Protection.Providers.Split(',', StringSplitOptions.RemoveEmptyEntries).ToList(),
        };
        snapshot.Protection = new DashboardProtection
        {
            Status = _state.Protection.Status,
            KeepDisplayAwake = _settings.CodexSleepProtectionKeepDisplayAwake,
            ActiveTaskCount = _state.Protection.Tasks,
        };
        var (group, selected, delayMs) = _state.Route;
        snapshot.Route = new DashboardRoute { Group = group, Selected = selected, DelayMs = delayMs };
        var (count, up, down) = _state.Connection;
        snapshot.Connection = new DashboardConnection { OpenAiConnectionCount = count, UploadBps = up, DownloadBps = down };
        return snapshot;
    }

    private HashSet<string> _followVisible = new(new[] { "codex", "kimi", "glm", "minimax" }, StringComparer.OrdinalIgnoreCase);

    /// <summary>Called by the tray host when follow-running-apps visibility changes.</summary>
    public void SetFollowVisibility(IReadOnlyCollection<string> visible)
        => _followVisible = new HashSet<string>(visible, StringComparer.OrdinalIgnoreCase);

    public void Dispose()
    {
        _cts.Cancel();
        _taskMonitor.ActiveTasksChanged -= OnTasksChanged;
        _sleep.StatusChanged -= OnProtectionStatusChanged;
        try
        {
            _loop?.Wait(TimeSpan.FromSeconds(3));
        }
        catch (AggregateException)
        {
        }

        Clash.Dispose();
        _taskMonitor.Dispose();
        _sleep.Dispose();
        _closedLid.Dispose();
        _watchClient?.Dispose();
        _dashboard?.Dispose();
        _cts.Dispose();
    }
}
