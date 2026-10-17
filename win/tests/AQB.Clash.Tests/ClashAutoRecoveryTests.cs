using System.Net;
using Xunit;

namespace AQB.Clash.Tests;

public class ClashAutoRecoveryTests
{
    private static readonly ClashEndpoint Endpoint = new()
    {
        BaseUrl = "http://127.0.0.1:9097",
        Secret = "test-secret",
        SourceConfigPath = @"C:\fake\config.yaml",
        ClientName = "Clash Verge Rev",
    };

    private const string ProxiesJson = """
        {
          "proxies": {
            "AI": { "name": "AI", "type": "Selector", "now": "US 01",
                    "all": ["US 01", "JP 01", "JP 02", "SG 01"] },
            "US 01": { "name": "US 01", "type": "Trojan",
                       "history": [{ "time": "t", "delay": 300 }] },
            "JP 01": { "name": "JP 01", "type": "Vless",
                       "history": [{ "time": "t", "delay": 999 }] },
            "JP 02": { "name": "JP 02", "type": "Hysteria2",
                       "history": [{ "time": "t", "delay": 888 }] },
            "SG 01": { "name": "SG 01", "type": "Vmess", "history": [] }
          }
        }
        """;

    private const string RulesJson = """
        { "rules": [ { "type": "RuleSet", "payload": "ai", "proxy": "AI" } ] }
        """;

    private const string DelayJson = """
        { "JP 01": 72, "JP 02": 95, "US 01": 140 }
        """;

    /// <summary>Clash API fake: answers the recovery flow's REST calls and records PUTs.</summary>
    private sealed class ClashApiFake
    {
        public List<string> SelectedNodes { get; } = new();

        public FakeHttpMessageHandler CreateHandler() => new((request, _) =>
            Task.FromResult(request.RequestUri!.AbsolutePath switch
            {
                "/version" => FakeHttpMessageHandler.Json(200, "{ \"meta\": true, \"version\": \"test\" }"),
                "/proxies" => FakeHttpMessageHandler.Json(200, ProxiesJson),
                "/rules" => FakeHttpMessageHandler.Json(200, RulesJson),
                "/proxies/AI" when request.Method == HttpMethod.Put => CapturePut(request),
                "/group/AI/delay" => FakeHttpMessageHandler.Json(200, DelayJson),
                _ => FakeHttpMessageHandler.Json(404, "{ \"message\": \"unexpected path\" }"),
            }));

        private HttpResponseMessage CapturePut(HttpRequestMessage request)
        {
            var body = request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();
            SelectedNodes.Add(body);
            return FakeHttpMessageHandler.Empty(204);
        }
    }

    /// <summary>Probe fake: two outcomes per probe round (one per domain), consumed FIFO.</summary>
    private sealed class ProbeFake
    {
        private readonly Queue<bool> _outcomes;

        public ProbeFake(params bool[] rounds)
        {
            _outcomes = new Queue<bool>(rounds.SelectMany(round => new[] { round, round }));
        }

        public FakeHttpMessageHandler CreateHandler() => new((request, _) =>
        {
            if (_outcomes.Count == 0)
            {
                return Task.FromException<HttpResponseMessage>(new HttpRequestException("no scripted outcome"));
            }

            return _outcomes.Dequeue()
                ? Task.FromResult(FakeHttpMessageHandler.Empty(200))
                : Task.FromException<HttpResponseMessage>(new HttpRequestException("probe unreachable"));
        });
    }

    private static ClashAutoRecovery Create(
        ProbeFake probe,
        ClashApiFake api,
        Func<DateTimeOffset>? clock = null,
        string filter = "JP")
        => new(
            endpointFinder: _ => Task.FromResult<ClashEndpoint?>(Endpoint),
            clientFactory: endpoint => new ClashClient(endpoint, api.CreateHandler()),
            probeHandlerFactory: probe.CreateHandler,
            clock: clock ?? (() => DateTimeOffset.UtcNow))
        {
            FilterQuery = filter,
        };

    [Fact]
    public async Task TwoConsecutiveFailuresSwitchAndRecover()
    {
        // Round 1/2 unreachability is fed straight into HandleProbeResultAsync;
        // the scripted queue answers only the post-switch recheck probe.
        var probe = new ProbeFake(true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api);

        var first = await recovery.HandleProbeResultAsync(false);
        Assert.Null(first);
        Assert.Equal(1, recovery.ConsecutiveUnreachableChecks);

        var second = await recovery.HandleProbeResultAsync(false);

        Assert.NotNull(second);
        Assert.True(
            second!.Outcome == ClashRecoveryOutcomeKind.Recovered,
            $"unexpected outcome: {second}");
        Assert.Equal("US 01", second.FromRoute);
        Assert.Equal("JP 01", second.ToRoute);
        Assert.Equal(72, second.DelayMs);
        Assert.True(second.DidSwitchRoute);

        var put = Assert.Single(api.SelectedNodes);
        Assert.Contains("JP 01", put);
    }

