import AppKit
import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexResetAlertIconTests: XCTestCase {
    private func frame(bright: Bool, percent: Double = 60) throws -> NSBitmapImageRep {
        let rings = StatusBarCompactRingsView()
        rings.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let snapshots = [UsageProvider.codex, .kimi].map {
            MenuBarSnapshot(provider: $0, modelName: nil, remainingPercent: percent,
                ringPercent: percent, paceDeltaPercent: 10, ringTrend: nil,
                resetsAt: nil, state: .ready, isLowQuota: false, tooltip: "test")
        }
        rings.setSnapshots(snapshots, codexConnectivity: .reachable,
            paceDisplayMode: .staged, isSelfTesting: false, activeTaskCounts: [:],
            horizontalPadding: 4, ringSpacing: 4, accessibilityLabel: "test")
        let images = rings.renderedFrames(scale: 2, height: 22, resetAlertBright: bright)
        XCTAssertEqual(images.count, 1)
        let image = try XCTUnwrap(images.first)
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 50, height: 22))
        XCTAssertTrue(image.representations.allSatisfy { $0 is NSBitmapImageRep })
        return try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
    }

    func testOnlyCodexChangesBetweenFixedRasterFrames() throws {
        let bright = try frame(bright: true)
        let normal = try frame(bright: false)
        var codexDifferences = 0
        for x in 0..<bright.pixelsWide {
            for y in 0..<bright.pixelsHigh {
                let a = bright.colorAt(x: x, y: y)
                let b = normal.colorAt(x: x, y: y)
                if x >= 54 { XCTAssertEqual(a, b, "Other provider rings must stay unchanged") }
                else if a != b { codexDifferences += 1 }
            }
        }
        XCTAssertGreaterThan(codexDifferences, 20)
    }

    func testQuotaUpdatesChangeBothAlertPhases() throws {
        for bright in [true, false] {
            XCTAssertNotEqual(try frame(bright: bright, percent: 20).tiffRepresentation,
                try frame(bright: bright, percent: 80).tiffRepresentation)
        }
    }

    func testYellowDotRemainsInNormalPhase() throws {
        let normal = try frame(bright: false)
        let yellowPixels = (0..<normal.pixelsWide / 2).flatMap { x in
            (0..<normal.pixelsHigh).compactMap { y -> NSColor? in
                guard let color = normal.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.5, color.redComponent > 0.8,
                      color.greenComponent > 0.6, color.blueComponent < 0.4 else { return nil }
                return color
            }
        }
        XCTAssertGreaterThan(yellowPixels.count, 3)
    }
}
