namespace AQB.Core;

public enum ProviderKind
{
    Codex = 0,
    Kimi = 1,
    Glm = 2,
    MiniMax = 3,
}

public static class ProviderKindExtensions
{
    public static char Letter(this ProviderKind kind) => kind switch
    {
        ProviderKind.Codex => 'C',
        ProviderKind.Kimi => 'K',
        ProviderKind.Glm => 'G',
        ProviderKind.MiniMax => 'M',
        _ => '?',
    };

    public static string WireName(this ProviderKind kind) => kind switch
    {
        ProviderKind.Codex => "codex",
        ProviderKind.Kimi => "kimi",
        ProviderKind.Glm => "glm",
        ProviderKind.MiniMax => "minimax",
        _ => "unknown",
    };

    public static string DisplayName(this ProviderKind kind) => kind switch
    {
        ProviderKind.Codex => "Codex",
        ProviderKind.Kimi => "Kimi",
        ProviderKind.Glm => "GLM",
        ProviderKind.MiniMax => "MiniMax",
        _ => "Unknown",
    };
}
