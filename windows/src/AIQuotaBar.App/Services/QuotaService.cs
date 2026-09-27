// Swift 来源：Services 各 provider UsageViewModel 聚合面（Windows 端收敛为单服务）。
// 职责：从 Credential Manager 取 provider 凭据 → 调 W1 的 GlmClient / MinimaxClient /
// CodexQuotaService 拉真实配额 → 维护面板/托盘所需状态。Kimi 待 Phase 0 spike 结论（计划 §9）。

using System.Net.Http;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;
using AIQuotaBar.Platform.Credentials;
using AIQuotaBar.Providers.Codex;
using AIQuotaBar.Providers.Codex.Credentials;
using AIQuotaBar.Providers.Glm;
using AIQuotaBar.Providers.Minimax;

namespace AIQuotaBar.App.Services;

/// <summary>单个 provider 的配额呈现状态（面板绑定用）。</summary>
public sealed class ProviderState
{
    public string Name { get; init; } = string.Empty;

    public ProviderStatus Status { get; init; } = ProviderStatus.NotConfigured;

    public UsageData? Usage { get; init; }

    public string? Error { get; init; }
}

public enum ProviderStatus
{
    NotConfigured,
    Loading,
    Ok,
    Error,
}

public sealed class QuotaService
{
    private const string GlmService = "glm";
    private const string MinimaxService = "minimax";
    private const string CodexService = "codex";
    private readonly AppSettings _settings;
    private readonly CredentialStore _credentials = new();
    private readonly SemaphoreSlim _refreshGate = new(1, 1);

    public event Action? StateChanged;

    public ProviderState Glm { get; private set; } = new() { Name = "GLM" };

    public ProviderState Minimax { get; private set; } = new() { Name = "MiniMax" };

    public ProviderState Codex { get; private set; } = new() { Name = "Codex" };

    /// <summary>托盘环百分比：首个成功 provider 的整体剩余比例；无数据时 null（灰色环）。</summary>
    public int? RingPercent
    {
        get
        {
            foreach (var state in new[] { Glm, Minimax, Codex })
            {
                if (state.Status == ProviderStatus.Ok && state.Usage is { } usage)
                {
                    return (int)Math.Round(usage.PercentageRemaining());
                }
            }

            return null;
        }
    }

    /// <summary>托盘 tooltip 摘要（"GLM 82% · MiniMax 45%"形态）。</summary>
    public string TraySummary
    {
        get
        {
            var parts = new List<string>();
            foreach (var state in new[] { Glm, Minimax, Codex })
            {
                if (state.Status == ProviderStatus.Ok && state.Usage is { } usage)
                {
                    parts.Add($"{state.Name} {usage.PercentageRemaining():F0}%");
                }
                else if (state.Status == ProviderStatus.Error)
                {
                    parts.Add($"{state.Name} !");
                }
            }

            return parts.Count > 0 ? string.Join(" · ", parts) : Lang.Get(AppStrings.TrayNotConfiguredSummary);
        }
    }

    public QuotaService(AppSettings settings) => _settings = settings;

