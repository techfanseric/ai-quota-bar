// Swift 来源：AIQuotaBar/Services/Clash/ClashConnectionHistoryStore.swift — final class ClashConnectionHistoryStore（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashConnectionTests.swift — testHistoryStoreRoundTripsAggregateAgesOnly
//
// 持久化差异：Swift 默认目录为 ~/Library/Application Support/com.techfanseric.aiquotabar/clash
//（.shared 单例）；Windows 端不做 App 数据目录决策（属 Platform 层），仅保留目录注入构造，
// 文件名 openai-connection-history.json 与 schema（version + samples）一致。JSON 用 QuotaJson.Default。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Clash;

/// <summary>活跃连接时序持久化：load 按参照时间裁剪到 60 分钟窗口；save 整体落盘（版本号当前为 1）。</summary>
public sealed class ClashConnectionHistoryStore
{
    public const int CurrentSchemaVersion = 1;

    private readonly string _directoryPath;

    public ClashConnectionHistoryStore(string directoryPath)
    {
        _directoryPath = directoryPath;
    }

    public string FilePath => Path.Combine(_directoryPath, "openai-connection-history.json");

    public Task<IReadOnlyList<ClashConnectionHistorySample>> LoadAsync(CancellationToken cancellationToken = default) =>
        LoadAsync(DateTimeOffset.UtcNow, cancellationToken);

    public async Task<IReadOnlyList<ClashConnectionHistorySample>> LoadAsync(
        DateTimeOffset relativeTo,
        CancellationToken cancellationToken = default)
    {
        byte[] data;
        try
        {
            if (!File.Exists(FilePath))
            {
                return Array.Empty<ClashConnectionHistorySample>();
            }

            data = await File.ReadAllBytesAsync(FilePath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<ClashConnectionHistorySample>();
        }

        StoreFile payload;
        try
        {
            payload = JsonSerializer.Deserialize<StoreFile>(data, QuotaJson.Default)
                ?? new StoreFile(CurrentSchemaVersion, Array.Empty<ClashConnectionHistorySample>());
        }
        catch (JsonException)
        {
            return Array.Empty<ClashConnectionHistorySample>();
        }

        if (payload.Version > CurrentSchemaVersion)
        {
            return Array.Empty<ClashConnectionHistorySample>();
        }

        return ClashConnectionHistory.Pruned(
            payload.Samples ?? Array.Empty<ClashConnectionHistorySample>(),
            relativeTo);
    }

    public async Task SaveAsync(
        IReadOnlyList<ClashConnectionHistorySample> samples,
        CancellationToken cancellationToken = default)
    {
        try
        {
            Directory.CreateDirectory(_directoryPath);
            var payload = new StoreFile(CurrentSchemaVersion, samples);
            var contents = JsonSerializer.Serialize(payload, QuotaJson.Default);

            // 原子写：先写临时文件再覆盖（对应 Swift Data.write(options: [.atomic])）。
            var temporaryPath = FilePath + ".tmp-" + Guid.NewGuid().ToString("N");
            await File.WriteAllTextAsync(temporaryPath, contents, cancellationToken).ConfigureAwait(false);
            File.Move(temporaryPath, FilePath, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Swift 端 save 失败仅 DEBUG 打印；此处静默忽略。
        }
    }

    private sealed record StoreFile(
        int Version,
        IReadOnlyList<ClashConnectionHistorySample>? Samples);
}