    [Fact]
    public async Task RecoversWithoutSwitchWhenAlreadyOnFastestCandidate()
    {
        var probe = new ProbeFake(true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api, filter: "US");

        var result = await recovery.HandleProbeResultAsync(false);
        var second = await recovery.HandleProbeResultAsync(false);

        Assert.Null(result);
        Assert.NotNull(second);
        Assert.Equal("US 01", second.ToRoute);
        Assert.False(second.DidSwitchRoute);
        Assert.Empty(api.SelectedNodes);
    }

    [Fact]
    public async Task AnyReachableRoundResetsTheFailureCounter()
    {
        var probe = new ProbeFake(false, true, false, true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api);

        Assert.Null(await recovery.HandleProbeResultAsync(false));
        Assert.Null(await recovery.HandleProbeResultAsync(true));
        Assert.Equal(0, recovery.ConsecutiveUnreachableChecks);
        Assert.Null(await recovery.HandleProbeResultAsync(false));
        Assert.Equal(1, recovery.ConsecutiveUnreachableChecks);
        Assert.Empty(api.SelectedNodes);
    }

    [Fact]
    public async Task TriesUpToThreeCandidatesThenNeedsAttention()
    {
        // Two failing rounds trigger; every recheck also fails.
        var probe = new ProbeFake(false, false);
        var api = new ClashApiFake();
        var recovery = Create(probe, api);

        Assert.Null(await recovery.HandleProbeResultAsync(false));
        var outcome = await recovery.HandleProbeResultAsync(false);

        Assert.NotNull(outcome);
        Assert.Equal(ClashRecoveryOutcomeKind.NeedsAttention, outcome.Outcome);
        Assert.Equal("recoveryFailed", outcome.Reason);
        // JP 01 and JP 02 are the only usable filtered candidates: two switches attempted.
        Assert.Equal(2, api.SelectedNodes.Count);
    }

    [Fact]
    public async Task SingleOutageIsHandledOnlyOnce()
    {
        var probe = new ProbeFake(true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api);

        Assert.Null(await recovery.HandleProbeResultAsync(false));
        var recovered = await recovery.HandleProbeResultAsync(false);
        var third = await recovery.HandleProbeResultAsync(false);

        Assert.Equal(ClashRecoveryOutcomeKind.Recovered, recovered!.Outcome);
        Assert.Null(third);
        Assert.Single(api.SelectedNodes);
    }

    [Fact]
    public async Task CooldownSuppressesRepeatRecovery()
    {
        var now = DateTimeOffset.UtcNow;
        var probe = new ProbeFake(true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api, clock: () => now);

        await recovery.HandleProbeResultAsync(false);
        var recovered = await recovery.HandleProbeResultAsync(false);
        Assert.True(
            recovered!.Outcome == ClashRecoveryOutcomeKind.Recovered,
            $"unexpected outcome: {recovered}");

        // Reachable round clears the outage flag, then a fresh outage triggers again.
        await recovery.HandleProbeResultAsync(true);
        now += TimeSpan.FromMinutes(1);
        var suppressed = await recovery.HandleProbeResultAsync(false);
        var suppressed2 = await recovery.HandleProbeResultAsync(false);

        Assert.Null(suppressed);
        Assert.NotNull(suppressed2);
        Assert.Equal(ClashRecoveryOutcomeKind.Suppressed, suppressed2.Outcome);
        Assert.Equal("cooldown", suppressed2.Reason);
        Assert.Single(api.SelectedNodes);
    }

    [Fact]
    public async Task CooldownExpiryAllowsAnotherRecovery()
    {
        var now = DateTimeOffset.UtcNow;
        var probe = new ProbeFake(true, true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api, clock: () => now);

        await recovery.HandleProbeResultAsync(false);
        var first = await recovery.HandleProbeResultAsync(false);
        Assert.Equal(ClashRecoveryOutcomeKind.Recovered, first!.Outcome);

        await recovery.HandleProbeResultAsync(true);
        now += TimeSpan.FromMinutes(11);
        Assert.Null(await recovery.HandleProbeResultAsync(false));
        var second = await recovery.HandleProbeResultAsync(false);

        Assert.NotNull(second);
        Assert.Equal(ClashRecoveryOutcomeKind.Recovered, second!.Outcome);
        Assert.Equal(2, api.SelectedNodes.Count);
    }

