// Swift 来源：AIQuotaBar/Services/Codex 的取数编排（macOS 侧散布在 CodexUsageService/
//   ProviderFetchContext 与 codexbar CodexOAuthUsageFetcher；Windows 端收敛为单一编排器，
//   组件复用 W1 已移植的 CodexAuthStore / CodexOAuthRefresher / CodexUsageParser /
//   CodexUsageDataMapper，传输归 CodexUsageClient——Win-CodexBar 无直接对应物，其
//   rust api.rs fetch_usage 的 load_credentials → fetch_usage_once 链路是行为参照）。
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexQuotaServiceTests.cs
//
// 编排语义（按 Win-CodexBar 实证与任务书规格）：
// - auth.json 缺失/不可解析 → CodexCredentialException 原样上抛（W1 已内置
//   "Run `codex login`" 提示文案，App 直接展示）；
// - NeedsRefresh（exp 进入刷新窗/无 exp 且 last_refresh 超 8 天）→ 刷新 → 回写 auth.json；
// - 刷新失败（过期/吊销/复用/网络）降级：沿用旧 access token 继续拉 usage，token 确已
//   失效时由 usage 端点 401 报错并携带 re-login 提示；
// - 回写失败不阻断拉取（下次刷新窗仍会重试）。

#nullable enable

using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Codex.Credentials;

namespace AIQuotaBar.Providers.Codex;

/// <summary>
/// Codex 配额编排器：auth.json 读取 → 按需 OAuth 刷新（含回写）→ usage 拉取 → 解析映射。
/// 全部依赖注入（store/refresher/client 各自可桩化），无全局状态。
/// </summary>
public sealed class CodexQuotaService
{
    private const string OAuthSourceLabel = "oauth";
    private const string ApiKeySourceLabel = "api-key";

    private readonly CodexAuthStore _authStore;
    private readonly CodexOAuthRefresher _refresher;
    private readonly CodexUsageClient _usageClient;

    public CodexQuotaService(
        CodexAuthStore authStore,
        CodexOAuthRefresher refresher,
        CodexUsageClient usageClient)
    {
        _authStore = authStore ?? throw new ArgumentNullException(nameof(authStore));
        _refresher = refresher ?? throw new ArgumentNullException(nameof(refresher));
        _usageClient = usageClient ?? throw new ArgumentNullException(nameof(usageClient));
    }

    /// <summary>
    /// 便捷构造（App 接线用）：<paramref name="httpClient"/> 同时供刷新与 usage 请求；
    /// auth.json 路径按 <paramref name="environment"/>（CODEX_HOME 覆盖 → %USERPROFILE%\.codex）。
    /// </summary>
    public CodexQuotaService(ICodexEnvironment environment, HttpClient httpClient)
        : this(
            new CodexAuthStore(environment),
            new CodexOAuthRefresher(httpClient),
            new CodexUsageClient(httpClient))
    {
    }

    /// <summary>
    /// codex login 零配置链路：读 %CODEX_HOME%\auth.json（OAuth 或 OPENAI_API_KEY 形态）→
    /// 按需刷新 → 拉取 usage。auth.json 缺失/仅 PAT → <see cref="CodexCredentialException"/>
    /// （文案含 `codex login` 指引）。
    /// </summary>
    public async Task<UsageData> FetchFromCodexHomeAsync(CancellationToken cancellationToken = default)
    {
        var credentials = await _authStore.LoadOAuthAsync(cancellationToken).ConfigureAwait(false);
        return await FetchWithCredentialsAsync(credentials, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// 调用方自带 API key（如 Credential Manager 手动配置）：API key 无需刷新，直接拉取
    /// （Win-CodexBar：OPENAI_API_KEY 与 OAuth 同端点同 Bearer 头形态）。
    /// </summary>
    public Task<UsageData> FetchWithApiKeyAsync(
        string apiKey,
        CancellationToken cancellationToken = default)
    {
        var trimmed = apiKey.Trim();
        if (trimmed.Length == 0)
        {
            throw new CodexUsageException(CodexUsageError.NotConfigured, "Codex API key 为空（未配置）。");
        }

        return FetchWithCredentialsAsync(
            new CodexOAuthCredentials(
                AccessToken: trimmed,
                RefreshToken: string.Empty,
                IdToken: null,
                AccountId: null,
                LastRefresh: null),
            cancellationToken);
    }

    /// <summary>
    /// 核心链路：按需刷新 → usage 拉取 → ParseUsageResponse → MapToUsageData。
    /// 解析失败（CodexUsageParseException）与 HTTP 失败（CodexUsageException）原样上抛。
    /// </summary>
    public async Task<UsageData> FetchWithCredentialsAsync(
        CodexOAuthCredentials credentials,
        CancellationToken cancellationToken = default)
    {
        credentials = await RefreshIfNeededAsync(credentials, cancellationToken).ConfigureAwait(false);

        var json = await _usageClient
            .FetchUsageJsonAsync(credentials.AccessToken, credentials.AccountId, cancellationToken)
            .ConfigureAwait(false);
        var response = CodexUsageParser.ParseUsageResponse(json);
        return CodexUsageParser.MapToUsageData(
            response,
            credentials,
            whoami: null,
            sourceLabel: credentials.IsApiKey ? ApiKeySourceLabel : OAuthSourceLabel,
            now: DateTimeOffset.UtcNow);
    }

    private async Task<CodexOAuthCredentials> RefreshIfNeededAsync(
        CodexOAuthCredentials credentials,
        CancellationToken cancellationToken)
    {
        if (!credentials.NeedsRefresh)
        {
            return credentials;
        }

        CodexOAuthCredentials refreshed;
        try
        {
            refreshed = await _refresher.RefreshAsync(credentials, cancellationToken).ConfigureAwait(false);
        }
        catch (CodexOAuthRefreshException)
        {
            // 降级：刷新失败（过期/吊销/复用/网络/畸形响应）不阻断本次拉取，沿用旧
            // access token 试一次；token 确已失效时 usage 端点以 401 报错并带 re-login 提示。
            return credentials;
        }

        await TrySaveAsync(refreshed, cancellationToken).ConfigureAwait(false);
        return refreshed;
    }

    private async Task TrySaveAsync(
        CodexOAuthCredentials credentials,
        CancellationToken cancellationToken)
    {
        try
        {
            await _authStore.SaveAsync(credentials, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is CodexCredentialException or IOException or UnauthorizedAccessException)
        {
            // 回写失败不阻断拉取：刷新结果本次照用，磁盘留旧值时下次仍会触发刷新。
        }
    }
}
