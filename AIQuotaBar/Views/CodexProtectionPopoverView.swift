import SwiftUI

@MainActor
struct CodexProtectionPopoverView: View {
    @Bindable var coordinator: CodexSleepProtectionCoordinator
    @Bindable var closedLidModeManager: ClosedLidModeManager
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 0) {
            protectionHeader

            Divider()

            HStack(spacing: 16) {
                compactToggle(
                    language.keepDisplayAwakeCompactTitle(),
                    isOn: $coordinator.keepDisplayAwake
                )
                .disabled(!coordinator.isEnabled)

                compactToggle(
                    language.preventScreenSaverCompactTitle(),
                    isOn: $coordinator.preventScreenSaver
                )
                .disabled(
                    !coordinator.isEnabled
                        || !coordinator.keepDisplayAwake
                )
            }
            .padding(.horizontal, 14)
            .frame(height: 36)

            Divider()
                .padding(.leading, 42)

            closedLidRow
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var protectionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: protectionSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(protectionColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(language.sleepProtectionSectionTitle())
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(protectionStatusText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if shouldOfferHookRetry {
                Button {
                    coordinator.retryHookInstallation()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(language.retryHookInstallationTitle())
            }

            Toggle(
                language.sleepProtectionEnabledTitle(),
                isOn: $coordinator.isEnabled
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
    }

    private func compactToggle(
        _ title: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closedLidRow: some View {
        HStack(spacing: 10) {
            Image(systemName: closedLidSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(closedLidColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(language.allowClosedLidCompactTitle())
                    .font(.system(size: 10, weight: .medium))
                Text(closedLidStatusText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(closedLidStatusHelp)
            }

            Spacer(minLength: 8)

            if let actionTitle = closedLidActionTitle {
                Button(actionTitle) {
                    closedLidModeManager.retryRegistration()
                }
                .controlSize(.mini)
            }

            if isClosedLidOperationInProgress {
                ProgressView()
                    .controlSize(.mini)
            }

            Toggle(
                language.allowClosedLidTitle(),
                isOn: $closedLidModeManager.isEnabled
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(
                !coordinator.isEnabled
                    || isClosedLidOperationInProgress)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var protectionStatusText: String {
        guard coordinator.isEnabled else {
            return language.sleepProtectionCompactOffStatus()
        }

        switch coordinator.protectionStatus {
        case .idle:
            return hookStatusText ?? language.sleepProtectionCompactReadyStatus()
        case .active:
            return language.sleepProtectionCompactActiveStatus(
                turnCount: coordinator.activeTurnCount
            )
        case let .failed(message):
            return language.sleepProtectionFailedStatus(message)
        }
    }

    private var hookStatusText: String? {
        switch coordinator.hookInstallationStatus {
        case .notChecked:
            return language.codexHooksNotCheckedStatus()
        case .installed:
            return nil
        case .helperMissing:
            return language.codexHooksMissingCompactStatus()
        case .failed:
            return language.codexHooksFailedCompactStatus()
        }
    }

    private var protectionSymbol: String {
        guard coordinator.isEnabled else { return "moon.zzz" }
        switch coordinator.protectionStatus {
        case .idle: return "shield"
        case .active: return "bolt.shield.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var protectionColor: Color {
        guard coordinator.isEnabled else { return .secondary }
        switch coordinator.protectionStatus {
        case .idle: return hookStatusText == nil ? .blue : .orange
        case .active: return .green
        case .failed: return .orange
        }
    }

    private var closedLidStatusText: String {
        switch closedLidModeManager.status {
        case .disabled:
            return language.closedLidCompactOffStatus()
        case .requiresInstallation:
            return language
                .closedLidCompactInstallationRequiredStatus()
        case .installing:
            return language.closedLidCompactInstallingStatus()
        case .checking:
            return language.closedLidCompactCheckingStatus()
        case .ready:
            return language.closedLidCompactReadyStatus()
        case .active:
            return language.closedLidCompactActiveStatus()
        case let .suspendedLowBattery(percentage):
            return language.closedLidCompactLowBatteryStatus(percentage)
        case .suspendedThermal:
            return language.closedLidCompactThermalStatus()
        case .suspendedMaximumDuration:
            return language.closedLidCompactMaximumDurationStatus()
        case let .unavailable(message):
            return language.closedLidCompactUnavailableStatus(
                message)
        }
    }

    private var closedLidStatusHelp: String {
        switch closedLidModeManager.status {
        case let .unavailable(message):
            return message
        default:
            return closedLidStatusText
        }
    }

    private var closedLidActionTitle: String? {
        switch closedLidModeManager.status {
        case .requiresInstallation:
            return language.installSleepHelperCompactTitle()
        case .unavailable:
            return language.retrySleepHelperCompactTitle()
        default:
            return nil
        }
    }

    private var isClosedLidOperationInProgress: Bool {
        switch closedLidModeManager.status {
        case .installing, .checking:
            return true
        default:
            return false
        }
    }

    private var closedLidSymbol: String {
        switch closedLidModeManager.status {
        case .disabled: return "laptopcomputer"
        case .requiresInstallation:
            return "wrench.and.screwdriver"
        case .installing, .checking:
            return "gearshape.2"
        case .ready: return "checkmark.shield"
        case .active: return "laptopcomputer.and.arrow.down"
        case .suspendedLowBattery: return "battery.25"
        case .suspendedThermal: return "thermometer.high"
        case .suspendedMaximumDuration, .unavailable:
            return "exclamationmark.triangle"
        }
    }

    private var closedLidColor: Color {
        switch closedLidModeManager.status {
        case .disabled: return .secondary
        case .requiresInstallation: return .orange
        case .installing, .checking: return .blue
        case .ready: return .blue
        case .active: return .green
        case .suspendedLowBattery, .suspendedThermal,
             .suspendedMaximumDuration, .unavailable:
            return .orange
        }
    }

    private var shouldOfferHookRetry: Bool {
        switch coordinator.hookInstallationStatus {
        case .notChecked, .installed:
            return false
        case .helperMissing, .failed:
            return coordinator.isEnabled
        }
    }
}
