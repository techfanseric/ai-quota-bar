using AQB.Clash;
using AQB.Settings;

namespace AQB.App;

/// <summary>Owns the Clash endpoint, REST client, connection monitor, auto-recovery and history.</summary>
public sealed class ClashHost : IDisposable
{
    private readonly AppSettings _settings;
    private readonly HostState _state;
    private readonly CancellationTokenSource _cts = new();
    private readonly object _gate = new();
    private Task? _recoveryLoop;
    private ConnectionSnapshot? _latestSnapshot;
    private ClashRouteSnapshot? _latestRoutes;

    public ClashHost(AppSettings settings, HostState state)
    {
        _settings = settings;
        _state = state;

        Endpoint = ClashControllerDiscovery.FindEndpoint();
        if (Endpoint is { IsUsable: true })
        {
            Client = new ClashClient(Endpoint);
        }

        Monitor = new ClashConnectionMonitor(endpointFinder: () => ClashControllerDiscovery.FindEndpoint());
        Monitor.Snapshot += OnSnapshot;
        Recovery = new ClashAutoRecovery();
        Recovery.Outcome += outcome =>
        {
            AppLog.Info($"Clash auto-recovery: {outcome.Outcome} {outcome.Reason}" +
                        (outcome.DidSwitchRoute ? $" ({outcome.FromRoute} → {outcome.ToRoute}, {outcome.DelayMs}ms)" : ""));
        };
    }

    public ClashEndpoint? Endpoint { get; }

    public ClashClient? Client { get; }

    public ClashConnectionMonitor Monitor { get; }

    public ClashAutoRecovery Recovery { get; }

    public ClashSwitchHistory History { get; } = new();

    public ConnectionSnapshot? LatestSnapshot
    {
        get
        {
            lock (_gate)
            {
                return _latestSnapshot;
            }
        }
    }

    public ClashRouteSnapshot? LatestRoutes
    {
        get
        {
            lock (_gate)
            {
                return _latestRoutes;
            }
        }
    }

    public event Action? StateChanged;

    internal void RaiseStateChanged() => StateChanged?.Invoke();

    internal void LatestRoutesUpdate(ClashRouteSnapshot snapshot)
    {
        lock (_gate)
        {
            _latestRoutes = snapshot;
        }
    }

    public void Start()
    {
        if (Endpoint is null)
        {
            AppLog.Info("Clash controller not found; route and connection panels will stay empty.");
            return;
        }

        AppLog.Info($"Clash controller found at {Endpoint.BaseUrl} ({Endpoint.ClientName ?? Endpoint.SourceConfigPath}).");
        Monitor.StartBackground();
        ApplySettings();
        _ = RefreshRoutesAsync();
    }

    public void ApplySettings()
    {
        Recovery.AutoRecoveryEnabled = _settings.ClashAutoRecoveryEnabled;
        Recovery.FilterQuery = _settings.ClashRouteFilterText;
        Recovery.FilterUsesRegex = _settings.ClashAutoRecoveryUseRegex;
        if (_settings.ClashAutoRecoveryEnabled && _recoveryLoop is null)
        {
            _recoveryLoop = Task.Run(() => Recovery.RunAsync(_cts.Token));
        }
    }

    public async Task RefreshRoutesAsync(CancellationToken cancellationToken = default)
    {
        if (Client is null)
        {
            return;
        }

        try
        {
            var proxies = await Client.GetProxiesAsync(cancellationToken);
            var rules = await Client.GetRulesAsync(cancellationToken);
            var groupName = ClashRouteResolver.ResolveGroupName(rules, proxies);
            if (groupName is null || !proxies.TryGetValue(groupName, out var group))
            {
                lock (_gate)
                {
                    _latestRoutes = null;
                }

                _state.Route = (null, null, null);
                StateChanged?.Invoke();
                return;
            }

            var routes = ClashRouteResolver.BuildRoutes(group, proxies);
            var selected = routes.FirstOrDefault(r => r.IsSelected);
            lock (_gate)
            {
                _latestRoutes = new ClashRouteSnapshot
                {
                    GroupName = groupName,
                    SelectedRouteName = group.Now ?? selected?.Name,
                    Routes = routes,
                };
            }

            // Track switches made outside this app (e.g. in Clash's own UI).
            var external = History.TryRecordExternalChange(groupName, group.Now, DateTimeOffset.UtcNow);
            _ = external;
            _state.Route = (groupName, group.Now, selected?.Delay is > 0 ? selected.Delay : null);
            StateChanged?.Invoke();
        }
        catch (Exception e)
        {
            AppLog.Warn("Clash route refresh failed: " + e.Message);
        }
    }

