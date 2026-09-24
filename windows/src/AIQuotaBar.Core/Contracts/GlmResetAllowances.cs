// Origin: AIQuotaBar/Models/GLMResetAllowances.swift — struct GLMResetAllowances.
//
// DATA SHAPE ONLY: the static decode(_:) parser (bigmodel.cn envelope, strict
// "yyyy-MM-dd HH:mm:ss" Asia/Shanghai expireTime strings with round-trip verification) and the
// request(for:) builder (endpoint allow-listing) are AIQuotaBar.Providers tasks.
//
// Wire format reference for the deferred Providers task (GET
// https://bigmodel.cn/api/biz/customer-package-reset/list?targetType=PERSONAL):
//   { "code": 200, "success": true,
//     "data": { "targetType": "PERSONAL",
//               "fiveHourResets":  [ { "available": true, "expireTime": "2026-09-25 10:00:00" }, ... ],
//               "weekResets":      [ { "available": true, "expireTime": "2026-09-28 00:00:00" }, ... ] } }
// Only items with available == true are kept; lists are sorted ascending. Non-200 / non-personal
// payloads are rejected (UsageError.invalidResponse).

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// Read-only personal Coding-Plan reset entitlements for GLM (Swift: GLMResetAllowances —
/// "These are not quota credits"). Each entry is the time at which one additional 5h / weekly
/// reset becomes available; already-elapsed entries are retained so "available at time T"
/// filtering stays deterministic (Swift: availableFiveHour(at:) / availableWeekly(at:) — Core logic).
/// </summary>
/// <param name="FiveHourExpirations">Ascending 5h-reset availability times.</param>
/// <param name="WeeklyExpirations">Ascending weekly-reset availability times.</param>
public sealed record GlmResetAllowances(
    IReadOnlyList<DateTimeOffset> FiveHourExpirations,
    IReadOnlyList<DateTimeOffset> WeeklyExpirations);
