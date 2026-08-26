import CodexBarCore
import Foundation

@MainActor
enum MobileDashboardSnapshotBuilder {
    static func make(
        usageViewModel: UsageViewModel,
        connectivityMonitor: CodexConnectivityMonitor,
        protectionCoordinator: CodexSleepProtectionCoordinator,
        routeViewModel: ClashRouteViewModel,
        connectionViewModel: ClashConnectionViewModel,
        masksAccountNames: Bool,
        selectedModelKeys: [MobileDashboardModelSelectionKey],
        lastRouteTestedAt: Date?,
        sharesTaskProgressText: Bool = false
    ) -> MobileDashboardSnapshot {
        let language = usageViewModel.appLanguage
        let sourceSections = usageViewModel.providerUsageSections
        let allModels = sourceSections.flatMap(\.models)
        let now = Date()
        let renderableModelIDs = Set(allModels.filter { model in
            guard model.containsCurrentInterval(at: now) else {
                return false
            }
            if model.parsedDetail.source == "Cloud",
               let sampledAt = model.sampledAt,
               let interval = usageViewModel
                .cloudCurrentWindowVisibilityLimit.interval {
                return now.timeIntervalSince(sampledAt) <= interval
            }
            return true
        }.map(\.id))
        let curveModelIDs = QuotaCurveModelSelector.curveModelIDs(
            in: allModels,
            renderableModelIDs: renderableModelIDs)
        let selectedModels = selectedModelKeys.compactMap { selection in
            allModels.first { selection.matches($0) }
        }
        var selectedDisplayOrder:
            [MobileDashboardModelSelectionKey: Int] = [:]
        for (index, model) in selectedModels.enumerated() {
            selectedDisplayOrder[model.mobileDashboardSelectionKey] = index
        }
        let selectedKeySet = Set(selectedModelKeys)
        let sections = sourceSections.compactMap {
            data -> UsageData? in
            let models = data.models.filter {
                selectedKeySet.contains(
                    $0.mobileDashboardSelectionKey)
            }
            return models.isEmpty ? nil : data.withModels(models)
        }
        let providerSnapshots = sections.map { data in
            MobileProviderQuotaSnapshot(
                id: data.provider.rawValue,
                name: data.provider.displayName,
                subscriptionTitle: data.subscribeTitle,
                subscriptionEndsAt: data.subscribeEndTime,
                models: data.models.map { model in
                    let displayOrder = selectedDisplayOrder[
                        model.mobileDashboardSelectionKey
                    ] ?? 0
                    return modelSnapshot(
                        model,
                        viewModel: usageViewModel,
                        displayOrder: displayOrder,
                        isPrimary: displayOrder == 0,
                        rendersAreaChart:
                            curveModelIDs.contains(model.id),
                        masksAccountNames: masksAccountNames)
                })
        }

        let quotaState: String
        if usageViewModel.isLoading && providerSnapshots.isEmpty {
            quotaState = "loading"
        } else if !providerSnapshots.isEmpty {
            quotaState = "ready"
        } else if usageViewModel.error != nil {
            quotaState = "error"
        } else {
            quotaState = "empty"
        }

        let providerErrors = UsageProvider.allCases.compactMap { provider in
            usageViewModel.providerErrors[provider].map {
                "\(provider.displayName): "
                    + MobileDashboardSafeText.usageErrorDescription(
                        $0,
                        language: language)
            }
        }
        let generalErrors = usageViewModel.error.map {
            [
                MobileDashboardSafeText.usageErrorDescription(
                    $0,
                    language: language),
            ]
        } ?? []
        let cloudErrors = usageViewModel.cloudUsageLoadError == nil
            ? []
            : [MobileDashboardSafeText.cloudUsageError(language: language)]

        return MobileDashboardSnapshot(
            schemaVersion: 3,
            generatedAt: Date(),
            language: language.rawValue,
            macName: Host.current().localizedName
                ?? ProcessInfo.processInfo.hostName,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "dev",
            connectivity: connectivityState(connectivityMonitor.state),
            menuBar: menuBarSnapshot(usageViewModel),
            quota: MobileQuotaSnapshot(
                state: quotaState,
                lastRefreshAt: usageViewModel.lastRefreshTime,
                primaryRemainingPercent:
                    selectedModels.first.map {
                        clampedPercent(
                            $0.currentIntervalPercentageRemaining)
                    },
                warningThresholdPercent:
                    usageViewModel.effectiveWarningThreshold > 0
                        ? clampedPercent(
                            usageViewModel.effectiveWarningThreshold)
                        : nil,
                errors: providerErrors + generalErrors + cloudErrors,
                providers: providerSnapshots),
            activitySummary: activitySummary(
                protectionCoordinator,
                now: now,
                sharesTaskProgressText: sharesTaskProgressText),
            protection: protectionSnapshot(protectionCoordinator),
            route: routeSnapshot(
                routeViewModel,
                lastTestedAt: lastRouteTestedAt),
            connections: connectionsSnapshot(connectionViewModel))
    }

