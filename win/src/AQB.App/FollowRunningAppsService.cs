using System.Diagnostics;

namespace AQB.App;

/// <summary>
/// "Follow running apps": hides providers whose desktop app is not running
/// (Windows counterpart of NSWorkspace observation via process-name polling).
/// </summary>
public sealed class FollowRunningAppsService : IDisposable
{
    // (provider, process-name fragments) — fragments keep it robust across exe naming.
    private static readonly (string Provider, string[] Fragments)[] Map =
    {
        ("codex", new[] { "chatgpt", "codex" }),
        ("kimi", new[] { "kimi" }),
        ("minimax", new[] { "minimax" }),
        ("glm", new[] { "zcode", "glm" }),
    };

    private readonly System.Threading.Timer _timer;
    private readonly object _gate = new();
    private HashSet<string> _visible = new(Map.Select(m => m.Provider), StringComparer.OrdinalIgnoreCase);

    public event Action? VisibilityChanged;

    public bool Enabled { get; set; }

    public IReadOnlyCollection<string> VisibleProviders
    {
        get
        {
            lock (_gate)
            {
                return _visible.ToArray();
            }
        }
    }

    public FollowRunningAppsService(bool enabled, int pollMilliseconds = 3000)
    {
        Enabled = enabled;
        _timer = new System.Threading.Timer(_ => Poll(), null, TimeSpan.Zero, TimeSpan.FromMilliseconds(pollMilliseconds));
    }

    private void Poll()
    {
        if (!Enabled)
        {
            return;
        }

        string[] processNames;
        try
        {
            processNames = Process.GetProcesses().Select(p => p.ProcessName).Where(n => !string.IsNullOrEmpty(n)).ToArray();
        }
        catch (Exception)
        {
            return; // transient process enumeration failure — keep previous state
        }

        var visible = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (provider, fragments) in Map)
        {
            if (processNames.Any(name => fragments.Any(f => name.Contains(f, StringComparison.OrdinalIgnoreCase))))
            {
                visible.Add(provider);
            }
        }

        lock (_gate)
        {
            if (visible.SetEquals(_visible))
            {
                return;
            }

            _visible = visible;
        }

        VisibilityChanged?.Invoke();
    }

    public void Dispose() => _timer.Dispose();
}
