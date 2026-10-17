using System.Net.WebSockets;
using System.Text;

namespace AQB.Clash;

/// <summary>Text-frame oriented WebSocket transport abstraction (test fakes plug in here).</summary>
public interface ClashConnectionTransport : IDisposable
{
    Task ConnectAsync(Uri uri, IReadOnlyDictionary<string, string> requestHeaders, CancellationToken cancellationToken);

    /// <summary>Next UTF-8 frame, or null when the stream ended.</summary>
    Task<string?> ReceiveAsync(CancellationToken cancellationToken);

    Task CloseAsync(CancellationToken cancellationToken);
}

/// <summary>ClientWebSocket based transport; handles text and binary frames.</summary>
public sealed class ClientWebSocketTransport : ClashConnectionTransport
{
    private readonly ClientWebSocket _webSocket = new();
    private readonly byte[] _buffer = new byte[64 * 1024];

    public Task ConnectAsync(
        Uri uri,
        IReadOnlyDictionary<string, string> requestHeaders,
        CancellationToken cancellationToken)
    {
        _webSocket.Options.UseDefaultCredentials = false;
        _webSocket.Options.Proxy = null;
        _webSocket.Options.SetRequestHeader("User-Agent", ClashClient.UserAgent);
        foreach (var (key, value) in requestHeaders)
        {
            _webSocket.Options.SetRequestHeader(key, value);
        }

        return _webSocket.ConnectAsync(uri, cancellationToken);
    }

    public async Task<string?> ReceiveAsync(CancellationToken cancellationToken)
    {
        using var message = new MemoryStream();
        while (true)
        {
            var result = await _webSocket
                .ReceiveAsync(new ArraySegment<byte>(_buffer), cancellationToken)
                .ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return null;
            }

            message.Write(_buffer, 0, result.Count);
            if (result.EndOfMessage)
            {
                return Encoding.UTF8.GetString(message.ToArray());
            }
        }
    }

    public async Task CloseAsync(CancellationToken cancellationToken)
    {
        if (_webSocket.State is WebSocketState.Open or WebSocketState.CloseReceived)
        {
            await _webSocket
                .CloseAsync(WebSocketCloseStatus.NormalClosure, "client stopping", cancellationToken)
                .ConfigureAwait(false);
        }
    }

    public void Dispose() => _webSocket.Dispose();
}

/// <summary>Snapshot pushed on every frame: filtered OpenAI connections, rates and minute history.</summary>
public sealed class ConnectionSnapshot
{
    public required DateTimeOffset ObservedAt { get; init; }

    public int OpenAiCount => Connections.Count;

    public double UploadBps { get; init; }

    public double DownloadBps { get; init; }

    public IReadOnlyList<ActiveConnection> Connections { get; init; } = Array.Empty<ActiveConnection>();

    public IReadOnlyList<ConnectionHistorySample> MinuteHistory { get; init; } = Array.Empty<ConnectionHistorySample>();
}

/// <summary>
/// Read-only OpenAI connection monitor. Subscribes to WS /connections?interval=… with two
/// tiers: live (1s frames) while owners are attached, background (60s frames) otherwise.
/// Multiple live owners are reference counted; tier switches restart the stream.
/// </summary>
public sealed class ClashConnectionMonitor : IDisposable
{
    public const int LiveIntervalMilliseconds = 1_000;

    public const int BackgroundIntervalMilliseconds = 60_000;

    public const int MinimumIntervalMilliseconds = 250;

    private static readonly TimeSpan LiveRetryDelay = TimeSpan.FromSeconds(3);

    private static readonly TimeSpan BackgroundRetryDelay = TimeSpan.FromSeconds(60);

    private readonly ClashEndpoint? _fixedEndpoint;
    private readonly Func<ClashEndpoint?> _endpointFinder;
    private readonly Func<ClashEndpoint, ClashClient> _clientFactory;
    private readonly ClashConnectionHistoryStore _historyStore;
    private readonly Func<ClashConnectionTransport> _transportFactory;
    private readonly Func<DateTimeOffset> _clock;

    private readonly HashSet<string> _liveOwners = new(StringComparer.Ordinal);
    private readonly object _gate = new();

