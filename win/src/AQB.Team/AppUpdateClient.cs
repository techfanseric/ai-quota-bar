using System.Text.Json;
using System.Text.Json.Nodes;
using AQB.Core;

namespace AQB.Team;

public sealed record AppUpdateInfo(
    string Version,
    string? Tag,
    string? ReleaseUrl,
    string? DownloadUrl,
    DateTimeOffset? PublishedAt);

/// <summary>
/// Checks the worker's /v1/app-update proxy (GitHub latest release, 5-minute worker cache).
/// The caller compares against the running assembly version and notifies once per version.
/// </summary>
public sealed class AppUpdateClient : IDisposable
{
    private readonly HttpClient _http;

    public AppUpdateClient(string? endpointUrl = null, HttpMessageHandler? handler = null)
    {
        var baseUrl = (endpointUrl ?? CodexWatchClient.DefaultEndpointUrl).TrimEnd('/');
        BaseUrl = baseUrl;
        _http = handler is null
            ? new HttpClient { Timeout = TimeSpan.FromSeconds(15) }
            : new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(15) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("AIQuotaBar-Win");
    }

    public string BaseUrl { get; }

    /// <summary>Fetches the latest release info; null when the check fails (never throws).</summary>
    public async Task<AppUpdateInfo?> CheckAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var response = await _http.GetAsync(BaseUrl + "/v1/app-update", cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var payload = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            if (payload is null || !payload.GetBool("ok"))
            {
                return null;
            }

            var version = payload.GetString("version");
            if (string.IsNullOrEmpty(version))
            {
                return null;
            }

            return new AppUpdateInfo(
                version,
                payload.GetString("tag"),
                payload.GetString("release_url"),
                payload.GetString("download_url"),
                CodexWatchClient.ParseDate(payload.GetString("published_at")));
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            return null;
        }
    }

    /// <summary>Loose semantic-ish compare: "v1.27.0" &gt; "1.26.9" &gt; "1.26" etc. Unparsable → not newer.</summary>
    public static bool IsNewer(string candidate, string current)
    {
        if (TryParse(candidate, out var c) && TryParse(current, out var cur))
        {
            return c.Major != cur.Major ? c.Major > cur.Major
                : c.Minor != cur.Minor ? c.Minor > cur.Minor
                : c.Patch > cur.Patch;
        }

        return false;
    }

    private static bool TryParse(string version, out (int Major, int Minor, int Patch) parsed)
    {
        var text = version.Trim().TrimStart('v', 'V');
        var parts = text.Split('.');
        var numbers = new int[3];
        for (var i = 0; i < 3; i++)
        {
            if (i < parts.Length)
            {
                var digits = new string(parts[i].TakeWhile(char.IsDigit).ToArray());
                if (!int.TryParse(digits, out numbers[i]))
                {
                    parsed = default;
                    return false;
                }
            }
        }

        parsed = (numbers[0], numbers[1], numbers[2]);
        return true;
    }

    public void Dispose() => _http.Dispose();
}
