using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Text.Json;
using AQB.Core;

namespace AQB.Power;

public enum ClosedLidStatus
{
    /// <summary>Not requested or fully restored.</summary>
    Inactive = 0,

    /// <summary>Enabled but the process lacks administrator rights to change the lid action.</summary>
    RequiresAdministrator = 1,

    /// <summary>Lid action rewritten to "do nothing"; originals saved for restore.</summary>
    Active = 2,

    /// <summary>Restored after use (transient observation state).</summary>
    Restored = 3,

    /// <summary>Read/write failed; nothing is being held.</summary>
    Failed = 4,
}

/// <summary>Power-scheme seam so the controller is testable without touching the OS.</summary>
public interface IClosedLidPowerScheme : IDisposable
{
    bool IsAdministrator { get; }

    /// <summary>Current LIDACTION index (0 nothing, 1 sleep, 2 hibernate, 3 shutdown). Null when unreadable.</summary>
    int? ReadLidAction(bool acPower);

    bool WriteLidAction(bool acPower, int value);

    /// <summary>Applies pending scheme changes (powercfg /SETACTIVE equivalent).</summary>
    bool Apply();
}

/// <summary>
/// Closed-lid mode for Windows: rewrites the current scheme's LIDACTION (AC+DC) to "do nothing"
/// while AI tasks run and restores the exact previous values afterwards — the counterpart of
/// the macOS `pmset -a disablesleep` helper, without needing a privileged service because the
/// writes happen inside the (already elevated) app process. A marker file survives crashes:
/// the next launch restores any values a dead process left behind.
/// </summary>
public sealed class ClosedLidModeController : IDisposable
{
    private readonly IClosedLidPowerScheme _scheme;
    private readonly string _markerPath;
    private readonly object _gate = new();
    private bool _holding;
    private int? _originalAc;
    private int? _originalDc;

    public ClosedLidModeController(IClosedLidPowerScheme? scheme = null, string? markerPath = null)
    {
        _scheme = scheme ?? new PowerCfgClosedLidScheme();
        _markerPath = markerPath ?? DefaultMarkerPath();
        // Crash self-heal: restore values a previous (killed) process left changed.
        RestoreFromMarkerIfPresent(_scheme, _markerPath);
    }

