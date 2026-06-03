// Stub - status bar 用 NSView + NSTextField 直接 addSubview，
// 不用 brand icon 也不需要 SVG 资源。
// 保留文件以防现有代码引用；本 enum 不再被使用。
import AppKit
enum MenuBarBrandIcon {
    static func image(for provider: UsageProvider) -> NSImage? { nil }
}