    private static func modelSnapshot(
        _ model: ModelUsageData,
        viewModel: UsageViewModel,
        displayOrder: Int,
        isPrimary: Bool,
        rendersAreaChart: Bool,
        masksAccountNames: Bool
    ) -> MobileModelQuotaSnapshot {
        let pace = model.currentIntervalPace
        let totalForSamples = model.currentIntervalTotal
        let recordedSamples = viewModel.samples(for: model)
        let plottableSamples: [ModelQuotaSample]
        if model.isCurrentIntervalPercentMode {
            let samplesWithPercent = recordedSamples.filter {
                $0.percent != nil
            }
            plottableSamples = samplesWithPercent.isEmpty
                ? recordedSamples.last.map { [$0] } ?? []
                : samplesWithPercent
        } else {
            plottableSamples = recordedSamples
        }
        let sourceSamples = MobileDashboardDownsampling.equidistant(
            plottableSamples,
            maximumCount: 240)
        let samples = sourceSamples.map { sample in
            let percent: Double
            if let directPercent = sample.percent {
                percent = Double(directPercent)
            } else if model.isCurrentIntervalPercentMode {
                percent = model.currentIntervalPercentageRemaining
            } else if totalForSamples > 0 {
                percent = Double(sample.remaining)
                    / Double(totalForSamples) * 100
            } else {
                percent = model.currentIntervalPercentageRemaining
            }
            return MobileQuotaSampleSnapshot(
                timestamp: sample.timestamp,
                remaining: sample.remaining,
                remainingPercent: clampedPercent(percent))
        }
        let consumptionForecasts = QuotaConsumptionForecaster.forecasts(
            samples: recordedSamples,
            isPercentMode: model.isCurrentIntervalPercentMode,
            maximumLookbackIntervals:
                viewModel.quotaForecastLookbackIntervals,
            maximumSampleGap:
                QuotaConsumptionForecaster.maximumSampleGap(
                    refreshInterval: viewModel.refreshInterval)
        ).map { forecast in
            MobileQuotaConsumptionForecastSnapshot(
                lookbackIntervals: forecast.lookbackIntervals,
                consumptionPerSecond: forecast.consumptionPerSecond,
                startsAt: forecast.startsAt,
                startingRemaining: forecast.startingRemaining,
                exhaustsAt: forecast.exhaustsAt)
        }
        let cycleLimit = model.isShortCurrentInterval ? 30 : 12
        var sourceCycles = viewModel.utilizationCycles(
            for: model,
            limit: cycleLimit
        )
        if model.parsedDetail.source == "Cloud" {
            let visibilityLimit = model.isShortCurrentInterval
                ? viewModel.cloudShortCyclesVisibilityLimit
                : viewModel.cloudWeeklyCyclesVisibilityLimit
            if let interval = visibilityLimit.interval {
                let now = Date()
                sourceCycles = sourceCycles.filter { cycle in
                    now.timeIntervalSince(cycle.resetsAt) <= interval
                }
            }
        }
        let cycles = sourceCycles.map {
            MobileUtilizationCycleSnapshot(
                resetsAt: $0.resetsAt,
                usedPercent: clampedPercent($0.peakPercent))
        }

        return MobileModelQuotaSnapshot(
            displayOrder: displayOrder,
            isPrimary: isPrimary,
            accountName: MobileDashboardAccountPrivacy.displayName(
                model.accountName,
                masksAccountNames: masksAccountNames),
            modelName: model.modelName,
            plan: model.parsedDetail.plan,
            source: model.parsedDetail.source,
            detail: model.parsedDetail.rest,
            remainingText: model.currentIntervalRemainingText,
            remainingPercent: clampedPercent(
                model.currentIntervalPercentageRemaining),
            total: model.currentIntervalTotal,
            remaining: model.currentIntervalRemaining,
            startsAt: model.startTime,
            resetsAt: model.endTime,
            resetText: model.resetTimeText,
            isShortWindow: model.isShortCurrentInterval,
            isExhausted: model.isExhaustedCurrentInterval,
            isFull: model.isFullQuotaUnused,
            isCurrentIntervalPercentMode:
                model.isCurrentIntervalPercentMode,
            usesReverseProgressTint:
                model.progressBarPercentOverride != nil,
            rendersAreaChart: rendersAreaChart,
            hasCurrentIntervalPace: pace != nil,
            paceStage: pace.map { paceStage($0.stage) },
            paceGuideTone: pace.map {
                $0.stage.isAhead ? "reserve" : "deficit"
            },
            paceGuideExpectedUsedPercent: pace.flatMap { _ in
                model.currentIntervalPaceUsedPercent.map(clampedPercent)
            },
            paceGuideExpectedRemaining: pace.flatMap { _ in
                model.currentIntervalPaceRemaining
            },
            paceGuideShowsMarker:
                pace.map { $0.stage != .onTrack } ?? false,
            weeklyTotal: model.weeklyTotal,
            weeklyRemaining: model.weeklyRemaining,
            weeklyRemainingPercent: model.weeklyRemainingPercent.map {
                min(100, max(0, $0))
            },
            weeklyUnlimited: model.isWeeklyUnlimited,
            paceDeltaPercent: model.currentIntervalPaceDeltaPercent,
            sampledAt: model.sampledAt,
            samples: samples,
            consumptionForecasts: consumptionForecasts,
            cycles: cycles)
    }

