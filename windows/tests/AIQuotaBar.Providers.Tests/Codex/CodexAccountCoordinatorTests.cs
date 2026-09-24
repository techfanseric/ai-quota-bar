// Swift 来源：无直接对应（Windows 端新增的分组协调）；键格式契约来自
//   AIQuotaBar/Models/UsageData.swift 的 id / normalizedAccountName / quotaIdentityKey 与
//   windows/src/AIQuotaBar.Core/Contracts/ProviderIdentity.cs（QuotaIdentity）。

#nullable enable

using System;
using System.Collections.Generic;
using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Providers.Codex;
using Xunit;

namespace AIQuotaBar.Providers.Tests.Codex;

public sealed class CodexAccountCoordinatorTests
{
    private static readonly DateTimeOffset Now = new(2026, 9, 24, 0, 0, 0, TimeSpan.Zero);

    private static ModelUsageData MakeRow(
        UsageProvider provider = UsageProvider.Codex,
        string? accountName = null,
        string modelName = "5h") =>
        new(
            Provider: provider,
            AccountName: accountName,
            ModelName: modelName,
            CurrentIntervalTotal: 100,
            CurrentIntervalRemaining: 50,
            WeeklyTotal: 0,
            WeeklyRemaining: 0,
            RemainsTimeMilliseconds: 0,
            StartTime: null,
            EndTime: null,
            WeeklyStartTime: null,
            WeeklyEndTime: null,
            ValueSuffix: "%",
            DetailText: null,
            CurrentIntervalRemainingPercent: 50,
            WeeklyRemainingPercent: null,
            ProgressBarPercentOverride: null,
            ProgressBarRightText: null,
            SampledAt: null);

    [Fact]
    public void GroupModelsByAccount_GroupsAndNormalizesAccounts()
    {
        var models = new List<ModelUsageData>
        {
            MakeRow(accountName: "Alice@Example.com", modelName: "5h"),
            MakeRow(accountName: "alice@example.com", modelName: "Weekly"),
            MakeRow(accountName: "bob@example.com", modelName: "5h"),
            MakeRow(accountName: null, modelName: "5h"),
        };

        var groups = CodexAccountCoordinator.GroupModelsByAccount(models);

        Assert.Equal(3, groups.Count);
        // 大小写不同的账号归并为同一组（normalizedAccountName 语义）。
        Assert.Equal("codex:alice@example.com", groups[0].QuotaIdentityKey);
        Assert.Equal(2, groups[0].Models.Count);
        Assert.Equal("Alice@Example.com", groups[0].AccountName);
        Assert.Equal("codex:bob@example.com", groups[1].QuotaIdentityKey);
        // 无账号组键保留空账号段（QuotaIdentity 的双冒号不对称语义：行级键为 "codex::<model>"）。
        Assert.Equal("codex:", groups[2].QuotaIdentityKey);
        Assert.Null(groups[2].AccountName);
    }

    [Fact]
    public void GroupModelsByAccount_RowKeysExtendGroupKeyPrefix()
    {
        var models = new List<ModelUsageData>
        {
            MakeRow(accountName: "Alice@Example.com", modelName: "Codex Spark 5-hour"),
        };

        var group = Assert.Single(CodexAccountCoordinator.GroupModelsByAccount(models));
        var row = group.Models[0];

        Assert.Equal(
            "codex:alice@example.com:codex spark 5-hour",
            QuotaIdentity.Key(row.Provider, row.AccountName, row.ModelName));
        Assert.StartsWith(
            group.QuotaIdentityKey + ":",
            QuotaIdentity.Key(row.Provider, row.AccountName, row.ModelName),
            StringComparison.Ordinal);
    }

    [Fact]
    public void GroupModelsByAccount_IgnoresNonCodexRows()
    {
        var models = new List<ModelUsageData>
        {
            MakeRow(provider: UsageProvider.Glm, accountName: "someone@example.com"),
            MakeRow(accountName: "codex@example.com"),
        };

        var groups = CodexAccountCoordinator.GroupModelsByAccount(models);

        var group = Assert.Single(groups);
        Assert.Equal("codex:codex@example.com", group.QuotaIdentityKey);
    }

    [Fact]
    public void GroupSnapshotsByAccount_FlattensSnapshots()
    {
        var firstSnapshot = new UsageData(
            Provider: UsageProvider.Codex,
            Remains: 1,
            Total: 1,
            Timestamp: Now,
            Models: new[] { MakeRow(accountName: "a@example.com", modelName: "5h") },
            SubscribeTitle: null,
            SubscribeEndTime: null,
            GlmResetAllowances: null);
        var secondSnapshot = firstSnapshot with { };
        var thirdSnapshot = new UsageData(
            Provider: UsageProvider.Codex,
            Remains: 1,
            Total: 1,
            Timestamp: Now,
            Models: new[] { MakeRow(accountName: "b@example.com", modelName: "Weekly") },
            SubscribeTitle: null,
            SubscribeEndTime: null,
            GlmResetAllowances: null);

        var groups = CodexAccountCoordinator.GroupSnapshotsByAccount(
            new[] { firstSnapshot, secondSnapshot, thirdSnapshot });

        Assert.Equal(2, groups.Count);
        Assert.Equal("codex:a@example.com", groups[0].QuotaIdentityKey);
        Assert.Equal(2, groups[0].Models.Count);
        Assert.Equal("codex:b@example.com", groups[1].QuotaIdentityKey);
        Assert.Single(groups[1].Models);
    }
}
