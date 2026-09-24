// Swift 来源：AIQuotaBar/Services/Codex/CodexAccountCoordinator.swift（App 侧协调器；
//   macOS 版包装 codexbar 的 FileManagedCodexAccountStore 做账号列表/删除——托管账号库是
//   macOS 专属（App Support 下的 managed codex homes），Windows 首期裁剪，本类型只保留
//   多账户分组与 quotaIdentityKey 生成，键格式对齐 Core Contracts 的 QuotaIdentity）
// 对应测试：AIQuotaBar.Providers.Tests/Codex/CodexAccountCoordinatorTests.cs

#nullable enable

using System.Collections.Generic;
using System.Linq;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Codex;

/// <summary>
/// Codex 多账户分组：把若干 <see cref="UsageData"/> 快照中的 Codex 模型行按账号归组，
/// 生成分组级 quotaIdentityKey（行级键的前缀）。非 Codex 的行被忽略（本协调器只服务 Codex）。
/// </summary>
public static class CodexAccountCoordinator
{
    /// <summary>
    /// 按账号分组模型行，保持账号首次出现的顺序。账号归一规则与
    /// <see cref="ProviderAccounts.Normalize"/> 一致（trim + 小写，null/空归并为空串）。
    /// </summary>
    public static IReadOnlyList<CodexAccountGroup> GroupModelsByAccount(
        IReadOnlyList<ModelUsageData> models)
    {
        var orderedKeys = new List<string>();
        var buckets = new Dictionary<string, List<ModelUsageData>>();
        var accountNames = new Dictionary<string, string?>();

        foreach (var model in models)
        {
            if (model.Provider != UsageProvider.Codex)
            {
                continue;
            }

            var normalized = ProviderAccounts.Normalize(model.AccountName);
            if (!buckets.TryGetValue(normalized, out var bucket))
            {
                bucket = new List<ModelUsageData>();
                buckets[normalized] = bucket;
                accountNames[normalized] = model.AccountName;
                orderedKeys.Add(normalized);
            }

            bucket.Add(model);
        }

        return orderedKeys
            .Select(normalized => new CodexAccountGroup(
                QuotaIdentityKey: GroupKey(normalized),
                AccountName: accountNames[normalized],
                NormalizedAccountName: normalized,
                Models: buckets[normalized]))
            .ToList();
    }

    /// <summary>把多个快照的 Codex 行扁平后按账号分组（多账户刷新结果的汇聚入口）。</summary>
    public static IReadOnlyList<CodexAccountGroup> GroupSnapshotsByAccount(
        IReadOnlyList<UsageData> snapshots) =>
        GroupModelsByAccount(snapshots.SelectMany(snapshot => snapshot.Models).ToList());

    /// <summary>
    /// 分组键："codex:&lt;normalizedAccount&gt;"。与行级
    /// <see cref="QuotaIdentity.Key(UsageProvider, string?, string)"/> 的关系：行级键 =
    /// 分组键 + ":" + 归一化模型名（QuotaIdentity 的账号段即使为空也保留，故无账号行为
    /// "codex::&lt;model&gt;"，分组键为 "codex:"——双冒号不对称是有意为之，见 Contracts 注释）。
    /// </summary>
    private static string GroupKey(string normalizedAccount) =>
        $"{UsageProvider.Codex.RawValue()}:{normalizedAccount}";
}
