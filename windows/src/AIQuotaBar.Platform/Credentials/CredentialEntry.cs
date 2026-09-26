// Swift 来源：无（Windows 端新增；CredentialStore.Enumerate 的返回条目）。
// 刻意不含密钥本体——枚举是展示/对账用途（CLI「cred list」、设置页账户列表），
// 密钥只在显式 Read 时按条取出。

#nullable enable

namespace AIQuotaBar.Platform.Credentials;

/// <summary>本应用命名空间下的一条凭据索引项（service + account 定位，UserName 为附加信息）。</summary>
public sealed record CredentialEntry(string Service, string Account, string? UserName);
