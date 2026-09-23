import SwiftUI

/// 左键菜单里供应商分组的排序设置：供应商按当前顺序排成一行，
/// 用上下箭头逐位移动，调回默认顺序后自动清除自定义持久化。
@MainActor
struct LeftClickMenuProviderOrderSection: View {
    let language: AppLanguage
    @Binding var preferences: LeftClickMenuDisplayPreferences

    private func t(_ zh: String, _ en: String) -> String {
        language == .simplifiedChinese ? zh : en
    }

    var body: some View {
        SettingsSection(
            title: t("左键菜单供应商顺序", "Menu provider order"),
            caption: t(
                "用箭头调整各供应商在左键菜单中的排列，只影响菜单展示顺序。",
                "Use the arrows to reorder providers inside the left-click menu; this only changes display order."))
        {
            HStack(spacing: 8) {
                ForEach(Array(preferences.providerOrder.enumerated()), id: \.element) { index, provider in
                    orderPill(index: index, provider: provider)
                }
                Spacer(minLength: 0)
                if preferences.hasCustomProviderOrder {
                    Button(t("恢复默认", "Reset")) { preferences.resetProviderOrder() }
                        .controlSize(.small)
                        .help(t(
                            "恢复默认顺序：Codex 在前，MiniMax 在最后。",
                            "Restore the default order: Codex first, MiniMax last."))
                }
            }
        }
    }

    private func orderPill(index: Int, provider: UsageProvider) -> some View {
        HStack(spacing: 6) {
            ProviderLogoIcon(provider: provider, pointSize: 12)
            Text(provider.displayName)
                .font(.footnote)
                .lineLimit(1)
            moveButton(provider: provider, offset: -1, index: index)
            moveButton(provider: provider, offset: 1, index: index)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func moveButton(
        provider: UsageProvider,
        offset: Int,
        index: Int
    ) -> some View {
        let isDisabled = offset < 0
            ? index == 0
            : index == preferences.providerOrder.count - 1
        let direction = offset < 0 ? t("上移", "Move up") : t("下移", "Move down")
        return Button {
            preferences.moveProvider(provider, byOffset: offset)
        } label: {
            Image(systemName: offset < 0 ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? Color(nsColor: .tertiaryLabelColor) : Color(nsColor: .secondaryLabelColor))
        .disabled(isDisabled)
        .accessibilityLabel("\(direction) \(provider.displayName)")
        .help("\(direction) \(provider.displayName)")
    }
}
