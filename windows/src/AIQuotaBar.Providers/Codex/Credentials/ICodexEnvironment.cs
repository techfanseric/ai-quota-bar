// Swift 来源：.dependencies/codexbar/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift
//   （authFilePath(env:) 的路径解析：CODEX_HOME 覆盖 → ~/.codex/auth.json）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexAuthStoreTests.cs

#nullable enable

namespace AIQuotaBar.Providers.Codex.Credentials;

/// <summary>
/// Codex 主目录（CODEX_HOME）解析的注入接口。生产实现见 <see cref="CodexEnvironment"/>；
/// 测试注入临时目录。
/// Windows 差异（相对 macOS）：macOS 端 codexbar 还存在托管 Codex home（managed store）与
/// 外部凭据源（legacy ~/.config/codex、OpenCode）回退链；Windows 首期只支持
/// CODEX_HOME 环境变量覆盖与 %USERPROFILE%\.codex 默认路径，不做外部源回退。
/// </summary>
public interface ICodexEnvironment
{
    /// <summary>
    /// Codex 主目录（末尾不带分隔符）。取 CODEX_HOME（非空白）覆盖值，否则
    /// %USERPROFILE%\.codex。等价 Swift：CodexOAuthCredentialsStore.authFilePath(env:)
    /// （Swift 另有 ambientHomeURL 的托管目录判定，Windows 首期不移植，见类注释）。
    /// </summary>
    string CodexHomeDirectory { get; }
}