    private void OnSnapshot(ConnectionSnapshot snapshot)
    {
        lock (_gate)
        {
            _latestSnapshot = snapshot;
        }

        _state.Connection = (snapshot.OpenAiCount, snapshot.UploadBps, snapshot.DownloadBps);
        StateChanged?.Invoke();
    }

    public void Dispose()
    {
        _cts.Cancel();
        Monitor.Snapshot -= OnSnapshot;
        Monitor.Dispose();
        Recovery.Dispose();
        try
        {
            _recoveryLoop?.Wait(TimeSpan.FromSeconds(2));
        }
        catch (AggregateException)
        {
        }

        _cts.Dispose();
    }
}

internal static class ClashPanelAdapterResolver
{
    public static IClashPanelAdapter Resolve(TrayHost host) => new Adapter(host);

    private sealed class Adapter(TrayHost host) : IClashPanelAdapter
    {
        private readonly TrayHost _host = host;
        private string _filterText = "";
        private bool _useRegex;

        public string? GroupName => _host.Clash.LatestRoutes?.GroupName;

        public event Action? StateChanged
        {
            add => _host.Clash.StateChanged += value;
            remove => _host.Clash.StateChanged -= value;
        }

        public bool FilterActive => _filterText.Length > 0;

        public bool AutoRecoveryEnabled
        {
            get => _host.Settings.ClashAutoRecoveryEnabled;
            set
            {
                _host.Settings.ClashAutoRecoveryEnabled = value;
                _host.Settings.Save();
                _host.Clash.ApplySettings();
            }
        }

        public string? StatusLine { get; private set; }

        public async Task<List<RouteNodeView>> GetNodesAsync()
        {
            var routes = _host.Clash.LatestRoutes;
            if (routes is null)
            {
                await _host.Clash.RefreshRoutesAsync();
                routes = _host.Clash.LatestRoutes;
            }

            if (routes is null)
            {
                StatusLine = "Clash controller not found";
                return new List<RouteNodeView>();
            }

            var names = routes.Routes.Select(r => r.Name).ToList();
            var views = routes.Routes.Select(r => new RouteNodeView
            {
                Name = r.Name,
                DelayMs = r.Delay is null ? null : r.Delay is 0 ? 0 : r.Delay,
                IsSelected = r.IsSelected,
                Badge = ProtocolBadge.Text(r.Type),
            }).ToList();

            if (_filterText.Length > 0)
            {
                var result = CountryMatcher.FilterNames(names, _filterText, _useRegex);
                StatusLine = result.ErrorMessage is { } error ? $"Filter error: {error}" : null;
                if (result.ErrorMessage is null)
                {
                    var keep = result.Matches.ToHashSet(StringComparer.Ordinal);
                    views = views.Where(v => keep.Contains(v.Name)).ToList();
                }
            }

            var order = routes.Routes.Select(r => r.Name).ToList();
            views = views.OrderBy(v => order.IndexOf(v.Name)).ToList();
            StatusLine ??= $"Group: {routes.GroupName} · {views.Count}/{routes.Routes.Count} routes";
            return views;
        }

        public Task RefreshNodesAsync() => _host.Clash.RefreshRoutesAsync();

