import AppKit
import SwiftUI

@MainActor
final class AccessibilityGuideWindow {
    static let shared = AccessibilityGuideWindow()
    private var panel: NSPanel?

    func show(appURL: URL = Bundle.main.bundleURL, chinese: Bool = AppLanguage.current == .simplifiedChinese) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let window = panel ?? NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                                      backing: .buffered, defer: false)
        window.title = chinese ? "辅助功能授权" : "Accessibility access"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: AccessibilityGuideView(chinese: chinese, appURL: appURL))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        let frame = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: frame.maxX - window.frame.width - 12, y: frame.maxY - window.frame.height - 12))
        panel = window
        window.orderFrontRegardless()
        // System Settings can open on a different screen from the menu bar.
        // Wait for its window to appear, then leave the guide where the user puts it.
        Task { @MainActor [weak window] in
            for _ in 0..<12 {
                guard let window, window.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
                if let settings = Self.settingsFrame(),
                   let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: settings.midX, y: settings.midY)) }) {
                    let bounds = screen.visibleFrame
                    let size = window.frame.size
                    let right = settings.maxX + 8
                    let left = settings.minX - size.width - 8
                    let x = right + size.width <= bounds.maxX ? right : left
                    window.setFrameOrigin(NSPoint(
                        x: max(bounds.minX, min(x, bounds.maxX - size.width)),
                        y: max(bounds.minY, min(settings.maxY - size.height, bounds.maxY - size.height))))
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private static func settingsFrame() -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let desktopTop = NSScreen.screens.first?.frame.maxY,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in windows where info[kCGWindowOwnerPID as String] as? pid_t == pid
            && info[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 200, rect.height > 200 else { continue }
            return NSRect(x: rect.minX, y: desktopTop - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

struct AccessibilityGuideView: View {
    let chinese: Bool
    let appURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(chinese ? "打开 AI Quota Bar 旁的开关" : "Turn on AI Quota Bar in the list")
                .font(.headline)
            Text(chinese ? "列表里没有？把下面的应用拖进「辅助功能」列表，再打开开关。" : "Missing from Accessibility? Drag the app below into the list, then turn it on.")
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable().frame(width: 38, height: 38)
                VStack(alignment: .leading) {
                    Text("AI Quota Bar").fontWeight(.semibold)
                    Text(chinese ? "按住拖入设置列表" : "Drag into Accessibility").foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: appURL as NSURL) }
            Text(chinese ? "开关已开，引导仍在？选中列表里的 AI Quota Bar，点下方的「−」移除，再把上面的应用拖进去。" : "Already on, but still seeing this guide? Select AI Quota Bar in the list, click the minus button, then drag the app back in.")
                .foregroundStyle(.secondary)
            Text(chinese ? "授权成功后，本窗口会自动关闭。" : "This window closes when access is granted.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(width: 295, alignment: .leading)
    }
}

struct AccessibilityMenuNotice: View {
    let chinese: Bool
    let brightnessEnabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard").foregroundStyle(.orange)
                Text(brightnessEnabled
                     ? (chinese ? "亮度键需要辅助功能权限" : "Brightness keys need Accessibility")
                     : (chinese ? "键盘唤醒亮度需要辅助功能权限" : "Keyboard restore needs Accessibility"))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 2)
                Text(chinese ? "去授权" : "Open Settings").font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.right").font(.caption2)
            }
            .padding(.horizontal, 13)
            .frame(height: ClashPopoverLayout.permissionNoticeHeight)
            .background(Color.orange.opacity(0.12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
