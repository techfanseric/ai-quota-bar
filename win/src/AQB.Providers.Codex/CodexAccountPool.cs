namespace AQB.Providers.Codex;

public sealed record CodexPoolAccount
{
    /// <summary>Display label = file name without .json.</summary>
    public required string Label { get; init; }

    public required string AccountId { get; init; }

    public string? Email { get; init; }

    public required string FilePath { get; init; }
}

/// <summary>
/// Optional multi-account pool: enumerates ~/.codex/accounts/*.json (file name = display label,
/// hidden files skipped, case-insensitive label sort). A missing directory simply means
/// single-account mode — an empty list is returned, never an error.
/// </summary>
public sealed class CodexAccountPool
{
    private readonly string _accountsDirectory;

    public CodexAccountPool(string? codexHome = null)
    {
        CodexHome = CodexPaths.ResolveHome(codexHome);
        _accountsDirectory = Path.Combine(CodexHome, "accounts");
    }

    public string CodexHome { get; }

    public IReadOnlyList<CodexPoolAccount> ListAccounts()
    {
        if (!Directory.Exists(_accountsDirectory))
        {
            return Array.Empty<CodexPoolAccount>();
        }

        var accounts = new List<CodexPoolAccount>();
        try
        {
            foreach (var file in Directory.EnumerateFiles(_accountsDirectory, "*.json"))
            {
                var fileName = Path.GetFileName(file);
                if (fileName.StartsWith(".", StringComparison.Ordinal))
                {
                    continue;
                }

                string raw;
                try
                {
                    raw = File.ReadAllText(file);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    continue;
                }

                var info = CodexAuthStore.Interpret(raw);
                if (info is null)
                {
                    continue;
                }

                accounts.Add(new CodexPoolAccount
                {
                    Label = Path.GetFileNameWithoutExtension(fileName),
                    AccountId = info.AccountId,
                    Email = info.Email,
                    FilePath = file,
                });
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<CodexPoolAccount>();
        }

        return accounts
            .OrderBy(account => account.Label, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }
}
