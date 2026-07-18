import Foundation

/// Which provider should own the single menu-bar glance target.
enum MenuBarContentSelection: String, CaseIterable, Codable, Identifiable {
    case automatic
    case codex
    case miniMax = "minimax"

    static let storageKey = "menuBarContentSelection"

    var id: String { rawValue }

    var provider: UsageProvider? {
        switch self {
        case .automatic: return nil
        case .codex: return .codex
        case .miniMax: return .miniMax
        }
    }
}

/// How the selected provider is rendered in the macOS menu bar.
enum MenuBarAppearance: String, CaseIterable, Codable, Identifiable {
    case detailedText
    case compactRing

    static let storageKey = "menuBarAppearance"

    var id: String { rawValue }
}

/// How precisely the split Codex pace glyph maps a pace delta to center fill.
enum MenuBarPaceDisplayMode: String, CaseIterable, Codable, Identifiable {
    /// Preserve the three glanceable 1/3, 2/3, and full-fill levels.
    case staged
    /// Map every percentage point directly to the filled width.
    case continuous

    static let storageKey = "menuBarPaceDisplayMode"

    var id: String { rawValue }
}

enum MenuBarSnapshotState: Equatable {
    case loading
    case ready
    case unavailable
    case failed
}

enum MenuBarPaceDirection: Equatable {
    case deficit
    case onTrack
    case reserve
}

/// Pace encoding for the split center circle. The user can favor either exact
/// percentage mapping or the more glanceable 2 / 6 / 12 percentage-point buckets.
struct MenuBarPaceGlyph: Equatable {
    let direction: MenuBarPaceDirection
    let fillFraction: Double

    init(deltaPercent: Double?, mode: MenuBarPaceDisplayMode = .staged) {
        guard let deltaPercent else {
            direction = .onTrack
            fillFraction = 0
            return
        }

        switch mode {
        case .staged:
            guard abs(deltaPercent) > 2 else {
                direction = .onTrack
                fillFraction = 0
                return
            }

            direction = deltaPercent < 0 ? .deficit : .reserve
            switch abs(deltaPercent) {
            case ...6:
                fillFraction = 1.0 / 3.0
            case ...12:
                fillFraction = 2.0 / 3.0
            default:
                fillFraction = 1
            }
        case .continuous:
            guard abs(deltaPercent) > 0.0001 else {
                direction = .onTrack
                fillFraction = 0
                return
            }
            direction = deltaPercent < 0 ? .deficit : .reserve
            fillFraction = min(1, abs(deltaPercent) / 100)
        }
    }
}

/// One deterministic frame in the refresh self-test loop.
/// The outer Weekly ring sweeps continuously while the center demonstrates
/// deficit, on-pace, and reserve in three equal phases.
struct MenuBarSelfTestFrame: Equatable {
    static let cycleDuration: TimeInterval = 3

    let ringPercent: Double
    let paceDeltaPercent: Double

    static func frame(
        elapsed: TimeInterval,
        paceDisplayMode: MenuBarPaceDisplayMode = .staged
    ) -> MenuBarSelfTestFrame {
        let safeElapsed = max(0, elapsed)
        let cyclePosition = safeElapsed
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        let ringPercent = 50 - 42 * cos(cyclePosition * 2 * .pi)
        let phasePosition = cyclePosition * 3
        let phase = min(2, Int(phasePosition))
        let localPosition = phasePosition - Double(phase)
        let easedPosition = localPosition * localPosition * (3 - 2 * localPosition)
        let demonstratedDelta: Double
        switch paceDisplayMode {
        case .staged:
            // Cross all three 2 / 6 / 12-point buckets during each side's phase.
            demonstratedDelta = 3 + 15 * easedPosition
        case .continuous:
            // Use most of the half-circle so the exact-width movement is legible.
            demonstratedDelta = 15 + 75 * easedPosition
        }

        switch phase {
        case 0:
            return MenuBarSelfTestFrame(
                ringPercent: ringPercent,
                paceDeltaPercent: -demonstratedDelta)
        case 1:
            return MenuBarSelfTestFrame(
                ringPercent: ringPercent,
                paceDeltaPercent: 0)
        default:
            return MenuBarSelfTestFrame(
                ringPercent: ringPercent,
                paceDeltaPercent: demonstratedDelta)
        }
    }
}

/// Protects the glance target from an inactive Codex weekly placeholder.
/// A weekly quota is monotonic inside one reset window, so a newer zero/low
/// placeholder must not replace a higher sample whose reset is still ahead.
enum MenuBarWeeklyMetricResolver {
    static let regressionTolerance = 2.0

    static func preferredHistoricalEntry(
        liveUsedPercent: Double,
        historyEntries: [UtilizationHistoryEntry],
        now: Date
    ) -> UtilizationHistoryEntry? {
        historyEntries
            .filter { entry in
                guard entry.capturedAt <= now,
                      let resetsAt = entry.resetsAt,
                      resetsAt > now else {
                    return false
                }
                return entry.usedPercent > liveUsedPercent + regressionTolerance
            }
            .max { lhs, rhs in lhs.capturedAt < rhs.capturedAt }
    }
}

/// Structured menu-bar data shared by text and graphical renderers.
/// Keeping the semantics here avoids parsing the formatted status-bar string.
struct MenuBarSnapshot: Equatable {
    let provider: UsageProvider
    let modelName: String?
    let remainingPercent: Double?
    /// Direct fraction for the compact ring. Codex uses Weekly consumed percent;
    /// other providers retain their existing remaining-percent presentation.
    let ringPercent: Double?
    let paceDeltaPercent: Double?
    let resetsAt: Date?
    let state: MenuBarSnapshotState
    let isLowQuota: Bool
    let tooltip: String

    var providerInitial: String {
        switch provider {
        case .codex: return "C"
        case .miniMax: return "M"
        case .glm: return "G"
        }
    }
}
