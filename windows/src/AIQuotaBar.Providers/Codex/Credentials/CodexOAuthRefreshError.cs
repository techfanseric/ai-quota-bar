// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexTokenRefresher.swift
//   （enum RefreshError）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexOAuthRefresherTests.cs

#nullable enable

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>OAuth refresh 失败分类（Swift: CodexTokenRefresher.RefreshError）。</summary>
public enum CodexOAuthRefreshError
{
    /// <summary>refresh_token 过期（401 或 refresh_token_expired）。</summary>
    Expired,

    /// <summary>refresh_token 被吊销（invalid_grant / refresh_token_invalidated）。</summary>
    Revoked,

    /// <summary>refresh_token 已被使用过（refresh_token_reused）。</summary>
    Reused,

    /// <summary>网络错误（含超时）。</summary>
    NetworkError,

    /// <summary>响应不可解析或状态码不可归类（附 "Status &lt;code&gt;" 细节）。</summary>
    InvalidResponse,
}
