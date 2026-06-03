import SwiftUI

/// codexbar 风格的 toggle 行：左 checkbox + 标题，下方 subtitle。
@MainActor
struct PreferenceToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.body)
            }
            .toggleStyle(.checkbox)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// codexbar 风格的 Picker 行：左 VStack(title + subtitle) + Spacer + 右侧 Picker。
@MainActor
struct PreferencePickerRow<Value: Hashable, Content: View>: View {
    let title: String
    let subtitle: String?
    @Binding var selection: Value
    let maxWidth: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        selection: Binding<Value>,
        maxWidth: CGFloat = 200,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._selection = selection
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Picker("", selection: $selection) {
                content()
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: maxWidth, alignment: .trailing)
        }
    }
}
