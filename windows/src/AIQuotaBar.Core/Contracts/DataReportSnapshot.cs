// Origin: AIQuotaBar/Models/DataReportSnapshot.swift — struct DataReportSnapshot.
//
// Enum-keyed dictionary shape: Swift's Codable encodes Dictionary<UsageProvider, T> (non-String
// key) as an ARRAY of { "key": ..., "value": ... } objects, e.g.
//   "providerUsageData": [ { "key": "codex", "value": { ... } }, ... ]
// The C# contract mirrors that wire shape explicitly via entry records, so a JSON produced by
// the macOS app (CloudSyncService.rawJSONString — .iso8601 dates, sorted keys, pretty-printed)
// parses here unchanged, and vice versa.
//
// Swift reference construction (UsageViewModel.dataReportSnapshot()): generatedAt = now;
// usageData = the currently selected provider's snapshot (may be null); providerUsageData = the
// per-provider sections currently displayed; modelQuotaSamples = the in-memory sample cache
// keyed by quota identity; utilizationHistories = the in-memory utilization stores.

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Core.Contracts;

/// <summary>One { key, value } element of the provider-keyed UsageData dictionary.</summary>
public sealed record ProviderUsageDataEntry(UsageProvider Key, UsageData Value);

/// <summary>One { key, value } element of the provider-keyed utilization-history dictionary.</summary>
public sealed record ProviderUtilizationHistoriesEntry(UsageProvider Key, ModelUtilizationStoreData Value);

/// <summary>
/// Cloud-sync report snapshot (Swift: DataReportSnapshot) — the full local state bundle behind
/// the "data report" HTML export and debugging payloads.
/// </summary>
/// <param name="GeneratedAt">Snapshot creation time.</param>
/// <param name="UsageData">The primary/selected provider snapshot; null when none loaded.</param>
/// <param name="ProviderUsageData">Per-provider snapshots as a { key, value } array (see file header).</param>
/// <param name="ModelQuotaSamples">
/// Forecast input samples keyed by quota identity string ("provider[:account]:model").
/// </param>
/// <param name="UtilizationHistories">
/// Per-provider utilization stores as a { key, value } array (see file header).
/// </param>
public sealed record DataReportSnapshot(
    DateTimeOffset GeneratedAt,
    UsageData? UsageData,
    IReadOnlyList<ProviderUsageDataEntry> ProviderUsageData,
    IReadOnlyDictionary<string, IReadOnlyList<ModelQuotaSample>> ModelQuotaSamples,
    IReadOnlyList<ProviderUtilizationHistoriesEntry> UtilizationHistories);
