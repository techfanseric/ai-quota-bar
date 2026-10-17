using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace AQB.Power;

/// <summary>
/// P/Invoke surface over kernel32's power APIs. Windows-only declarations;
/// every call site guards with <c>OperatingSystem.IsWindows()</c> so the
/// library still runs (no-op) on other platforms.
/// </summary>
[SupportedOSPlatform("windows")]
internal static class NativeMethods
{
    // ---- SetThreadExecutionState ----

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED = 0x00000002;

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint SetThreadExecutionState(uint esFlags);

    // ---- Power Request API (visible in `powercfg /requests`, crash-safe) ----

    public const uint PowerRequestContextVersion = 0;
    public const uint PowerRequestContextSimple = 1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct PowerRequestContext
    {
        public uint Version;
        public uint Flags;
        public string Reason;
    }

    internal enum PowerRequestType
    {
        PowerRequestSystemRequired = 0,
        PowerRequestDisplayRequired = 1,
        PowerRequestAwayModeRequired = 2,
        PowerRequestExecutionRequired = 3,
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern IntPtr PowerCreateRequest(ref PowerRequestContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool PowerSetRequest(IntPtr powerRequest, PowerRequestType requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool PowerClearRequest(IntPtr powerRequest, PowerRequestType requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CloseHandle(IntPtr handle);

    // ---- Battery status (avoids switching the project to net8.0-windows) ----

    [StructLayout(LayoutKind.Sequential)]
    internal struct SystemPowerStatus
    {
        public byte AcLineStatus;        // 0 = offline, 1 = online, 255 = unknown
        public byte BatteryFlag;         // 128 = no system battery, 255 = unknown
        public byte BatteryLifePercent;  // 0-100, 255 = unknown
        public byte Reserved1;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool GetSystemPowerStatus(ref SystemPowerStatus powerStatus);
}
