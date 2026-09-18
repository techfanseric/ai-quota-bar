import SwiftUI

@MainActor
struct AnonymousAnalyticsSection: View {
    @Bindable var analytics: AppUsageAnalytics
    let language: AppLanguage
    private func t(_ zh: String, _ en: String) -> String { language == .simplifiedChinese ? zh : en }
    var body: some View {
        SettingsSection(title: t("隐私", "Privacy"), contentSpacing: 8) {
            PreferenceToggleRow(title: t("分享匿名使用统计", "Share anonymous usage statistics"),
                subtitle: t("默认关闭。仅上报随机安装标识、活跃状态、App 版本和 macOS 版本，帮助了解使用情况。不包含账号、对话、文件或用量数据。",
                    "Off by default. Shares a random installation ID, activity, app and macOS versions. No accounts, conversations, files or quota data."),
                isOn: $analytics.enabled)
                .disabled(analytics.deleting)
            HStack {
                Text(analytics.status).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button(t("停止并删除本机统计", "Stop & delete this installation’s statistics")) {
                    Task { await analytics.deleteStatistics() }
                }.controlSize(.small).disabled(analytics.deleting)
            }
            Text(t("活跃日明细保留 90 天。关闭后停止上报；删除只影响本机匿名运营统计，不影响用量历史。",
                "Daily activity is retained for 90 days. Turning this off stops reporting. Deletion affects only this installation’s product analytics, not usage history."))
                .font(.footnote).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
