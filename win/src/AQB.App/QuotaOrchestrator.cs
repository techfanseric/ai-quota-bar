using AQB.Core;
using AQB.Settings;

namespace AQB.App;

/// <summary>Adapter seam between the tray host and each provider library.</summary>
public interface IProviderAdapter
{
    ProviderKind Kind { get; }

    bool IsConfigured { get; }

    Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Coordinates periodic quota refresh across providers (parallel fetch, failures keep the
/// previous snapshot, matching macOS semantics) and exposes the merged state for UI/dashboard.
/// </summary>
public sealed class QuotaOrchestrator : IDisposable
{
    private readonly AppSettings _settings;
    private readonly IEnumerable<IProviderAdapter> _adapters;
    private readonly Dictionary<ProviderKind, ProviderSnapshot> _latest = new();
    private readonly object _gate = new();
    private readonly CancellationTokenSource _cts = new();
    private Task? _loop;
    private int _inFlight;

    public event Action? SnapshotsChanged;

    public QuotaOrchestrator(AppSettings settings, IEnumerable<IProviderAdapter> adapters)
    {
        _settings = settings;
        _adapters = adapters.ToArray();
    }

    public IReadOnlyDictionary<ProviderKind, ProviderSnapshot> Latest
    {
        get
        {
            lock (_gate)
            {
                return new Dictionary<ProviderKind, ProviderSnapshot>(_latest);
            }
        }
    }

    public void Start()
    {
        _ = RefreshAsync(_cts.Token);
        _loop = Task.Run(() => LoopAsync(_cts.Token));
    }

    public bool IsRefreshing => Volatile.Read(ref _inFlight) > 0;

    public async Task RefreshAsync(CancellationToken cancellationToken)
    {
        if (Interlocked.Exchange(ref _inFlight, 1) == 1)
        {
            return;
        }

        try
        {
            var paused = _settings.PausedUsageProviders.ToHashSet(StringComparer.OrdinalIgnoreCase);
            var fetches = _adapters
                .Where(a => !paused.Contains(a.Kind.WireName()))
                .Select(async a =>
                {
                    try
                    {
                        if (!a.IsConfigured)
                        {
                            return new ProviderSnapshot
                            {
                                Kind = a.Kind,
                                Status = ProviderStatus.Offline,
                                Error = "Not configured",
                                LastUpdatedUtc = DateTimeOffset.UtcNow,
                            };
                        }

                        var snapshot = await a.FetchAsync(cancellationToken);
                        return snapshot;
                    }
                    catch (OperationCanceledException)
                    {
                        throw;
                    }
                    catch (Exception e)
                    {
                        return new ProviderSnapshot
                        {
                            Kind = a.Kind,
                            Status = ProviderStatus.Failed,
                            Error = e.Message,
                            LastUpdatedUtc = DateTimeOffset.UtcNow,
                        };
                    }
                });
            var results = await Task.WhenAll(fetches);
            lock (_gate)
            {
                foreach (var snapshot in results)
                {
                    _latest[snapshot.Kind] = snapshot;
                }
            }

            SnapshotsChanged?.Invoke();
        }
        finally
        {
            Volatile.Write(ref _inFlight, 0);
        }
    }

    private async Task LoopAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Max(30, _settings.UsageRefreshIntervalSeconds)));
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await timer.WaitForNextTickAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            try
            {
                await RefreshAsync(cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        try
        {
            _loop?.Wait(TimeSpan.FromSeconds(3));
        }
        catch (AggregateException)
        {
        }

        _cts.Dispose();
    }
}