    [Fact]
    public async Task GuardsRejectDisabledMissingAndInvalidFilters()
    {
        var recovery = Create(new ProbeFake(), new ClashApiFake());

        recovery.FilterQuery = "JP";
        recovery.AutoRecoveryEnabled = false;
        var disabled = await recovery.AttemptRecoveryAsync();
        Assert.Equal(ClashRecoveryOutcomeKind.NeedsAttention, disabled.Outcome);
        Assert.Equal("autoRecoveryDisabled", disabled.Reason);

        recovery.AutoRecoveryEnabled = true;
        recovery.FilterQuery = "   ";
        var missing = await recovery.AttemptRecoveryAsync();
        Assert.Equal(ClashRecoveryOutcomeKind.NeedsAttention, missing.Outcome);
        Assert.Equal("filterMissing", missing.Reason);

        recovery.FilterQuery = "^(JP";
        recovery.FilterUsesRegex = true;
        var invalid = await recovery.AttemptRecoveryAsync();
        Assert.Equal(ClashRecoveryOutcomeKind.NeedsAttention, invalid.Outcome);
        Assert.Equal("filterInvalid", invalid.Reason);
    }

    [Fact]
    public async Task NoUsableCandidatesNeedsAttention()
    {
        // Filter matches only SG 01, which is absent from the delay results (timed out).
        var probe = new ProbeFake();
        var api = new ClashApiFake();
        var recovery = Create(probe, api, filter: "SG");

        Assert.Null(await recovery.HandleProbeResultAsync(false));
        var outcome = await recovery.HandleProbeResultAsync(false);

        Assert.Equal(ClashRecoveryOutcomeKind.NeedsAttention, outcome.Outcome);
        Assert.Equal("noUsableCandidates", outcome.Reason);
        Assert.Empty(api.SelectedNodes);
    }

    [Fact]
    public async Task OutcomeEventFiresForRecoveryResults()
    {
        var probe = new ProbeFake(true);
        var api = new ClashApiFake();
        var recovery = Create(probe, api);
        var events = new List<ClashAutoRecoveryResult>();
        recovery.Outcome += events.Add;

        await recovery.HandleProbeResultAsync(false);
        await recovery.HandleProbeResultAsync(false);

        var evt = Assert.Single(events);
        Assert.Equal(ClashRecoveryOutcomeKind.Recovered, evt!.Outcome);
    }

    [Fact]
    public async Task EndpointFailureNeedsAttention()
    {
        var probe = new ProbeFake();
        var recovery = new ClashAutoRecovery(
            endpointFinder: _ => Task.FromResult<ClashEndpoint?>(new ClashEndpoint
            {
                BaseUrl = "",
                SourceConfigPath = "",
                DisabledReason = ClashDiscoveryReasons.ExternalControllerDisabled,
            }),
            probeHandlerFactory: probe.CreateHandler,
            clock: () => DateTimeOffset.UtcNow)
        {
            FilterQuery = "JP",
        };

        Assert.Null(await recovery.HandleProbeResultAsync(false));
        var outcome = await recovery.HandleProbeResultAsync(false);

        Assert.Equal(ClashRecoveryOutcomeKind.NeedsAttention, outcome!.Outcome);
        Assert.Equal(ClashDiscoveryReasons.ExternalControllerDisabled, outcome.Reason);
    }

    [Fact]
    public async Task ProbeAsyncTreatsAnyHttpResponseAsReachable()
    {
        var reachable = new ProbeFake(true);
        var unreachable = new ProbeFake(false);

        Assert.True(await Create(reachable, new ClashApiFake()).ProbeAsync());
        Assert.False(await Create(unreachable, new ClashApiFake()).ProbeAsync());
    }

    [Fact]
    public async Task AnyHttpStatusCodeCountsAsReachable()
    {
        var handler = new FakeHttpMessageHandler((request, _) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden)));
        var recovery = new ClashAutoRecovery(
            endpointFinder: _ => Task.FromResult<ClashEndpoint?>(Endpoint),
            probeHandlerFactory: () => handler,
            clock: () => DateTimeOffset.UtcNow);

        Assert.True(await recovery.ProbeAsync());
    }
}
