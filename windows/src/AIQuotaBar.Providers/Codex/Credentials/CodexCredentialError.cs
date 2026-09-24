// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （enum CodexOAuthCredentialsError）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// auth.json 读取/解析错误分类（Swift: CodexOAuthCredentialsError）。文案在
/// <see cref="CodexCredentialException"/> 中镜像 Swift errorDescription。
/// </summary>
public enum CodexCredentialError
{
    /// <summary>auth.json 不存在（应运行 `codex login` 登录）。</summary>
    NotFound,

    /// <summary>auth.json 存在但读不了（权限/IO 错误）。</summary>
    Unreadable,

    /// <summary>JSON 解码失败。</summary>
    DecodeFailed,

    /// <summary>文件存在但没有可用的 tokens / PAT（例如仅含 PAT 的文件按 OAuth 解析）。</summary>
    MissingTokens,

    /// <summary>凭据需要刷新但本实现按策略不代刷（保留语义位，Windows 首期不抛出）。</summary>
    NativeRefreshRequired,

    /// <summary>外部只读源不允许回写刷新结果。</summary>
    ReadOnlySource,
}
