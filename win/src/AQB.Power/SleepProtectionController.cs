namespace AQB.Power;

/// <summary>
/// Open-lid sleep protection, aligned with the macOS CodexSleepProtectionCoordinator
/// (power.md §1): while at least one AI task is active the controller holds an
/// ES_SYSTEM_REQUIRED grant (plus ES_DISPLAY_REQUIRED, which also blocks the idle
/// screensaver, when <see cref="KeepDisplayAwake"/> is set). The last task's end
/// starts a 5-minute grace period before the grant is released; Disable/Dispose
/// release immediately. Safety nets: battery &lt; 20% (off AC) degrades to
/// system-only, and a 12-hour maximum hold time suspends protection (per batch of
/// tasks, reset when the count returns to zero).
/// </summary>
public sealed class SleepProtectionController : IDisposable
{
    /// <summary>Mobile summary task-count ceiling (mobileActivityTaskCountLimit).</summary>
    public const int ReportedTaskCountLimit = 99;

    /// <summary>Mobile summary freshness window (mobileActivityFreshnessWindow).</summary>
    public static readonly TimeSpan ActivityFreshnessWindow = TimeSpan.FromMinutes(10);

    public static readonly TimeSpan DefaultGracePeriod = TimeSpan.FromSeconds(300);
    public static readonly TimeSpan DefaultMaxHoldDuration = TimeSpan.FromSeconds(43200); // 12h
    private static readonly TimeSpan DefaultEvaluationInterval = TimeSpan.FromSeconds(1);

    public const int LowBatteryPercentThreshold = 20;
    public const string MaximumDurationReason = "maximumDuration";

    private sealed class TaskEntry
    {
        public string ProviderKey = "";
        public DateTimeOffset StartedAtUtc;
        public DateTimeOffset LastActiveAtUtc;
    }

    private readonly IPowerRequest _request;
    private readonly IPowerState _powerState;
    private readonly IClock _clock;
    private readonly TimeSpan _gracePeriod;
    private readonly TimeSpan _maxHoldDuration;
    private readonly Timer? _timer;
    private readonly object _gate = new();

    private readonly Dictionary<string, TaskEntry> _tasks = new(StringComparer.Ordinal);
    private readonly List<string> _providers = new();
    private bool _enabled = true;
    private bool _keepDisplayAwake = true;
    private bool _holding;
    private bool _everReleased;
    private DateTimeOffset? _holdStartedAt;
    private DateTimeOffset? _graceEndsAt;
    private bool _suspendedForMaxDuration;
    private bool _displayDegraded;
    private bool _disposed;
    private ProtectionSnapshot _snapshot = new(
        ProtectionStatus.Inactive, 0, KeepDisplayAwake: true, KeepDisplayAwakeEffective: false,
        Array.Empty<string>(), SuspendedReason: null);

    /// <summary>Raised (outside the controller lock, possibly on a timer thread) whenever the snapshot changes.</summary>
    public event EventHandler<ProtectionSnapshot>? StatusChanged;

    public SleepProtectionController(
        IPowerRequest? request = null,
        IPowerState? powerState = null,
        IClock? clock = null,
        TimeSpan? gracePeriod = null,
        TimeSpan? maxHoldDuration = null,
        TimeSpan? evaluationInterval = null)
    {
        _request = request ?? new NativePowerRequest();
        _powerState = powerState ?? new NativePowerState();
        _clock = clock ?? SystemClock.Instance;
        _gracePeriod = gracePeriod ?? DefaultGracePeriod;
        _maxHoldDuration = maxHoldDuration ?? DefaultMaxHoldDuration;
        var interval = evaluationInterval ?? DefaultEvaluationInterval;
        if (interval > TimeSpan.Zero)
        {
            _timer = new Timer(_ => Evaluate(), null, interval, interval);
        }
    }

    public bool IsEnabled
    {
        get
        {
            lock (_gate)
            {
                return _enabled;
            }
        }
    }