    private CancellationTokenSource? _cancellation;
    private Task? _monitorTask;
    private int _generation;
    private bool _backgroundRequested;
    private bool _isLive;

    private ClashConnectionActivityCalculator _calculator = new();
    private List<ConnectionHistorySample> _history = new();

    /// <summary>Raised for every applied frame.</summary>
    public event Action<ConnectionSnapshot>? Snapshot;

    /// <summary>Raised with a machine readable reason when the stream drops (a retry follows).</summary>
    public event Action<string>? Unavailable;

    public bool IsLive
    {
        get
        {
            lock (_gate)
            {
                return _isLive;
            }
        }
    }

    public IReadOnlyList<ConnectionHistorySample> History
    {
        get
        {
            lock (_gate)
            {
                return _history.ToArray();
            }
        }
    }

    /// <summary>Completes when the monitoring loop has fully stopped after <see cref="Stop"/> or tier switch.</summary>
    public Task MonitoringTask => Volatile.Read(ref _monitorTask) ?? Task.CompletedTask;

    public ClashConnectionMonitor(
        ClashEndpoint? endpoint = null,
        Func<ClashEndpoint?>? endpointFinder = null,
        ClashConnectionHistoryStore? historyStore = null,
        Func<ClashConnectionTransport>? transportFactory = null,
        Func<ClashEndpoint, ClashClient>? clientFactory = null,
        Func<DateTimeOffset>? clock = null)
    {
        _fixedEndpoint = endpoint;
        _endpointFinder = endpointFinder ?? (() => ClashControllerDiscovery.FindEndpoint());
        _clientFactory = clientFactory ?? (found => new ClashClient(found));
        _historyStore = historyStore ?? new ClashConnectionHistoryStore();
        _transportFactory = transportFactory ?? (() => new ClientWebSocketTransport());
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        lock (_gate)
        {
            _history = _historyStore.Load(_clock());
        }
    }

    /// <summary>Starts (or keeps running) the background tier.</summary>
    public void StartBackground()
    {
        lock (_gate)
        {
            _backgroundRequested = true;
            RestartMonitoringLocked();
        }
    }

    /// <summary>Registers a live owner (1s frames). The first owner switches the tier and restarts the stream.</summary>
    public void StartLive(string owner = "popover")
    {
        lock (_gate)
        {
            var wasLive = _liveOwners.Count > 0;
            _liveOwners.Add(owner);
            if (wasLive)
            {
                return;
            }

            _isLive = true;
            RestartMonitoringLocked();
        }
    }

    /// <summary>Releases a live owner. The last one saves history and falls back to the background tier.</summary>
    public void EndLive(string owner = "popover")
    {
        lock (_gate)
        {
            _liveOwners.Remove(owner);
            if (_liveOwners.Count > 0)
            {
                return;
            }

            if (!_isLive)
            {
                return;
            }

            _isLive = false;
            _historyStore.Save(_history);
            RestartMonitoringLocked();
        }
    }

    /// <summary>Cancels the stream and persists history.</summary>
    public void Stop()
    {
        lock (_gate)
        {
            _backgroundRequested = false;
            _liveOwners.Clear();
            _isLive = false;
            _generation++;
            _cancellation?.Cancel();
            _cancellation = null;
            _historyStore.Save(_history);
        }
    }

    public void Dispose() => Stop();

    private void RestartMonitoringLocked()
    {
        _generation++;
        _calculator = new ClashConnectionActivityCalculator();
        _cancellation?.Cancel();
        _cancellation = new CancellationTokenSource();
        var generation = _generation;
        var token = _cancellation.Token;
        var task = Task.Run(() => MonitorAsync(generation, token), CancellationToken.None);
        Volatile.Write(ref _monitorTask, task);
    }

