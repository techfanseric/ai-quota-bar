using AQB.Core;
using Xunit;

namespace AQB.Clash.Tests;

public sealed class FakeConnectionTransport : ClashConnectionTransport
{
    private readonly Queue<string> _frames;
    private readonly TaskCompletionSource _drained = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly CancellationTokenSource _closed = new();
    private int _delivered;

    public Uri? ConnectedUri { get; private set; }

    public IReadOnlyDictionary<string, string>? ConnectedHeaders { get; private set; }

    /// <summary>Optional async gate awaited before delivering the frame at the given index.</summary>
    public Func<int, Task>? Gate { get; set; }

    public FakeConnectionTransport(IEnumerable<string> frames) => _frames = new Queue<string>(frames);

    public Task ConnectAsync(Uri uri, IReadOnlyDictionary<string, string> requestHeaders, CancellationToken cancellationToken)
    {
        ConnectedUri = uri;
        ConnectedHeaders = requestHeaders;
        return Task.CompletedTask;
    }

    public async Task<string?> ReceiveAsync(CancellationToken cancellationToken)
    {
        if (_frames.Count > 0)
        {
            if (Gate is not null)
            {
                await Gate(_delivered);
                cancellationToken.ThrowIfCancellationRequested();
            }

            _delivered++;
            return _frames.Dequeue();
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closed.Token);
        await await Task.WhenAny(_drained.Task, Task.Delay(Timeout.Infinite, linked.Token));
        return null;
    }

    public Task CloseAsync(CancellationToken cancellationToken)
    {
        _closed.Cancel();
        return Task.CompletedTask;
    }

    public void Dispose() => _closed.Cancel();
}

