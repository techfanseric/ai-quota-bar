import Foundation

struct QuotaConsumptionForecast: Equatable {
    let lookbackIntervals: Int
    let consumptionPerSecond: Double
    let startsAt: Date
    let startingRemaining: Double
    let exhaustsAt: Date
}

enum QuotaConsumptionForecaster {
    static func forecasts(
        samples: [ModelQuotaSample],
        isPercentMode: Bool,
        maximumLookbackIntervals: Int,
        maximumSampleGap: TimeInterval? = nil
    ) -> [QuotaConsumptionForecast] {
        let limit = min(max(maximumLookbackIntervals, 1), 5)
        let sorted = samples
            .compactMap { sample -> (date: Date, remaining: Double)? in
                let remaining: Double
                if isPercentMode {
                    guard let percent = sample.percent else { return nil }
                    remaining = Double(percent)
                } else {
                    remaining = Double(sample.remaining)
                }
                guard remaining.isFinite, remaining >= 0 else { return nil }
                return (sample.timestamp, remaining)
            }
            .sorted { $0.date < $1.date }

        let recent = Array(sorted.suffix(limit + 1))
        guard recent.count >= 2,
              let latest = recent.last,
              latest.remaining > 0 else {
            return []
        }

        var result: [QuotaConsumptionForecast] = []
        let maximumAvailable = recent.count - 1

        for lookback in 1...maximumAvailable {
            let older = recent[recent.count - 1 - lookback]
            let newer = recent[recent.count - lookback]

            if let maximumSampleGap,
               newer.date.timeIntervalSince(older.date) > maximumSampleGap {
                break
            }

            // An increase marks a refill, reset, or correction. Never project
            // through it into an earlier consumption run.
            if newer.remaining > older.remaining {
                break
            }

            let elapsed = latest.date.timeIntervalSince(older.date)
            let consumed = older.remaining - latest.remaining
            guard elapsed > 0, consumed > 0 else { continue }

            let rate = consumed / elapsed
            guard rate.isFinite, rate > 0 else { continue }

            // Several lookbacks can describe effectively the same slope. A
            // single line is clearer than repeatedly darkening that path.
            let isDuplicate = result.contains { existing in
                abs(existing.consumptionPerSecond - rate)
                    / max(existing.consumptionPerSecond, rate) < 0.01
            }
            guard !isDuplicate else { continue }

            result.append(QuotaConsumptionForecast(
                lookbackIntervals: lookback,
                consumptionPerSecond: rate,
                startsAt: latest.date,
                startingRemaining: latest.remaining,
                exhaustsAt: latest.date.addingTimeInterval(
                    latest.remaining / rate)))
        }

        return result
    }

    static func maximumSampleGap(refreshInterval: Int) -> TimeInterval {
        max(Double(refreshInterval) * 3, 180)
    }
}
