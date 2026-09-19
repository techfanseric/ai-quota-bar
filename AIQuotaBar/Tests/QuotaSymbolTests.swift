// Rendering probes require the DEBUG-only AppKit test hooks.
#if DEBUG
import AppKit
import XCTest
@testable import AIQuotaBar

final class QuotaSymbolTests: XCTestCase {
    @MainActor
    func testWarningAndFailureColorsAreIndependentOfPaceAndProvider() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for scale in [1, 2] {
                let normal = try render(state: .ready, low: false, appearance: appearance, scale: scale)
                let warning = try render(state: .ready, low: true, appearance: appearance, scale: scale)
                let failed = try render(state: .failed, low: true, appearance: appearance, scale: scale)
                let offline = try render(state: .ready, low: false, connectivity: .unreachable, appearance: appearance, scale: scale)
                XCTAssertFalse(hasColor(normal, red: true))
                XCTAssertFalse(hasColor(normal, red: false))
                XCTAssertTrue(hasColor(warning, red: false))
                XCTAssertFalse(hasColor(warning, red: true))
                XCTAssertTrue(hasColor(failed, red: true))
                XCTAssertTrue(hasColor(offline, red: true))
                XCTAssertFalse(hasColor(failed, red: false), "Failure takes precedence over low quota")
            }
        }
    }

    @MainActor
    func testUnknownLoadingSetupAndOfflineDoNotImplyEmptyOrHealthyQuota() throws {
        let ready = try render(state: .ready)
        let loading = try render(state: .loading)
        let setup = try render(state: .needsSetup)
        let unknown = try render(state: .ready, delta: nil)
        let unavailable = try render(state: .unavailable)
        let images = try [ready, loading, setup, unknown, unavailable].map {
            try XCTUnwrap($0.representation(using: .png, properties: [:]))
        }
        XCTAssertEqual(Set(images).count, images.count)
        // An OpenAI connectivity failure must not mark Kimi unavailable.
        let kimiOnline = try render(state: .ready, provider: .kimi)
        let kimiOffline = try render(state: .ready, connectivity: .unreachable, provider: .kimi)
        XCTAssertEqual(kimiOnline.tiffRepresentation, kimiOffline.tiffRepresentation)
    }

    @MainActor
    func testFinalButtonFramesKeepColorsAndAnimateSelfTestAndOffline() throws {
        for selfTest in [false, true] {
            let view = StatusBarCompactRingsView(frame: NSRect(x: 0, y: 0, width: 19, height: 22))
            view.appearance = NSAppearance(named: .aqua)
            view.setSnapshots([MenuBarSnapshot(provider: .codex, modelName: nil,
                remainingPercent: 12, ringPercent: 12, paceDeltaPercent: -12,
                resetsAt: nil, state: .ready, isLowQuota: true, tooltip: "Test")],
                codexConnectivity: selfTest ? .reachable : .unreachable,
                paceDisplayMode: .staged, isSelfTesting: selfTest, activeTaskCounts: [:],
                accessibilityLabel: "Test")
            let frames = view.renderedFrames(scale: 2, height: 22)
            XCTAssertTrue(frames.allSatisfy { !$0.isTemplate }, "Template images discard warning colors")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertEqual(frames.count, selfTest ? 90 : 30)
                XCTAssertNotEqual(frames[0].tiffRepresentation, frames[7].tiffRepresentation)
            }
            let bitmap = try XCTUnwrap(frames[0].representations.first as? NSBitmapImageRep)
            XCTAssertTrue(hasColor(bitmap, red: !selfTest))
        }
    }

    @MainActor
    func testOneXScreenStillProducesNativeRetinaFrames() throws {
        let view = StatusBarCompactRingsView()
        view.setSnapshots([MenuBarSnapshot(provider: .codex, modelName: nil,
            remainingPercent: 65, ringPercent: 65, paceDeltaPercent: 10,
            resetsAt: nil, state: .ready, isLowQuota: false, tooltip: "Test")],
            codexConnectivity: .reachable, paceDisplayMode: .staged,
            isSelfTesting: false, activeTaskCounts: [.codex: 3], accessibilityLabel: "Test")
        let frames = view.renderedFrames(scale: 1, height: 22)
        for frame in frames {
            let reps = frame.representations.compactMap { $0 as? NSBitmapImageRep }
            XCTAssertTrue(reps.contains { $0.pixelsWide == Int(frame.size.width) && $0.pixelsHigh == 22 })
            XCTAssertTrue(reps.contains { $0.pixelsWide == Int(frame.size.width)*2 && $0.pixelsHigh == 44 })
        }
        if let folder = ProcessInfo.processInfo.environment["AI_QUOTA_MOTION_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for (index, frame) in frames.enumerated() {
                let rep = try XCTUnwrap(frame.representations.first as? NSBitmapImageRep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent(String(format: "%03d.png", index)))
            }
        }
    }

    func testTaskOrbitHidesInHeaderInsteadOfJumpingAcrossEndpoints() {
        XCTAssertNil(MenuBarTaskEnergyMotion.visibleArcInterval(start: 0, end: 0.1))
        XCTAssertNil(MenuBarTaskEnergyMotion.visibleArcInterval(start: 0.9, end: 1))
        let all = MenuBarTaskEnergyMotion.visibleArcInterval(start: 0, end: 1)
        XCTAssertEqual(all?.lowerBound, 0)
        XCTAssertEqual(all?.upperBound, 1)
        let right = MenuBarTaskEnergyMotion.visibleArcInterval(start: 0.2, end: 0.3)
        XCTAssertNotNil(right)
        XCTAssertLessThan(right!.upperBound, 0.5)
    }

    private func hasColor(_ bitmap: NSBitmapImageRep, red: Bool) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.3 else { continue }
                if red && c.redComponent > c.greenComponent * 2 && c.redComponent > c.blueComponent * 2 { return true }
                if !red && c.redComponent > 0.5 && c.greenComponent > 0.35 && c.blueComponent < 0.2 { return true }
            }
        }
        return false
    }

    @MainActor
    private func render(state: MenuBarSnapshotState, low: Bool = false, delta: Double? = 0,
                        connectivity: CodexConnectivityState = .reachable, provider: UsageProvider = .codex,
                        appearance: NSAppearance.Name = .aqua, scale: Int = 2) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22*scale, pixelsHigh: 22*scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 22, height: 22)
        let view = StatusBarCompactRingView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        view.setSnapshot(MenuBarSnapshot(provider: provider, modelName: nil, remainingPercent: 65,
            ringPercent: 65, paceDeltaPercent: delta, resetsAt: nil, state: state, isLowQuota: low, tooltip: "Test"),
            connectivity: connectivity, accessibilityLabel: "Test")
        view.setOfflinePulseOpacityForTesting(1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        try XCTUnwrap(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        return bitmap
    }
}

#endif
