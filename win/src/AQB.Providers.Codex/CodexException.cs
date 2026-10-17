namespace AQB.Providers.Codex;

/// <summary>Base exception for Codex provider failures (network/parse errors).</summary>
public class CodexException : Exception
{
    public CodexException(string message)
        : base(message)
    {
    }
}

/// <summary>
/// Auth failure (missing / expired / revoked credentials). <see cref="RequiresRelogin"/> = true
/// means the stored credentials can no longer be refreshed and the user must run codex again.
/// </summary>
public sealed class CodexAuthException : CodexException
{
    public CodexAuthException(string message, bool requiresRelogin = false)
        : base(message)
    {
        RequiresRelogin = requiresRelogin;
    }

    public bool RequiresRelogin { get; }
}
