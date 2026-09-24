// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （enum CodexOAuthCredentialSource）

#nullable enable

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// Codex OAuth 凭据来源（Swift: CodexOAuthCredentialSource）。Windows 首期只会产生
/// <see cref="CodexHome"/>；其余两个成员保留枚举位以对齐 Swift 判定语义（刷新回写权限）。
/// </summary>
public enum CodexCredentialSource
{
    /// <summary>~/.codex/auth.json（Windows：%CODEX_HOME%\auth.json）——Codex CLI 自有文件，可回写刷新结果。</summary>
    CodexHome,

    /// <summary>旧版 ~/.config/codex/auth.json —— 只读外部源（Windows 首期不读取）。</summary>
    LegacyCodexHome,

    /// <summary>OpenCode 数据目录下的 auth.json —— 只读外部源（Windows 首期不读取）。</summary>
    OpenCode,
}
