import AppKit

struct CodexResetAlertRenderState: Equatable {
    let appearance: String
    let reduceMotion: Bool
    let isDimmingActive: Bool

    @MainActor init(button: NSStatusBarButton, isDimmingActive: Bool = false) {
        self.isDimmingActive = isDimmingActive
        appearance = button.effectiveAppearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua
        ])?.rawValue ?? ""
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

@MainActor
enum CodexResetAlertIcon {
    /// Resolve dynamic system colors and symbols once. A live NSImage drawing
    /// handler would reenter appearance observation during menu-bar snapshots.
    static func image(bright: Bool, appearance: NSAppearance) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = NSSize(width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        appearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            symbol.draw(in: rect)
            (bright ? NSColor.systemOrange : NSColor.labelColor.withAlphaComponent(0.25)).setFill()
            rect.fill(using: .sourceIn)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}
