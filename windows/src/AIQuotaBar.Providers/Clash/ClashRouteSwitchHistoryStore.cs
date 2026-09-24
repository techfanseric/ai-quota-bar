// Swift 来源：AIQuotaBar/Services/Clash/ClashRouteSwitchHistoryStore.swift — struct ClashRouteSwitchHistoryStore（v1.28.1）
// 对应测试：AIQuotaBar/Tests/Clash/ClashRouteSwitchHistoryStoreTests.swift
//
// 持久化差异：Swift 存 UserDefaults（JSON blob，键 clashRouteSwitchHistory）；
// Windows 端无 UserDefaults，改为注入路径的 JSON 文件（QuotaJson.Default，
// camelCase + 严格 ISO 8601 日期）。保留逻辑：仅保留最近 3 条、同线路切换不记录。

#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Providers.Clash;

/// <summary>线路切换历史 store：load 排序裁剪到 3 条；recordSwitch 追加后同样裁剪并落盘。</summary>
public sealed class ClashRouteSwitchHistoryStore
{
    private const string DefaultsKey = "clashRouteSwitchHistory";

    public const int MaximumRecordCount = 3;

    private readonly string _filePath;

    public ClashRouteSwitchHistoryStore(string filePath)
    {
        _filePath = filePath;
    }

    /// <summary>Swift 端 UserDefaults 键名；Windows 端以同名 JSON 文件承载（文件名见构造函数）。</summary>
    public static string StorageKey => DefaultsKey;

    public async Task<IReadOnlyList<ClashRouteSwitchRecord>> LoadAsync(CancellationToken cancellationToken = default)
    {
        byte[] data;
        try
        {
            if (!File.Exists(_filePath))
            {
                return Array.Empty<ClashRouteSwitchRecord>();
            }

            data = await File.ReadAllBytesAsync(_filePath, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return Array.Empty<ClashRouteSwitchRecord>();
        }

        List<ClashRouteSwitchRecord> records;
        try
        {
            records = JsonSerializer.Deserialize<List<ClashRouteSwitchRecord>>(data, QuotaJson.Default)
                ?? new List<ClashRouteSwitchRecord>();
        }
        catch (JsonException)
        {
            return Array.Empty<ClashRouteSwitchRecord>();
        }

        return records
            .OrderByDescending(record => record.SwitchedAt)
            .Take(MaximumRecordCount)
            .ToList();
    }

    public async Task<IReadOnlyList<ClashRouteSwitchRecord>> RecordSwitchAsync(
        string fromRoute,
        string toRoute,
        DateTimeOffset? switchedAt = null,
        CancellationToken cancellationToken = default)
    {
        if (fromRoute == toRoute)
        {
            return await LoadAsync(cancellationToken).ConfigureAwait(false);
        }

        var newRecord = new ClashRouteSwitchRecord(
            Id: Guid.NewGuid(),
            SwitchedAt: switchedAt ?? DateTimeOffset.UtcNow,
            FromRoute: fromRoute,
            ToRoute: toRoute);

        var loaded = await LoadAsync(cancellationToken).ConfigureAwait(false);
        var records = new[] { newRecord }
            .Concat(loaded)
            .OrderByDescending(record => record.SwitchedAt)
            .Take(MaximumRecordCount)
            .ToList();

        await WriteFileAsync(_filePath, JsonSerializer.Serialize(records, QuotaJson.Default), cancellationToken)
            .ConfigureAwait(false);
        return records;
    }

    private static async Task WriteFileAsync(string filePath, string contents, CancellationToken cancellationToken)
    {
        try
        {
            var directory = Path.GetDirectoryName(Path.GetFullPath(filePath));
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            // 原子写：先写临时文件再覆盖（对应 Swift Data.write(options: [.atomic])）。
            var temporaryPath = filePath + ".tmp-" + Guid.NewGuid().ToString("N");
            await File.WriteAllTextAsync(temporaryPath, contents, cancellationToken).ConfigureAwait(false);
            File.Move(temporaryPath, filePath, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Swift 端 try? 编码/写失败静默忽略；此处保持一致。
        }
    }
}