    private async Task MonitorAsync(int generation, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested
            && IsSameGeneration(generation)
            && ShouldRun())
        {
            try
            {
                var endpoint = ResolveEndpoint();
                if (endpoint is null || !endpoint.IsUsable)
                {
                    throw new ClashApiException(
                        ClashApiException.ControllerUnavailable,
                        0,
                        endpoint?.DisabledReason ?? ClashDiscoveryReasons.ConfigurationNotFound);
                }

                using var client = _clientFactory(endpoint);
                await client.GetVersionAsync(cancellationToken).ConfigureAwait(false);
                ThrowIfStale(generation, cancellationToken);

                using var transport = _transportFactory();
                await transport.ConnectAsync(
                        BuildConnectionsUri(endpoint, IsLive ? LiveIntervalMilliseconds : BackgroundIntervalMilliseconds),
                        BuildHeaders(endpoint),
                        cancellationToken)
                    .ConfigureAwait(false);
                ThrowIfStale(generation, cancellationToken);

                while (true)
                {
                    ThrowIfStale(generation, cancellationToken);
                    var frame = await transport.ReceiveAsync(cancellationToken).ConfigureAwait(false);
                    ThrowIfStale(generation, cancellationToken);
                    if (frame is null)
                    {
                        throw new ClashApiException(
                            ClashApiException.ControllerUnavailable,
                            0,
                            "connection stream ended");
                    }

                    var response = ConnectionsResponse.Parse(frame)
                        ?? throw new ClashApiException(
                            ClashApiException.IncompatibleResponse,
                            0,
                            "unparsable frame");
                    ApplyFrame(response);
                }
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception e) when (e is ClashApiException or HttpRequestException or WebSocketException)
            {
                var reason = e is ClashApiException api ? api.Reason : ClashApiException.ControllerUnavailable;
                Unavailable?.Invoke(reason);
                var delay = IsLive ? LiveRetryDelay : BackgroundRetryDelay;
                try
                {
                    await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }
    }

    private void ApplyFrame(ConnectionsResponse response)
    {
        ConnectionSnapshot snapshot;
        lock (_gate)
        {
            var observedAt = _clock();
            var previousLatest = _history.Count > 0 ? _history[^1].Timestamp : (DateTimeOffset?)null;
            var activity = _calculator.Update(response, observedAt);
            _history = ClashConnectionHistory.Upsert(activity, _history);
            snapshot = new ConnectionSnapshot
            {
                ObservedAt = observedAt,
                UploadBps = activity.UploadBps,
                DownloadBps = activity.DownloadBps,
                Connections = activity.Connections,
                MinuteHistory = _history,
            };

            var latest = _history.Count > 0 ? _history[^1].Timestamp : (DateTimeOffset?)null;
            if (latest != previousLatest)
            {
                _historyStore.Save(_history);
            }
        }

        Snapshot?.Invoke(snapshot);
    }

    private ClashEndpoint? ResolveEndpoint() => _fixedEndpoint ?? _endpointFinder();

    private bool ShouldRun()
    {
        lock (_gate)
        {
            return _isLive || _backgroundRequested;
        }
    }

    private bool IsSameGeneration(int generation)
    {
        lock (_gate)
        {
            return generation == _generation;
        }
    }

    private void ThrowIfStale(int generation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsSameGeneration(generation) || !ShouldRun())
        {
            throw new OperationCanceledException();
        }
    }

    internal static Uri BuildConnectionsUri(ClashEndpoint endpoint, int intervalMilliseconds)
    {
        var clamped = Math.Max(MinimumIntervalMilliseconds, intervalMilliseconds);
        var baseUri = endpoint.BaseUri;
        var scheme = baseUri.Scheme.ToLowerInvariant() switch
        {
            "http" => "ws",
            "https" => "wss",
            "ws" => "ws",
            "wss" => "wss",
            _ => throw new ClashApiException(
                ClashDiscoveryReasons.InvalidControllerAddress,
                0,
                baseUri.Scheme),
        };
        var rawHost = baseUri.Host;
        var host = rawHost.StartsWith('[') || !rawHost.Contains(':')
            ? rawHost
            : "[" + rawHost + "]";
        return new Uri($"{scheme}://{host}:{baseUri.Port}/connections?interval={clamped}");
    }

    private static IReadOnlyDictionary<string, string> BuildHeaders(ClashEndpoint endpoint)
        => endpoint.Secret.Length > 0
            ? new Dictionary<string, string> { ["Authorization"] = "Bearer " + endpoint.Secret }
            : new Dictionary<string, string>();
}
