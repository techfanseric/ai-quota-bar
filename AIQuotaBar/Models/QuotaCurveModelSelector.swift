import Foundation

/// Chooses which current quota windows receive area curves.
///
/// Existing short windows remain curves. For each Codex account without a
/// visible short curve, the canonical Weekly window is promoted as a fallback.
enum QuotaCurveModelSelector {
    static func curveModelIDs(
        in models: [ModelUsageData],
        renderableModelIDs: Set<String>
    ) -> Set<String> {
        let renderableModels = models.filter {
            renderableModelIDs.contains($0.id)
        }
        var result = Set(renderableModels
            .filter(\.isShortCurrentInterval)
            .map(\.id))

        let codexAccounts = Dictionary(grouping: renderableModels.filter {
            $0.provider == .codex
        }) {
            $0.normalizedAccountName
        }

        for accountModels in codexAccounts.values {
            let hasVisibleShortCurve = accountModels.contains {
                $0.isShortCurrentInterval
                    && !$0.isFullQuotaUnused
                    && !$0.isExhaustedCurrentInterval
            }
            guard !hasVisibleShortCurve,
                  let weekly = preferredWeeklyWindow(in: accountModels) else {
                continue
            }
            result.insert(weekly.id)
        }

        return result
    }

    private static func preferredWeeklyWindow(
        in models: [ModelUsageData]
    ) -> ModelUsageData? {
        models
            .filter(\.isCodexWeeklyCurveWindow)
            .min { lhs, rhs in
                let lhsPriority = weeklyPriority(lhs)
                let rhsPriority = weeklyPriority(rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.modelName.localizedStandardCompare(rhs.modelName)
                    == .orderedAscending
            }
    }

    private static func weeklyPriority(_ model: ModelUsageData) -> Int {
        let name = model.modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if name == "weekly" { return 0 }
        if name.contains("weekly") && !name.contains("spark") { return 1 }
        if name.contains("weekly") { return 2 }
        return 3
    }
}
