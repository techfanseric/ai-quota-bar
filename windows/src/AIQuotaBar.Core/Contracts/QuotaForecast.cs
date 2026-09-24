// Origin: AIQuotaBar/Models/QuotaConsumptionForecast.swift — struct QuotaConsumptionForecast,
// enum QuotaConsumptionForecaster (input/output shapes only; the forecast ALGORITHM is a
// later AIQuotaBar.Core task), and AIQuotaBar/Models/ModelQuotaSample.swift — struct
// ModelQuotaSample (the forecast's input samples).

#nullable enable

using System;
using System.Collections.Generic;

namespace AIQuotaBar.Core.Contracts;

/// <summary>
/// One recorded quota sample for a single model window (Swift: ModelQuotaSample).
/// Persisted per model as JSON ({provider}.json in the samples store) and uploaded to cloud sync.
/// </summary>
/// <param name="Timestamp">When the sample was taken.</param>
/// <param name="Remaining">Remaining count on the window's native scale (count or percent).</param>
/// <param name="Percent">Remaining percent (0-100) when the window reports percent; else null.</param>
public sealed record ModelQuotaSample(DateTimeOffset Timestamp, int Remaining, int? Percent = null);

/// <summary>
/// One projected consumption line (Swift: QuotaConsumptionForecast).
/// All lines start at the LATEST sample and extrapolate a constant burn rate backwards over
/// `lookbackIntervals` intervals; multiple lines describe different confidence horizons.
/// </summary>
/// <param name="LookbackIntervals">
/// How many sample intervals back the slope was computed from (1 = last two samples).
/// </param>
/// <param name="ConsumptionPerSecond">Units (count or percent points) consumed per second.</param>
/// <param name="StartsAt">The latest sample's timestamp — the anchor of the projection.</param>
/// <param name="StartingRemaining">Remaining value at <paramref name="StartsAt"/>.</param>
/// <param name="ExhaustsAt">Projected full-exhaustion time (StartsAt + StartingRemaining / rate).</param>
public sealed record QuotaConsumptionForecast(
    int LookbackIntervals,
    double ConsumptionPerSecond,
    DateTimeOffset StartsAt,
    double StartingRemaining,
    DateTimeOffset ExhaustsAt);

/// <summary>
/// Input bundle for the forecast computation (Swift: QuotaConsumptionForecaster.forecasts
/// parameter list — algorithm itself deferred to Core).
/// </summary>
/// <param name="Samples">Recent samples for one model window, any order (Swift sorts by timestamp).</param>
/// <param name="IsPercentMode">
/// True when the window's native scale is percent points (ValueSuffix == "%" or the API
/// provides remaining-percent); then <see cref="ModelQuotaSample.Percent"/> is used and samples
/// without it are skipped. False uses <see cref="ModelQuotaSample.Remaining"/>.
/// </param>
/// <param name="MaximumLookbackIntervals">Clamped by Swift to min(max(value, 1), 5).</param>
/// <param name="MaximumSampleGap">
/// Skip a lookback when the gap between its two samples exceeds this (staleness guard);
/// null disables the guard. Swift derives it as max(refreshInterval * 3, 180s).
/// </param>
public sealed record QuotaForecastRequest(
    IReadOnlyList<ModelQuotaSample> Samples,
    bool IsPercentMode,
    int MaximumLookbackIntervals,
    TimeSpan? MaximumSampleGap = null);
