// Swift 来源：AIQuotaBar/Services/ModelUtilizationHistoryStore.swift — 通知
// didBackupCorruptHistory 的 userInfo["backupURL"]（NotificationCenter 通知在 C# 端以
// 事件表达，payload 提为 EventArgs；Swift 用户信息键见属性注释）。

#nullable enable

using System;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 损坏历史文件被备份到 corrupt/ 目录后的事件参数。
/// 对应 Swift userInfo 键：backupURL。
/// </summary>
public sealed class CorruptHistoryBackupEventArgs : EventArgs
{
    /// <param name="backupPath">备份文件路径（{corrupt}/{provider}.json.corrupt-{unixSeconds}）。</param>
    public CorruptHistoryBackupEventArgs(string backupPath)
    {
        BackupPath = backupPath;
    }

    /// <summary>备份文件路径（{corrupt}/{provider}.json.corrupt-{unixSeconds}）。</summary>
    public string BackupPath { get; }
}
