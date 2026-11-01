using System.Runtime.CompilerServices;
using System.Windows.Forms;

namespace AQB.App.Tests;

internal static class DpiTestEnvironment
{
    // Match ApplicationConfiguration.Initialize before any test creates a handle.
    // Mixing unaware and per-monitor windows corrupts WinForms' process-wide metric caches.
    [ModuleInitializer]
    internal static void Initialize() => Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
}
