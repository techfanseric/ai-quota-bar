using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AQB.Settings;

/// <summary>
/// DPAPI-encrypted credential vault persisted to %APPDATA%\AIQuotaBar\vault.bin — the Windows
/// counterpart of the macOS Keychain vault (service com.techfanseric.aiquotabar). Entries are
/// opaque strings; each module owns its key names and JSON payloads.
/// </summary>
public sealed class CredentialVault : IDisposable
{
    private static readonly byte[] Entropy = "AIQuotaBar.Win.vault.v1"u8.ToArray();

    private readonly string _path;
    private readonly bool _persisted;
    private Dictionary<string, string> _entries = new();
    private bool _dirty;
    private readonly object _gate = new();

    public static string DefaultVaultPath()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "AIQuotaBar");
        return Path.Combine(root, "vault.bin");
    }

    /// <param name="path">Vault file path; use <c>in-memory://</c> for tests.</param>
    /// <param name="persisted">When false the vault never touches disk (unit tests on any OS).</param>
    public CredentialVault(string? path = null, bool persisted = true)
    {
        _path = path ?? DefaultVaultPath();
        _persisted = persisted;
        if (!_persisted)
        {
            return;
        }

        try
        {
            if (File.Exists(_path))
            {
                var decrypted = ProtectedData.Unprotect(File.ReadAllBytes(_path), Entropy, DataProtectionScope.CurrentUser);
                _entries = JsonSerializer.Deserialize<Dictionary<string, string>>(decrypted) ?? new Dictionary<string, string>();
            }
        }
        catch (Exception e) when (e is CryptographicException or IOException or JsonException or UnauthorizedAccessException or PlatformNotSupportedException)
        {
            // Unreadable vault starts empty; the next Save rewrites it.
            _entries = new Dictionary<string, string>();
        }
    }

    public string? Get(string key)
    {
        lock (_gate)
        {
            return _entries.TryGetValue(key, out var value) ? value : null;
        }
    }

    public void Set(string key, string value)
    {
        lock (_gate)
        {
            _entries[key] = value;
            _dirty = true;
        }
    }

    public bool Delete(string key)
    {
        lock (_gate)
        {
            var removed = _entries.Remove(key);
            if (removed)
            {
                _dirty = true;
            }

            return removed;
        }
    }

    public IReadOnlyCollection<string> Keys
    {
        get
        {
            lock (_gate)
            {
                return _entries.Keys.ToArray();
            }
        }
    }

    public string GetOrCreateDeviceId()
    {
        const string key = "device.id";
        var existing = Get(key);
        if (!string.IsNullOrEmpty(existing))
        {
            return existing;
        }

        var created = Guid.NewGuid().ToString("N");
        Set(key, created);
        Save();
        return created;
    }

    public void Save()
    {
        if (!_persisted)
        {
            return;
        }

        lock (_gate)
        {
            if (!_dirty && File.Exists(_path))
            {
                return;
            }

            var plain = JsonSerializer.Serialize(_entries);
            var encrypted = ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), Entropy, DataProtectionScope.CurrentUser);
            var directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var temp = _path + ".tmp";
            File.WriteAllBytes(temp, encrypted);
            if (File.Exists(_path))
            {
                File.Replace(temp, _path, null);
            }
            else
            {
                File.Move(temp, _path);
            }

            _dirty = false;
        }
    }

    public void Dispose() => Save();
}