    public static string DefaultMarkerPath()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "AIQuotaBar", "closed-lid-state.json");

    public ClosedLidStatus Status { get; private set; } = ClosedLidStatus.Inactive;

    public string? FailureReason { get; private set; }

    /// <summary>Re-enables after a restore (Status back to a clean Inactive).</summary>
    public void Reset() => Status = ClosedLidStatus.Inactive;

    public bool Acquire()
    {
        lock (_gate)
        {
            if (_holding)
            {
                return Status == ClosedLidStatus.Active;
            }

            if (!_scheme.IsAdministrator)
            {
                Status = ClosedLidStatus.RequiresAdministrator;
                return false;
            }

            var ac = _scheme.ReadLidAction(true);
            var dc = _scheme.ReadLidAction(false);
            if (ac is null || dc is null)
            {
                Status = ClosedLidStatus.Failed;
                FailureReason = "unreadable lid action";
                return false;
            }

            if (ac != 0 && !_scheme.WriteLidAction(true, 0))
            {
                Status = ClosedLidStatus.Failed;
                FailureReason = "write failed (ac)";
                return false;
            }

            if (dc != 0 && !_scheme.WriteLidAction(false, 0))
            {
                // Put AC back before reporting failure.
                if (ac != 0)
                {
                    _scheme.WriteLidAction(true, ac.Value);
                }

                Status = ClosedLidStatus.Failed;
                FailureReason = "write failed (dc)";
                return false;
            }

            if (!_scheme.Apply())
            {
                RestoreLocked();
                Status = ClosedLidStatus.Failed;
                FailureReason = "apply failed";
                return false;
            }

            _originalAc = ac;
            _originalDc = dc;
            _holding = true;
            WriteMarker(ac.Value, dc.Value);
            Status = ClosedLidStatus.Active;
            FailureReason = null;
            return true;
        }
    }

    public bool Restore()
    {
        lock (_gate)
        {
            if (!_holding)
            {
                return true;
            }

            return RestoreLocked();
        }
    }

    private bool RestoreLocked()
    {
        var restored = true;
        if (_originalAc is { } ac && !_scheme.WriteLidAction(true, ac))
        {
            restored = false;
        }

        if (_originalDc is { } dc && !_scheme.WriteLidAction(false, dc))
        {
            restored = false;
        }

        if (restored && !_scheme.Apply())
        {
            restored = false;
        }

        _holding = false;
        _originalAc = null;
        _originalDc = null;
        TryDeleteMarker();
        Status = restored ? ClosedLidStatus.Restored : ClosedLidStatus.Failed;
        if (!restored)
        {
            FailureReason = "restore failed — originals kept in marker";
        }

        return restored;
    }

    private void WriteMarker(int ac, int dc)
    {
        try
        {
            Json.AtomicWrite(_markerPath, JsonSerializer.Serialize(new
            {
                version = 1,
                lidActionAc = ac,
                lidActionDc = dc,
                acquiredAtUtc = TimeText.FixedIso(DateTimeOffset.UtcNow),
            }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The in-memory originals still restore on the normal path.
        }
    }

    private void TryDeleteMarker()
    {
        try
        {
            if (File.Exists(_markerPath))
            {
                File.Delete(_markerPath);
            }
        }
        catch (IOException)
        {
        }
    }

    /// <summary>Startup self-heal: a marker without a live holder means a crashed process.</summary>
    internal static bool RestoreFromMarkerIfPresent(IClosedLidPowerScheme scheme, string markerPath)
    {
        try
        {
            if (!File.Exists(markerPath))
            {
                return false;
            }

            JsonNode payload;
            try
            {
                payload = JsonNode.Parse(File.ReadAllText(markerPath))!;
            }
            catch (JsonException)
            {
                // Corrupt marker: nothing to restore from, and retrying every launch is pointless.
                File.Delete(markerPath);
                return false;
            }

            if (payload is null)
            {
                File.Delete(markerPath);
                return false;
            }

            var ac = (int)payload.GetLong("lidActionAc", -1);
            var dc = (int)payload.GetLong("lidActionDc", -1);
            var restored = true;
            if (ac is >= 0 and <= 3 && !scheme.WriteLidAction(true, ac))
            {
                restored = false;
            }

            if (dc is >= 0 and <= 3 && !scheme.WriteLidAction(false, dc))
            {
                restored = false;
            }

            if (restored && !scheme.Apply())
            {
                restored = false;
            }

            if (restored)
            {
                File.Delete(markerPath);
            }

            return restored;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public void Dispose() => Restore();
}

/// <summary>Real implementation over the Power* APIs (locale-independent, unlike parsing powercfg output).</summary>
public sealed class PowerCfgClosedLidScheme : IClosedLidPowerScheme
{
    private static readonly Guid SubButtons = new("4f971e89-eebd-4455-a8de-9e59040e7347");
    private static readonly Guid LidAction = new("5ca83367-6e45-459f-a27b-476b1d01c936");

    public bool IsAdministrator
    {
        get
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            return new System.Security.Principal.WindowsPrincipal(identity)
                .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        }
    }

    public int? ReadLidAction(bool acPower)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        if (ActiveSchemeGuid() is not { } scheme)
        {
            return null;
        }

        var subgroup = SubButtons;
        var setting = LidAction;
        var ok = acPower
            ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out var value)
            : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value);
        return ok == 0 && value is >= 0 and <= 3 ? (int)value : null;
    }

    public bool WriteLidAction(bool acPower, int value)
    {
        if (!OperatingSystem.IsWindows() || value is < 0 or > 3)
        {
            return false;
        }

        if (ActiveSchemeGuid() is not { } scheme)
        {
            return false;
        }

        var subgroup = SubButtons;
        var setting = LidAction;
        return acPower
            ? PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, (uint)value) == 0
            : PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, (uint)value) == 0;
    }

    public bool Apply()
    {
        if (!OperatingSystem.IsWindows() || ActiveSchemeGuid() is not { } scheme)
        {
            return false;
        }

        return PowerSetActiveScheme(IntPtr.Zero, ref scheme) == 0;
    }

    public void Dispose()
    {
    }

    private static Guid? ActiveSchemeGuid()
    {
        if (PowerGetActiveScheme(IntPtr.Zero, out var pointer) != 0)
        {
            return null;
        }

        try
        {
            return Marshal.PtrToStructure<Guid>(pointer);
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerGetActiveScheme(IntPtr rootPowerKey, out IntPtr activePolicyGuid);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerReadACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupOfPowerSettingsGuid, ref Guid powerSettingGuid, out uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerReadDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupOfPowerSettingsGuid, ref Guid powerSettingGuid, out uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerWriteACValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupOfPowerSettingsGuid, ref Guid powerSettingGuid, uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerWriteDCValueIndex(IntPtr rootPowerKey, ref Guid schemeGuid, ref Guid subGroupOfPowerSettingsGuid, ref Guid powerSettingGuid, uint valueIndex);

    [DllImport("powrprof.dll", SetLastError = true)]
    private static extern uint PowerSetActiveScheme(IntPtr rootPowerKey, ref Guid schemeGuid);
}
