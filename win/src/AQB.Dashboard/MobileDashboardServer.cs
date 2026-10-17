using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using AQB.Core;

namespace AQB.Dashboard;

/// <summary>
/// Read-only local mobile dashboard (the macOS port-18765 server). Serves the static PWA and
/// pushes status snapshots over SSE; every mutating verb is rejected.
/// </summary>
public sealed class MobileDashboardServer : IDisposable
{
    private const int MaxViewers = 8;

    private HttpListener _listener = new();
    private readonly string _accessToken;
    private readonly Func<DashboardSnapshot>? _snapshotProvider;
    private readonly string _staticRoot;
    private readonly bool _maskLabels;
    private readonly ConcurrentDictionary<Guid, Viewer> _viewers = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly object _gate = new();

    private Task? _acceptLoop;
    private int _port;

    public MobileDashboardServer(
        int port,
        string accessToken,
        Func<DashboardSnapshot>? snapshotProvider = null,
        string? staticRoot = null,
        bool maskLabels = true)
    {
        _port = port;
        _accessToken = accessToken;
        _snapshotProvider = snapshotProvider;
        _staticRoot = staticRoot ?? Path.Combine(AppContext.BaseDirectory, "mobile-dashboard");
        _maskLabels = maskLabels;
    }

    public int BoundPort => _port;

    public bool IsRunning
    {
        get
        {
            lock (_gate)
            {
                return _listener.IsListening;
            }
        }
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_listener.IsListening)
            {
                return;
            }

            // Bind LAN-facing prefixes first; fall back to loopback-only when the OS refuses.
            // A failed Start() poisons the listener, so each attempt uses a fresh instance.
            var attempts = new[]
            {
                new[] { $"http://+:{_port}/" },
                new[] { $"http://*:{_port}/" },
                new[] { $"http://localhost:{_port}/", $"http://127.0.0.1:{_port}/" },
            };
            var bound = false;
            foreach (var prefixes in attempts)
            {
                try
                {
                    foreach (var prefix in prefixes)
                    {
                        _listener.Prefixes.Add(prefix);
                    }

                    _listener.Start();
                    bound = true;
                    break;
                }
                catch (HttpListenerException)
                {
                    // Try the next prefix group with a fresh listener.
                    RecreateListener();
                }
            }

            if (!bound)
            {
                throw new InvalidOperationException($"Could not bind the mobile dashboard on port {_port}.");
            }