    static func activitySummary(
        _ coordinator: CodexSleepProtectionCoordinator,
        now: Date,
        sharesTaskProgressText: Bool = false
    ) -> MobileActivitySummarySnapshot {
        let summary = coordinator.mobileActivitySummary(now: now)
        return MobileActivitySummarySnapshot(
            state: summary.state.rawValue,
            activeTaskCount: summary.activeTaskCount,
            oldestStartedAt: summary.oldestStartedAt,
            elapsedSeconds: summary.elapsedSeconds,
            lastActivityAt: summary.lastActivityAt,
            phase: summary.phase.rawValue,
            toolCategory: summary.toolCategory?.rawValue,
            toolStatus: summary.toolStatus?.rawValue,
            progressLines: sharesTaskProgressText
                ? summary.progressLines
                : nil,
            recentEvents: summary.recentEvents.map {
                MobileActivityEventSnapshot(
                    kind: $0.kind.rawValue,
                    at: $0.at)
            },
            tasks: summary.tasks.map { task in
                MobileActivityTaskSnapshot(
                    state: task.state.rawValue,
                    title: sharesTaskProgressText ? task.title : nil,
                    projectName: sharesTaskProgressText
                        ? task.projectName : nil,
                    gitBranch: sharesTaskProgressText
                        ? task.gitBranch : nil,
                    source: task.source,
                    model: task.model,
                    modelProvider: task.modelProvider,
                    reasoningEffort: task.reasoningEffort,
                    sandboxPolicy: task.sandboxPolicy,
                    approvalMode: task.approvalMode,
                    tokensUsed: task.tokensUsed,
                    activeSubtaskCount: task.activeSubtaskCount,
                    subtaskNames: sharesTaskProgressText
                        ? task.subtaskNames : nil,
                    createdAt: task.createdAt,
                    startedAt: task.startedAt,
                    elapsedSeconds: task.elapsedSeconds,
                    lastActivityAt: task.lastActivityAt,
                    cliVersion: task.cliVersion,
                    phase: task.phase.rawValue,
                    toolCategory: task.toolCategory?.rawValue,
                    toolStatus: task.toolStatus?.rawValue,
                    progressLines: sharesTaskProgressText
                        ? task.progressLines : nil,
                    recentEvents: task.recentEvents.map {
                        MobileActivityEventSnapshot(
                            kind: $0.kind.rawValue,
                            at: $0.at)
                    })
            })
    }

    private static func paceStage(_ stage: UsagePace.Stage) -> String {
        switch stage {
        case .onTrack: return "onTrack"
        case .slightlyAhead: return "slightlyAhead"
        case .ahead: return "ahead"
        case .farAhead: return "farAhead"
        case .slightlyBehind: return "slightlyBehind"
        case .behind: return "behind"
        case .farBehind: return "farBehind"
        }
    }

