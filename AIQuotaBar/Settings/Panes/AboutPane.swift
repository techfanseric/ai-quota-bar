import AppKit
import SwiftUI

/// About tab：版本 + 检查更新 + 退出按钮。
@MainActor
struct AboutPane: View {
    @Bindable var viewModel: UsageViewModel
    @State private var isCheckingForUpdate: Bool = false
    @State private var updateFeedback: InlineFeedback? = nil
    @State private var latestVersion: String? = nil
    @State private var releaseURL: URL? = nil

    private var language: AppLanguage { viewModel.appLanguage }
    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                appSection
                Divider()
                updatesSection
                Divider()
                quitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - APP

    private var appSection: some View {
        SettingsSection(title: language.text(.appTitle), contentSpacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("AI Quota Bar")
                    .font(.title2.weight(.semibold))
                Text("v\(currentVersion)")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Text(language.text(.appDescription))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - UPDATES

    private var updatesSection: some View {
        SettingsSection(title: language.text(.updatesTitle), contentSpacing: 12) {
            Text(language.text(.updatesDescription))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await checkForUpdates() }
                } label: {
                    Label(language.text(.checkForUpdates), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCheckingForUpdate)

                if isCheckingForUpdate {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                if let updateFeedback {
                    InlineFeedbackView(feedback: updateFeedback)
                }
            }

            if let releaseURL {
                Button {
                    NSWorkspace.shared.open(releaseURL)
                } label: {
                    Label(language.text(.openReleasePage), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
    }

    // MARK: - QUIT

    private var quitSection: some View {
        HStack {
            Spacer()
            Button(language.text(.quitApp)) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Actions

    private func checkForUpdates() async {
        isCheckingForUpdate = true
        updateFeedback = nil
        latestVersion = nil
        releaseURL = nil
        defer { isCheckingForUpdate = false }

        do {
            let result = try await UpdateChecker.shared.checkForUpdates()
            switch result {
            case .upToDate(let version):
                updateFeedback = InlineFeedback(
                    kind: .success,
                    message: language.upToDateText(current: version)
                )
            case .updateAvailable(let current, let latest, let url):
                latestVersion = latest
                releaseURL = url
                updateFeedback = InlineFeedback(
                    kind: .success,
                    message: language.updateAvailableText(current: current, latest: latest)
                )
            }
        } catch {
            updateFeedback = InlineFeedback(
                kind: .error,
                message: language.updateCheckFailedText(error.localizedDescription)
            )
        }
    }
}
