using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Clash;

/// <summary>
/// Persists the minute-grid connection history as {"version":1,"samples":[...]} to
/// %APPDATA%\AIQuotaBar\clash-connection-history.json. Only aggregate ages are stored —
/// never hosts, processes or IPs. Writes are atomic.
/// </summary>
public sealed class ClashConnectionHistoryStore
{
    public const int CurrentSchemaVersion = 1;

    public ClashConnectionHistoryStore(string? directory = null)
    {
        Directory = directory
            ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "AIQuotaBar");
        FilePath = Path.Combine(Directory, "clash-connection-history.json");
    }

    public string Directory { get; }

    public string FilePath { get; }

    /// <summary>Loads and prunes the samples; corrupt files, missing files and newer schemas yield an empty list.</summary>
    public List<ConnectionHistorySample> Load(DateTimeOffset? now = null)
    {
        var root = Json.TryReadFile(FilePath);
        if (root?["version"] is not null && root.GetLong("version") > CurrentSchemaVersion)
        {
            return new List<ConnectionHistorySample>();
        }

        if (root?["samples"] is not JsonArray samples)
        {
            return new List<ConnectionHistorySample>();
        }

        var parsed = new List<ConnectionHistorySample>();
        foreach (var node in samples)
        {
            var timestampText = node?.GetString("timestamp");
            if (string.IsNullOrWhiteSpace(timestampText)
                || !TimeText.TryParseIso(timestampText, out var timestamp))
            {
                continue;
            }

            var ages = new List<double>();
            if (node?["ages"] is JsonArray ageArray)
            {
                foreach (var age in ageArray)
                {
                    ages.Add(age?.GetValue<double>() ?? 0);
                }
            }

            parsed.Add(new ConnectionHistorySample
            {
                Timestamp = timestamp.ToUniversalTime(),
                ConnectionAges = ages,
            });
        }

        return ClashConnectionHistory.Prune(parsed, now ?? DateTimeOffset.UtcNow);
    }

    /// <summary>Atomically writes the payload; failures are swallowed (monitoring must not crash).</summary>
    public void Save(IReadOnlyList<ConnectionHistorySample> samples)
    {
        try
        {
            var array = new JsonArray();
            foreach (var sample in samples)
            {
                var ages = new JsonArray();
                foreach (var age in sample.ConnectionAges)
                {
                    ages.Add(Math.Round(age, 3));
                }

                array.Add(new JsonObject
                {
                    ["timestamp"] = TimeText.FixedIso(sample.Timestamp),
                    ["ages"] = ages,
                });
            }

            var payload = new JsonObject
            {
                ["version"] = CurrentSchemaVersion,
                ["samples"] = array,
            };
            Json.AtomicWrite(FilePath, payload.ToJsonString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Best effort persistence only.
        }
    }
}
