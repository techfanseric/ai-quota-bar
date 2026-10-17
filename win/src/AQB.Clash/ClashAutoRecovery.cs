using System.Net.Http;
using System.Net.Sockets;

namespace AQB.Clash;

public enum ClashRecoveryOutcomeKind
{
    Recovered,
    Suppressed,
    NeedsAttention,
}

/// <summary>Outcome of one automatic recovery evaluation.</summary>
public sealed record ClashAutoRecoveryResult
{
    public required ClashRecoveryOutcomeKind Outcome { get; init; }

    /// <summary>Route selected before the recovery started (recovered outcomes only).</summary>
    public string? FromRoute { get; init; }

    /// <summary>Route the flow ended on (recovered outcomes only).</summary>
    public string? ToRoute { get; init; }

    /// <summary>Measured delay of the recovered route (recovered outcomes only).</summary>
    public int DelayMs { get; init; }

    /// <summary>Machine readable reason for suppressed/needsAttention outcomes.</summary>
    public string? Reason { get; init; }

    public bool DidSwitchRoute => FromRoute != ToRoute;

    public override string ToString()
        => Outcome == ClashRecoveryOutcomeKind.Recovered
            ? $"Recovered({FromRoute} -> {ToRoute}, {DelayMs}ms)"
            : $"{Outcome}({Reason})";
}

/// <summary>
/// Automatic OpenAI route recovery. Polls chatgpt.com/openai.com with HEAD probes; after two
/// consecutive fully-unreachable rounds (and only once per outage) it re-tests the group and
/// switches to the fastest filtered candidates until a fresh-probe recheck succeeds.
/// </summary>
public sealed class ClashAutoRecovery : IDisposable
{
    public const string ProbeChatGptUrl = "https://chatgpt.com/";

    public const string ProbeOpenAiUrl = "https://openai.com/";

    public static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(3);

    public static readonly TimeSpan DefaultRecoveryCooldown = TimeSpan.FromMinutes(10);

    private readonly Func<CancellationToken, Task<ClashEndpoint?>> _endpointFinder;
    private readonly Func<ClashEndpoint, ClashClient> _clientFactory;
    private readonly Func<HttpMessageHandler> _probeHandlerFactory;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Func<double> _random;

    private CancellationTokenSource? _runCancellation;
    private Task? _runLoop;

    public event Action<ClashAutoRecoveryResult>? Outcome;

    public bool AutoRecoveryEnabled { get; set; } = true;

    /// <summary>Country/regex filter the recovered candidates must match.</summary>
    public string FilterQuery { get; set; } = "";

    public bool FilterUsesRegex { get; set; }

    public TimeSpan RecoveryCooldown { get; set; } = DefaultRecoveryCooldown;

    /// <summary>Consecutive fully-unreachable probe rounds (any reachable endpoint resets it).</summary>
    public int ConsecutiveUnreachableChecks { get; private set; }

    /// <summary>True while a recovery attempt is in flight.</summary>
    public bool IsRecovering { get; private set; }

    public DateTimeOffset? LastRecoveryAttemptUtc { get; private set; }

    public ClashAutoRecovery(
        Func<CancellationToken, Task<ClashEndpoint?>>? endpointFinder = null,
        Func<ClashEndpoint, ClashClient>? clientFactory = null,
        Func<HttpMessageHandler>? probeHandlerFactory = null,
        Func<DateTimeOffset>? clock = null,
        Func<double>? random = null)
    {
        _endpointFinder = endpointFinder ?? (ct => Task.FromResult(ClashControllerDiscovery.FindEndpoint()));
        _clientFactory = clientFactory ?? (endpoint => new ClashClient(endpoint));
        _probeHandlerFactory = probeHandlerFactory
            ?? (() => new SocketsHttpHandler { UseProxy = false, UseCookies = false });
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _random = random ?? Random.Shared.NextDouble;
    }