            _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        }
    }

    private async Task AcceptLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && _listener.IsListening)
        {
            HttpListenerContext context;
            try
            {
                context = await _listener.GetContextAsync();
            }
            catch (Exception e) when (e is HttpListenerException or ObjectDisposedException)
            {
                return;
            }

            _ = Task.Run(() => HandleAsync(context, cancellationToken), cancellationToken);
        }
    }

    private async Task HandleAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        try
        {
            var request = context.Request;
            var response = context.Response;
            response.Headers["Cache-Control"] = "no-store";
            response.Headers["Content-Security-Policy"] = "default-src 'self'";

            if (!IsPrivatePeer(request.RemoteEndPoint))
            {
                response.StatusCode = 403;
                response.Close();
                return;
            }

            if (request.HttpMethod != "GET" && request.HttpMethod != "HEAD")
            {
                response.StatusCode = 405;
                response.Headers["Allow"] = "GET, HEAD";
                response.Close();
                return;
            }

            var path = request.Url?.AbsolutePath ?? "/";
            switch (path)
            {
                case "/api/v1/health":
                    await WriteJsonAsync(response, """{"status":"ok","schemaVersion":2}""", cancellationToken);
                    return;

                case "/api/v1/events":
                    await HandleEventsAsync(context, cancellationToken);
                    return;

                case "/api/v1/pair/code" when _pairingCode is { } pairing:
                    await WriteJsonAsync(response, JsonSerializer.Serialize(new { code = pairing.Code, expiresAt = TimeText.FixedIso(pairing.ExpiresAtUtc) }, Json.SnakeCase), cancellationToken);
                    return;

                default:
                    await ServeStaticAsync(response, path, cancellationToken);
                    return;
            }
        }
        catch (Exception e) when (e is HttpListenerException or OperationCanceledException)
        {
            // Client vanished mid-response.
        }
    }

    private async Task HandleEventsAsync(HttpListenerContext context, CancellationToken cancellationToken)
    {
        var request = context.Request;
        var response = context.Response;
        var authorization = request.Headers["Authorization"] ?? "";
        if (!TokenMatches(authorization))
        {
            response.StatusCode = 401;
            response.Headers["WWW-Authenticate"] = "Bearer";
            response.Close();
            return;
        }

        var viewer = new Viewer(Guid.NewGuid());
        if (_viewers.Count >= MaxViewers)
        {
            response.StatusCode = 503;
            response.Close();
            return;
        }

        _viewers[viewer.Id] = viewer;
        try
        {
            response.StatusCode = 200;
            response.ContentType = "text/event-stream";
            response.Headers["X-Accel-Buffering"] = "no";
            response.ContentEncoding = Encoding.UTF8;
            var stream = response.OutputStream;
            var lastPayload = "";
            var started = DateTimeOffset.UtcNow;

            while (!cancellationToken.IsCancellationRequested && started + TimeSpan.FromHours(12) > DateTimeOffset.UtcNow)
            {
                var payload = BuildSnapshotJson();
                if (payload != lastPayload || lastPayload.Length == 0)
                {
                    await stream.WriteAsync(Encoding.UTF8.GetBytes($"event: snapshot\ndata: {payload}\n\n"), cancellationToken);
                    await stream.FlushAsync(cancellationToken);
                    lastPayload = payload;
                }
                else
                {
                    await stream.WriteAsync(": keep-alive\n\n"u8.ToArray(), cancellationToken);
                    await stream.FlushAsync(cancellationToken);
                }

                await Task.Delay(2000, cancellationToken);
            }
        }
        catch (Exception e) when (e is HttpListenerException or OperationCanceledException)
        {
        }
        finally
        {
            _viewers.TryRemove(viewer.Id, out _);
            try
            {
                response.Close();
            }
            catch
            {
                // Already closed.
            }
        }
    }

    private string BuildSnapshotJson()
    {
        var snapshot = _snapshotProvider?.Invoke() ?? new DashboardSnapshot { GeneratedAt = TimeText.FixedIso(DateTimeOffset.UtcNow) };
        if (_maskLabels)
        {
            foreach (var provider in snapshot.Providers)
            {
                foreach (var account in provider.Accounts)
                {
                    account.Label = TimeText.MaskLabel(account.Label);
                }
            }
        }

        return JsonSerializer.Serialize(snapshot, Json.SnakeCase);
    }

    private bool TokenMatches(string header)
    {
        const string prefix = "Bearer ";
        if (!header.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var presented = header[prefix.Length..].Trim();
        if (presented.Length != _accessToken.Length)
        {
            return false;
        }

        var mismatch = 0;
        for (var i = 0; i < presented.Length; i++)
        {
            mismatch |= presented[i] ^ _accessToken[i];
        }

        return mismatch == 0;
    }

    private static bool IsPrivatePeer(IPEndPoint? endPoint)
    {
        if (endPoint is null)
        {
            return false;
        }

        var address = endPoint.Address;
        if (address.IsIPv6LinkLocal || Equals(address, IPAddress.IPv6Loopback))
        {
            return true;
        }

        if (IPAddress.IsLoopback(address))
        {
            return true;
        }

        if (address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
        {
            return false;
        }

        var bytes = address.GetAddressBytes();
        return bytes[0] == 10
            || (bytes[0] == 192 && bytes[1] == 168)
            || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31);
    }

    private static readonly Dictionary<string, string> ContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        [".html"] = "text/html; charset=utf-8",
        [".js"] = "text/javascript; charset=utf-8",
        [".css"] = "text/css; charset=utf-8",
        [".json"] = "application/json",
        [".webmanifest"] = "application/manifest+json",
        [".png"] = "image/png",
        [".svg"] = "image/svg+xml",
        [".mp4"] = "video/mp4",
        [".ico"] = "image/x-icon",
    };

    private async Task ServeStaticAsync(HttpListenerResponse response, string path, CancellationToken cancellationToken)
    {
        var relative = path.TrimStart('/');
        if (relative.Length == 0)
        {
            relative = "index.html";
        }

        // Whitelist + path traversal guard.
        if (relative.Contains("..") || relative.Contains('\\'))
        {
            response.StatusCode = 404;
            response.Close();
            return;
        }

        var filePath = Path.GetFullPath(Path.Combine(_staticRoot, relative));
        if (!filePath.StartsWith(_staticRoot, StringComparison.OrdinalIgnoreCase) || !File.Exists(filePath))
        {
            response.StatusCode = 404;
            response.Close();
            return;
        }

        var extension = Path.GetExtension(filePath).ToLowerInvariant();
        if (!ContentTypes.TryGetValue(extension, out var contentType))
        {
            response.StatusCode = 404;
            response.Close();
            return;
        }

        response.StatusCode = 200;
        response.ContentType = contentType;
        await using var file = File.OpenRead(filePath);
        response.ContentLength64 = file.Length;
        await file.CopyToAsync(response.OutputStream, cancellationToken);
        response.Close();
    }

    private static async Task WriteJsonAsync(HttpListenerResponse response, string json, CancellationToken cancellationToken)
    {
        response.StatusCode = 200;
        response.ContentType = "application/json";
        var bytes = Encoding.UTF8.GetBytes(json);
        response.ContentLength64 = bytes.Length;
        await response.OutputStream.WriteAsync(bytes, cancellationToken);
        response.Close();
    }

    private sealed class Viewer(Guid id)
    {
        public Guid Id { get; } = id;
    }

    private readonly (string Code, DateTimeOffset ExpiresAtUtc)? _pairingCode = null;

    /// <summary>Generates an 8-digit pairing code valid for five minutes (optional pairing flow).</summary>
    public static (string Code, DateTimeOffset ExpiresAtUtc) GeneratePairingCode()
    {
        var random = Random.Shared.Next(0, 100_000_000);
        return (random.ToString("D8"), DateTimeOffset.UtcNow.AddMinutes(5));
    }

    private void RecreateListener()
    {
        try
        {
            _listener.Close();
        }
        catch
        {
            // Already closed.
        }

        _listener = new HttpListener();
    }

    public void Dispose()
    {
        _cts.Cancel();
        lock (_gate)
        {
            try
            {
                if (_listener.IsListening)
                {
                    _listener.Stop();
                }

                _listener.Close();
            }
            catch
            {
                // Already torn down.
            }
        }

        try
        {
            _acceptLoop?.Wait(TimeSpan.FromSeconds(2));
        }
        catch (AggregateException)
        {
        }

        _cts.Dispose();
    }
}
