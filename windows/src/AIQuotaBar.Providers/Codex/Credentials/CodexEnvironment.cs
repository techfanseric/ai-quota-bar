// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （authFilePath(env:)：CODEX_HOME → homeDirectoryForCurrentUser/.codex）
// 纯新增的生产实现（Windows：%USERPROFILE%\.codex）。

#nullable enable

using System;
using System.IO;

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// <see cref="ICodexEnvironment"/> 的生产实现：CODEX_HOME 环境变量（非空白）覆盖，
/// 否则 %USERPROFILE%\.codex。
/// </summary>
public sealed class CodexEnvironment : ICodexEnvironment
{
    public static CodexEnvironment Instance { get; } = new();

    public string CodexHomeDirectory
    {
        get
        {
            var overrideHome = NonEmpty(Environment.GetEnvironmentVariable("CODEX_HOME"));
            if (overrideHome is not null)
            {
                return overrideHome;
            }

            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(userProfile, ".codex");
        }
    }

    private static string? NonEmpty(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
