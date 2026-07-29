import AppKit
import XCTest
@testable import AIQuotaBar

final class MenuBarRingRenderingTests: XCTestCase {
    @MainActor
    func testCompactRingStatesRenderDistinctPixels() throws {
        let states: [(ring: Double, delta: Double?, mode: MenuBarPaceDisplayMode, connectivity: CodexConnectivityState, offlineMorph: CGFloat, offlinePulseOpacity: CGFloat)] = [
            (99, -1, .continuous, .reachable, 0, 1),
            (20, -18, .staged, .reachable, 0, 1),
            (50, 0, .staged, .reachable, 0, 1),
            (80, 18, .staged, .reachable, 0, 1),
            (35, -MenuBarPaceGlyph.percentPointsPerDay, .continuous, .reachable, 0, 1),
            (70, MenuBarPaceGlyph.fullScaleDeltaPercent, .continuous, .reachable, 0, 1),
            (70, MenuBarPaceGlyph.fullScaleDeltaPercent + 1, .continuous, .reachable, 0, 1),
            (70, 42, .staged, .unreachable, 1, 1),
            (70, 42, .staged, .unreachable, 1, 0.32),
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
            view.setOfflinePulseOpacityForTesting(state.offlinePulseOpacity)

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
        func centerX(for stateIndex: Int) -> Int {
            stateIndex * iconPixelWidth + iconPixelWidth / 2
        }
        let centerY = pixelsHigh / 2

        func borderLuminance(stateIndex: Int, xOffset: CGFloat) -> Int {
            luminanceAt(
                x: centerX(for: stateIndex) + Int(xOffset * scale),
                y: centerY)
        }

        let deficitLeft = borderLuminance(stateIndex: 1, xOffset: -4.25)
        let deficitRight = borderLuminance(stateIndex: 1, xOffset: 4.25)
        XCTAssertGreaterThan(deficitLeft, deficitRight + 60)

        let onPaceLeft = borderLuminance(stateIndex: 2, xOffset: -4.25)
        let onPaceRight = borderLuminance(stateIndex: 2, xOffset: 4.25)
        let onPaceDivider = borderLuminance(stateIndex: 2, xOffset: 0)
        XCTAssertLessThan(abs(onPaceLeft - onPaceRight), 40)
        XCTAssertLessThan(onPaceDivider + 150, min(onPaceLeft, onPaceRight))

        let reserveLeft = borderLuminance(stateIndex: 3, xOffset: -4.25)
        let reserveRight = borderLuminance(stateIndex: 3, xOffset: 4.25)
        XCTAssertGreaterThan(reserveRight, reserveLeft + 60)

        let exactTwoDayOuterEdge = borderLuminance(stateIndex: 5, xOffset: 4.5)
        let overflowOuterEdge = borderLuminance(stateIndex: 6, xOffset: 4.5)
        XCTAssertLessThan(overflowOuterEdge + 100, exactTwoDayOuterEdge)

        let offlineBrightIndex = states.count - 2
        let offlineDimIndex = states.count - 1
        let offlineCenterX = centerX(for: offlineBrightIndex)
        let bandLuminance = luminanceAt(x: offlineCenterX, y: centerY)
        let filledLuminance = luminanceAt(x: offlineCenterX, y: centerY + Int(2 * scale))
        XCTAssertGreaterThan(bandLuminance - filledLuminance, 300)

        let dimFilledLuminance = luminanceAt(
            x: centerX(for: offlineDimIndex),
            y: centerY + Int(2 * scale))
        XCTAssertGreaterThan(dimFilledLuminance - filledLuminance, 250)

        let ringTopOffset = Int(8.0 * scale)
        let onlineRingTop = luminanceAt(
            x: centerX(for: 5),
            y: centerY + ringTopOffset)
        let offlineBrightRingTop = luminanceAt(
            x: centerX(for: offlineBrightIndex),
            y: centerY + ringTopOffset)
        let offlineDimRingTop = luminanceAt(
            x: centerX(for: offlineDimIndex),
            y: centerY + ringTopOffset)
        XCTAssertGreaterThan(offlineBrightRingTop - onlineRingTop, 250)
        XCTAssertLessThan(abs(offlineBrightRingTop - offlineDimRingTop), 5)

        if let previewPath = ProcessInfo.processInfo.environment["AI_QUOTA_RENDER_PREVIEW_PATH"] {
            try pngData.write(to: URL(fileURLWithPath: previewPath), options: .atomic)
        }
    }
}
