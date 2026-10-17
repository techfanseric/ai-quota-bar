using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using AQB.Core;

namespace AQB.Clash;

/// <summary>GET /connections and WS frame payload (only the fields this app uses).</summary>
public sealed class ConnectionsResponse
{
    public long? DownloadTotal { get; init; }

    public long? UploadTotal { get; init; }

    public IReadOnlyList<ConnectionRecord> Connections { get; init; } = Array.Empty<ConnectionRecord>();

    /// <summary>Tolerant parse; null when the frame is not valid JSON.</summary>
    public static ConnectionsResponse? Parse(string json)
    {
        try
        {
            var root = JsonNode.Parse(json);
            if (root is null)
            {
                return null;
            }

            var records = new List<ConnectionRecord>();
            if (root["connections"] is JsonArray array)
            {
                foreach (var node in array)
                {
                    if (node is not null)
                    {
                        records.Add(ParseRecord(node));
                    }
                }
            }

            return new ConnectionsResponse
            {
                DownloadTotal = root["downloadTotal"] is null ? null : root.GetLong("downloadTotal"),
                UploadTotal = root["uploadTotal"] is null ? null : root.GetLong("uploadTotal"),
                Connections = records,
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static ConnectionRecord ParseRecord(JsonNode node) => new()
    {
        Id = node.GetString("id"),
        Download = node.GetLong("download"),
        Upload = node.GetLong("upload"),
        Chains = node["chains"] is JsonArray chains
            ? chains.Where(item => item is not null).Select(item => item!.ToString()).ToArray()
            : Array.Empty<string>(),
        Rule = node["rule"] is null ? null : node.GetString("rule"),
        RulePayload = node["rulePayload"] is null ? null : node.GetString("rulePayload"),
        Start = node.GetString("start"),
        Metadata = ParseMetadata(node["metadata"]),
    };

    private static ConnectionMetadata ParseMetadata(JsonNode? node) => new()
    {
        Network = node?["network"] is null ? null : node!.GetString("network"),
        Type = node?["type"] is null ? null : node.GetString("type"),
        DestinationIP = node?["destinationIP"] is null ? null : node.GetString("destinationIP"),
        Host = node?["host"] is null ? null : node.GetString("host"),
        Process = node?["process"] is null ? null : node.GetString("process"),
        ProcessPath = node?["processPath"] is null ? null : node.GetString("processPath"),
        RemoteDestination = node?["remoteDestination"] is null ? null : node.GetString("remoteDestination"),
        SniffHost = node?["sniffHost"] is null ? null : node.GetString("sniffHost"),
    };
}

public sealed class ConnectionRecord
{
    public string Id { get; init; } = "";

    public long Download { get; init; }

    public long Upload { get; init; }

    public IReadOnlyList<string> Chains { get; init; } = Array.Empty<string>();

    public string? Rule { get; init; }

    public string? RulePayload { get; init; }

    /// <summary>ISO8601 with or without fractional seconds.</summary>
    public string Start { get; init; } = "";

    public ConnectionMetadata Metadata { get; init; } = new();
}

public sealed class ConnectionMetadata
{
    public string? Network { get; init; }

    public string? Type { get; init; }

    public string? DestinationIP { get; init; }

    public string? Host { get; init; }

    public string? Process { get; init; }

    public string? ProcessPath { get; init; }

    public string? RemoteDestination { get; init; }

    public string? SniffHost { get; init; }
}

/// <summary>Parses mihomo connection start timestamps (fractional and plain ISO8601).</summary>
public static class ClashConnectionDateParser
{
    private static readonly Regex GoTimestamp = new(
        @"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\.(\d{1,9})(Z|[+-]\d{2}:\d{2})?$",
        RegexOptions.CultureInvariant);

    public static DateTimeOffset? Parse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var text = value.Trim();
        if (TimeText.TryParseIso(text, out var parsed))
        {
            return parsed;
        }

        // Go emits RFC3339Nano with up to 9 fractional digits; .NET parses at most 7.
        var match = GoTimestamp.Match(text);
        if (!match.Success)
        {
            return null;
        }

        var fraction = match.Groups[2].Value;
        if (fraction.Length > 7)
        {
            fraction = fraction[..7];
        }

        var normalized = match.Groups[1].Value + "." + fraction + match.Groups[3].Value;
        return DateTimeOffset.TryParse(
            normalized,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal,
            out parsed)
            ? parsed
            : null;
    }
}

/// <summary>Filters connections down to openai.com / chatgpt.com traffic (host, sniffHost, remoteDestination, rulePayload).</summary>
public static class ClashOpenAiConnectionFilter
{
    public static readonly string[] ObservedDomains = { "openai.com", "chatgpt.com" };

    public static bool Matches(ConnectionRecord connection)
    {
        var candidates = new[]
        {
            connection.Metadata.Host,
            connection.Metadata.SniffHost,
            connection.Metadata.RemoteDestination,
            connection.RulePayload,
        };

        return candidates
            .OfType<string>()
            .Any(MatchesObservedDomain);
    }

    /// <summary>Display host: first non-empty normalized of host/sniffHost/remoteDestination, else destinationIP, else an em dash.</summary>
    public static string DisplayHost(ConnectionRecord connection)
    {
        var candidates = new[]
        {
            connection.Metadata.Host,
            connection.Metadata.SniffHost,
            connection.Metadata.RemoteDestination,
        };

        foreach (var candidate in candidates.OfType<string>())
        {
            var normalized = NormalizeHost(candidate);
            if (normalized.Length > 0)
            {
                return normalized;
            }
        }

        return connection.Metadata.DestinationIP ?? "—";
    }

    public static bool MatchesObservedDomain(string rawValue)
    {
        var host = NormalizeHost(rawValue);
        return ObservedDomains.Any(domain =>
            host == domain || host.EndsWith("." + domain, StringComparison.Ordinal));
    }

    /// <summary>trim + lower, URL host extraction, leading "+."/"." strip, trailing ":port" strip, trailing dot strip.</summary>
    public static string NormalizeHost(string rawValue)
    {
        var value = rawValue.Trim().ToLowerInvariant();

        if (Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Host.Length > 0)
        {
            value = uri.Host;
        }

        if (value.StartsWith("+.", StringComparison.Ordinal))
        {
            value = value[2..];
        }
        else if (value.StartsWith(".", StringComparison.Ordinal))
        {
            value = value[1..];
        }

        var colon = value.LastIndexOf(':');
        if (colon >= 0
            && !value.Contains(']')
            && IsAllDigits(value[(colon + 1)..]))
        {
            value = value[..colon];
        }

        while (value.EndsWith(".", StringComparison.Ordinal))
        {
            value = value[..^1];
        }

        return value;

        static bool IsAllDigits(string tail)
            => tail.All(char.IsAsciiDigit);
    }
}

/// <summary>A filtered live connection with per-second speeds and age.</summary>
public sealed class ActiveConnection
{
    public required string Id { get; init; }

    public required string Host { get; init; }

    public string? Process { get; init; }

    public string? Network { get; init; }

    public IReadOnlyList<string> Chains { get; init; } = Array.Empty<string>();

    public DateTimeOffset? StartedAt { get; init; }

    /// <summary>Seconds since start, clamped at 0; 0 when the start timestamp is unparsable.</summary>
    public double DurationSeconds { get; init; }

    public double UploadBps { get; init; }

    public double DownloadBps { get; init; }

    public string? PrimaryChain => Chains.Count > 0 ? Chains[0] : null;
}

/// <summary>Result of applying one connection frame.</summary>
public sealed class ActivitySnapshot
{
    public required DateTimeOffset ObservedAt { get; init; }

    public required IReadOnlyList<ActiveConnection> Connections { get; init; }

    public double UploadBps { get; init; }

    public double DownloadBps { get; init; }
}

/// <summary>
/// Computes per-connection byte deltas over time. New connections (no previous sample) and
/// counter resets (current &lt; previous) deliberately yield 0 so restarts never spike.
/// </summary>
public sealed class ClashConnectionActivityCalculator
{
    private sealed record Counter(long Upload, long Download, DateTimeOffset ObservedAt);

    private Dictionary<string, Counter> _previousCounters = new();

    public void Reset() => _previousCounters = new Dictionary<string, Counter>();

    public ActivitySnapshot Update(ConnectionsResponse response, DateTimeOffset observedAt)
    {
        var matchingConnections = response.Connections.Where(ClashOpenAiConnectionFilter.Matches).ToList();

        var nextCounters = new Dictionary<string, Counter>(matchingConnections.Count);
        var activeConnections = new List<ActiveConnection>(matchingConnections.Count);

        foreach (var connection in matchingConnections)
        {
            _previousCounters.TryGetValue(connection.Id, out var previous);
            var elapsed = previous is null
                ? 0
                : Math.Max(0, (observedAt - previous.ObservedAt).TotalSeconds);

            var startedAt = ClashConnectionDateParser.Parse(connection.Start);
            activeConnections.Add(new ActiveConnection
            {
                Id = connection.Id,
                Host = ClashOpenAiConnectionFilter.DisplayHost(connection),
                Process = NonEmpty(connection.Metadata.Process),
                Network = NonEmpty(connection.Metadata.Network),
                Chains = connection.Chains,
                StartedAt = startedAt,
                DurationSeconds = startedAt is null
                    ? 0
                    : Math.Max(0, (observedAt - startedAt.Value).TotalSeconds),
                UploadBps = Speed(connection.Upload, previous?.Upload, elapsed),
                DownloadBps = Speed(connection.Download, previous?.Download, elapsed),
            });

            nextCounters[connection.Id] = new Counter(connection.Upload, connection.Download, observedAt);
        }

        _previousCounters = nextCounters;
        activeConnections.Sort((lhs, rhs) =>
        {
            var lhsStart = lhs.StartedAt ?? DateTimeOffset.MinValue;
            var rhsStart = rhs.StartedAt ?? DateTimeOffset.MinValue;
            if (lhsStart != rhsStart)
            {
                return rhsStart.CompareTo(lhsStart);
            }

            return NaturalStringComparer.Instance.Compare(lhs.Host, rhs.Host);
        });

        return new ActivitySnapshot
        {
            ObservedAt = observedAt,
            Connections = activeConnections,
            UploadBps = activeConnections.Sum(connection => connection.UploadBps),
            DownloadBps = activeConnections.Sum(connection => connection.DownloadBps),
        };
    }

    private static double Speed(long current, long? previous, double elapsed)
        => previous is { } previousValue && current >= previousValue && elapsed > 0
            ? (current - previousValue) / elapsed
            : 0;

    private static string? NonEmpty(string? value)
        => string.IsNullOrWhiteSpace(value) ? null : value;
}

/// <summary>Connection age color scale: green (0.20, 0.78, 0.35) to orange (1.00, 0.49, 0.05) over 60 minutes.</summary>
public static class ClashConnectionAgeScale
{
    public const double OldestAgeSeconds = 60 * 60;

    public static (double R, double G, double B) FreshColor => (0.20, 0.78, 0.35);

    public static (double R, double G, double B) OldestColor => (1.00, 0.49, 0.05);

    /// <summary>Clamped linear progress 0..1 across one hour (negative ages clamp to 0, beyond an hour to 1).</summary>
    public static double Progress(double ageSeconds)
        => Math.Clamp(ageSeconds / OldestAgeSeconds, 0, 1);

    public static (double R, double G, double B) Color(double ageSeconds)
    {
        var progress = Progress(ageSeconds);
        var fresh = FreshColor;
        var oldest = OldestColor;
        return (
            fresh.R + (oldest.R - fresh.R) * progress,
            fresh.G + (oldest.G - fresh.G) * progress,
            fresh.B + (oldest.B - fresh.B) * progress);
    }
}

/// <summary>One minute-grid history sample: only connection ages, never hosts/processes (privacy).</summary>
public sealed record ConnectionHistorySample
{
    public required DateTimeOffset Timestamp { get; init; }

    public required IReadOnlyList<double> ConnectionAges { get; init; }

    public int ConnectionCount => ConnectionAges.Count;
}

/// <summary>Minute-aligned upsert/prune over the 60-minute rolling window.</summary>
public static class ClashConnectionHistory
{
    public const int SampleIntervalSeconds = 60;

    public const int RetainedSampleCount = 60;

    public static DateTimeOffset MinuteStart(DateTimeOffset value)
    {
        var epochSeconds = value.ToUnixTimeSeconds();
        return DateTimeOffset.FromUnixTimeSeconds(epochSeconds - epochSeconds % SampleIntervalSeconds);
    }

    /// <summary>Upserts the snapshot's minute (same-minute observations overwrite) and prunes to the 60-minute window.</summary>
    public static List<ConnectionHistorySample> Upsert(
        ActivitySnapshot snapshot,
        IEnumerable<ConnectionHistorySample> samples)
    {
        var timestamp = MinuteStart(snapshot.ObservedAt);
        var sample = new ConnectionHistorySample
        {
            Timestamp = timestamp,
            ConnectionAges = snapshot.Connections
                .Select(connection => connection.DurationSeconds)
                .OrderByDescending(age => age)
                .ToArray(),
        };

        var result = samples
            .Where(existing => existing.Timestamp != timestamp)
            .Append(sample)
            .OrderBy(existing => existing.Timestamp)
            .ToList();

        var earliestTimestamp = timestamp.AddSeconds(-SampleIntervalSeconds * (RetainedSampleCount - 1));
        return result.Where(existing => existing.Timestamp >= earliestTimestamp).ToList();
    }

    /// <summary>Keeps samples within [now - 59 minutes, current minute], ascending.</summary>
    public static List<ConnectionHistorySample> Prune(IEnumerable<ConnectionHistorySample> samples, DateTimeOffset now)
    {
        var latestTimestamp = MinuteStart(now);
        var earliestTimestamp = latestTimestamp.AddSeconds(-SampleIntervalSeconds * (RetainedSampleCount - 1));
        return samples
            .Where(sample => sample.Timestamp >= earliestTimestamp && sample.Timestamp <= latestTimestamp)
            .OrderBy(sample => sample.Timestamp)
            .ToList();
    }
}
