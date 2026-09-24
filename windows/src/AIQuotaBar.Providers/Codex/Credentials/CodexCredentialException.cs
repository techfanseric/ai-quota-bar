// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （enum CodexOAuthCredentialsError: LocalizedError 的 errorDescription）
// Swift 错误枚举在 C# 侧映射为 异常类型 + 错误码枚举（<see cref="CodexCredentialError"/>）。

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// auth.json 读取/解析失败。错误码与用户可见文案逐条镜像 Swift CodexOAuthCredentialsError。
/// </summary>
public sealed class CodexCredentialException : Exception
{
    public CodexCredentialError Error { get; }

    public CodexCredentialException(CodexCredentialError error, string? detail = null)
        : base(detail is null ? MessageFor(error) : $"{MessageFor(error)} ({detail})")
    {
        Error = error;
    }

    private static string MessageFor(CodexCredentialError error) => error switch
    {
        CodexCredentialError.NotFound =>
            "Codex auth.json not found. Run `codex login` to sign in.",
        CodexCredentialError.Unreadable =>
            "Codex auth.json could not be read. Check its permissions or run `codex login` to sign in again.",
        CodexCredentialError.DecodeFailed =>
            "Failed to decode Codex credentials.",
        CodexCredentialError.MissingTokens =>
            "Codex auth.json exists but contains no tokens.",
        CodexCredentialError.NativeRefreshRequired =>
            "Codex auth.json needs refresh. Reauthenticate this account or run `codex login` in the same Codex home.",
        CodexCredentialError.ReadOnlySource =>
            "This external Codex credential source is stale and read-only. "
            + "Sign in again with its owning app or run `codex login` to create fresh native credentials.",
        _ => "Unknown Codex credential error.",
    };
}
