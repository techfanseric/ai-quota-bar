import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct MobileDashboardPane: View {
    @Bindable var viewModel: UsageViewModel
    @Bindable var service: MobileDashboardService
    @State private var feedback: String?
    @State private var manualPairingFeedback: String?
    @State private var pairingPolicyFeedback: String?

    private var language: AppLanguage { viewModel.appLanguage }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                enableSection
                Divider()
                modelSelectionSection

                if service.isEnabled {
                    Divider()
                    accessSection
                    Divider()
                    privacySection
                    Divider()
                    troubleshootingSection
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onAppear {
            initializeModelSelection()
        }
        .onChange(of: candidateSelectionKeys) { _, _ in
            initializeModelSelection()
        }
    }

    private var modelSelectionSection: some View {
        SettingsSection(
            title: language.mobileDashboardModelsTitle(),
            caption: language.mobileDashboardModelsDescription(),
            contentSpacing: 10
        ) {
            HStack(spacing: 8) {
                Text(
                    language.mobileDashboardModelsSelectedCount(
                        service.selectedModelKeys.count,
                        maximum:
                            MobileDashboardService
                                .maximumSelectedModelCount))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if service.selectedModelKeys.count
                    == MobileDashboardService
                        .maximumSelectedModelCount
                {
                    Text(language.mobileDashboardModelsLimitReached())
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }

            if modelProviderGroups.isEmpty {
                Text(language.mobileDashboardModelsEmpty())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(modelProviderGroups) { providerGroup in
                    modelProviderGroup(providerGroup)
                }
            }

            if !orphanedSelectionKeys.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        language
                            .mobileDashboardUnavailableModelsTitle())
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(
                        language
                            .mobileDashboardUnavailableModelsDescription())
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true)

                    ForEach(
                        orphanedSelectionKeys,
                        id: \.self
                    ) { key in
                        orphanedModelRow(key)
                    }
                }
            }
        }
    }

    private func modelProviderGroup(
        _ providerGroup: MobileDashboardModelProviderGroup
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(providerGroup.providerName)
                .font(.subheadline.weight(.semibold))

            ForEach(
                providerGroup.accounts.indices,
                id: \.self
            ) { accountIndex in
                let accountGroup =
                    providerGroup.accounts[accountIndex]
                VStack(alignment: .leading, spacing: 5) {
                    Text(accountGroup.accountDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(
                        accountGroup.models.indices,
                        id: \.self
                    ) { modelIndex in
                        let model =
                            accountGroup.models[modelIndex]
                        candidateModelRow(
                            model,
                            providerName:
                                providerGroup.providerName,
                            accountName:
                                accountGroup.accountDisplayName)
                    }
                }
            }
        }
    }

    private func candidateModelRow(
        _ model: ModelUsageData,
        providerName: String,
        accountName: String
    ) -> some View {
        let key = model.mobileDashboardSelectionKey
        return Toggle(
            isOn: selectionBinding(for: key)
        ) {
            HStack(spacing: 10) {
                Text(model.modelName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(
                    "\(Int(model.currentIntervalPercentageRemaining.rounded()))%"
                )
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isSelectionDisabled(key))
        .help(selectionHelp(for: key))
        .accessibilityLabel(
            language.mobileDashboardModelAccessibilityLabel(
                provider: providerName,
                account: accountName,
                model: model.modelName))
        .accessibilityHint(selectionHelp(for: key))
    }

    private func orphanedModelRow(
        _ key: MobileDashboardModelSelectionKey
    ) -> some View {
        let providerName =
            UsageProvider(rawValue: key.providerRaw)?.displayName
            ?? key.providerRaw
        let accountName = key.normalizedAccount.isEmpty
            ? language.mobileDashboardDefaultAccount()
            : key.normalizedAccount
        return Toggle(
            isOn: selectionBinding(for: key)
        ) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(key.normalizedModel)
                    Text("\(providerName) · \(accountName)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text(language.mobileDashboardUnavailableBadge())
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(isSelectionDisabled(key))
        .help(selectionHelp(for: key))
        .accessibilityLabel(
            language.mobileDashboardModelAccessibilityLabel(
                provider: providerName,
                account: accountName,
                model: key.normalizedModel))
        .accessibilityHint(
            language.mobileDashboardUnavailableModelAccessibilityHint()
                + " "
                + selectionHelp(for: key))
    }

    private var enableSection: some View {
        SettingsSection(
            title: language.mobileDashboardSectionTitle(),
            contentSpacing: 12
        ) {
            PreferenceToggleRow(
                title: language.mobileDashboardEnableTitle(),
                subtitle:
                    language.mobileDashboardEnableDescription(),
                isOn: $service.isEnabled)

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var accessSection: some View {
        SettingsSection(
            title: language.mobileDashboardAccessTitle(),
            caption: language.mobileDashboardAccessCaption(),
            contentSpacing: 12
        ) {
            PreferenceToggleRow(
                title: language.mobileDashboardPairingRequiredTitle(),
                subtitle:
                    language.mobileDashboardPairingRequiredDescription(),
                isOn: pairingCodeBinding)

            PreferenceToggleRow(
                title: language.mobileDashboardShareTaskProgressTitle(),
                subtitle: language
                    .mobileDashboardShareTaskProgressDescription(
                        pairingRequired: service.requiresPairingCode),
                isOn: shareTaskProgressTextBinding)
                .disabled(!service.requiresPairingCode)

            if let pairingPolicyFeedback {
                Text(pairingPolicyFeedback)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if case .starting = service.state {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.mobileDashboardStartingStatus())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if case let .failed(message) = service.state {
                Label {
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            } else if let link = service.accessURLString {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 20) {
                        if let image = MobileDashboardQRCode.image(
                            for: link
                        ) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 168, height: 168)
                                .background(Color.white)
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: 10,
                                        style: .continuous))
                                .accessibilityLabel(
                                    language.mobileDashboardScanTitle())
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text(language.mobileDashboardScanTitle())
                                .font(.headline)
                            Text(
                                language
                                    .mobileDashboardScanDescription())
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true)

                            Text(
                                primaryUsesLocalHostName
                                    ? language
                                        .mobileDashboardStableAddressTitle()
                                    : language
                                        .mobileDashboardCurrentIPAddressTitle())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(displayLink(link))
                                .font(.system(
                                    .footnote,
                                    design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)

                            HStack(spacing: 8) {
                                Button {
                                    copy(link)
                                } label: {
                                    Label(
                                        language
                                            .mobileDashboardCopyLink(),
                                        systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button(
                                    language
                                        .mobileDashboardResetLink()
                                ) {
                                    feedback = service
                                        .regenerateAccessLink()
                                        ? nil
                                        : statusText
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if let feedback {
                                Text(feedback)
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            }
                        }
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading)
                    }

                    if !service.alternateURLStrings.isEmpty {
                        Divider()
                        fallbackLinks
                    }

                    if service.requiresPairingCode {
                        Divider()
                        manualPairingSection
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 7) {
                        Text(language.mobileDashboardInstallTitle())
                            .font(.subheadline.weight(.semibold))
                        Text(
                            language.mobileDashboardInstallDescription())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true)
                        Label(
                            primaryUsesLocalHostName
                                ? language
                                    .mobileDashboardReinstallNotice()
                                : language
                                    .mobileDashboardBonjourUnavailableNotice(),
                            systemImage: primaryUsesLocalHostName
                                ? "exclamationmark.arrow.triangle.2.circlepath"
                                : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(
                                horizontal: false,
                                vertical: true)
                    }
                }
            } else if case .ready = service.state {
                Text(language.mobileDashboardWaitingAddress())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fallbackLinks: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preferred = service.alternateURLStrings.first {
                Text(
                    primaryUsesLocalHostName
                        ? language.mobileDashboardIPFallbackTitle()
                        : language.mobileDashboardAdditionalIPTitle())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayLink(preferred))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        copy(preferred)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(language.mobileDashboardCopyFallbackLink())
                }
            }

            if service.alternateURLStrings.count > 1 {
                DisclosureGroup(
                    language.mobileDashboardMoreIPAddresses(
                        service.alternateURLStrings.count - 1)
                ) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(
                            Array(
                                service.alternateURLStrings
                                    .dropFirst()),
                            id: \.self
                        ) { alternate in
                            HStack(
                                alignment: .firstTextBaseline,
                                spacing: 8
                            ) {
                                Text(displayLink(alternate))
                                    .font(.system(
                                        .caption,
                                        design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer(minLength: 8)
                                Button {
                                    copy(alternate)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help(
                                    language
                                        .mobileDashboardCopyFallbackLink())
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.footnote)
            }

            Text(language.mobileDashboardIPFallbackDescription())
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualPairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.mobileDashboardManualPairingTitle())
                .font(.subheadline.weight(.semibold))
            Text(language.mobileDashboardManualPairingDescription())
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let code = service.manualPairingCode,
               let expiresAt = service.manualPairingCodeExpiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(
                        0,
                        Int(
                            expiresAt.timeIntervalSince(context.date)
                                .rounded(.up)))
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(formattedManualPairingCode(code))
                            .font(.system(
                                size: 24,
                                weight: .semibold,
                                design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityLabel(code)
                        Text(
                            seconds > 0
                                ? language
                                    .mobileDashboardManualPairingRemaining(
                                        seconds)
                                : language
                                    .mobileDashboardManualPairingExpired())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(
                                seconds > 0
                                    ? Color.secondary
                                    : Color.orange)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            code,
                            forType: .string)
                        manualPairingFeedback = language
                            .mobileDashboardManualPairingCopied()
                    } label: {
                        Label(
                            language.mobileDashboardManualPairingCopy(),
                            systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(
                        language.mobileDashboardManualPairingRefresh()
                    ) {
                        manualPairingFeedback = service
                            .refreshManualPairingCode()
                            ? nil
                            : statusText
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text(language.mobileDashboardManualPairingUnavailable())
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            if let manualPairingFeedback {
                Text(manualPairingFeedback)
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }

    private var privacySection: some View {
        SettingsSection(contentSpacing: 12) {
            PreferenceToggleRow(
                title:
                    language.mobileDashboardPrivacyTitle(),
                subtitle:
                    language.mobileDashboardPrivacyDescription(),
                isOn: $service.masksAccountNames)

            VStack(alignment: .leading, spacing: 7) {
                Text(language.mobileDashboardColorSchemeTitle())
                    .font(.body)
                Text(language.mobileDashboardColorSchemeDescription())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(
                    language.mobileDashboardColorSchemeTitle(),
                    selection: $service.colorScheme
                ) {
                    Text(language.mobileDashboardAutomaticColorScheme())
                        .tag(MobileDashboardColorScheme.automatic)
                    Text(language.mobileDashboardDarkColorScheme())
                        .tag(MobileDashboardColorScheme.dark)
                    Text(language.mobileDashboardLightColorScheme())
                        .tag(MobileDashboardColorScheme.light)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

            }

            PreferenceToggleRow(
                title: language
                    .mobileDashboardIdleBlackoutMarqueeTitle(),
                subtitle: language
                    .mobileDashboardIdleBlackoutMarqueeDescription(),
                isOn: $service.idleBlackoutMarqueeEnabled)

            PreferenceToggleRow(
                title: language.mobileDashboardOLEDTitle(),
                subtitle:
                    language.mobileDashboardOLEDDescription(),
                isOn: $service.oledProtectionEnabled)

            VStack(alignment: .leading, spacing: 7) {
                Text(
                    language
                        .mobileDashboardActivityBackgroundEffectTitle())
                    .font(.body)
                Text(
                    language
                        .mobileDashboardActivityBackgroundEffectDescription())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(
                    language
                        .mobileDashboardActivityBackgroundEffectTitle(),
                    selection: $service.activityBackgroundEffect
                ) {
                    Text(language.mobileDashboardGrainyDigitalRainEffect())
                        .tag(
                            MobileDashboardActivityBackgroundEffect
                                .grainyDigitalRain)
                    Text(language.mobileDashboardDotWavesEffect())
                        .tag(
                            MobileDashboardActivityBackgroundEffect
                                .dotWaves)
                    Text(language.mobileDashboardTaskTelemetryMarqueeEffect())
                        .tag(
                            MobileDashboardActivityBackgroundEffect
                                .taskTelemetryMarquee)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if service.activityBackgroundEffect ==
                    .taskTelemetryMarquee
                {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(language.mobileDashboardTaskTelemetryFieldsTitle())
                            .font(.body)
                        Text(
                            language
                                .mobileDashboardTaskTelemetryFieldsDescription())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 150),
                                    alignment: .leading),
                            ],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(
                                MobileDashboardTaskTelemetryField.allCases
                            ) { field in
                                Toggle(
                                    language
                                        .mobileDashboardTaskTelemetryFieldName(
                                            field),
                                    isOn: taskTelemetryFieldBinding(field)
                                )
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }

            PreferenceToggleRow(
                title:
                    language.mobileDashboardExperimentalWakeMediaTitle(),
                subtitle:
                    language
                        .mobileDashboardExperimentalWakeMediaDescription(),
                isOn: $service.experimentalWakeMediaEnabled)

            Text(
                language.mobileDashboardResetLinkDescription())
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pairingCodeBinding: Binding<Bool> {
        Binding(
            get: { service.requiresPairingCode },
            set: { required in
                guard required != service.requiresPairingCode else {
                    return
                }
                if service.setRequiresPairingCode(required) {
                    pairingPolicyFeedback = nil
                    manualPairingFeedback = nil
                } else {
                    pairingPolicyFeedback = language
                        .mobileDashboardPairingChangeFailed()
                }
            })
    }

    private func taskTelemetryFieldBinding(
        _ field: MobileDashboardTaskTelemetryField
    ) -> Binding<Bool> {
        Binding(
            get: { service.isTaskTelemetryFieldEnabled(field) },
            set: { enabled in
                service.setTaskTelemetryField(field, enabled: enabled)
            })
    }

    private var shareTaskProgressTextBinding: Binding<Bool> {
        Binding(
            get: { service.shareTaskProgressText },
            set: { shared in
                _ = service.setShareTaskProgressText(shared)
            })
    }

    private var troubleshootingSection: some View {
        SettingsSection(
            title:
                language.mobileDashboardTroubleshootingTitle(),
            caption:
                language
                    .mobileDashboardTroubleshootingDescription()
        ) {
            EmptyView()
        }
    }

    private var statusText: String {
        switch service.state {
        case .off:
            return language.mobileDashboardOffStatus()
        case .starting:
            return language.mobileDashboardStartingStatus()
        case .ready:
            return language.mobileDashboardReadyStatus(
                viewerCount: service.viewerCount)
        case let .failed(message):
            return message
        }
    }

    private var statusColor: Color {
        switch service.state {
        case .off: return .secondary
        case .starting: return .blue
        case .ready: return .green
        case .failed: return .orange
        }
    }

    private var candidateModels: [ModelUsageData] {
        var seen = Set<MobileDashboardModelSelectionKey>()
        return viewModel.providerUsageSections
            .flatMap(\.models)
            .filter {
                seen.insert(
                    $0.mobileDashboardSelectionKey).inserted
            }
    }

    private var candidateSelectionKeys:
        [MobileDashboardModelSelectionKey]
    {
        candidateModels.map(\.mobileDashboardSelectionKey)
    }

    private var modelProviderGroups:
        [MobileDashboardModelProviderGroup]
    {
        var groups: [MobileDashboardModelProviderGroup] = []
        for model in candidateModels {
            let providerIndex: Int
            if let existing = groups.firstIndex(where: {
                $0.providerRaw == model.provider.rawValue
            }) {
                providerIndex = existing
            } else {
                groups.append(
                    MobileDashboardModelProviderGroup(
                        providerRaw: model.provider.rawValue,
                        providerName: model.provider.displayName,
                        accounts: []))
                providerIndex = groups.count - 1
            }

            let normalizedAccount = model.normalizedAccountName
            if let accountIndex = groups[providerIndex]
                .accounts.firstIndex(where: {
                    $0.normalizedAccount == normalizedAccount
                })
            {
                groups[providerIndex].accounts[accountIndex]
                    .models.append(model)
            } else {
                let fullAccountName = model.accountName?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines)
                let accountDisplayName =
                    fullAccountName.flatMap {
                        $0.isEmpty ? nil : $0
                    }
                    ?? language.mobileDashboardDefaultAccount()
                groups[providerIndex].accounts.append(
                    MobileDashboardModelAccountGroup(
                        providerRaw: model.provider.rawValue,
                        normalizedAccount: normalizedAccount,
                        accountDisplayName: accountDisplayName,
                        models: [model]))
            }
        }
        return groups
    }

    private var orphanedSelectionKeys:
        [MobileDashboardModelSelectionKey]
    {
        let candidateKeys = Set(candidateSelectionKeys)
        return service.selectedModelKeys.filter {
            !candidateKeys.contains($0)
        }
    }

    private func initializeModelSelection() {
        service.initializeModelSelectionIfNeeded(
            candidates: candidateModels)
    }

    private func selectionBinding(
        for key: MobileDashboardModelSelectionKey
    ) -> Binding<Bool> {
        Binding(
            get: {
                service.selectedModelKeys.contains(key)
            },
            set: { isSelected in
                guard isSelected
                        != service.selectedModelKeys.contains(key)
                else {
                    return
                }
                _ = service.toggleModelSelection(key)
            })
    }

    private func isSelectionDisabled(
        _ key: MobileDashboardModelSelectionKey
    ) -> Bool {
        if service.selectedModelKeys.contains(key) {
            return service.selectedModelKeys.count <= 1
        }
        return service.selectedModelKeys.count
            >= MobileDashboardService.maximumSelectedModelCount
    }

    private func selectionHelp(
        for key: MobileDashboardModelSelectionKey
    ) -> String {
        if service.selectedModelKeys.contains(key),
           service.selectedModelKeys.count <= 1 {
            return language
                .mobileDashboardAtLeastOneModelRequired()
        }
        if !service.selectedModelKeys.contains(key),
           service.selectedModelKeys.count
            >= MobileDashboardService.maximumSelectedModelCount {
            return language
                .mobileDashboardDeselectModelFirst()
        }
        return language.mobileDashboardModelSelectionHint()
    }

    private func copy(_ link: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            link,
            forType: .string)
        feedback = language.mobileDashboardLinkCopied()
    }

    private func displayLink(_ link: String) -> String {
        guard let hash = link.firstIndex(of: "#") else {
            return link
        }
        return String(link[...hash]) + "token=••••••••"
    }

    private func formattedManualPairingCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return String(code.prefix(4)) + " " + String(code.suffix(4))
    }

    private var primaryUsesLocalHostName: Bool {
        guard let link = service.accessURLString,
              let host = URL(string: link)?.host?.lowercased()
        else {
            return false
        }
        return host.hasSuffix(".local")
    }
}

private struct MobileDashboardModelProviderGroup: Identifiable {
    let providerRaw: String
    let providerName: String
    var accounts: [MobileDashboardModelAccountGroup]

    var id: String { providerRaw }
}

private struct MobileDashboardModelAccountGroup: Identifiable {
    let providerRaw: String
    let normalizedAccount: String
    let accountDisplayName: String
    var models: [ModelUsageData]

    var id: String {
        providerRaw + "\u{1F}" + normalizedAccount
    }
}

private enum MobileDashboardQRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 9, y: 9))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