public class ClashConnectionMonitorTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.FromUnixTimeSeconds(1_785_307_200);

    private static string Frame(long openaiUpload, long openaiDownload, string startIso) => $$"""
        {
          "downloadTotal": 9000,
          "uploadTotal": 9000,
          "connections": [
            {
              "id": "openai",
              "download": {{openaiDownload}},
              "upload": {{openaiUpload}},
              "chains": ["AI group", "JP 01"],
              "rule": "DomainSuffix",
              "rulePayload": "openai.com",
              "start": "{{startIso}}",
              "metadata": {
                "network": "tcp",
                "destinationIP": "203.0.113.1",
                "host": "api.openai.com",
                "process": "Codex",
                "remoteDestination": "api.openai.com:443",
                "sniffHost": ""
              }
            },
            {
              "id": "other",
              "download": 100,
              "upload": 100,
              "start": "{{startIso}}",
              "metadata": { "host": "example.com" }
            }
          ]
        }
        """;

    [Fact]
    public async Task LiveStreamProducesSnapshotsRatesAndPersistedHistory()
    {
        var tempDir = Path.Combine(Path.GetTempPath(), "aqb-monitor-" + Guid.NewGuid().ToString("N"));
        var store = new ClashConnectionHistoryStore(tempDir);
        var versionHandler = new FakeHttpMessageHandler((request, _)
            => Task.FromResult(FakeHttpMessageHandler.Json(200, "{ \"meta\": true, \"version\": \"v1\" }")));
        var endpoint = new ClashEndpoint
        {
            BaseUrl = "http://127.0.0.1:9097",
            Secret = "test-secret",
            SourceConfigPath = @"C:\fake\config.yaml",
        };
        var startIso = TimeText.FixedIso(T0.AddSeconds(-10));
        var secondFrameGate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var transport = new FakeConnectionTransport(new[]
        {
            Frame(1_000, 2_000, startIso),
            Frame(1_600, 3_000, startIso),
        })
        {
            Gate = index =>
            {
                if (index == 1)
                {
                    return secondFrameGate.Task;
                }

                return Task.CompletedTask;
            },
        };

        var now = T0;
        var monitor = new ClashConnectionMonitor(
            endpoint: endpoint,
            historyStore: store,
            transportFactory: () => transport,
            clientFactory: found => new ClashClient(found, versionHandler),
            clock: () => now);

        var first = new TaskCompletionSource<ConnectionSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource<ConnectionSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var seen = 0;
        monitor.Snapshot += snapshot =>
        {
            if (Interlocked.Increment(ref seen) == 1)
            {
                first.SetResult(snapshot);
            }
            else
            {
                second.SetResult(snapshot);
            }
        };

        try
        {
            monitor.StartLive("popover");
            Assert.True(monitor.IsLive);

            var snapshot1 = await first.Task.WaitAsync(TimeSpan.FromSeconds(10));
            now = T0.AddSeconds(2);
            secondFrameGate.SetResult();
            var snapshot2 = await second.Task.WaitAsync(TimeSpan.FromSeconds(10));

            Assert.Equal(1, snapshot1.OpenAiCount);
            Assert.Equal(0, snapshot1.UploadBps);
            Assert.Equal(0, snapshot1.DownloadBps);
            Assert.Equal("api.openai.com", snapshot1.Connections[0].Host);
            Assert.Equal("Codex", snapshot1.Connections[0].Process);

            Assert.Equal(1, snapshot2.OpenAiCount);
            Assert.Equal(300, snapshot2.UploadBps, 0.001);
            Assert.Equal(500, snapshot2.DownloadBps, 0.001);
            Assert.Equal(10, snapshot1.Connections[0].DurationSeconds, 3);
            Assert.Equal(12, snapshot2.Connections[0].DurationSeconds, 3);

            Assert.Equal(
                "ws://127.0.0.1:9097/connections?interval=1000",
                transport.ConnectedUri!.ToString());
            Assert.Equal("Bearer test-secret", transport.ConnectedHeaders!["Authorization"]);
        }
        finally
        {
            monitor.Stop();
            await monitor.MonitoringTask.WaitAsync(TimeSpan.FromSeconds(10));
        }

        Assert.False(monitor.IsLive);
        var history = store.Load(T0.AddSeconds(2));
        var sample = Assert.Single(history);
        Assert.Equal(12, sample.ConnectionAges[0], 3);
        var persistedText = File.ReadAllText(store.FilePath);
        Assert.Contains("\"version\":1", persistedText);
        Assert.DoesNotContain("openai.com", persistedText);
        Assert.DoesNotContain("Codex", persistedText);
    }

    [Fact]
    public async Task BackgroundAndLiveAreReferenceCounted()
    {
        var endpoint = new ClashEndpoint { BaseUrl = "http://127.0.0.1:9097", SourceConfigPath = "x" };
        var streamRestarts = 0;
        var monitor = new ClashConnectionMonitor(
            endpoint: endpoint,
            historyStore: new ClashConnectionHistoryStore(Path.Combine(Path.GetTempPath(), "aqb-monitor-" + Guid.NewGuid().ToString("N"))),
            transportFactory: () =>
            {
                Interlocked.Increment(ref streamRestarts);
                return new FakeConnectionTransport(Array.Empty<string>());
            },
            clientFactory: found => new ClashClient(found, new FakeHttpMessageHandler((request, _)
                => Task.FromResult(FakeHttpMessageHandler.Json(200, "{ \"version\": \"v1\" }")))));

        static async Task WaitUntil(Func<bool> condition)
        {
            var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(5);
            while (DateTime.UtcNow < deadline)
            {
                if (condition())
                {
                    return;
                }

                await Task.Delay(10);
            }
        }

        try
        {
            monitor.StartBackground();
            Assert.False(monitor.IsLive);
            await WaitUntil(() => Volatile.Read(ref streamRestarts) >= 1);

            monitor.StartLive("popover");
            monitor.StartLive("dashboard");
            Assert.True(monitor.IsLive);
            await WaitUntil(() => Volatile.Read(ref streamRestarts) >= 2);

            monitor.EndLive("popover");
            Assert.True(monitor.IsLive);

            monitor.EndLive("dashboard");
            Assert.False(monitor.IsLive);
            await WaitUntil(() => Volatile.Read(ref streamRestarts) >= 3);
        }
        finally
        {
            monitor.Stop();
        }

        // Tier switches restart the stream exactly three times: background start, first live
        // owner, and the fall back to background. The second owner attach/detach must not
        // restart anything.
        Assert.Equal(3, Volatile.Read(ref streamRestarts));
    }
}
