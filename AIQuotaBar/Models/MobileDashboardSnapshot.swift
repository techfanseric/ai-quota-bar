import Foundation

struct MobileDashboardSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let language: String
    let macName: String
    let appVersion: String
    let connectivity: String
    let menuBar: MobileMenuBarQuotaSnapshot
    let quota: MobileQuotaSnapshot
    let activitySummary: MobileActivitySummarySnapshot
    let protection: MobileProtectionSnapshot
    let route: MobileRouteSnapshot
    let connections: MobileConnectionsSnapshot

    func hasSameContent(as other: MobileDashboardSnapshot) -> Bool {
        schemaVersion == other.schemaVersion
            && language == other.language
            && macName == other.macName
            && appVersion == other.appVersion
            && connectivity == other.connectivity
            && menuBar == other.menuBar
            && quota == other.quota
            && activitySummary == other.activitySummary
            && protection == other.protection
            && route == other.route
            && connections == other.connections
    }
}

/// Read-only values used by the native status item's quota ring and pace
/// indicator. The mobile page can mirror the exact menu-bar selection without
/// attempting to infer it from the independently selected dashboard models.
struct MobileMenuBarQuotaSnapshot: Codable, Equatable {
    let state: String
    let providerID: String
    let modelName: String?
    let remainingPercent: Double?
    let ringPercent: Double?
    let paceDeltaPercent: Double?
    let resetsAt: Date?
    let isLowQuota: Bool
    let appearance: String
    let paceDisplayMode: String
}

struct MobileQuotaSnapshot: Codable, Equatable {
    let state: String
    let lastRefreshAt: Date?
    let primaryRemainingPercent: Double?
    let warningThresholdPercent: Double?
    let errors: [String]
    let providers: [MobileProviderQuotaSnapshot]
}

struct MobileProviderQuotaSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let subscriptionTitle: String?
    let subscriptionEndsAt: Date?
    let models: [MobileModelQuotaSnapshot]
}

struct MobileModelQuotaSnapshot: Codable, Equatable {
    /// Stable position in the user's mobile-dashboard selection (zero or one).
    /// The private selection key itself is deliberately not encoded.
    let displayOrder: Int
    /// The first selected model is the mobile dashboard's primary model.
    let isPrimary: Bool
    let accountName: String?
    let modelName: String
    let plan: String?
    let source: String?
    let detail: String?
    let remainingText: String
    let remainingPercent: Double
    let total: Int
    let remaining: Int
    let startsAt: Date?
    let resetsAt: Date?
    let resetText: String
    let isShortWindow: Bool
    let isExhausted: Bool
    let isFull: Bool
    /// Mirrors `ModelUsageData.isCurrentIntervalPercentMode`, so clients do
    /// not infer chart units from suffixes or missing counts.
    let isCurrentIntervalPercentMode: Bool
    /// Credits-style quotas color the remaining portion, unlike the default
    /// utilization tint. This exposes display semantics only, not controls.
    let usesReverseProgressTint: Bool
    /// The result of the native `QuotaCurveModelSelector` for this model.
    let rendersAreaChart: Bool
    /// Explicit native pace availability and rendering semantics.
    let hasCurrentIntervalPace: Bool
    let paceStage: String?
    let paceGuideTone: String?
    let paceGuideExpectedUsedPercent: Double?
    let paceGuideExpectedRemaining: Double?
    let paceGuideShowsMarker: Bool
    let weeklyTotal: Int
    let weeklyRemaining: Int
    let weeklyRemainingPercent: Int?
    let weeklyUnlimited: Bool
    let paceDeltaPercent: Double?
    let sampledAt: Date?
    let samples: [MobileQuotaSampleSnapshot]
    let cycles: [MobileUtilizationCycleSnapshot]
}

struct MobileActivitySummarySnapshot: Codable, Equatable {
    let state: String
    let activeTaskCount: Int
    let oldestStartedAt: Date?
    let elapsedSeconds: TimeInterval?
    let lastActivityAt: Date?
    let phase: String
    let toolCategory: String?
    let toolStatus: String?
    /// Omitted unless the user explicitly enabled task-detail sharing while
    /// manual pairing is required. An empty array means sharing is on but no
    /// current safe commentary is available.
    let progressLines: [String]?
    let recentEvents: [MobileActivityEventSnapshot]
    let tasks: [MobileActivityTaskSnapshot]

