// Swift 来源：AIQuotaBar/Services/ModelUtilizationHistoryStore.swift — final class
// ModelUtilizationHistoryStore（load/save/clear/clearAll、损坏文件 corrupt/ 备份、
// 通知 didBackupCorruptHistory / didFailToSaveHistory）。
// JSON 持久化统一走 Contracts 的 QuotaJson.Default（camelCase + Swift .iso8601 日期，
// histories 缺失容忍旧文件）。
// 与 Swift 的差异：目录路径经构造函数注入（无 shared 单例、不探查 Application Support —
// 那是 Platform 层职责）；I/O 一律 async Task（编码规范 §3）；NotificationCenter 通知
// 以 C# 事件表达（DidBackupCorruptHistory / DidFailToSaveHistory）。
// 对应测试：AIQuotaBar/Tests/ModelUtilizationHistoryStoreTests.swift

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 跨周期 utilization 历史持久化。路径：{directory}/{provider}.json（Swift 为
/// ~/Library/Application Support/com.techfanseric.aiquotabar/history/{provider}.json）。
/// 加载/保存 best-effort 策略（与 Swift 对齐）：
/// - 读失败（权限/占用/挂载异常）≠ 文件损坏：只返回空，不动文件（下次 load 还有机会；
///   move 到 corrupt/ 反而会让 save 用空 store 覆盖原路径，把数据锁死）；
/// - 解析失败 / schema 版本过新 / 强类型 decode 失败 → move 到 corrupt/ 备份 + 事件，
///   返回空 store（备份保证下次 save 不会覆盖原始数据）；
/// - 保存失败 → DidFailToSaveHistory 事件（调用方降级提示，不阻塞主刷新流程）。
/// </summary>
public sealed class ModelUtilizationHistoryStore
{
    /// <summary>损坏文件备份子目录名（Swift: corruptBackupDirectoryName）。</summary>
    public const string CorruptBackupDirectoryName = "corrupt";

    private const int CurrentSchemaVersion = 1;

    private readonly string _directoryPath;

    /// <summary>损坏文件已备份到 corrupt/（Swift 通知 didBackupCorruptHistory；userInfo: backupURL）。</summary>
    public event EventHandler<CorruptHistoryBackupEventArgs>? DidBackupCorruptHistory;

    /// <summary>保存失败（Swift 通知 didFailToSaveHistory；userInfo: error / provider）。</summary>
    public event EventHandler<HistorySaveFailureEventArgs>? DidFailToSaveHistory;

    /// <param name="directoryPath">history 目录（Swift 测试专用 init 的 directoryURL 注入同构）。</param>
    public ModelUtilizationHistoryStore(string directoryPath)
    {
        _directoryPath = directoryPath;
    }

    /// <summary>Swift: fileURL(for:)。文件名 = provider rawValue + ".json"。</summary>
    public string FileFor(UsageProvider provider) =>
        Path.Combine(_directoryPath, provider.RawValue() + ".json");

    /// <summary>加载并返回 store；失败时返回空 store 并按需备份/发事件。Swift: load(for:)。</summary>
    public async Task<ModelUtilizationStoreData> LoadAsync(
        UsageProvider provider,
        CancellationToken cancellationToken = default)
    {
        var path = FileFor(provider);
        if (!File.Exists(path))
        {
            return EmptyStore();
        }

        string json;
        try
        {
            json = await File.ReadAllTextAsync(path, cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // 读失败（权限/文件被占用/磁盘挂载异常）≠ 文件损坏：不动文件，下次 load 还有机会。
            return EmptyStore();
        }

        int fileVersion;
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                BackupCorruptFile(path, "JSON parse failed");
                return EmptyStore();
            }

            fileVersion = 0;
            if (document.RootElement.TryGetProperty("version", out var versionElement) &&
                versionElement.ValueKind == JsonValueKind.Number &&
                versionElement.TryGetInt32(out var parsedVersion))
            {
                fileVersion = parsedVersion;
            }
        }
        catch (JsonException)
        {
            BackupCorruptFile(path, "JSON parse failed");
            return EmptyStore();
        }

        if (fileVersion > CurrentSchemaVersion)
        {
            BackupCorruptFile(
                path,
                $"schema version {fileVersion} newer than supported {CurrentSchemaVersion}");
            return EmptyStore();
        }

        StoreFile payload;
        try
        {
            payload = JsonSerializer.Deserialize<StoreFile>(json, QuotaJson.Default)
                ?? new StoreFile(CurrentSchemaVersion, Histories: null);
        }
        catch (JsonException ex)
        {
            BackupCorruptFile(path, $"decode failed: {ex.Message}");
            return EmptyStore();
        }

        return new ModelUtilizationStoreData(
            payload.Histories ?? new Dictionary<string, ModelUtilizationHistory>());
    }

    /// <summary>保存 store（原子写）；失败发 DidFailToSaveHistory 事件。Swift: save(_:for:)。</summary>
    public async Task SaveAsync(
        ModelUtilizationStoreData store,
        UsageProvider provider,
        CancellationToken cancellationToken = default)
    {
        try
        {
            Directory.CreateDirectory(_directoryPath);
            var payload = new StoreFile(CurrentSchemaVersion, store.Histories);
            var json = JsonSerializer.Serialize(payload, QuotaJson.Default);
            await AtomicFileWriter.WriteAsync(FileFor(provider), json, cancellationToken);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            DidFailToSaveHistory?.Invoke(this, new HistorySaveFailureEventArgs(provider, ex));
        }
    }

    /// <summary>删除单个 provider 的历史文件（不存在时无操作）。Swift: clear(for:)。</summary>
    public Task ClearAsync(UsageProvider provider, CancellationToken cancellationToken = default)
    {
        // 删除是纯元数据操作（Swift 同步 removeItem），无需异步内核调用。
        cancellationToken.ThrowIfCancellationRequested();
        var path = FileFor(provider);
        if (File.Exists(path))
        {
            File.Delete(path);
        }

        return Task.CompletedTask;
    }

    /// <summary>删除全部 provider 的历史文件。Swift: clearAll()。</summary>
    public Task ClearAllAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        foreach (var provider in UsageProviders.All)
        {
            var path = FileFor(provider);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }

        return Task.CompletedTask;
    }

    /// <summary>Swift private backupCorruptFile(at:reason:)：move 到 corrupt/ 并发事件。</summary>
    private void BackupCorruptFile(string path, string reason)
    {
        try
        {
            var backupDirectoryPath = Path.Combine(_directoryPath, CorruptBackupDirectoryName);
            Directory.CreateDirectory(backupDirectoryPath);
            var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var backupPath = Path.Combine(
                backupDirectoryPath,
                $"{Path.GetFileName(path)}.corrupt-{timestamp}");
            File.Move(path, backupPath);
            DidBackupCorruptHistory?.Invoke(this, new CorruptHistoryBackupEventArgs(backupPath));
        }
        catch (IOException)
        {
            // 备份失败仅吞掉（Swift 只在 DEBUG print）；原文件保留在原位。
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static ModelUtilizationStoreData EmptyStore() =>
        new(new Dictionary<string, ModelUtilizationHistory>());

    /// <summary>磁盘文件内容（Swift private struct StoreFile）。histories 为 null 时序列化省略（Swift encodeIfPresent）。</summary>
    private sealed record StoreFile(int Version, Dictionary<string, ModelUtilizationHistory>? Histories);
}
