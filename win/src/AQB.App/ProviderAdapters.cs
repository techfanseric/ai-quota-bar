using AQB.Core;
using AQB.Providers.Codex;
using AQB.Providers.GlmMiniMax;
using AQB.Providers.Kimi;
using AQB.Settings;

namespace AQB.App;

/// <summary>Codex adapter: reads local credentials; unconfigured auth.json maps to Offline.</summary>
public sealed class CodexProviderAdapter : IProviderAdapter
{
    private readonly CodexQuotaService _service;
    private readonly CodexAuthStore _authStore;

    public CodexProviderAdapter(CredentialVault vault)
    {
        _service = new CodexQuotaService();
        _authStore = new CodexAuthStore();
    }

    public ProviderKind Kind => ProviderKind.Codex;

    public bool IsConfigured => _authStore.Load() is not null;

    public Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken)
        => _service.FetchAsync(cancellationToken);
}

/// <summary>Kimi adapter: tries vault API key, then desktop session, then CLI /status.</summary>
public sealed class KimiProviderAdapter : IProviderAdapter
{
    private readonly CredentialVault _vault;

    public KimiProviderAdapter(CredentialVault vault) => _vault = vault;

    public ProviderKind Kind => ProviderKind.Kimi;

    /// <summary>Any of the three credential sources present (cheap file/PATH probes only).</summary>
    public bool IsConfigured =>
        !string.IsNullOrWhiteSpace(_vault.Get("kimi.apiKey"))
        || new KimiDesktopSessionReader().IsPresent()
        || KimiCliLocator.FindExecutable() is not null;

    public Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        var service = new KimiQuotaService(apiKey: _vault.Get("kimi.apiKey"));
        return service.FetchAsync(cancellationToken);
    }
}

/// <summary>GLM adapter: vault API key, or the imported web-session cURL.</summary>
public sealed class GlmProviderAdapter : IProviderAdapter
{
    private readonly CredentialVault _vault;

    public GlmProviderAdapter(CredentialVault vault) => _vault = vault;

    public ProviderKind Kind => ProviderKind.Glm;

    public bool IsConfigured => _vault.Get("glm.apiKey") is not null || _vault.Get("glm.importedCurl") is not null;

    public Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken)
    {
        // API key is the recommended path and wins when present; the cURL import is
        // optional. ParseCurl throws on empty/garbage input, so it must be guarded.
        var apiKey = _vault.Get("glm.apiKey");
        if (!string.IsNullOrWhiteSpace(apiKey))
        {
            return GlmQuotaService.ForApiKey(apiKey).FetchAsync(cancellationToken);
        }

        var importedCurl = _vault.Get("glm.importedCurl");
        if (!string.IsNullOrWhiteSpace(importedCurl))
        {
            try
            {
                return new GlmQuotaService(GlmCredentialParser.Parse(importedCurl)).FetchAsync(cancellationToken);
            }
            catch (GlmCredentialException)
            {
                // Fall through to the empty-key service below, which reports a clear error.
            }
        }

        return GlmQuotaService.ForApiKey("").FetchAsync(cancellationToken);
    }
}

/// <summary>MiniMax adapter: coding-plan token from the vault.</summary>
public sealed class MiniMaxProviderAdapter : IProviderAdapter
{
    private readonly CredentialVault _vault;

    public MiniMaxProviderAdapter(CredentialVault vault) => _vault = vault;

    public ProviderKind Kind => ProviderKind.MiniMax;

    public bool IsConfigured => _vault.Get("minimax.token") is not null;

    public Task<ProviderSnapshot> FetchAsync(CancellationToken cancellationToken)
        => new MiniMaxQuotaService().FetchAsync(_vault.Get("minimax.token") ?? "", cancellationToken);
}
