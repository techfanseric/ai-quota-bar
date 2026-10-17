using System.Text;
using System.Text.Json;

namespace AQB.Clash;

/// <summary>Reason strings surfaced through <see cref="ClashEndpoint.DisabledReason"/>.</summary>
public static class ClashDiscoveryReasons
{
    public const string ExternalControllerDisabled = "externalControllerDisabled";
    public const string ConfigurationNotFound = "configurationNotFound";
    public const string UnsafeControllerHost = "unsafeControllerHost";
    public const string InvalidControllerAddress = "invalidControllerAddress";
}

/// <summary>
/// Result of controller discovery. A usable endpoint has <see cref="DisabledReason"/> == null
/// and a non-empty <see cref="BaseUrl"/>; otherwise the reason describes why not.
/// </summary>
public sealed record ClashEndpoint
{
    public required string BaseUrl { get; init; }

    public string Secret { get; init; } = "";

    /// <summary>Absolute path of the config file the endpoint was read from.</summary>
    public required string SourceConfigPath { get; init; }

    /// <summary>Human readable client name, e.g. "Clash Verge Rev".</summary>
    public string ClientName { get; init; } = "";

    /// <summary>null on success; otherwise one of <see cref="ClashDiscoveryReasons"/> (host detail appended after ':').</summary>
    public string? DisabledReason { get; init; }

    public bool IsUsable => DisabledReason is null && BaseUrl.Length > 0;

    public Uri BaseUri => new(BaseUrl, UriKind.Absolute);
}

/// <summary>
/// Hand written parser for top level scalar YAML keys only. Nested blocks are naturally
/// ignored because their lines start with whitespace. No YAML dependency.
/// </summary>
public static class TopLevelYaml
{
    /// <summary>Parses top level "key: value" scalars; later duplicates overwrite earlier ones.</summary>
    public static Dictionary<string, string> Parse(string contents)
    {
        var result = new Dictionary<string, string>();
        if (string.IsNullOrEmpty(contents))
        {
            return result;
        }

        var start = 0;
        while (start <= contents.Length)
        {
            var end = contents.IndexOf('\n', start);
            var line = end < 0 ? contents[start..] : contents[start..end];
            start = end < 0 ? contents.Length + 1 : end + 1;
            ParseLine(line, result);
        }

        return result;
    }

    private static void ParseLine(string line, Dictionary<string, string> result)
    {
        if (line.Length == 0)
        {
            return;
        }

        var first = line[0];
        if (char.IsWhiteSpace(first) || first == '#')
        {
            return;
        }

        var separator = line.IndexOf(':');
        if (separator < 0)
        {
            return;
        }

        var key = line[..separator].Trim();
        if (key.Length == 0)
        {
            return;
        }

        result[key] = DecodeScalar(line[(separator + 1)..]);
    }

    /// <summary>Decodes a scalar value: single/double quoted strings, or plain text with " #" comments stripped.</summary>
    public static string DecodeScalar(string rawValue)
    {
        var trimmed = rawValue.Trim();
        if (trimmed.Length == 0)
        {
            return "";
        }

        if (trimmed[0] == '\'')
        {
            var closing = ClosingSingleQuote(trimmed);
            if (closing < 0)
            {
                return trimmed[1..];
            }

            return trimmed[1..closing].Replace("''", "'");
        }

        if (trimmed[0] == '"')
        {
            // Prefer a full JSON string decode (handles \" escapes); fall back to the
            // text before the closing double quote using an escape state machine.
            try
            {
                return JsonSerializer.Deserialize<string>(trimmed) ?? "";
            }
            catch (JsonException)
            {
                var closing = ClosingDoubleQuote(trimmed);
                if (closing > 0)
                {
                    return trimmed[1..closing];
                }
            }
        }

        var comment = trimmed.IndexOf(" #", StringComparison.Ordinal);
        if (comment >= 0)
        {
            return trimmed[..comment].Trim();
        }

        return trimmed;
    }

    private static int ClosingSingleQuote(string value)
    {
        var index = 1;
        while (index < value.Length)
        {
            if (value[index] != '\'')
            {
                index++;
                continue;
            }

            if (index + 1 < value.Length && value[index + 1] == '\'')
            {
                index += 2;
                continue;
            }

            return index;
        }

        return -1;
    }

    private static int ClosingDoubleQuote(string value)
    {
        var index = 1;
        var isEscaped = false;
        while (index < value.Length)
        {
            var character = value[index];
            if (character == '"' && !isEscaped)
            {
                return index;
            }

            if (character == '\\')
            {
                isEscaped = !isEscaped;
            }
            else
            {
                isEscaped = false;
            }

            index++;
        }

        return -1;
    }
}

/// <summary>
/// Reads candidate Clash configs (Windows paths first, macOS ~/.config paths kept for
/// compatibility) and extracts the external controller endpoint. Read only, no port scanning.
/// </summary>
public static class ClashControllerDiscovery
{
    /// <summary>
    /// Finds the first candidate whose config exists and yields a valid loopback
    /// external-controller. Returns an endpoint carrying a <see cref="ClashEndpoint.DisabledReason"/>
    /// when no usable controller can be produced.
    /// </summary>
    public static ClashEndpoint? FindEndpoint(string? appDataDirectory = null, string? homeDirectory = null)
        => FindEndpoint(GetCandidateConfigPaths(appDataDirectory, homeDirectory));

