// Swift 来源：AIQuotaBar/Tests/ModelUtilizationHistoryStoreTests.swift — final class
// ModelUtilizationHistoryStoreTests（被测：AIQuotaBar.Core/Quota/ModelUtilizationHistoryStore.cs）。
//
// 验收对照表（Swift 函数 → xUnit 方法）：
// - test_noFile_returnsEmptyWithoutCorruptDir       → NoFile_ReturnsEmptyWithoutCorruptDir
// - test_corruptJSON_movesToCorruptBackup           → CorruptJson_MovesToCorruptBackup
// - test_schemaVersionMismatch_movesToCorruptBackup → SchemaVersionMismatch_MovesToCorruptBackup
// - test_corruptFile_postsBackupNotification        → CorruptFile_PostsBackupNotification
// - test_saveLoad_roundTrip_singleModel             → SaveLoad_RoundTrip_SingleModel
// - test_saveLoad_roundTrip_multipleModels          → SaveLoad_RoundTrip_MultipleModels
// - test_saveFailure_postsNotification              → SaveFailure_PostsNotification
//
// 差异说明：Swift NotificationCenter 通知（didBackupCorruptHistory / didFailToSaveHistory）
// 在 C# 端为 store 实例事件；expectation(forNotification:) 等价改为事件标志位断言
// （LoadAsync/SaveAsync 返回前同步触发事件，无需异步等待）。
// store 文件是本地持久化格式：损坏样本（"{ invalid json" / "not json" / version 999）与
// Swift 端逐字相同，不属于 API 响应 fixtures 范畴。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;

using AIQuotaBar.Core.Contracts;
using AIQuotaBar.Core.Quota;

using Xunit;

namespace AIQuotaBar.Core.Tests.Quota;

/// <summary>
/// 覆盖 ModelUtilizationHistoryStore 的 load/save 路径（Swift 端类注释逐条对应）：
/// 损坏文件（JSON 解析失败 / schema version 不匹配）→ move 到 corrupt/ 备份 + 返回空；
/// 读失败 → 不应 move 文件（防止数据锁死在备份里）；正常 save/load 等幂；
/// save 失败 → DidFailToSaveHistory 事件。
/// </summary>
public sealed class ModelUtilizationHistoryStoreTests : IDisposable
{
    private readonly string _tempDir;
    private readonly ModelUtilizationHistoryStore _store;

    public ModelUtilizationHistoryStoreTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "util-test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempDir);
        _store = new ModelUtilizationHistoryStore(_tempDir);
    }

    public void Dispose()
    {
        if (Directory.Exists(_tempDir))
        {
            Directory.Delete(_tempDir, recursive: true);
        }
    }

    // ---------------------------------------------------------------- load 路径

    [Fact]
    public async Task NoFile_ReturnsEmptyWithoutCorruptDir()
    {
        var result = await _store.LoadAsync(UsageProvider.MiniMax);
        Assert.True(result.HistoriesOrEmpty().Count == 0, "不存在的文件应返回空 store");

        // 没有文件 → 不应触发 backup，corrupt/ 目录也不应被创建。
        var corruptDir = CorruptDirPath();
        Assert.False(Directory.Exists(corruptDir), "无文件场景下不应创建 corrupt/ 目录");
    }

    [Fact]
    public async Task CorruptJson_MovesToCorruptBackup()
    {
        var provider = UsageProvider.Glm;
        var url = _store.FileFor(provider);
        await File.WriteAllTextAsync(url, "{ invalid json");

        var result = await _store.LoadAsync(provider);

        Assert.True(result.HistoriesOrEmpty().Count == 0, "损坏 JSON 应返回空 store");
        Assert.False(File.Exists(url), "损坏文件应被 move 到 corrupt/，原路径应不存在");
        Assert.True(Directory.Exists(CorruptDirPath()), "corrupt/ 目录应被创建");
    }

    [Fact]
    public async Task SchemaVersionMismatch_MovesToCorruptBackup()
    {
        var provider = UsageProvider.MiniMax;
        var url = _store.FileFor(provider);
        await File.WriteAllTextAsync(url, "{ \"version\": 999, \"histories\": {} }");

        var result = await _store.LoadAsync(provider);

        Assert.True(result.HistoriesOrEmpty().Count == 0, "新版本 schema 应返回空 store");
        Assert.False(File.Exists(url), "version 不匹配文件应被 move 到 corrupt/");
    }

    [Fact]
    public async Task CorruptFile_PostsBackupNotification()
    {
        var provider = UsageProvider.Codex;
        var url = _store.FileFor(provider);
        await File.WriteAllTextAsync(url, "not json");

        var didBackup = false;
        _store.DidBackupCorruptHistory += (_, _) => didBackup = true;

        await _store.LoadAsync(provider);

        Assert.True(didBackup, "损坏文件被备份后应触发 DidBackupCorruptHistory 事件");
    }

    // ---------------------------------------------------------------- round-trip

    [Fact]
    public async Task SaveLoad_RoundTrip_SingleModel()
    {
        var provider = UsageProvider.MiniMax;
        var history = new ModelUtilizationHistory(
            ModelId: "test:single",
            Entries: new[]
            {
                new UtilizationHistoryEntry(
                    CapturedAt: new DateTimeOffset(1_700_000_000, TimeSpan.Zero),
                    UsedPercent: 50,
                    ResetsAt: new DateTimeOffset(1_700_500_000, TimeSpan.Zero)),
            });
        var payload = new ModelUtilizationStoreData(
            Histories: new Dictionary<string, ModelUtilizationHistory> { ["test:single"] = history });

        await _store.SaveAsync(payload, provider);
        var loaded = await _store.LoadAsync(provider);

        Assert.True(
            loaded.HistoriesOrEmpty().TryGetValue("test:single", out var restored),
            "round-trip 后应存在 key test:single");
        Assert.Equal(1, restored!.Entries.Count);
        Assert.Equal(50, restored.Entries[0].UsedPercent);
    }

    [Fact]
    public async Task SaveLoad_RoundTrip_MultipleModels()
    {
        var provider = UsageProvider.Codex;
        var modelA = new ModelUtilizationHistory(
            ModelId: "codex:a",
            Entries: new[]
            {
                new UtilizationHistoryEntry(
                    CapturedAt: new DateTimeOffset(1_700_000_000, TimeSpan.Zero),
                    UsedPercent: 30,
                    ResetsAt: new DateTimeOffset(1_700_500_000, TimeSpan.Zero)),
            });
        var modelB = new ModelUtilizationHistory(
            ModelId: "codex:b",
            Entries: new[]
            {
                new UtilizationHistoryEntry(
                    CapturedAt: new DateTimeOffset(1_700_000_100, TimeSpan.Zero),
                    UsedPercent: 70,
                    ResetsAt: null),
            });
        var payload = new ModelUtilizationStoreData(
            Histories: new Dictionary<string, ModelUtilizationHistory>
            {
                ["codex:a"] = modelA,
                ["codex:b"] = modelB,
            });

        await _store.SaveAsync(payload, provider);
        var loaded = await _store.LoadAsync(provider);

        Assert.True(
            loaded.HistoriesOrEmpty().TryGetValue("codex:a", out var restoredA),
            "round-trip 后应存在 key codex:a");
        Assert.Equal(30, restoredA!.Entries[0].UsedPercent);
        Assert.True(
            loaded.HistoriesOrEmpty().TryGetValue("codex:b", out var restoredB),
            "round-trip 后应存在 key codex:b");
        Assert.Equal(70, restoredB!.Entries[0].UsedPercent);
        Assert.Null(restoredB!.Entries[0].ResetsAt);
    }

    // ---------------------------------------------------------------- save 失败

    [Fact]
    public async Task SaveFailure_PostsNotification()
    {
        // 构造一个 directoryPath 让 CreateDirectory 失败：把它指向一个已存在的普通文件。
        var blockingFile = Path.Combine(_tempDir, "blocking-file");
        await File.WriteAllTextAsync(blockingFile, "x");

        var brokenStore = new ModelUtilizationHistoryStore(blockingFile);
        var payload = new ModelUtilizationStoreData(
            Histories: new Dictionary<string, ModelUtilizationHistory>
            {
                ["k"] = new ModelUtilizationHistory(ModelId: "k", Entries: Array.Empty<UtilizationHistoryEntry>()),
            });

        var didFail = false;
        brokenStore.DidFailToSaveHistory += (_, _) => didFail = true;

        await brokenStore.SaveAsync(payload, UsageProvider.Glm);

        Assert.True(didFail, "保存失败应触发 DidFailToSaveHistory 事件");
    }

    // ---------------------------------------------------------------- helpers

    // Swift: private func corruptDirPath() -> String。
    private string CorruptDirPath() => Path.Combine(_tempDir, ModelUtilizationHistoryStore.CorruptBackupDirectoryName);
}