    private static func protectionSnapshot(
        _ coordinator: CodexSleepProtectionCoordinator
    ) -> MobileProtectionSnapshot {
        let protectionStatus: (String, String?)
        switch coordinator.protectionStatus {
        case .idle:
            protectionStatus = ("idle", nil)
        case .active:
            protectionStatus = ("active", nil)
        case .failed:
            protectionStatus = ("failed", nil)
        }

        let hookStatus: String
        let hookActionRequired: Bool
        switch coordinator.hookInstallationStatus {
        case .notChecked:
            hookStatus = "notChecked"
            hookActionRequired = false
        case .installed:
            hookStatus = "installed"
            hookActionRequired = false
        case .helperMissing:
            hookStatus = "helperMissing"
            hookActionRequired = true
        case .failed:
            hookStatus = "failed"
            hookActionRequired = true
        }

        let lidStatus: (String, String?)
        let closedLidActionRequired: Bool
        switch coordinator.closedLidModeManager.status {
        case .disabled:
            lidStatus = ("disabled", nil)
            closedLidActionRequired = false
        case .requiresInstallation:
            lidStatus = ("requiresInstallation", nil)
            closedLidActionRequired = true
        case .installing:
            lidStatus = ("installing", nil)
            closedLidActionRequired = false
        case .checking:
            lidStatus = ("checking", nil)
            closedLidActionRequired = false
        case .ready:
            lidStatus = ("ready", nil)
            closedLidActionRequired = false
        case .active:
            lidStatus = ("active", nil)
            closedLidActionRequired = false
        case let .suspendedLowBattery(percentage):
            lidStatus = ("lowBattery", String(percentage))
            closedLidActionRequired = false
        case .suspendedThermal:
            lidStatus = ("thermal", nil)
            closedLidActionRequired = false
        case .suspendedMaximumDuration:
            lidStatus = ("maximumDuration", nil)
            closedLidActionRequired = false
        case .unavailable:
            lidStatus = ("unavailable", nil)
            closedLidActionRequired = true
        }

        return MobileProtectionSnapshot(
            isEnabled: coordinator.isEnabled,
            activeTaskCount: coordinator.activeTurnCount,
            hasActiveTasks: coordinator.activeTurnCount > 0,
            status: protectionStatus.0,
            statusDetail: protectionStatus.1,
            keepDisplayAwake: coordinator.keepDisplayAwake,
            keepDisplayAwakeEffective:
                coordinator.keepDisplayAwakeEffective,
            preventScreenSaver: coordinator.preventScreenSaver,
            preventScreenSaverEffective:
                coordinator.preventScreenSaverEffective,
            hookStatus: hookStatus,
            hookActionRequired: hookActionRequired,
            closedLidEnabled: coordinator.closedLidModeManager.isEnabled,
            closedLidStatus: lidStatus.0,
            closedLidDetail: lidStatus.1,
            closedLidActionRequired: closedLidActionRequired,
            lastActivityAt: coordinator.lastEventAt)
    }

    private static func routeSnapshot(
        _ viewModel: ClashRouteViewModel,
        lastTestedAt: Date?
    ) -> MobileRouteSnapshot {
        let state: String
        switch viewModel.phase {
        case .idle:
            state = "idle"
        case .loading:
            state = "loading"
        case .ready:
            state = "ready"
        case .unavailable:
            state = "unavailable"
        }

        let selectedRoute = viewModel.routes.first(where: \.isSelected)
            ?? viewModel.selectedRouteName.flatMap { selectedName in
                viewModel.routes.first { $0.name == selectedName }
            }

        return MobileRouteSnapshot(
            state: state,
            groupName: viewModel.groupName,
            selectedRouteName: viewModel.selectedRouteName,
            selectedRouteType: selectedRoute?.type,
            selectedRouteDelay: selectedRoute?.delay,
            clientName: viewModel.clientName,
            autoRecoveryEnabled: viewModel.autoRecoveryEnabled,
            isSpeedTesting: viewModel.isSpeedTesting,
            statusMessage: nil,
            lastTestedAt: lastTestedAt,
            recentSwitches: viewModel.switchHistory.map {
                MobileRouteSwitchSnapshot(
                    switchedAt: $0.switchedAt,
                    fromRoute: $0.fromRoute,
                    toRoute: $0.toRoute)
            })
    }

