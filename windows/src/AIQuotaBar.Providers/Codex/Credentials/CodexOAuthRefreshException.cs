// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexTokenRefresher.swift
//   （enum RefreshError: LocalizedError 的 errorDescription）

#nullable enable

using System;

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// OAuth token 刷新失败。错误码与用户可见文案镜像 Swift CodexTokenRefresher.RefreshError。
/// </summary>
public sealed class CodexOAuthRefreshException : Exception
{
    public CodexOAuthRefreshError Error { get; }

    public CodexOAuthRefreshException(CodexOAuthRefreshError error, string? detail = null, Exception? inner = null)
        : base(detail is null ? MessageFor(error) : $"{MessageFor(error)} ({detail})", inner)
    {
        Error = error;
    }

    private static string MessageFor(CodexOAuthRefreshError error) => error switch
    {
        CodexOAuthRefreshError.Expired =>
            "Refresh token expired. Please run `codex` to log in again.",
        CodexOAuthRefreshError.Revoked =>
            "Refresh token was revoked. Please run `codex` to log in again.",
        CodexOAuthRefreshError.Reused =>
            "Refresh token was already used. Please run `codex` to log in again.",
        CodexOAuthRefreshError.NetworkError =>
            "Network error during token refresh.",
        CodexOAuthRefreshError.InvalidResponse =>
            "Invalid refresh response.",
        _ => "Unknown Codex token refresh error.",
    };
}
