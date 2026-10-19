import SwiftUI

@MainActor
struct DisplayBrightnessSettingsView: View {
    @Bindable var preferences: StepAwayPreferences = .shared
    @Bindable var controller: StepAwayDimController = .shared
    let language: AppLanguage
    private var chinese: Bool { language == .simplifiedChinese }
    private var busy: Bool { controller.isTransitioning || controller.isRefreshing }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(chinese ? "各屏幕目标亮度" : "Targets by display")
                    .font(.body.weight(.medium))
                Spacer()
                if controller.isRefreshing { ProgressView().controlSize(.small) }
                Button(chinese ? "刷新读数" : "Refresh readings") { controller.refreshDisplays() }
                    .controlSize(.small)
                    .disabled(busy || controller.isActive)
            }
            if controller.displays.isEmpty && !controller.isRefreshing {
                Text(chinese ? "未读取到屏幕，请刷新。" : "No displays read yet. Refresh to try again.")
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.displays) { display in
                displayRow(display)
            }
            Text(chinese
                ? "外接屏采用 MonitorControl 式组合范围：50% 为硬件最低亮度，低于 50% 使用 Gamma 色表继续压暗，0% 保留 15% 色表输出。内置屏直接调真实亮度。不创建遮罩，不修改显示器对比度或 RGB 增益。拖动滑块直接预览所选屏幕。松开后移动鼠标或按任意键恢复原亮度；离开此页面也会恢复。"
                : "External displays use a combined range: 50% is the hardware minimum; below 50%, gamma dimming extends the range, down to 15% table output at 0%. Built-in displays use native brightness. No overlay or monitor contrast/RGB gain changes. Drag a slider to preview only that display. After releasing it, move the pointer or press any key to restore. Leaving this page also restores.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { controller.refreshDisplays() }
        .onDisappear {
            controller.endPreview()
        }
    }

    private func displayRow(_ display: DisplayBrightnessReading) -> some View {
        let target = preferences.targetPercent(for: display.id)
        let plan = DisplayDimPlan(targetPercent: target, builtin: display.builtin)
        let previewing = controller.previewDisplayKey == display.id
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: display.builtin ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(display.name).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(currentText(display)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text(chinese ? "目标" : "Target").font(.footnote)
                Slider(value: Binding(
                    get: { preferences.targetPercent(for: display.id) },
                    set: {
                        preferences.setTargetPercent($0, for: display.id)
                        controller.requestPreview(displayKey: display.id)
                    }), in: 0...100, step: 1,
                    onEditingChanged: { editing in
                        if editing { controller.startPreviewEditing(displayKey: display.id) }
                        else { controller.finishPreviewEditing(displayKey: display.id) }
                    })
                    .accessibilityLabel("\(display.name) \(language.stepAwayTargetBrightnessLabel())")
                    .disabled(controller.isRefreshing || (controller.isTransitioning && !previewing)
                        || (controller.isActive && !previewing) || display.currentPercent == nil)
                Text(String(format: "%.0f%%", target))
                    .font(.footnote.monospacedDigit()).frame(width: 40, alignment: .trailing)
                if previewing {
                    Text(chinese ? "预览中" : "Previewing")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !display.builtin {
                Text(String(format: chinese ? "硬件目标 %.0f%% · Gamma 输出 %.0f%%" : "Hardware target %.0f%% · Gamma output %.0f%%",
                    plan.hardwarePercent, Double(plan.gammaFactor) * 100))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = controller.verification[display.id] {
                Text(verificationText(result))
                    .font(.caption)
                    .foregroundStyle(result.matches ? Color.secondary : Color.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func currentText(_ display: DisplayBrightnessReading) -> String {
        guard let percent = display.currentPercent else {
            return chinese ? "无法读取硬件亮度" : "Hardware brightness unreadable"
        }
        if let raw = display.rawValue, let maximum = display.maximum {
            return String(format: chinese ? "当前硬件 %.0f%% · %d/%d" : "Hardware %.0f%% · %d/%d", percent, raw, maximum)
        }
        return String(format: chinese ? "当前 %.0f%%" : "Current %.0f%%", percent)
    }

    private func verificationText(_ result: DisplayBrightnessVerification) -> String {
        guard let actual = result.actualHardware else {
            return chinese ? "最近调节：写入后无法读回确认" : "Last adjustment: read-back unavailable"
        }
        var text = String(format: chinese ? "最近调节：硬件读回 %.0f%%" : "Last adjustment: hardware read-back %.0f%%", actual)
        if result.expectedGamma < 1 {
            text += result.actualGamma.map { String(format: " · Gamma %.0f%%", Double($0) * 100) }
                ?? (chinese ? " · Gamma 未确认" : " · Gamma unverified")
        }
        return text + (result.matches ? (chinese ? " · 已确认" : " · Verified") : (chinese ? " · 未达到目标，请检查其他调光应用" : " · Target not reached; check other dimming apps"))
    }
}
