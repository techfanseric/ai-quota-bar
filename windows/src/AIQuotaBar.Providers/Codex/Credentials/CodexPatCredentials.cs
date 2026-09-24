// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexPAT/CodexPATCredentials.swift
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexAuthStoreTests.cs

#nullable enable

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// auth.json 的 personal_access_token 形态（Swift: CodexPATCredentials）。
/// PAT 与 OAuth tokens 互斥解析：纯 PAT 文件不得被当作 OAuth 解析（missingTokens）。
/// </summary>
/// <param name="Token">personal_access_token（非空白）。</param>
/// <param name="Source">凭据来源；Windows 首期恒为 <see cref="CodexCredentialSource.CodexHome"/>。</param>
public sealed record CodexPatCredentials(
    string Token,
    CodexCredentialSource Source = CodexCredentialSource.CodexHome);