    init(
        state: String,
        activeTaskCount: Int,
        oldestStartedAt: Date?,
        elapsedSeconds: TimeInterval?,
        lastActivityAt: Date?,
        phase: String = "unknown",
        toolCategory: String? = nil,
        toolStatus: String? = nil,
        progressLines: [String]? = nil,
        recentEvents: [MobileActivityEventSnapshot],
        tasks: [MobileActivityTaskSnapshot] = []
    ) {
        self.state = state
        self.activeTaskCount = activeTaskCount
        self.oldestStartedAt = oldestStartedAt
        self.elapsedSeconds = elapsedSeconds
        self.lastActivityAt = lastActivityAt
        self.phase = phase
        self.toolCategory = toolCategory
        self.toolStatus = toolStatus
        self.progressLines = progressLines
        self.recentEvents = recentEvents
        self.tasks = tasks
    }
}

struct MobileActivityTaskSnapshot: Codable, Equatable {
    let state: String
    let title: String?
    let projectName: String?
    let gitBranch: String?
    let source: String?
    let model: String?
    let modelProvider: String?
    let reasoningEffort: String?
    let sandboxPolicy: String?
    let approvalMode: String?
    let tokensUsed: Int64?
    let activeSubtaskCount: Int
    let subtaskNames: [String]?
    let createdAt: Date?
    let startedAt: Date?
    let elapsedSeconds: TimeInterval?
    let lastActivityAt: Date?
    let cliVersion: String?
    let phase: String
    let toolCategory: String?
    let toolStatus: String?
    let progressLines: [String]?
    let recentEvents: [MobileActivityEventSnapshot]
}

struct MobileActivityEventSnapshot: Codable, Equatable {
    let kind: String
    let at: Date
}

struct MobileQuotaSampleSnapshot: Codable, Equatable {
    let timestamp: Date
    /// Raw remaining count from the native sample. `remainingPercent` stays
    /// available for existing percent-based clients.
    let remaining: Int
    let remainingPercent: Double
}

struct MobileUtilizationCycleSnapshot: Codable, Equatable {
    let resetsAt: Date
    let usedPercent: Double
}

struct MobileProtectionSnapshot: Codable, Equatable {
    let isEnabled: Bool
    let activeTaskCount: Int
    let hasActiveTasks: Bool
    let status: String
    let statusDetail: String?
    let keepDisplayAwake: Bool
    let keepDisplayAwakeEffective: Bool
    let preventScreenSaver: Bool
    let preventScreenSaverEffective: Bool
    let hookStatus: String
    let hookActionRequired: Bool
    let closedLidEnabled: Bool
    let closedLidStatus: String
    let closedLidDetail: String?
    let closedLidActionRequired: Bool
    let lastActivityAt: Date?
}

struct MobileRouteSnapshot: Codable, Equatable {
    let state: String
    let groupName: String?
    let selectedRouteName: String?
    let selectedRouteType: String?
    let selectedRouteDelay: Int?
    let clientName: String?
    let autoRecoveryEnabled: Bool
    let isSpeedTesting: Bool
    let statusMessage: String?
    let lastTestedAt: Date?
    let recentSwitches: [MobileRouteSwitchSnapshot]
}

struct MobileRouteSwitchSnapshot: Codable, Equatable {
    let switchedAt: Date
    let fromRoute: String
    let toRoute: String
}

struct MobileConnectionsSnapshot: Codable, Equatable {
    let state: String
    let stateDetail: String?
    let observedAt: Date?
    let clientName: String?
    let isLive: Bool
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double
    let activeCount: Int
    /// Longest duration, in seconds, among every currently active matching
    /// connection. Nil means there are no active matching connections.
    let longestActiveDuration: TimeInterval?
    let history: [MobileConnectionHistorySnapshot]
    let active: [MobileActiveConnectionSnapshot]
}

struct MobileConnectionHistorySnapshot: Codable, Equatable {
    let timestamp: Date
    let connectionCount: Int
    let oldestConnectionAge: TimeInterval
    /// Per-connection ages for the native 60-bucket dot matrix. This contains
    /// no host, process, route, or connection identifier.
    let connectionAges: [TimeInterval]
}

struct MobileActiveConnectionSnapshot: Codable, Equatable {
    let host: String
    let network: String?
    let route: String?
    let duration: TimeInterval
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double
}

enum MobileDashboardAccountPrivacy {
    static func displayName(
        _ accountName: String?,
        masksAccountNames: Bool
    ) -> String? {
        guard let accountName,
              !accountName.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard masksAccountNames else { return accountName }

        let normalized = accountName.trimmingCharacters(
            in: .whitespacesAndNewlines)

        if let atIndex = normalized.lastIndex(of: "@") {
            let localPart = normalized[..<atIndex]
            let domain = normalized[normalized.index(after: atIndex)...]
            let prefix = localPart.count > 1
                ? localPart.first.map(String.init) ?? ""
                : ""
            return "\(prefix)•••@\(domain)"
        }

        switch normalized.count {
        case 0, 1:
            return "•••"
        case 2:
            return "\(normalized.prefix(1))•••"
        default:
            return "\(normalized.prefix(2))•••"
        }
    }
}
