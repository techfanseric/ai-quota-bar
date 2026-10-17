using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Core;

/// <summary>One sampled point of a quota window.</summary>
public sealed record QuotaSamplePoint(DateTimeOffset AtUtc, double RemainingPercent);

/// <summary>
/// Rolling per-window quota history (the data source for trend sparklines in the
/// control center). Keyed by "provider|account|window"; capped and pruned per window;
/// persisted atomically as JSON. Thread-safe.
/// </summary>
public sealed class QuotaHistoryStore : IDisposable
{
    public const int MaxPointsPerWindow = 1008; // 7 days at a 10-minute refresh
    public static readonly TimeSpan Retention = TimeSpan.FromDays(7);

    private readonly string? _path;
    private readonly object _gate = new();
    private readonly Dictionary<string, List<QuotaSamplePoint>> _series = new(StringComparer.Ordinal);
    private int _recordsSinceSave;

    public QuotaHistoryStore(string? path = null)
    {
        _path = path;
        Load();
    }

    /// <summary>Appends the latest sample of every window in the snapshot set (deduped per minute).</summary>
    public void Record(IReadOnlyDictionary<ProviderKind, ProviderSnapshot> snapshots, DateTimeOffset? nowUtc = null)
    {
        var now = nowUtc ?? DateTimeOffset.UtcNow;
        lock (_gate)
        {
            foreach (var snapshot in snapshots.Values)
            {
                foreach (var account in snapshot.Accounts)
                {
                    foreach (var window in account.Windows)
                    {
                        var key = Key(snapshot.Kind, account.AccountKey, window.Name);
                        if (!_series.TryGetValue(key, out var points))
                        {
                            points = new List<QuotaSamplePoint>();
                            _series[key] = points;
                        }

                        // One sample per minute is plenty for a sparkline.
                        if (points.Count > 0 && now - points[^1].AtUtc < TimeSpan.FromMinutes(1))
                        {
                            continue;
                        }

                        points.Add(new QuotaSamplePoint(now, Math.Clamp(window.RemainingPercent, 0, 100)));
                        if (points.Count > MaxPointsPerWindow)
                        {
                            points.RemoveRange(0, points.Count - MaxPointsPerWindow);
                        }
                    }
                }
            }

            PruneLocked(now);
            if (++_recordsSinceSave >= 10)
            {
                SaveLocked();
            }
        }
    }

    /// <summary>Series for the given provider/window over any account (newest points win on name clashes).</summary>
    public IReadOnlyList<QuotaSamplePoint> GetSeries(ProviderKind kind, string windowName, DateTimeOffset? nowUtc = null)
    {
        var now = nowUtc ?? DateTimeOffset.UtcNow;
        lock (_gate)
        {
            List<QuotaSamplePoint>? best = null;
            foreach (var (key, points) in _series)
            {
                if (!key.StartsWith(kind.WireName() + "|", StringComparison.Ordinal) ||
                    !key.EndsWith("|" + windowName, StringComparison.Ordinal))
                {
                    continue;
                }

                if (best is null || points.Count > best.Count)
                {
                    best = points;
                }
            }

            if (best is null)
            {
                return Array.Empty<QuotaSamplePoint>();
            }

            var cutoff = now - Retention;
            return best.Where(p => p.AtUtc >= cutoff).ToList();
        }
    }

    public IReadOnlyCollection<string> WindowKeys
    {
        get
        {
            lock (_gate)
            {
                return _series.Keys.ToArray();
            }
        }
    }

    private void PruneLocked(DateTimeOffset now)
    {
        var cutoff = now - Retention;
        foreach (var key in _series.Keys.ToList())
        {
            _series[key].RemoveAll(p => p.AtUtc < cutoff);
            if (_series[key].Count == 0)
            {
                _series.Remove(key);
            }
        }
    }

    private static string Key(ProviderKind kind, string accountKey, string windowName)
        => kind.WireName() + "|" + accountKey + "|" + windowName;

    private void Load()
    {
        if (_path is null)
        {
            return;
        }

        try
        {
            var root = Json.TryReadFile(_path)?["series"] as JsonObject;
            if (root is null)
            {
                return;
            }

            foreach (var (key, value) in root)
            {
                if (value is not JsonArray points)
                {
                    continue;
                }

                var list = new List<QuotaSamplePoint>(points.Count);
                foreach (var point in points)
                {
                    if (TimeText.TryParseIso(point.GetString("t"), out var at))
                    {
                        list.Add(new QuotaSamplePoint(at, point.GetDouble("r")));
                    }
                }

                if (list.Count > 0)
                {
                    _series[key] = list;
                }
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // Unreadable history starts empty.
        }
    }

    public void Save()
    {
        lock (_gate)
        {
            SaveLocked();
        }
    }

    public void Dispose() => Save();

    private void SaveLocked()
    {
        _recordsSinceSave = 0;
        if (_path is null)
        {
            return;
        }

        try
        {
            var root = new JsonObject();
            var series = new JsonObject();
            foreach (var (key, points) in _series)
            {
                var array = new JsonArray();
                foreach (var point in points)
                {
                    array.Add(new JsonObject
                    {
                        ["t"] = TimeText.FixedIso(point.AtUtc),
                        ["r"] = point.RemainingPercent,
                    });
                }

                series[key] = array;
            }

            root["version"] = 1;
            root["series"] = series;
            Json.AtomicWrite(_path, root.ToJsonString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // History is best-effort; a failed save keeps the in-memory points.
        }
    }
}
