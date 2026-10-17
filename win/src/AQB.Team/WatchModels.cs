using System.Security.Cryptography;
using System.Text;

namespace AQB.Team;

/// <summary>One quota window of a watch snapshot — percent only, never absolute amounts.</summary>
public sealed record CodexWatchWindow(
    string Name,
    int RemainingPercent,
    DateTimeOffset? ResetsAt = null,
    DateTimeOffset? SampledAt = null,
    DateTimeOffset? StartsAt = null);

/// <summary>Shape submitted by the publisher (full-replace semantics per publish call).</summary>
public sealed record CodexWatchAccountSnapshot(
    string Account,
    string? Plan,
    IReadOnlyList<CodexWatchWindow> Windows);

/// <summary>A snapshot of someone else's shared quota.</summary>
public sealed record CodexWatchSnapshot(
    string Account,
    string? Plan,
    IReadOnlyList<CodexWatchWindow> Windows,
    DateTimeOffset? PublishedAt);

public sealed record CodexWatchReadCount(
    long ReadCount,
    DateTimeOffset? LastReadAt,
    bool Stale);

public enum WatchFetchStatus
{
    Available = 0,

    /// <summary>Nobody is sharing this email — the most common state.</summary>
    NotShared = 1,

    /// <summary>A snapshot exists but the owner has not published for a long time (HTTP 410).</summary>
    Stale = 2,

    /// <summary>Network/service failure. The reason is safe to show.</summary>
    Unreachable = 3,
}

public sealed record WatchFetchResult(
    WatchFetchStatus Status,
    CodexWatchSnapshot? Snapshot = null,
    string? Reason = null)
{
    public static WatchFetchResult Available(CodexWatchSnapshot snapshot) => new(WatchFetchStatus.Available, snapshot);

    public static WatchFetchResult NotShared() => new(WatchFetchStatus.NotShared);

    public static WatchFetchResult Stale(string account) =>
        new(WatchFetchStatus.Stale, new CodexWatchSnapshot(account, null, Array.Empty<CodexWatchWindow>(), null));

    public static WatchFetchResult Unreachable(string reason) => new(WatchFetchStatus.Unreachable, null, reason);
}

/// <summary>Email normalization and validation, ported verbatim from CodexWatchStore.swift.</summary>
public static class WatchAccount
{
    public static string Normalize(string raw) => raw.Trim().ToLowerInvariant();

    public static bool IsValidAccountName(string raw)
    {
        var value = Normalize(raw);
        if (value.Length is < 3 or > 254 || value.StartsWith('.') || value.EndsWith('.'))
        {
            return false;
        }

        if (value.Contains(".."))
        {
            return false;
        }

        var parts = value.Split('@');
        if (parts.Length != 2)
        {
            return false;
        }

        var local = parts[0];
        var domain = parts[1];
        if (local.Length == 0 || local.Length > 64 || domain.Length == 0
            || !domain.Contains('.')
            || domain.StartsWith('.') || domain.EndsWith('.')
            || domain.StartsWith("-") || domain.EndsWith("-"))
        {
            return false;
        }

        // URL / display-name leftovers: atext allows these, but a pasted address
        // bar containing them is not an account name.
        if (value.IndexOfAny("/#:\\\"<>()[],;".ToCharArray()) >= 0)
        {
            return false;
        }

        const string allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~@-";
        return value.All(allowed.Contains);
    }

    /// <summary>Byte-identical to the server's account_key: SHA-256 of the normalized email, lowercase hex.</summary>
    public static string? AccountKey(string account)
    {
        var normalized = Normalize(account);
        return IsValidAccountName(normalized)
            ? Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized))).ToLowerInvariant()
            : null;
    }
}
