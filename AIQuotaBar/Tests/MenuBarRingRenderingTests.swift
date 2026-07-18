import AppKit
import XCTest
@testable import AIQuotaBar

final class MenuBarRingRenderingTests: XCTestCase {
    @MainActor
    func testCompactRingStatesRenderDistinctPixels() throws {
        let states: [(ring: Double, delta: Double?, mode: MenuBarPaceDisplayMode, connectivity: CodexConnectivityState, offlineMorph: CGFloat)] = [
            (20, -18, .staged, .reachable, 0),
            (50, 0, .staged, .reachable, 0),
            (80, 18, .staged, .reachable, 0),
            (35, -42, .continuous, .reachable, 0),
            (70, 42, .continuous, .reachable, 0),
            (70, 42, .staged, .unreachable, 1),
        ]
        let iconSize = NSSize(width: 22, height: 22)
        let scale: CGFloat = 4
        let pixelsWide = Int(iconSize.width * CGFloat(states.count) * scale)
        let pixelsHigh = Int(iconSize.height * scale)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = NSSize(width: iconSize.width * CGFloat(states.count), height: iconSize.height)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: bitmap.size)).fill()

        for (index, state) in states.enumerated() {
            let view = StatusBarCompactRingView(frame: NSRect(origin: .zero, size: iconSize))
            let snapshot = MenuBarSnapshot(
                provider: .codex,
                modelName: "5h",
                remainingPercent: 72,
                ringPercent: state.ring,
                paceDeltaPercent: state.delta,
                resetsAt: Date().addingTimeInterval(3600),
                state: .ready,
                isLowQuota: false,
                tooltip: "Preview")
            view.setSnapshot(
                snapshot,
                connectivity: state.connectivity,
                paceDisplayMode: state.mode,
                accessibilityLabel: "Preview")
            view.setOfflineMorphForTesting(state.offlineMorph)

            context.cgContext.saveGState()
            context.cgContext.translateBy(x: CGFloat(index) * iconSize.width, y: 0)
            view.draw(view.bounds)
            context.cgContext.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()

        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(pngData.count, 500)

        let bytes = try XCTUnwrap(bitmap.bitmapData)
        let iconPixelWidth = Int(iconSize.width * scale)
        let bytesPerPixel = 4
        var signatures = Set<Data>()
        for iconIndex in states.indices {
            var iconBytes = Data(capacity: iconPixelWidth * pixelsHigh * bytesPerPixel)
            for row in 0 ..< pixelsHigh {
                let offset = row * bitmap.bytesPerRow + iconIndex * iconPixelWidth * bytesPerPixel
                iconBytes.append(bytes + offset, count: iconPixelWidth * bytesPerPixel)
            }
            signatures.insert(iconBytes)
        }
        XCTAssertEqual(signatures.count, states.count)

        func luminanceAt(x: Int, y: Int) -> Int {
            let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
            return Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
        }
        let offlineCenterX = (states.count - 1) * iconPixelWidth + iconPixelWidth / 2
        let centerY = pixelsHigh / 2
        let bandLuminance = luminanceAt(x: offlineCenterX, y: centerY)
        let filledLuminance = luminanceAt(x: offlineCenterX, y: centerY + Int(2 * scale))
        XCTAssertGreaterThan(bandLuminance - filledLuminance, 300)

        if let previewPath = ProcessInfo.processInfo.environment["AI_QUOTA_RENDER_PREVIEW_PATH"] {
            try pngData.write(to: URL(fileURLWithPath: previewPath), options: .atomic)
        }
    }
}
