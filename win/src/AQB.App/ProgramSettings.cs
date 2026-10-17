using AQB.Settings;

namespace AQB.App;

/// <summary>Process-wide settings handle for UI code paths that don't carry it explicitly.</summary>
internal static class ProgramSettings
{
    public static AppSettings Current { get; set; } = new();
}
