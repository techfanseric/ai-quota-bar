using System.Collections.Concurrent;

namespace AQB.Power;

/// <summary>
/// Serializes <see cref="NativeMethods.SetThreadExecutionState"/> calls onto one
/// dedicated long-lived thread. ES_CONTINUOUS flags bind to the calling thread;
/// invoking them from transient thread-pool threads would silently lapse when the
/// thread dies (power.md §4.1). Only used by the fallback path.
/// </summary>
internal static class ExecutionStateInvoker
{
    private static readonly BlockingCollection<Action> Queue = new(new ConcurrentQueue<Action>());

    // Static field initializer guarantees the worker starts before the first Invoke.
    private static readonly Thread Worker = CreateWorker();

    private static Thread CreateWorker()
    {
        var thread = new Thread(Run)
        {
            IsBackground = true,
            Name = "AQB.ExecutionState",
        };
        thread.Start();
        return thread;
    }

    private static void Run()
    {
        foreach (var action in Queue.GetConsumingEnumerable())
        {
            try
            {
                action();
            }
            catch
            {
                // Never kill the worker; a failed flag change just retries next update.
            }
        }
    }

    public static void Invoke(Action action) => Queue.Add(action);
}

/// <summary>
/// Real OS implementation of <see cref="IPowerRequest"/>. Prefers the Power Request
/// API (PowerCreateRequest / PowerSetRequest / PowerCloseRequest) because handles are
/// process-owned (crash-safe) and show up in <c>powercfg /requests</c> with the reason
/// string. If request creation fails it falls back to SetThreadExecutionState on a
/// dedicated thread. The reason string matches the macOS assertion reason.
/// </summary>
public sealed class NativePowerRequest : IPowerRequest
{
    public const string DefaultReason = "AI Quota Bar: an AI task is working";

    private static readonly IntPtr InvalidHandle = new(-1);

    private readonly object _gate = new();
    private readonly string _reason;

    private IntPtr _handle;
    private bool _useFallback;
    private bool _wantSystem;
    private bool _wantDisplay;
    private bool _systemSet;
    private bool _displaySet;
    private bool _fallbackActive;
    private bool _disposed;

    public NativePowerRequest(string? reason = null)
    {
        _reason = string.IsNullOrWhiteSpace(reason) ? DefaultReason : reason;
    }

    /// <summary>Handle of the active Power Request (IntPtr.Zero when not using the API). Exposed for the smoke test.</summary>
    public IntPtr LastPowerRequestHandle
    {
        get
        {
            lock (_gate)
            {
                return _handle;
            }
        }
    }

    public bool IsUsingPowerRequestApi
    {
        get
        {
            lock (_gate)
            {
                return _handle != IntPtr.Zero;
            }
        }
    }

    public bool IsHolding
    {
        get
        {
            lock (_gate)
            {
                return _wantSystem || _wantDisplay;
            }
        }
    }

    public void Acquire(bool keepDisplayAwake)
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            EnsureGrantLocked();
            _wantSystem = true;
            _wantDisplay = keepDisplayAwake;
            ApplyLocked();
        }
    }

    public void SetDisplayRequired(bool required)
    {
        lock (_gate)
        {
            if (_disposed || _wantDisplay == required)
            {
                return;
            }

            _wantDisplay = required;
            if (!_wantSystem && !required)
            {
                // Nothing left to hold; fall through to Apply which clears everything.
            }

            ApplyLocked();
        }
    }

    public void Release()
    {
        lock (_gate)
        {
            _wantSystem = false;
            _wantDisplay = false;
            if (_handle != IntPtr.Zero)
            {
                // Power request handles are released with CloseHandle (closing the
                // handle clears both SYSTEM_REQUIRED and DISPLAY_REQUIRED requests).
                NativeMethods.CloseHandle(_handle);
                _handle = IntPtr.Zero;
                _systemSet = false;
                _displaySet = false;
            }

            ApplyLocked();
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            Release();
        }
    }

    private void EnsureGrantLocked()
    {
        if (!OperatingSystem.IsWindows() || _handle != IntPtr.Zero || _useFallback)
        {
            return;
        }

        var context = new NativeMethods.PowerRequestContext
        {
            Version = NativeMethods.PowerRequestContextVersion,
            Flags = NativeMethods.PowerRequestContextSimple,
            Reason = _reason,
        };
        var handle = NativeMethods.PowerCreateRequest(ref context);
        if (handle != IntPtr.Zero && handle != InvalidHandle)
        {
            _handle = handle;
        }
        else
        {
            // Power Request API unavailable (old OS / restricted session): degrade to
            // SetThreadExecutionState instead of failing protection entirely.
            _useFallback = true;
        }
    }

    private void ApplyLocked()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        if (_handle != IntPtr.Zero)
        {
            if (_wantSystem && !_systemSet)
            {
                if (NativeMethods.PowerSetRequest(_handle, NativeMethods.PowerRequestType.PowerRequestSystemRequired))
                {
                    _systemSet = true;
                }
            }
            else if (!_wantSystem && _systemSet)
            {
                NativeMethods.PowerClearRequest(_handle, NativeMethods.PowerRequestType.PowerRequestSystemRequired);
                _systemSet = false;
            }

            if (_wantDisplay && !_displaySet)
            {
                if (NativeMethods.PowerSetRequest(_handle, NativeMethods.PowerRequestType.PowerRequestDisplayRequired))
                {
                    _displaySet = true;
                }
            }
            else if (!_wantDisplay && _displaySet)
            {
                NativeMethods.PowerClearRequest(_handle, NativeMethods.PowerRequestType.PowerRequestDisplayRequired);
                _displaySet = false;
            }

            return;
        }

        // Fallback path: ES_CONTINUOUS flags on the dedicated invoker thread.
        if (_wantSystem || _wantDisplay)
        {
            var flags = NativeMethods.ES_CONTINUOUS;
            if (_wantSystem)
            {
                flags |= NativeMethods.ES_SYSTEM_REQUIRED;
            }

            if (_wantDisplay)
            {
                flags |= NativeMethods.ES_DISPLAY_REQUIRED;
            }

            ExecutionStateInvoker.Invoke(() => NativeMethods.SetThreadExecutionState(flags));
            _fallbackActive = true;
        }
        else if (_fallbackActive)
        {
            // ES_CONTINUOUS alone clears the previously set requirement bits.
            ExecutionStateInvoker.Invoke(() => NativeMethods.SetThreadExecutionState(NativeMethods.ES_CONTINUOUS));
            _fallbackActive = false;
        }
    }
}
