using System.Text.Json;
using AQB.Core;

namespace AQB.Settings;

/// <summary>
/// Strongly-typed settings persisted to %APPDATA%\AIQuotaBar\settings.json — the Windows
/// counterpart of the macOS UserDefaults set (same defaults where applicable).
/// Modules own their extra settings as JSON sections via <see cref="GetSection{T}"/>.
/// </summary>
public sealed class AppSettings
{
    public string MenuBarAppearance { get; set; } = "detailedText"; // detailedText | compactRing

    public string MenuBarRingDisplayMode { get; set; } = "automatic"; // automatic | all

    public List<string> MenuBarRingSelectedProviders { get; set; } = new() { "codex", "kimi", "glm", "minimax" };

    public string MenuBarRingQuotaWindow { get; set; } = "current"; // current | weekly | total

    public int UsageRefreshIntervalSeconds { get; set; } = 600;

    public List<string> PausedUsageProviders { get; set; } = new();

    public bool FollowRunningApps { get; set; }

    /// <summary>Control-center sections the user collapsed (persisted, macOS parity).</summary>
    public List<string> CollapsedSections { get; set; } = new();

    public List<string> CustomProviderOrder { get; set; } = new() { "codex", "kimi", "glm", "minimax" };

    // Power / sleep protection (macOS: codexSleepProtection*)
    public bool CodexSleepProtectionEnabled { get; set; } = true;

    public bool CodexSleepProtectionKeepDisplayAwake { get; set; }

    public bool CodexSleepProtectionPreventScreenSaver { get; set; }

    public bool CodexSleepProtectionAllowClosedLid { get; set; }

    // Clash
    public string ClashRouteFilterText { get; set; } = "";

    public bool ClashAutoRecoveryEnabled { get; set; }

    public bool ClashAutoRecoveryUseRegex { get; set; }

    // Mobile dashboard (macOS: mobileDashboard*)
    public bool MobileDashboardEnabled { get; set; }

    public int MobileDashboardPort { get; set; } = 18765;

    public bool MobileDashboardRequiresPairingCode { get; set; }

    public bool MobileDashboardMaskAccountNames { get; set; } = true;

    // Cloud sync / team
    public bool CloudSyncEnabled { get; set; }

    public string? CloudSyncDeviceId { get; set; }

    public string CloudflareEndpointUrl { get; set; } = "https://ai-quota-bar.pages.dev";

    // CodexWatch (share own quota by email / watch others')
    public bool CodexWatchSharingEnabled { get; set; }

    /// <summary>Local account emails ticked for sharing (macOS codexWatch.shared.v1).</summary>
    public List<string> CodexWatchSharedEmails { get; set; } = new();

    /// <summary>Emails this machine watches (macOS codexWatch.watched.v1).</summary>
    public List<string> CodexWatchWatchedEmails { get; set; } = new();

    // App update (worker /v1/app-update proxy)
    public bool AppUpdateCheckEnabled { get; set; } = true;

    public string? LastAppUpdateCheckAt { get; set; }

    public string? LastNotifiedUpdateVersion { get; set; }

    // Local usage reporting
    public bool LocalUsageReporting { get; set; }

    public Dictionary<string, JsonElement> Sections { get; set; } = new();

    [System.Text.Json.Serialization.JsonIgnore]
    public string StorePath { get; private set; } = DefaultStorePath();

    public static string DefaultStorePath()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "AIQuotaBar");
        return Path.Combine(root, "settings.json");
    }

    public static AppSettings Load(string? path = null)
    {
        path ??= DefaultStorePath();
        var settings = new AppSettings { StorePath = path };
        try
        {
            if (File.Exists(path))
            {
                var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Json.SnakeCase);
                if (loaded is not null)
                {
                    loaded.StorePath = path;
                    return loaded;
                }
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // Corrupt settings fall back to defaults; the file is rewritten on next save.
        }

        return settings;
    }

    public void Save()
    {
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions(Json.SnakeCase) { WriteIndented = true });
        Json.AtomicWrite(StorePath, json);
    }

    /// <summary>Binds a module section, falling back to the module's default instance.</summary>
    public T GetSection<T>(string key) where T : new()
    {
        if (Sections.TryGetValue(key, out var element))
        {
            try
            {
                return element.Deserialize<T>(Json.SnakeCase) ?? new T();
            }
            catch (JsonException)
            {
                return new T();
            }
        }

        return new T();
    }

    public void SetSection(string key, object value)
    {
        Sections[key] = JsonSerializer.SerializeToElement(value, Json.SnakeCase);
    }
}