    private static func connectionsSnapshot(
        _ viewModel: ClashConnectionViewModel
    ) -> MobileConnectionsSnapshot {
        let state: String
        switch viewModel.phase {
        case .idle:
            state = "idle"
        case .loading:
            state = "loading"
        case .ready:
            state = "ready"
        case .unavailable:
            state = "unavailable"
        }

        return MobileConnectionsSnapshot(
            state: state,
            stateDetail: nil,
            observedAt: viewModel.observedAt,
            clientName: viewModel.clientName,
            isLive: viewModel.isLive,
            uploadBytesPerSecond: viewModel.uploadSpeed,
            downloadBytesPerSecond: viewModel.downloadSpeed,
            activeCount: viewModel.activeConnectionCount,
            longestActiveDuration: MobileDashboardPayloadLimits
                .longestActiveDuration(viewModel.connections),
            history: viewModel.history.map { sample in
                let connectionAges = MobileDashboardPayloadLimits
                    .boundedConnectionAges(sample.connectionAges)
                return MobileConnectionHistorySnapshot(
                    timestamp: sample.timestamp,
                    connectionCount: sample.connectionCount,
                    oldestConnectionAge:
                        connectionAges.max() ?? 0,
                    connectionAges: connectionAges)
            },
            active: MobileDashboardPayloadLimits.boundedActiveConnections(
                viewModel.connections
            ).map {
                MobileActiveConnectionSnapshot(
                    host: $0.host,
                    network: $0.network,
                    route: $0.primaryChain,
                    duration: $0.duration,
                    uploadBytesPerSecond: $0.uploadSpeed,
                    downloadBytesPerSecond: $0.downloadSpeed)
            })
    }

    private static func connectivityState(
        _ state: CodexConnectivityState
    ) -> String {
        switch state {
        case .unknown: return "unknown"
        case .reachable: return "reachable"
        case .unreachable: return "unreachable"
        }
    }

    private static func menuBarSnapshot(
        _ viewModel: UsageViewModel
    ) -> MobileMenuBarQuotaSnapshot {
        let snapshot = viewModel.menuBarSnapshot
        let state: String
        switch snapshot.state {
        case .loading: state = "loading"
        case .ready: state = "ready"
        case .unavailable: state = "unavailable"
        case .failed: state = "failed"
        }

        return MobileMenuBarQuotaSnapshot(
            state: state,
            providerID: snapshot.provider.rawValue,
            modelName: snapshot.modelName,
            remainingPercent: snapshot.remainingPercent.map {
                clampedPercent($0)
            },
            ringPercent: snapshot.ringPercent.map {
                clampedPercent($0)
            },
            paceDeltaPercent: snapshot.paceDeltaPercent,
            resetsAt: snapshot.resetsAt,
            isLowQuota: snapshot.isLowQuota,
            appearance: viewModel.menuBarAppearance.rawValue,
            paceDisplayMode:
                viewModel.menuBarPaceDisplayMode.rawValue)
    }

    private static func clampedPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

}

enum MobileDashboardSafeText {
    static func usageErrorDescription(
        _ error: UsageError,
        language: AppLanguage
    ) -> String {
        switch error {
        case .invalidURL:
            return language.text(.errorInvalidURL)
        case .networkError:
            return language.text(.errorNetwork)
        case .invalidResponse:
            return language.text(.errorInvalidResponse)
        case .apiError:
            return language.text(.errorAPI)
        case .keychainError:
            return language.text(.errorKeychain)
        case .notConfigured:
            return language.text(.errorNotConfigured)
        }
    }

    static func cloudUsageError(language: AppLanguage) -> String {
        language == .simplifiedChinese
            ? "云端用量暂时无法载入。"
            : "Cloud usage could not be loaded."
    }
}

enum MobileDashboardPayloadLimits {
    static let maximumActiveConnections = 100
    static let maximumConnectionAgesPerSample = 100

    static func boundedActiveConnections<Element>(
        _ values: [Element]
    ) -> [Element] {
        Array(values.prefix(maximumActiveConnections))
    }

    static func boundedConnectionAges(
        _ values: [TimeInterval]
    ) -> [TimeInterval] {
        Array(
            values.lazy
                .filter(\.isFinite)
                .map { max(0, $0) }
                .prefix(maximumConnectionAgesPerSample))
    }

    static func longestActiveDuration(
        _ values: [ClashActiveConnection]
    ) -> TimeInterval? {
        values.lazy
            .map(\.duration)
            .filter(\.isFinite)
            .map { max(0, $0) }
            .max()
    }
}

enum MobileDashboardDownsampling {
    static func equidistant<Element>(
        _ values: [Element],
        maximumCount: Int
    ) -> [Element] {
        guard maximumCount > 0 else { return [] }
        guard values.count > maximumCount else { return values }
        guard maximumCount > 1 else {
            return values.first.map { [$0] } ?? []
        }

        let lastIndex = values.count - 1
        let denominator = Double(maximumCount - 1)
        return (0..<maximumCount).map { outputIndex in
            let sourceIndex = Int(
                (Double(outputIndex) * Double(lastIndex)
                    / denominator).rounded())
            return values[sourceIndex]
        }
    }
}