    /// <summary>Candidate config paths in priority order: Clash Verge Rev (Windows), Mihomo, Clash.</summary>
    public static IReadOnlyList<(string Path, string ClientName)> GetCandidateConfigPaths(
        string? appDataDirectory = null,
        string? homeDirectory = null)
    {
        var appData = appDataDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var home = homeDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new[]
        {
            (Path.Combine(appData, "io.github.clash-verge-rev.clash-verge-rev", "config.yaml"), "Clash Verge Rev"),
            (Path.Combine(home, ".config", "mihomo", "config.yaml"), "Mihomo"),
            (Path.Combine(home, ".config", "clash", "config.yaml"), "Clash"),
        };
    }

    internal static ClashEndpoint? FindEndpoint(IReadOnlyList<(string Path, string ClientName)> candidates)
    {
        var foundConfiguration = false;

        foreach (var (path, clientName) in candidates)
        {
            string contents;
            try
            {
                if (!File.Exists(path))
                {
                    continue;
                }

                foundConfiguration = true;
                contents = File.ReadAllText(path, new UTF8Encoding(false));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            var values = TopLevelYaml.Parse(contents);
            if (!values.TryGetValue("external-controller", out var rawController) ||
                string.IsNullOrWhiteSpace(rawController))
            {
                // File exists but the key is missing: keep looking at later candidates.
                continue;
            }

            if (!TryNormalizeControllerUrl(rawController, out var baseUrl, out var rejection))
            {
                // An existing config with a present but unusable address is terminal,
                // matching the macOS behaviour of propagating the error immediately.
                return new ClashEndpoint
                {
                    BaseUrl = "",
                    Secret = values.TryGetValue("secret", out var secret) ? secret : "",
                    SourceConfigPath = path,
                    ClientName = clientName,
                    DisabledReason = rejection,
                };
            }

            return new ClashEndpoint
            {
                BaseUrl = baseUrl,
                Secret = values.TryGetValue("secret", out var secretValue) ? secretValue : "",
                SourceConfigPath = path,
                ClientName = clientName,
                DisabledReason = null,
            };
        }

        return new ClashEndpoint
        {
            BaseUrl = "",
            Secret = "",
            SourceConfigPath = "",
            ClientName = "",
            DisabledReason = foundConfiguration
                ? ClashDiscoveryReasons.ExternalControllerDisabled
                : ClashDiscoveryReasons.ConfigurationNotFound,
        };
    }

    /// <summary>
    /// Normalizes a raw external-controller address. Wildcard / empty-host bindings are
    /// rewritten to 127.0.0.1; only loopback hosts (127.0.0.1, localhost, ::1) are accepted.
    /// </summary>
    public static bool TryNormalizeControllerUrl(string rawAddress, out string baseUrl, out string? rejectionReason)
    {
        var address = rawAddress.Trim();
        if (address.StartsWith(":", StringComparison.Ordinal))
        {
            address = "127.0.0.1" + address;
        }
        else if (address.StartsWith("*:", StringComparison.Ordinal))
        {
            address = "127.0.0.1:" + address[2..];
        }
        else if (address.StartsWith("0.0.0.0:", StringComparison.Ordinal))
        {
            address = "127.0.0.1:" + address["0.0.0.0:".Length..];
        }
        else if (address.StartsWith("[::]:", StringComparison.Ordinal))
        {
            address = "127.0.0.1:" + address["[::]:".Length..];
        }

        if (!address.Contains("://", StringComparison.Ordinal))
        {
            address = "http://" + address;
        }

        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)
            || uri.Host.Length == 0
            || !uri.IsDefaultPort && uri.Port <= 0)
        {
            baseUrl = "";
            rejectionReason = ClashDiscoveryReasons.InvalidControllerAddress + ":" + rawAddress.Trim();
            return false;
        }

        var port = uri.IsDefaultPort ? (uri.Scheme == "http" ? 80 : 443) : uri.Port;
        if (port <= 0)
        {
            baseUrl = "";
            rejectionReason = ClashDiscoveryReasons.InvalidControllerAddress + ":" + rawAddress.Trim();
            return false;
        }

        // .NET reports IPv6 hosts with brackets ("[::1]"); strip them for the loopback check.
        var rawHost = uri.Host;
        var host = rawHost.StartsWith('[') && rawHost.EndsWith(']')
            ? rawHost[1..^1]
            : rawHost;
        host = host.ToLowerInvariant();
        if (host is not ("127.0.0.1" or "localhost" or "::1"))
        {
            baseUrl = "";
            rejectionReason = ClashDiscoveryReasons.UnsafeControllerHost + ":" + host;
            return false;
        }

        var hostPart = host.Contains(':') ? "[" + host + "]" : host;
        baseUrl = uri.Scheme.ToLowerInvariant() + "://" + hostPart + ":" + port;
        rejectionReason = null;
        return true;
    }
}
