import SwiftUI

/// codexbar 风格的分组容器：
/// 顶部 uppercase caption 标题（可选），中间内容按 `contentSpacing` 排布。
@MainActor
struct SettingsSection<Content: View>: View {
    let title: String?
    let caption: String?
    let contentSpacing: CGFloat
    let content: () -> Content

    init(
        title: String? = nil,
        caption: String? = nil,
        contentSpacing: CGFloat = 12,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.caption = caption
        self.contentSpacing = contentSpacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: contentSpacing) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
