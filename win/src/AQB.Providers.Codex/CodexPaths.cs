namespace AQB.Providers.Codex;

using System.Text.RegularExpressions;

/// <summary>
/// Resolves the Codex home directory. Precedence: constructor override &gt; CODEX_HOME env var &gt;
/// %USERPROFILE%\.codex (mirrors the macOS rule: CODEX_HOME wins over ~/.codex).
/// </summary>
public static class CodexPaths
{
    private static readonly Regex ChatGptBaseUrlAssignment =
        new(@"^\s*chatgpt_base_url\s*=\s*""(?<url>[^""]+)""", RegexOptions.Compiled);

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

    /// <summary>
    /// Reads a top-level chatgpt_base_url string assignment from ~/.codex/config.toml (only
    /// before the first [section] header), mirroring the macOS fetcher's base URL override.
    /// Null when the file or the key is absent.
    /// </summary>
    public static string? ReadChatgptBaseUrl(string? codexHome = null)
    {
        try
        {
            var path = Path.Combine(ResolveHome(codexHome), "config.toml");
            if (!File.Exists(path))
            {
                return null;
            }

            foreach (var line in File.ReadLines(path))
            {
                if (line.TrimStart().StartsWith("[", StringComparison.Ordinal))
                {
                    return null; // only the top-level table counts
                }

                var match = ChatGptBaseUrlAssignment.Match(line);
                if (match.Success)
                {
                    return match.Groups["url"].Value;
                }
            }

            return null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
