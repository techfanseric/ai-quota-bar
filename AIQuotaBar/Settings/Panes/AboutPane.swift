import AppKit
import SwiftUI

/// About tab：版本 + 检查更新 + 反馈 + 退出按钮。
@MainActor
struct AboutPane: View {
    @Bindable var viewModel: UsageViewModel
    @State private var updates = UpdateChecker.shared
    @State private var feedbackNickname = ""
    @State private var feedbackMessage = ""
    @State private var feedbackContact = ""
    @State private var feedbackSending = false
    @State private var feedbackResult: InlineFeedback?

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
                feedbackSection
                Divider()
                quitSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .task { await updates.checkIfNeeded() }
    }

    private func t(_ zh: String, _ en: String) -> String {
        language == .simplifiedChinese ? zh : en
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

    // MARK: - FEEDBACK

    private var feedbackSection: some View {
        SettingsSection(title: t("反馈", "Feedback"), contentSpacing: 10) {
            Text(t("欢迎留下建议或问题。提交后会实时展示在官网反馈墙上；联系方式仅开发者可见，不会公开展示。",
                   "Leave a suggestion or issue. Submissions appear on the website feedback wall immediately; contact info stays private and is only visible to the developer."))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(t("昵称（可选，展示在反馈墙上）", "Nickname (optional, shown on the wall)"), text: $feedbackNickname)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $feedbackMessage)
                .font(.body)
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            TextField(t("联系方式（可选，仅开发者可见）", "Contact info (optional, private)"), text: $feedbackContact)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button {
                    submitFeedback()
                } label: {
                    Label(t("提交反馈", "Send feedback"), systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(feedbackSending || feedbackMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if feedbackSending { ProgressView().controlSize(.small) }
                Link(t("在官网查看反馈墙 →", "View the feedback wall →"),
                     destination: URL(string: CloudSyncSettings.defaultEndpointURLString + "/feedback")!)
                    .font(.footnote)
            }
            if let feedbackResult {
                InlineFeedbackView(feedback: feedbackResult)
            }
        }
    }

    private func submitFeedback() {
        feedbackSending = true
        feedbackResult = nil
        Task {
            defer { feedbackSending = false }
            do {
                _ = try await FeedbackService.shared.submit(
                    nickname: feedbackNickname,
                    message: feedbackMessage,
                    contact: feedbackContact
                )
                feedbackNickname = ""
                feedbackMessage = ""
                feedbackContact = ""
                feedbackResult = InlineFeedback(
                    kind: .success,
                    message: t("已发布，感谢你的反馈！现在可以在官网反馈墙上看到它。",
                               "Published — thank you! You can now see it on the website feedback wall.")
                )
            } catch {
                feedbackResult = InlineFeedback(kind: .error, message: error.localizedDescription)
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
