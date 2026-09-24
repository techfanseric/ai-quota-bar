// Swift 来源：无（Windows 端新增；对齐 Core Contracts 的 QuotaIdentity 键格式——见
//   windows/src/AIQuotaBar.Core/Contracts/ProviderIdentity.cs）。Swift 侧的分组语义来自
//   AIQuotaBar/Models/UsageData.swift 的 normalizedAccountName / quotaIdentityKey。

#nullable enable

using System.Collections.Generic;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Codex;

/// <summary>
/// 一个 Codex 账号的模型行分组。<see cref="QuotaIdentityKey"/> 是行级
/// <see cref="QuotaIdentity"/> 键的公共前缀（"codex:&lt;normalizedAccount&gt;"）；
/// 行级键 = 分组键 + ":" + 归一化模型名。
/// </summary>
/// <param name="QuotaIdentityKey">分组身份键："codex:&lt;normalizedAccount&gt;（无账号时 "codex:"）。</param>
/// <param name="AccountName">原始账号名（邮箱）；无账号为 null。</param>
/// <param name="NormalizedAccountName">trim + 小写归一（Swift: normalizedAccountName）。</param>
/// <param name="Models">该账号的模型行（保持输入顺序）。</param>
public sealed record CodexAccountGroup(
    string QuotaIdentityKey,
    string? AccountName,
    string NormalizedAccountName,
    IReadOnlyList<ModelUsageData> Models);
