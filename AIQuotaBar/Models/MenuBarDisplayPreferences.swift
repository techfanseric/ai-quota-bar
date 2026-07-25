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

/// Pace encoding for the split center circle. Weekly pace deviation is normalized
/// so one day fills half of the active side and two days fill it completely.
struct MenuBarPaceGlyph: Equatable {
    static let weeklyCycleDays = 7.0
    static let fullScaleDeviationDays = 2.0
    static let percentPointsPerDay = 100 / weeklyCycleDays
    static let fullScaleDeltaPercent = percentPointsPerDay * fullScaleDeviationDays

    let direction: MenuBarPaceDirection
    let fillFraction: Double
    /// The active-side outline is reserved for deviation beyond the two-day
    /// fill scale. At or below two days, fill alone communicates magnitude.
    let showsActiveBorder: Bool

    init(deltaPercent: Double?, mode: MenuBarPaceDisplayMode = .staged) {
        guard let deltaPercent else {
            direction = .onTrack
            fillFraction = 0
            showsActiveBorder = false
            return
        }

        let magnitude = abs(deltaPercent)
        let continuousFraction = min(1, magnitude / Self.fullScaleDeltaPercent)
        showsActiveBorder = magnitude > Self.fullScaleDeltaPercent

        switch mode {
        case .staged:
            guard magnitude > 2 else {
                direction = .onTrack
                fillFraction = 0
                return
            }

            direction = deltaPercent < 0 ? .deficit : .reserve
            // Bias staged rendering upward so it remains an alerting view:
            // 25 / 50 / 75 / 100%, with exact one- and two-day anchors.
            fillFraction = min(1, ceil(continuousFraction * 4) / 4)
        case .continuous:
            guard magnitude > 0.0001 else {
                direction = .onTrack
                fillFraction = 0
                return
            }
            direction = deltaPercent < 0 ? .deficit : .reserve
            fillFraction = continuousFraction
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
            // Cross all four alerting levels and finish at two days of deviation.
            demonstratedDelta = 3
                + (MenuBarPaceGlyph.fullScaleDeltaPercent - 3) * easedPosition
        case .continuous:
            // Sweep nearly the full two-day scale while preserving a fine start.
            demonstratedDelta = 1
                + (MenuBarPaceGlyph.fullScaleDeltaPercent - 1) * easedPosition
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

/// Structured menu-bar data shared by text and graphical renderers.
/// Keeping the semantics here avoids parsing the formatted status-bar string.
struct MenuBarSnapshot: Equatable {
    let provider: UsageProvider
    let modelName: String?
    let remainingPercent: Double?
    /// Direct fraction for the compact ring. All providers use remaining percent;
    /// Codex specifically sources it from the Weekly quota window.
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