    /// <summary>User setting: also keep the display awake (and the screensaver blocked) while tasks run.</summary>
    public bool KeepDisplayAwake
    {
        get
        {
            lock (_gate)
            {
                return _keepDisplayAwake;
            }
        }
        set
        {
            ProtectionSnapshot? changed = null;
            lock (_gate)
            {
                if (_disposed || _keepDisplayAwake == value)
                {
                    return;
                }

                _keepDisplayAwake = value;
                changed = EvaluateLocked();
            }

            changed?.Notify(this);
        }
    }

    public ProtectionSnapshot Snapshot
    {
        get
        {
            lock (_gate)
            {
                return _snapshot;
            }
        }
    }

    /// <summary>True when any task was active within the 10-minute freshness window.</summary>
    public bool HasFreshActivity
    {
        get
        {
            lock (_gate)
            {
                var cutoff = _clock.UtcNow - ActivityFreshnessWindow;
                return _tasks.Values.Any(task => task.LastActiveAtUtc >= cutoff);
            }
        }
    }

    /// <summary>
    /// Registers (or refreshes) a task. Tasks are counted even while protection is
    /// disabled, mirroring the macOS "count stays authoritative when protection is off".
    /// </summary>
    public void BeginTask(string taskId, string providerKey)
    {
        if (string.IsNullOrEmpty(taskId))
        {
            throw new ArgumentException("Task id is required.", nameof(taskId));
        }

        if (string.IsNullOrEmpty(providerKey))
        {
            throw new ArgumentException("Provider key is required.", nameof(providerKey));
        }

        ProtectionSnapshot? changed;
        lock (_gate)
        {
            if (_disposed)
            {
                changed = null;
                return;
            }

            var now = _clock.UtcNow;
            var key = providerKey + "|" + taskId;
            if (_tasks.TryGetValue(key, out var entry))
            {
                entry.LastActiveAtUtc = now;
            }
            else
            {
                _tasks[key] = new TaskEntry
                {
                    ProviderKey = providerKey,
                    StartedAtUtc = now,
                    LastActiveAtUtc = now,
                };
                if (!_providers.Contains(providerKey))
                {
                    _providers.Add(providerKey);
                }
            }

            // Any activity cancels a pending grace release.
            _graceEndsAt = null;
            changed = EvaluateLocked();
        }

        changed?.Notify(this);
    }

    public void EndTask(string taskId, string providerKey)
    {
        ProtectionSnapshot? changed;
        lock (_gate)
        {
            if (_disposed || !_tasks.Remove(providerKey + "|" + taskId))
            {
                return;
            }

            if (!_tasks.Any(task => task.Value.ProviderKey == providerKey))
            {
                _providers.Remove(providerKey);
            }

            if (_tasks.Count == 0)
            {
                if (_suspendedForMaxDuration)
                {
                    // Maximum-duration suspension is per batch of tasks: reset once the
                    // count reaches zero (the next task gets a fresh 12h window).
                    _suspendedForMaxDuration = false;
                    _graceEndsAt = null;
                }
                else
                {
                    _graceEndsAt = _clock.UtcNow + _gracePeriod;
                }
            }

            changed = EvaluateLocked();
        }

        changed?.Notify(this);
    }

    /// <summary>Immediately releases everything (does not wait for grace). Task counting continues.</summary>
    public void Disable()
    {
        ProtectionSnapshot? changed;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _enabled = false;
            _graceEndsAt = null;
            ReleaseHeldLocked();
            changed = UpdateSnapshot(ProtectionStatus.Released);
        }

