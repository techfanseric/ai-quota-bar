using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AQB.Providers.Kimi;

/// <summary>
/// Reads the Kimi desktop app login token (spec §1.2, task A.4).
///
/// Two candidate store locations are probed on every platform:
///  - Windows: %APPDATA%\kimi-desktop\bridge-store\token-store.json
///  - macOS layout: ~/Library/Application Support/kimi-desktop/bridge-store/token-store.json
///
/// The store is either plain JSON ({"origin", "tokens":{"access_token"}}) or an Electron
/// safeStorage envelope {"encryption":"safeStorage.v1","data":"&lt;base64&gt;"}. On Windows Electron
/// safeStorage uses DPAPI (CryptProtectData) — unlike macOS there is no v10/saltysalt/PBKDF2
/// layer — so the envelope is decrypted with ProtectedData.Unprotect (optionally skipping a
/// "v10" prefix some builds prepend). Any failure returns null instead of throwing; only
/// tokens.access_token is used (refresh_token is ignored).
/// </summary>
public sealed class KimiDesktopSessionReader
{
    private readonly string _windowsStorePath;
    private readonly string _macStorePath;

    public KimiDesktopSessionReader(string? windowsStorePath = null, string? macStorePath = null)
    {
        _windowsStorePath = windowsStorePath ?? DefaultWindowsStorePath();
        _macStorePath = macStorePath ?? DefaultMacStorePath();
    }

    public static string DefaultWindowsStorePath()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "kimi-desktop", "bridge-store", "token-store.json");

    public static string DefaultMacStorePath()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "kimi-desktop", "bridge-store", "token-store.json");

    /// <summary>Presence probe: does either candidate store file exist (never decrypts)?</summary>
    public bool IsPresent() => File.Exists(_windowsStorePath) || File.Exists(_macStorePath);

    /// <summary>Best-effort load; returns null on any failure (missing file, bad JSON, undecryptable envelope).</summary>
    public KimiWebCredential? TryLoad()
    {
        foreach (var path in new[] { _windowsStorePath, _macStorePath })
        {
            string text;
            try
            {
                if (!File.Exists(path))
                {
                    continue;
                }

                text = File.ReadAllText(path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            var credential = TryParseStore(text);
            if (credential is not null)
            {
                return credential;
            }
        }

        return null;
    }

    internal static KimiWebCredential? TryParseStore(string text)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }

        if (root is null)
        {
            return null;
        }

        // Plain store: {"origin": "...", "tokens": {"access_token": "..."}}.
        var plain = CredentialFromNode(root);
        if (plain is not null)
        {
            return plain;
        }

        // Encrypted envelope: {"encryption": "safeStorage.v1", "data": "<base64>"}.
        var encryption = root["encryption"]?.ToString();
        if (encryption is null)
        {
            return null;
        }

        var base64 = root["data"]?.ToString();
        if (string.IsNullOrEmpty(base64))
        {
            return null;
        }

        byte[] blob;
        try
        {
            blob = Convert.FromBase64String(base64);
        }
        catch (FormatException)
        {
            return null;
        }

        var decrypted = DecryptSafeStorageBlob(blob);
        if (decrypted is null)
        {
            return null;
        }

        try
        {
            var payload = JsonNode.Parse(Encoding.UTF8.GetString(decrypted));
            return CredentialFromNode(payload);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static KimiWebCredential? CredentialFromNode(JsonNode? node)
    {
        var token = node?["tokens"]?["access_token"]?.ToString();
        if (string.IsNullOrWhiteSpace(token))
        {
            return null;
        }

        var origin = node?["origin"]?.ToString();
        if (string.IsNullOrWhiteSpace(origin) || !origin.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
        {
            origin = KimiWebCredential.AllowedOrigins[0];
        }

        return new KimiWebCredential(token, origin);
    }

    /// <summary>Windows DPAPI decrypt of the Electron safeStorage blob; null on failure (never throws).</summary>
    internal static byte[]? DecryptSafeStorageBlob(byte[] blob)
    {
        if (!OperatingSystem.IsWindows())
        {
            // The macOS v10/PBKDF2/saltysalt path is intentionally not ported (§5.2: DPAPI only on Windows).
            return null;
        }

        try
        {
            return ProtectedData.Unprotect(blob, null, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException)
        {
        }

        // Some Electron builds prepend the "v10" marker even on Windows; retry without it.
        if (blob.Length > 3 && blob[0] == (byte)'v' && blob[1] == (byte)'1' && blob[2] == (byte)'0')
        {
            try
            {
                return ProtectedData.Unprotect(blob[3..], null, DataProtectionScope.CurrentUser);
            }
            catch (CryptographicException)
            {
            }
        }

        return null;
    }
}