    public async Task RefreshAsync()
    {
        if (!await _refreshGate.WaitAsync(0).ConfigureAwait(false))
        {
            return; // 上一次刷新还在跑：跳过本轮（计划 §11：请求合并，不排队）。
        }

        try
        {
            Glm = await FetchGlmAsync().ConfigureAwait(false);
            Minimax = await FetchMinimaxAsync().ConfigureAwait(false);
            Codex = await FetchCodexAsync().ConfigureAwait(false);
            StateChanged?.Invoke();
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    private async Task<ProviderState> FetchGlmAsync()
    {
        // 凭据来源优先级（实测验证的零配置链路，参考 Win-CodexBar 的 z.ai 成功经验）：
        // 1. Credential Manager 手动配置（设置窗）；
        // 2. ZCode 客户端凭据（~/.zcode/v2/credentials.json 的 coding-plan api-key，
        //    ZcodeCredentialStore 解密）——ZCode 已登录的机器上用户零配置即出数。
        var credential = _credentials.Read(GlmService, string.Empty);
        if (string.IsNullOrEmpty(credential))
        {
            var zcode = new ZcodeCredentialStore().TryLoad();
            credential = zcode?.ApiKeys.Values.FirstOrDefault(v => !string.IsNullOrWhiteSpace(v));
            if (string.IsNullOrEmpty(credential))
            {
                return new ProviderState { Name = "GLM", Status = ProviderStatus.NotConfigured };
            }
        }

        try
        {
            using var http = new HttpClient(_settings.CreateHttpHandler(), disposeHandler: true)
            {
                Timeout = TimeSpan.FromSeconds(30),
            };
            var usage = await new GlmClient(http).FetchUsageAsync(credential).ConfigureAwait(false);
            return new ProviderState { Name = "GLM", Status = ProviderStatus.Ok, Usage = usage };
        }
        catch (Exception ex)
        {
            return new ProviderState { Name = "GLM", Status = ProviderStatus.Error, Error = ex.Message };
        }
    }

    private async Task<ProviderState> FetchMinimaxAsync()
    {
        // 凭据来源优先级（零配置链路，对齐上方 FetchGlmAsync 的 ZCode 回退；路径结论来自
        // Win-CodexBar minimax provider）：
        // 1. Credential Manager 手动配置（设置窗）；
        // 2. mcode CLI 登录凭据（%APPDATA%\minimax\config.json，次选 %USERPROFILE%\.minimax\
        //    config.json，MinimaxCliCredentialReader 读取）——mcode 已登录的机器上用户零配置
        //    即出数；coding-plan remains 端点只需 Bearer api_key（见 MinimaxClient）。
        var token = _credentials.Read(MinimaxService, string.Empty);
        string? groupId = null;
        if (string.IsNullOrEmpty(token))
        {
            var cliCredentials = new MinimaxCliCredentialReader().TryLoad();
            if (cliCredentials is null)
            {
                return new ProviderState { Name = "MiniMax", Status = ProviderStatus.NotConfigured };
            }

            token = cliCredentials.ApiKey;
            groupId = cliCredentials.GroupId;
        }

        try
        {
            using var http = new HttpClient(_settings.CreateHttpHandler(), disposeHandler: true)
            {
                Timeout = TimeSpan.FromSeconds(30),
            };
            var usage = await new MinimaxClient(http).FetchUsageAsync(token, groupId).ConfigureAwait(false);
            return new ProviderState { Name = "MiniMax", Status = ProviderStatus.Ok, Usage = usage };
        }
        catch (Exception ex)
        {
            return new ProviderState { Name = "MiniMax", Status = ProviderStatus.Error, Error = ex.Message };
        }
    }

    private async Task<ProviderState> FetchCodexAsync()
    {
        // 凭据来源优先级（对齐 FetchGlmAsync 的零配置链路）：
        // 1. Credential Manager 手动配置（设置窗，API key 形态，直接拉取）；
        // 2. Codex CLI 登录凭据（%CODEX_HOME%\auth.json，默认 ~/.codex）——`codex login`
        //    之后零配置即出数；token 过期自动 OAuth 刷新并回写（CodexQuotaService 编排）。
        var apiKey = _credentials.Read(CodexService, string.Empty);

        try
        {
            using var http = new HttpClient(_settings.CreateHttpHandler(), disposeHandler: true)
            {
                Timeout = TimeSpan.FromSeconds(30),
            };
            var service = new CodexQuotaService(CodexEnvironment.Instance, http);
            var usage = string.IsNullOrWhiteSpace(apiKey)
                ? await service.FetchFromCodexHomeAsync().ConfigureAwait(false)
                : await service.FetchWithApiKeyAsync(apiKey).ConfigureAwait(false);
            return new ProviderState { Name = "Codex", Status = ProviderStatus.Ok, Usage = usage };
        }
        catch (Exception ex)
        {
            // 未登录（auth.json 缺失）也走此分支：CodexCredentialException 文案自带
            // "Run `codex login`" 指引（Win-CodexBar 同先例），面板直接展示。
            return new ProviderState { Name = "Codex", Status = ProviderStatus.Error, Error = ex.Message };
        }
    }
}