        public async Task TestGroupAsync()
        {
            var routes = _host.Clash.LatestRoutes;
            if (routes is null || _host.Clash.Client is null)
            {
                return;
            }

            var delays = await _host.Clash.Client.TestGroupDelayAsync(routes.GroupName);
            var updated = ClashRouteResolver.ApplyDelays(routes.Routes, delays);
            var selected = updated.FirstOrDefault(r => r.IsSelected);
            _host.Clash.LatestRoutesUpdate(new ClashRouteSnapshot
            {
                GroupName = routes.GroupName,
                SelectedRouteName = routes.SelectedRouteName,
                Routes = updated,
            });
            _host.State.Route = (routes.GroupName, routes.SelectedRouteName, selected?.Delay is > 0 ? selected.Delay : null);
            _host.Clash.RaiseStateChanged();
        }

        public async Task<bool> SwitchAsync(string nodeName)
        {
            var routes = _host.Clash.LatestRoutes;
            if (routes is null || _host.Clash.Client is null)
            {
                return false;
            }

            var from = routes.SelectedRouteName;
            try
            {
                await _host.Clash.Client.SelectProxyAsync(routes.GroupName, nodeName);
            }
            catch (ClashApiException e)
            {
                StatusLine = "Switch failed: " + e.Message;
                return false;
            }

            var delay = routes.Routes.FirstOrDefault(r => r.Name == nodeName)?.Delay;
            _host.Clash.History.Record(routes.GroupName, from, nodeName, delay);
            await _host.Clash.RefreshRoutesAsync();
            return true;
        }

        public IReadOnlyList<SwitchHistoryView> History => _host.Clash.History.Records.Select(r => new SwitchHistoryView
        {
            Group = r.GroupName,
            From = r.FromName ?? "-",
            To = r.ToName,
            AgeText = ClashSwitchTimeFormat.Format(r.AtUtc, DateTimeOffset.UtcNow),
        }).ToList();

        public void SetFilter(string text, bool useRegex, bool valid)
        {
            _filterText = text;
            _useRegex = useRegex && valid;
        }
    }
}

internal static class ConnectionViewAdapterResolver
{
    public static IConnectionViewAdapter Resolve(TrayHost host) => new Adapter(host);

    private sealed class Adapter(TrayHost host) : IConnectionViewAdapter
    {
        private readonly TrayHost _host = host;

        public event Action? StateChanged
        {
            add => _host.Clash.StateChanged += value;
            remove => _host.Clash.StateChanged -= value;
        }

        public int OpenAiCount => _host.Clash.LatestSnapshot?.OpenAiCount ?? 0;

        public double UploadBps => _host.Clash.LatestSnapshot?.UploadBps ?? 0;

        public double DownloadBps => _host.Clash.LatestSnapshot?.DownloadBps ?? 0;

        public IReadOnlyList<ConnectionView> Connections => _host.Clash.LatestSnapshot?.Connections.Select(c => new ConnectionView
        {
            Host = c.Host,
            Protocol = c.Network ?? "",
            Route = c.PrimaryChain ?? "",
            AgeMinutes = c.DurationSeconds / 60.0,
            SpeedText = $"↓{FormatBps(c.DownloadBps)} ↑{FormatBps(c.UploadBps)}",
        }).ToList() ?? new List<ConnectionView>();

        public IReadOnlyList<double?> MinuteAges => _host.Clash.LatestSnapshot?.MinuteHistory.Select(s => (double?)s.ConnectionAges.DefaultIfEmpty(0).Max()).ToList()
            ?? new List<double?>();

        public void SetLive(bool live)
        {
            if (live)
            {
                _host.Clash.Monitor.StartLive("connections-panel");
            }
            else
            {
                _host.Clash.Monitor.EndLive("connections-panel");
            }
        }

        private static string FormatBps(double bps) => bps >= 1_000_000
            ? $"{bps / 1_000_000:0.0}MB/s"
            : bps >= 1_000 ? $"{bps / 1_000:0.0}kB/s" : $"{bps:0}B/s";
    }
}
