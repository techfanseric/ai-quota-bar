// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （struct CodexOAuthCredentials：needsRefresh 判定逐字段镜像）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexAuthStoreTests.cs

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// ~/.codex/auth.json 的 OAuth（或 OPENAI_API_KEY）凭据（Swift: CodexOAuthCredentials）。
/// Windows 差异：macOS 端的 Keychain 托管 home / 外部源（legacy、OpenCode）不移植——
/// Windows 上 auth.json 文件本身就是唯一凭据源（DPAPI/凭据管理器方案属后续 Platform 阶段）。
/// </summary>
/// <param name="AccessToken">access_token（或 OPENAI_API_KEY 模式下的 API key）。</param>
/// <param name="RefreshToken">refresh_token；API key 模式为空串。</param>
/// <param name="IdToken">可选 id_token（JWT，含账号身份声明）。</param>
/// <param name="AccountId">tokens.account_id；缺失时从 JWT 声明尽力恢复。</param>
/// <param name="LastRefresh">last_refresh（ISO 8601）；API key 模式为 null。</param>
/// <param name="ExpiresAt">从 access_token JWT exp 声明推导的过期时间（尽力而为）。</param>
/// <param name="Source">凭据来源；决定刷新结果是否允许回写。</param>
/// <param name="IsApiKey">OPENAI_API_KEY 模式（无需刷新）。</param>
public sealed record CodexOAuthCredentials(
    string AccessToken,
    string RefreshToken,
    string? IdToken,
    string? AccountId,
    DateTimeOffset? LastRefresh,
    DateTimeOffset? ExpiresAt = null,
    CodexCredentialSource Source = CodexCredentialSource.CodexHome,
    bool IsApiKey = false)
{
    /// <summary>
    /// Swift: needsRefresh。API key 永不刷新；有 exp 声明时按来源窗口（codexHome 5 分钟，
    /// 外部源 60 秒）判断；否则 last_refresh 超过 8 天需要刷新。
    /// </summary>
    public bool NeedsRefresh
    {
        get
        {
            if (IsApiKey)
            {
                return false;
            }

            var now = DateTimeOffset.UtcNow;
            if (ExpiresAt is { } expiresAt)
            {
                var refreshWindowSeconds = Source == CodexCredentialSource.CodexHome ? 5 * 60 : 60;
                return (expiresAt - now).TotalSeconds <= refreshWindowSeconds;
            }

            if (LastRefresh is not { } lastRefresh)
            {
                return true;
            }

            return (now - lastRefresh) > TimeSpan.FromDays(8);
        }
    }
}
