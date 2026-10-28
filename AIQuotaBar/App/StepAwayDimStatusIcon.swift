import AppKit

/// A steady, semantic-color indicator that survives remote menu-bar replicas.
@MainActor
enum StepAwayDimStatusIcon {
    static let width: CGFloat = 19

    /// Bake the badge into each cached frame so compact mode keeps AppKit's
    /// native image path. Template quota pixels need their resolved label color
    /// before becoming part of this non-template, black-screen image.
    static func image(
        addingTo base: NSImage? = nil,
        appearance: NSAppearance,
        scale: CGFloat = 2
    ) -> NSImage {
        let baseWidth = base?.size.width ?? 0
        let size = NSSize(width: baseWidth + width, height: max(22, base?.size.height ?? 0))
        let image = NSImage(size: size)
        for scale in Set([CGFloat(1), CGFloat(2), max(1, scale)]).sorted(by: >) {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(size.width * scale)),
                pixelsHigh: Int(ceil(size.height * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            appearance.performAsCurrentDrawingAppearance {
                if let base {
                    let rect = NSRect(origin: .zero, size: base.size)
                    base.draw(in: rect)
                    if base.isTemplate {
                        NSColor.labelColor.setFill()
                        rect.fill(using: .sourceIn)
                    }
                }
                draw(in: NSRect(x: baseWidth, y: (size.height - 22) / 2,
                    width: width, height: 22))
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(bitmap)
        }
        image.isTemplate = false
        return image
    }

    /// The quota icon has a letter above its ring. Lower this borderless screen
    /// optically relative to the shared canvas, keeping its moon centered inside.
    private static func draw(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY - 1.5)
        transform.concat()

        let screen = NSBezierPath(roundedRect:
            NSRect(x: 2, y: 3.5, width: 15, height: 15), xRadius: 1.5, yRadius: 1.5)
        NSColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1).setFill()
        screen.fill()

        if let moon = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil),
           let context = NSGraphicsContext.current?.cgContext {
            let moonRect = NSRect(x: 5.75, y: 7, width: 7.5, height: 8)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            moon.draw(in: moonRect)
            NSColor.white.setFill()
            moonRect.fill(using: .sourceIn)
            context.endTransparencyLayer()
        }
    }
}
