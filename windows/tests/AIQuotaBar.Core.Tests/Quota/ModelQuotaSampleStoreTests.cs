// Swift 来源：AIQuotaBar/Tests/ModelQuotaSampleStoreTests.swift — final class
// ModelQuotaSampleStoreTests（被测：AIQuotaBar.Core/Quota/ModelQuotaSampleStore.cs）。
//
// 验收对照表（Swift 函数 → xUnit 方法）：
// - test_saveLoad_roundTrip                            → SaveLoad_RoundTrip
// - test_saveAll_splitsByProvider                      → SaveAll_SplitsByProvider
// - test_clearAll_removesPersistedSamples              → ClearAll_RemovesPersistedSamples
// - test_prunedQuotaSamples_dropsSamplesOlderThanRetention → PrunedQuotaSamples_DropsSamplesOlderThanRetention
// - test_prunedQuotaSamples_capsCountDroppingOldest    → PrunedQuotaSamples_CapsCountDroppingOldest
//
// setUp/tearDown → 构造函数 + IDisposable（临时根 = Path.GetTempPath() + UUID 子目录，
// 见 windows/docs/coding-conventions.md §7.2）。store 文件是本地持久化格式，
// 不属于 API 响应 fixtures 范畴，样本对象走代码构造（与 Swift 端一致）。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;

using Xunit;

namespace AIQuotaBar.Core.Tests.Quota;

public sealed class ModelQuotaSampleStoreTests : IDisposable
{
    private readonly string _tempDir;
    private readonly ModelQuotaSampleStore _store;

    public ModelQuotaSampleStoreTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "quota-samples-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
        _store = new ModelQuotaSampleStore(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
        {
            Directory.Delete(_tempDir, recursive: true);
        }
    }

    [Fact]
    public async Task SaveLoad_RoundTrip()
    {
        var samples = new Dictionary<string, IReadOnlyList<ModelQuotaSample>>
        {
            ["codex:user@example.com:Codex Spark 5-hour"] = new[]
            {
                new ModelQuotaSample(
                    Timestamp: new DateTimeOffset(1_700_000_000, TimeSpan.Zero),
                    Remaining: 72,
                    Percent: 72),
                new ModelQuotaSample(
                    Timestamp: new DateTimeOffset(1_700_000_060, TimeSpan.Zero),
                    Remaining: 70,
                    Percent: 70),
            },
        };

        await _store.SaveAsync(samples, UsageProvider.Codex);
        var loaded = await _store.LoadAsync(UsageProvider.Codex);

        Assert.True(
            loaded.TryGetValue("codex:user@example.com:Codex Spark 5-hour", out var restored),
            "round-trip 后应存在 key codex:user@example.com:Codex Spark 5-hour");
        Assert.Equal(2, restored!.Count);
        Assert.Equal(70, restored![^1].Remaining);
        Assert.Equal(70, restored![^1].Percent);
    }

    [Fact]
    public async Task SaveAll_SplitsByProvider()
    {
        var samples = new Dictionary<string, IReadOnlyList<ModelQuotaSample>>
        {
            ["codex:user@example.com:Codex Spark 5-hour"] = new[]
            {
                new ModelQuotaSample(new DateTimeOffset(1, TimeSpan.Zero), 80, 80),
            },
            ["minimax:MiniMax"] = new[]
            {
                new ModelQuotaSample(new DateTimeOffset(2, TimeSpan.Zero), 5, null),
            },
        };

        await _store.SaveAllAsync(samples);

        var codexKeys = (await _store.LoadAsync(UsageProvider.Codex))
            .Keys.OrderBy(static key => key, StringComparer.Ordinal).ToArray();
        var miniMaxKeys = (await _store.LoadAsync(UsageProvider.MiniMax))
            .Keys.OrderBy(static key => key, StringComparer.Ordinal).ToArray();
        Assert.Equal(new[] { "codex:user@example.com:Codex Spark 5-hour" }, codexKeys);
        Assert.Equal(new[] { "minimax:MiniMax" }, miniMaxKeys);
        Assert.True((await _store.LoadAsync(UsageProvider.Glm)).Count == 0, "glm 文件应不含样本");
    }

    [Fact]
    public async Task ClearAll_RemovesPersistedSamples()
    {
        await _store.SaveAsync(
            new Dictionary<string, IReadOnlyList<ModelQuotaSample>>
            {
                ["codex:user@example.com:Codex Spark 5-hour"] = new[]
                {
                    new ModelQuotaSample(new DateTimeOffset(1, TimeSpan.Zero), 80, 80),
                },
            },
            UsageProvider.Codex);

        await _store.ClearAllAsync();

        Assert.True((await _store.LoadAllAsync()).Count == 0, "clearAll 后 loadAll 应为空");
    }

    [Fact]
    public void PrunedQuotaSamples_DropsSamplesOlderThanRetention()
    {
        var now = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var inside = now - ModelQuotaSampleStore.QuotaSampleRetention + TimeSpan.FromSeconds(60);
        var outside = now - ModelQuotaSampleStore.QuotaSampleRetention - TimeSpan.FromSeconds(60);
        var samples = new[]
        {
            new ModelQuotaSample(outside, 90, 90),
            new ModelQuotaSample(inside, 80, 80),
            new ModelQuotaSample(now, 70, 70),
        };

        var pruned = ModelQuotaSampleStore.PrunedQuotaSamples(samples, now);

        Assert.Equal(new[] { inside, now }, pruned.Select(static sample => sample.Timestamp));
    }

    [Fact]
    public void PrunedQuotaSamples_CapsCountDroppingOldest()
    {
        var now = new DateTimeOffset(1_700_000_000, TimeSpan.Zero);
        var samples = Enumerable
            .Range(0, ModelQuotaSampleStore.MaxSamplesPerModel + 5)
            .Select(index => new ModelQuotaSample(
                now.AddSeconds(index),
                index,
                null))
            .ToList();

        var pruned = ModelQuotaSampleStore.PrunedQuotaSamples(samples, now: samples[^1].Timestamp);

        Assert.Equal(ModelQuotaSampleStore.MaxSamplesPerModel, pruned.Count);
        Assert.Equal(samples[5].Timestamp, pruned[0].Timestamp);
        Assert.Equal(samples[^1].Timestamp, pruned[^1].Timestamp);
    }
}
