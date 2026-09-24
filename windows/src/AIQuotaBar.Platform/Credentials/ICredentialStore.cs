// Swift 来源：无（Windows 端新增；对应计划 §4 平台映射：Keychain（SecItem）→ Credential Manager（CredReadW/CredWriteW））
// 对应测试：windows/tests/AIQuotaBar.Platform.Tests/Credentials/CredentialStoreTests.cs

using System;

namespace AIQuotaBar.Platform.Credentials;

/// <summary>
/// provider 凭据（API key / token）的持久化存取接口。
/// </summary>
/// <remarks>
/// Windows 端等价 macOS 端 Keychain（<c>SecItemAdd/SecItemCopyMatching/SecItemDelete</c>）：
/// 每条凭据 = 服务名 + 账户 → 字符串密钥（计划 §4）。实现见 <see cref="CredentialStore"/>
/// （advapi32 Credential Manager，GENERIC 类型，本机持久化）。上层（Providers 的凭据装配）
/// 只依赖本接口，便于测试替身与后续迁移。
/// </remarks>
public interface ICredentialStore
{
    /// <summary>
    /// 读取指定服务与账户下保存的字符串密钥；不存在时返回 <see langword="null"/>。
    /// </summary>
    /// <param name="service">服务名（如 provider 标识 <c>"codex"</c>、<c>"glm"</c>），不可为空且不含 <c>':'</c>。</param>
    /// <param name="account">账户标识（可为空字符串），不可含 <c>':'</c>。</param>
    string? Read(string service, string account);

    /// <summary>
    /// 写入（新建或覆盖）指定服务与账户的字符串密钥。
    /// </summary>
    /// <param name="service">服务名，不可为空且不含 <c>':'</c>。</param>
    /// <param name="account">账户标识，不可含 <c>':'</c>。</param>
    /// <param name="secret">密钥内容（UTF-8 存储主体，长度受 Credential Manager blob 上限约束）。</param>
    void Write(string service, string account, string secret);

    /// <summary>
    /// 删除指定服务与账户的凭据。
    /// </summary>
    /// <returns>凭据存在且已删除返回 <see langword="true"/>；本就不存在返回 <see langword="false"/>。</returns>
    bool Delete(string service, string account);
}