        changed?.Notify(this);
    }

    public void Enable()
    {
        ProtectionSnapshot? changed;
        lock (_gate)
        {
            if (_disposed || _enabled)
            {
                return;
            }

            _enabled = true;
            changed = EvaluateLocked();
        }

        changed?.Notify(this);
    }

    /// <summary>Runs one evaluation cycle. Called automatically on a timer; public for tests.</summary>
    public void Evaluate()
    {
        ProtectionSnapshot? changed;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            changed = EvaluateLocked();
        }

        changed?.Notify(this);
    }

    /// <summary>Releases everything unconditionally (even if never held) and stops the timer.</summary>
    public void Dispose()
    {
        ProtectionSnapshot? changed;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _timer?.Dispose();
            _graceEndsAt = null;
            ReleaseHeldLocked();
            changed = UpdateSnapshot(ProtectionStatus.Released);
        }

        changed?.Notify(this);
    }

    private ProtectionSnapshot? EvaluateLocked()
    {
        var now = _clock.UtcNow;

        // 12h maximum hold: 43199s does not trigger, 43200s does (>=).
        if (_holding && _holdStartedAt is { } started && now - started >= _maxHoldDuration)
        {
            ReleaseHeldLocked();
            _graceEndsAt = null;
            _suspendedForMaxDuration = true;
            return UpdateSnapshot(ProtectionStatus.Suspended, MaximumDurationReason);
        }

        if (!_enabled)
        {
            if (_holding)
            {
                ReleaseHeldLocked();
                return UpdateSnapshot(ProtectionStatus.Released);
            }

            return null;
        }

        if (_suspendedForMaxDuration)
        {
            if (_tasks.Count == 0)
            {
                _suspendedForMaxDuration = false;
                return UpdateSnapshot(ProtectionStatus.Released);
            }

            return UpdateSnapshot(ProtectionStatus.Suspended, MaximumDurationReason);
        }

        // Low-battery safety net: strictly below 20% while on battery degrades to
        // system-only protection (display may turn off; system stays awake).
        var power = _powerState.Read();
        _displayDegraded = power.HasBattery
            && !power.OnAcPower
            && (power.BatteryPercent ?? 0) < LowBatteryPercentThreshold;
        var displayWanted = _keepDisplayAwake && !_displayDegraded;

        if (_tasks.Count > 0)
        {
            _graceEndsAt = null;
            if (!_holding)
            {
                _request.Acquire(displayWanted);
                _holding = true;
                _holdStartedAt = now;
            }
            else
            {
                _request.SetDisplayRequired(displayWanted);
            }

            return UpdateSnapshot(ProtectionStatus.Active);
        }

        if (_graceEndsAt is { } endsAt)
        {
            if (now >= endsAt)
            {
                _graceEndsAt = null;
                ReleaseHeldLocked();
                return UpdateSnapshot(ProtectionStatus.Released);
            }

            if (_holding)
            {
                _request.SetDisplayRequired(displayWanted);
            }

            return UpdateSnapshot(ProtectionStatus.Grace);
        }

        if (_holding)
        {
            ReleaseHeldLocked();
            return UpdateSnapshot(ProtectionStatus.Released);
        }

        return UpdateSnapshot(_everReleased ? ProtectionStatus.Released : ProtectionStatus.Inactive);
    }

    private void ReleaseHeldLocked()
    {
        _request.Release();
        _holding = false;
        _holdStartedAt = null;
        _everReleased = true;
    }

    private ProtectionSnapshot? UpdateSnapshot(ProtectionStatus status, string? suspendedReason = null)
    {
        var snapshot = new ProtectionSnapshot(
            status,
            Math.Min(_tasks.Count, ReportedTaskCountLimit),
            _keepDisplayAwake,
            (status is ProtectionStatus.Active or ProtectionStatus.Grace) && _keepDisplayAwake && !_displayDegraded,
            _providers.ToArray(),
            status == ProtectionStatus.Suspended ? suspendedReason ?? MaximumDurationReason : null);
        if (snapshot.Equals(_snapshot))
        {
            return null;
        }

        _snapshot = snapshot;
        return snapshot;
    }

    /// <summary>Invoked by the public wrappers after the controller lock has been released.</summary>
    private void OnStatusChanged(ProtectionSnapshot snapshot) => StatusChanged?.Invoke(this, snapshot);

    internal void NotifyStatusChanged(ProtectionSnapshot snapshot) => OnStatusChanged(snapshot);
}

internal static class ProtectionSnapshotExtensions
{
    public static void Notify(this ProtectionSnapshot snapshot, SleepProtectionController sender)
        => sender.NotifyStatusChanged(snapshot);
}
