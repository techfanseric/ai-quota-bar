namespace AQB.CodexTasks;

/// <summary>Shared path conventions for the Codex task-detection stack.</summary>
public static class CodexPaths
{
    /// <summary>CODEX_HOME environment variable when set, otherwise %USERPROFILE%\.codex.</summary>
    public static string DefaultHome()
    {
        var environmentHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (!string.IsNullOrWhiteSpace(environmentHome))
        {
            return environmentHome;
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex");
    }

    /// <summary>%LOCALAPPDATA%\AIQuotaBar — the app's own writable state directory.</summary>
    public static string AppDataDirectory()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AIQuotaBar");
    }
}
