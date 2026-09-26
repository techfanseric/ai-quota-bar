// Swift 来源：Services 各 provider UsageViewModel 聚合面（Windows 端收敛为单服务）。
// 职责：从 Credential Manager 取 provider 凭据 → 调 W1 的 GlmClient / MinimaxClient
// 拉真实配额 → 维护面板/托盘所需状态。Codex/Kimi 待 Phase 0 spike 结论（计划 §9）。

using System.Net.Http;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;
using AIQuotaBar.Platform.Credentials;
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
    private readonly AppSettings _settings;
    private readonly CredentialStore _credentials = new();
    private readonly SemaphoreSlim _refreshGate = new(1, 1);

    public event Action? StateChanged;

    public ProviderState Glm { get; private set; } = new() { Name = "GLM" };

    public ProviderState Minimax { get; private set; } = new() { Name = "MiniMax" };

    /// <summary>托盘环百分比：首个成功 provider 的整体剩余比例；无数据时 null（灰色环）。</summary>
    public int? RingPercent
    {
        get
        {
            foreach (var state in new[] { Glm, Minimax })
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
            foreach (var state in new[] { Glm, Minimax })
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

            return parts.Count > 0 ? string.Join(" · ", parts) : "AI Quota Bar（未配置 — 左键打开设置）";
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
            StateChanged?.Invoke();
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    private async Task<ProviderState> FetchGlmAsync()
    {
        var credential = _credentials.Read(GlmService, string.Empty);
        if (string.IsNullOrEmpty(credential))
        {
            return new ProviderState { Name = "GLM", Status = ProviderStatus.NotConfigured };
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
        var token = _credentials.Read(MinimaxService, string.Empty);
        if (string.IsNullOrEmpty(token))
        {
            return new ProviderState { Name = "MiniMax", Status = ProviderStatus.NotConfigured };
        }

        try
        {
            using var http = new HttpClient(_settings.CreateHttpHandler(), disposeHandler: true)
            {
                Timeout = TimeSpan.FromSeconds(30),
            };
            var usage = await new MinimaxClient(http).FetchUsageAsync(token).ConfigureAwait(false);
            return new ProviderState { Name = "MiniMax", Status = ProviderStatus.Ok, Usage = usage };
        }
        catch (Exception ex)
        {
            return new ProviderState { Name = "MiniMax", Status = ProviderStatus.Error, Error = ex.Message };
        }
    }
}
