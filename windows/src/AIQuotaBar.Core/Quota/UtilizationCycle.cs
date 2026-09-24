// Swift 来源：AIQuotaBar/Models/ModelUtilizationHistory.swift — cycles(limit:now:mode:) 与
// ModelUtilizationCycleMerger.mergeLiveCurrentCycle 返回的元组 (resetsAt:peakPercent:)。
// Swift 用匿名元组；C# 端提为具名 record 以获得值语义与可读调用点（形状等价）。

#nullable enable

using System;

namespace AIQuotaBar.Core.Quota;

/// <summary>
/// 一个 utilization 周期的聚合结果：reset 边界 + 周期内 usedPercent 峰值。
/// Swift: (resetsAt: Date, peakPercent: Double)。
/// </summary>
/// <param name="ResetsAt">该周期的 reset 边界（120s 容差合并后的代表值，取组内最大）。</param>
/// <param name="PeakPercent">周期内 usedPercent 峰值（0-100，in-progress 周期取周期内历史 peak）。</param>
public sealed record UtilizationCycle(DateTimeOffset ResetsAt, double PeakPercent);
