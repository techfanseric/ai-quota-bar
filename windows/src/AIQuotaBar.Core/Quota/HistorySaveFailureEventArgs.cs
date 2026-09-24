// Swift 来源：AIQuotaBar/Services/ModelUtilizationHistoryStore.swift — 通知
// didFailToSaveHistory 的 userInfo（error / provider 两个键；NotificationCenter 通知在
// C# 端以事件表达，payload 提为 EventArgs record）。

#nullable enable

using System;

using AIQuotaBar.Core.Contracts;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// utilization 历史保存失败的事件参数（调用方应考虑降级提示，不阻塞主刷新流程）。
/// 对应 Swift userInfo 键：error、provider（rawValue）。
/// </summary>
/// <param name="Provider">保存失败的 provider。</param>
/// <param name="Error">保存失败的异常（磁盘满 / 权限变更 / 目录被删等）。</param>
public sealed record HistorySaveFailureEventArgs(UsageProvider Provider, Exception Error) : EventArgs;
