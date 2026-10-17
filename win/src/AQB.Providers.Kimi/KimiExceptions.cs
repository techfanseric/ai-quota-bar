namespace AQB.Providers.Kimi;

/// <summary>Reason codes carried by <see cref="KimiCliException"/>.</summary>
public static class KimiCliReason
{
    public const string CliNotInstalled = "cliNotInstalled";
    public const string WorkspaceTrustRequired = "workspaceTrustRequired";
    public const string StatusUnavailable = "statusUnavailable";
    public const string Timeout = "timeout";
}

/// <summary>
/// Kimi CLI probe failure. <see cref="Reason"/> is a stable machine code
/// (cliNotInstalled / workspaceTrustRequired / statusUnavailable / timeout) while
/// <see cref="Exception.Message"/> carries the human-facing text.
/// </summary>
public sealed class KimiCliException : Exception
{
    public string Reason { get; }

    public KimiCliException(string reason, string? message = null, Exception? inner = null)
        : base(message ?? reason, inner)
    {
        Reason = reason;
    }
}

/// <summary>Local credential problems for a Kimi web/desktop session (spec §1.3 error table).</summary>
public enum KimiSessionErrorKind
{
    Missing = 0,
    InvalidStore = 1,
    Expired = 2,
    UnsupportedOrigin = 3,
}

public sealed class KimiSessionException : Exception
{
    public KimiSessionErrorKind Kind { get; }

    public KimiSessionException(KimiSessionErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }
}

/// <summary>Web quota API failures. Messages never include the response body or auth headers.</summary>
public enum KimiWebErrorKind
{
    SessionExpired = 0,
    InvalidResponse = 1,
    HttpError = 2,
    NetworkError = 3,
}

public sealed class KimiWebException : Exception
{
    public KimiWebErrorKind Kind { get; }

    public KimiWebException(KimiWebErrorKind kind, string message, Exception? inner = null)
        : base(message, inner)
    {
        Kind = kind;
    }
}
