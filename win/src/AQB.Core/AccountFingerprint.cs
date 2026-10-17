using System.Security.Cryptography;
using System.Text;

namespace AQB.Core;

public static class AccountFingerprint
{
    /// <summary>
    /// Codex account digest used as the cloud correlation key on macOS:
    /// SHA-256 of "codex-account|" + account_id, lowercase hex. Must stay byte-compatible.
    /// </summary>
    public static string Codex(string accountId)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes("codex-account|" + accountId));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }

    /// <summary>Watch account key: SHA-256 of trimmed lowercase email, lowercase hex.</summary>
    public static string WatchEmail(string email)
    {
        var normalized = email.Trim().ToLowerInvariant();
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
