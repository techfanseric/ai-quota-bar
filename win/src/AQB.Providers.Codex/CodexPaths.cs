namespace AQB.Providers.Codex;

/// <summary>
/// Resolves the Codex home directory. Precedence: constructor override &gt; CODEX_HOME env var &gt;
/// %USERPROFILE%\.codex (mirrors the macOS rule: CODEX_HOME wins over ~/.codex).
/// </summary>
public static class CodexPaths
{
    public static string ResolveHome(string? codexHome = null)
    {
        if (!string.IsNullOrWhiteSpace(codexHome))
        {
            return codexHome;
        }

        var fromEnv = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (!string.IsNullOrWhiteSpace(fromEnv))
        {
            return fromEnv;
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex");
    }
}
