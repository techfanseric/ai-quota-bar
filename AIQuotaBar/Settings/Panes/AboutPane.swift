import AppKit
import SwiftUI

/// About tab：版本 + 检查更新 + 退出按钮。
@MainActor
struct AboutPane: View {
    @Bindable var viewModel: UsageViewModel
    @State private var updates = UpdateChecker.shared

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
        .task { await updates.checkIfNeeded() }
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
                Button { Task { _ = try? await updates.checkForUpdates() } } label: {
                    Label(language.text(.checkForUpdates), systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(updates.isChecking)
                if updates.isChecking { ProgressView().controlSize(.small) }
            }
            if let release = updates.availableRelease {
                Text(language.updateAvailableText(current: currentVersion, latest: release.version))
                    .font(.footnote)
                HStack(spacing: 16) {
                    Link(language == .simplifiedChinese ? "下载新版" : "Download update", destination: release.downloadURL)
                    Link(language == .simplifiedChinese ? "查看更新日志" : "Release notes", destination: release.changelogURL)
                }
                .font(.footnote)
                Text(language == .simplifiedChinese ? "下载后打开 DMG，将 App 拖入应用程序完成替换。" : "Open the downloaded DMG and drag the app into Applications to replace the installed version.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if updates.lastCheckedAt != nil && updates.lastError == nil {
                Text(language.upToDateText(current: currentVersion))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = updates.lastError {
                Text(language.updateCheckFailedText(error))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let checked = updates.lastCheckedAt {
                Text("\(language == .simplifiedChinese ? "上次成功检查" : "Last checked"): \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
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

}