    /// <summary>
    /// HEAD probes both domains concurrently with a fresh HTTP session. Any HTTP response
    /// (any status code) counts as reachable; transport failures do not.
    /// </summary>
    public async Task<bool> ProbeAsync(CancellationToken cancellationToken = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ProbeTimeout);
        using var http = new HttpClient(_probeHandlerFactory(), disposeHandler: true)
        {
            Timeout = ProbeTimeout,
        };
        http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", ClashClient.UserAgent);

        var tasks = new[]
        {
            ProbeOneAsync(http, ProbeChatGptUrl, timeout.Token),
            ProbeOneAsync(http, ProbeOpenAiUrl, timeout.Token),
        };
        var results = await Task.WhenAll(tasks).ConfigureAwait(false);
        return results.Any(reachable => reachable);
    }

    /// <summary>
    /// Feeds one connectivity observation. Two consecutive unreachable rounds fire a single
    /// recovery attempt for the outage. Returns that attempt's result, or null when no
    /// attempt ran.
    /// </summary>
    public async Task<ClashAutoRecoveryResult?> HandleProbeResultAsync(
        bool reachable,
        CancellationToken cancellationToken = default)
    {
        if (reachable)
        {
            ConsecutiveUnreachableChecks = 0;
            _hasHandledCurrentOutage = false;
            return null;
        }

        ConsecutiveUnreachableChecks++;
        if (ConsecutiveUnreachableChecks < 2
            || _hasHandledCurrentOutage
            || IsRecovering)
        {
            return null;
        }

        _hasHandledCurrentOutage = true;
        return await AttemptRecoveryAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Runs the guard checks in spec order, then the recovery flow.</summary>
    public async Task<ClashAutoRecoveryResult> AttemptRecoveryAsync(CancellationToken cancellationToken = default)
    {
        if (!AutoRecoveryEnabled)
        {
            return Publish(new ClashAutoRecoveryResult
            {
                Outcome = ClashRecoveryOutcomeKind.NeedsAttention,
                Reason = "autoRecoveryDisabled",
            });
        }

        var trimmedQuery = FilterQuery.Trim();
        if (trimmedQuery.Length == 0)
        {
            return Publish(new ClashAutoRecoveryResult
            {
                Outcome = ClashRecoveryOutcomeKind.NeedsAttention,
                Reason = "filterMissing",
            });
        }

        if (FilterUsesRegex && !CountryMatcher.IsRegexValid(trimmedQuery))
        {
            return Publish(new ClashAutoRecoveryResult
            {
                Outcome = ClashRecoveryOutcomeKind.NeedsAttention,
                Reason = "filterInvalid",
            });
        }

        if (IsRecovering)
        {
            return Publish(new ClashAutoRecoveryResult
            {
                Outcome = ClashRecoveryOutcomeKind.Suppressed,
                Reason = "busy",
            });
        }

        var now = _clock();
        if (LastRecoveryAttemptUtc is { } lastAttempt && now - lastAttempt < RecoveryCooldown)
        {
            return Publish(new ClashAutoRecoveryResult
            {
                Outcome = ClashRecoveryOutcomeKind.Suppressed,
                Reason = "cooldown",
            });
        }

        LastRecoveryAttemptUtc = now;

        IsRecovering = true;
        try
        {
            return Publish(await RunRecoveryFlowAsync(trimmedQuery, cancellationToken).ConfigureAwait(false));
        }
        finally
        {
            IsRecovering = false;
        }
    }

    /// <summary>Poll loop: probe, feed the state machine, sleep 8-12s (jittered).</summary>
    public Task RunAsync(CancellationToken cancellationToken)
    {
        _runCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = _runCancellation.Token;
        _runLoop = Task.Run(() => RunLoopAsync(token), token);
        return _runLoop;
    }

    private async Task RunLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var reachable = await ProbeAsync(cancellationToken).ConfigureAwait(false);
            await HandleProbeResultAsync(reachable, cancellationToken).ConfigureAwait(false);

            var jitteredSeconds = 8 + Math.Clamp(_random(), 0, 1) * 4;
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(jitteredSeconds), cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task<ClashAutoRecoveryResult> RunRecoveryFlowAsync(
        string trimmedQuery,
        CancellationToken cancellationToken)
    {
        var endpoint = await _endpointFinder(cancellationToken).ConfigureAwait(false);
        if (endpoint is null || !endpoint.IsUsable)
        {
            return NeedsAttention(endpoint?.DisabledReason ?? ClashDiscoveryReasons.ConfigurationNotFound);
        }

        using var client = _clientFactory(endpoint);
        try
        {
            await client.GetVersionAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ClashApiException e)
        {
            return NeedsAttention(e.Reason);
        }

        IReadOnlyDictionary<string, ClashProxy> proxies;
        IReadOnlyList<ClashRule> rules;
        try
        {
            proxies = await client.GetProxiesAsync(cancellationToken).ConfigureAwait(false);
            rules = await client.GetRulesAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ClashApiException e)
        {
            return NeedsAttention(e.Reason);
        }

        var groupName = ClashRouteResolver.ResolveGroupName(rules, proxies);
        if (groupName is null || !proxies.TryGetValue(groupName, out var group))
        {
            return NeedsAttention("strategyGroupNotFound");
        }

        IReadOnlyDictionary<string, int> delays;
        try
        {
            delays = await client.TestGroupDelayAsync(groupName, cancellationToken: cancellationToken)
                .ConfigureAwait(false);
        }
        catch (ClashApiException e)
        {
            return NeedsAttention("speedTestFailed:" + e.Reason);
        }

        var routes = ClashRouteResolver.ApplyDelays(ClashRouteResolver.BuildRoutes(group, proxies), delays);
        var filterResult = CountryMatcher.Filter((IReadOnlyList<ClashRoute>)routes, route => route.Name, trimmedQuery, FilterUsesRegex);
        var candidates = filterResult.Matches
            .Where(route => route.HasUsableDelay)
            .Take(3)
            .ToList();
        if (candidates.Count == 0)
        {
            return NeedsAttention("noUsableCandidates");
        }

        var originalRoute = group.Now ?? "—";
        var currentRoute = group.Now;
        foreach (var candidate in candidates)
        {
            if (candidate.Name != currentRoute)
            {
                try
                {
                    await client.SelectProxyAsync(groupName, candidate.Name, cancellationToken).ConfigureAwait(false);
                    currentRoute = candidate.Name;
                }
                catch (ClashApiException)
                {
                    continue;
                }
            }

            // Fresh HTTP session per recheck so a pooled connection cannot mask the new route.
            if (await ProbeAsync(cancellationToken).ConfigureAwait(false))
            {
                return new ClashAutoRecoveryResult
                {
                    Outcome = ClashRecoveryOutcomeKind.Recovered,
                    FromRoute = originalRoute,
                    ToRoute = candidate.Name,
                    DelayMs = candidate.Delay ?? 0,
                };
            }
        }

        return NeedsAttention("recoveryFailed");
    }

    private bool _hasHandledCurrentOutage;

    private ClashAutoRecoveryResult NeedsAttention(string reason)
        => new() { Outcome = ClashRecoveryOutcomeKind.NeedsAttention, Reason = reason };

    private ClashAutoRecoveryResult Publish(ClashAutoRecoveryResult result)
    {
        Outcome?.Invoke(result);
        return result;
    }

    private static async Task<bool> ProbeOneAsync(HttpClient http, string url, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, url);
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            return true;
        }
        catch (Exception e) when (e is HttpRequestException or SocketException or OperationCanceledException or InvalidOperationException)
        {
            return false;
        }
    }

    public void Dispose()
    {
        _runCancellation?.Cancel();
        _runCancellation?.Dispose();
        _runCancellation = null;
    }
}
