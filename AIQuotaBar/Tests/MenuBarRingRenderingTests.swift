// Rendering probes require the DEBUG-only AppKit test hooks.
#if DEBUG
import AppKit
import XCTest
@testable import AIQuotaBar

final class MenuBarRingRenderingTests: XCTestCase {
    func testRasterCacheIgnoresTooltipButInvalidatesVisibleInputs() {
        func key(tooltip: String = "one", percent: Double = 50, appearance: String = "dark",
                 scale: CGFloat = 2, tasks: Int = 1, reduceMotion: Bool = false,
                 placeholderShowsCount: Bool = false) -> CompactStatusRenderState {
            CompactStatusRenderState(snapshots: [MenuBarSnapshot(provider: .codex, modelName: nil,
                remainingPercent: percent, ringPercent: percent, paceDeltaPercent: 0,
                resetsAt: nil, state: .ready, isLowQuota: false, tooltip: tooltip)],
                connectivity: .reachable, pace: .staged, selfTesting: false, tasks: [.codex: tasks],
                padding: 4, spacing: 4, appearance: appearance, scale: scale, height: 22, reduceMotion: reduceMotion,
                placeholderShowsCount: placeholderShowsCount)
        }
        XCTAssertEqual(key(), key(tooltip: "countdown changed"))
        XCTAssertNotEqual(key(), key(percent: 49))
        XCTAssertNotEqual(key(), key(appearance: "light"))
        XCTAssertNotEqual(key(), key(scale: 1))
        XCTAssertNotEqual(key(), key(tasks: 2))
        XCTAssertNotEqual(key(), key(reduceMotion: true))
        XCTAssertNotEqual(key(), key(placeholderShowsCount: true))
    }

    func testInteractiveSelfTestAnimationUsesABoundedFrameRate() {
        XCTAssertGreaterThanOrEqual(
            StatusBarAnimationCadence.selfTestNanoseconds,
            50_000_000)
        XCTAssertLessThanOrEqual(
            StatusBarAnimationCadence.taskWaveSegmentCount,
            16)
        XCTAssertEqual(StatusBarAnimationCadence.taskWaveFramesPerSecond, 30)
    }

    @MainActor
    func testIdleRingIsOpaqueAndTaskRingUsesMovingOpacityWave() throws {
        let idle = try renderTaskRing(
            activeTaskCount: 0,
            orbitPhase: 0)
        let activeWaveAway = try renderTaskRing(
            activeTaskCount: 1,
            orbitPhase: 0)
        let activeWaveOnThickArc = try renderTaskRing(
            activeTaskCount: 1,
            orbitPhase: 0.76)
        let activeWaveOnThinArc = try renderTaskRing(
            activeTaskCount: 1,
            orbitPhase: 0.26)

        let scale: CGFloat = 4
        let center = Int(11 * scale)
        let radius = Int(7.61 * scale)
        let centerY = Int(12.05 * scale)

        let idleRingLuminance = try luminance(
            idle,
            x: center + radius,
            y: centerY)
        let activeBaseLuminance = try luminance(
            activeWaveAway,
            x: center + radius,
            y: centerY)
        XCTAssertEqual(activeBaseLuminance, idleRingLuminance, accuracy: 0.05)

        let waveLuminance = try luminance(
            activeWaveOnThickArc,
            x: center + radius,
            y: centerY)
        XCTAssertGreaterThan(waveLuminance, activeBaseLuminance + 0.2)

        let consumedSampleX = center - radius
        let consumedAwayLuminance = try luminance(
            activeWaveAway,
            x: consumedSampleX,
            y: centerY)
        let consumedWaveLuminance = try luminance(
            activeWaveOnThinArc,
            x: consumedSampleX,
            y: centerY)
        XCTAssertLessThan(
            consumedWaveLuminance,
            consumedAwayLuminance - 0.05,
            "The energy wave must remain visible after it hands off to the thin consumed arc.")
    }

    func testTaskEnergyMovesCounterclockwiseAcrossCompleteRing() {
        let phases: [CGFloat] = [0, 0.25, 0.5, 0.75, 0.99, 1]
        let positions = phases.map {
            MenuBarTaskEnergyMotion.orbitPosition(phase: $0)
        }

        XCTAssertEqual(positions[0], 0, accuracy: 0.0001)
        XCTAssertEqual(positions[1], 0.75, accuracy: 0.0001)
        XCTAssertEqual(positions[2], 0.5, accuracy: 0.0001)
        XCTAssertEqual(positions[3], 0.25, accuracy: 0.0001)
        XCTAssertEqual(positions[4], 0.01, accuracy: 0.0001)
        XCTAssertEqual(positions[5], 0, accuracy: 0.0001)

        for position in positions {
            XCTAssertGreaterThanOrEqual(position, 0)
            XCTAssertLessThan(position, 1)
        }
    }

    func testTaskEnergySeamlesslySwitchesWidthAtQuotaBoundary() {
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveLineWidth(
                at: 0.499,
                remainingFraction: 0.5),
            MenuBarTaskEnergyMotion.thickWaveLineWidth,
            accuracy: 0.0001)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveLineWidth(
                at: 0.5,
                remainingFraction: 0.5),
            MenuBarTaskEnergyMotion.thinWaveLineWidth,
            accuracy: 0.0001)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.orbitPosition(phase: 0),
            MenuBarTaskEnergyMotion.orbitPosition(phase: 1),
            accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            8 + MenuBarTaskEnergyMotion.thickWaveLineWidth / 2,
            9.5,
            "The thick electrical wave must stay inside the 19pt ring view.")
    }

    func testTaskEnergyIsSubduedAcrossThinConsumedArc() {
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveOpacityScale(
                at: 0.499,
                remainingFraction: 0.5),
            1,
            accuracy: 0.0001)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveOpacityScale(
                at: 0.5,
                remainingFraction: 0.5),
            MenuBarTaskEnergyMotion.thinWaveOpacityScale,
            accuracy: 0.0001)
        XCTAssertLessThan(
            MenuBarTaskEnergyMotion.thinWaveOpacityScale,
            0.5,
            "The current on the thin arc should stay visible without competing with the thick quota arc.")
    }

    @MainActor
    func testNearlyExhaustedRingStillAnimatesAcrossThinArc() throws {
        let waveAway = try renderTaskRing(
            activeTaskCount: 1,
            orbitPhase: 0,
            ringPercent: 5)
        let waveOnConsumedArc = try renderTaskRing(
            activeTaskCount: 1,
            orbitPhase: 0.26,
            ringPercent: 5)
        let scale: CGFloat = 4
        let center = Int(11 * scale)
        let radius = Int(8 * scale)

        let away = try luminance(
            waveAway,
            x: center - radius,
            y: center)
        let energized = try luminance(
            waveOnConsumedArc,
            x: center - radius,
            y: center)
        XCTAssertLessThan(
            energized,
            away - 0.05,
            "A 5%-remaining ring must still show current around its thin consumed arc.")
    }

    func testTaskEnergyWaveFadesClockwiseBehindOpaqueHead() {
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0),
            1,
            accuracy: 0.0001)
        XCTAssertGreaterThan(
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0.25),
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0.5))
        XCTAssertGreaterThan(
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0.5),
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0.75))
        XCTAssertGreaterThan(
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0.5),
            0.6)
        XCTAssertGreaterThan(
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 0.75),
            0.35)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveOpacity(
                clockwiseDistanceFromHead: 1),
            0,
            accuracy: 0.0001)
    }

    func testTaskCountMapsDirectlyToAtMostFiveEnergyWaves() {
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveCount(
                activeTaskCount: 0),
            0)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveCount(
                activeTaskCount: 1),
            1)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveCount(
                activeTaskCount: 4),
            4)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveCount(
                activeTaskCount: 5),
            5)
        XCTAssertEqual(
            MenuBarTaskEnergyMotion.waveCount(
                activeTaskCount: 12),
            5)
    }

    func testMultipleTaskWavesUseEvenPhaseSpacing() {
        let phases = (0 ..< 5).map {
            MenuBarTaskEnergyMotion.phase(
                basePhase: 0.1,
                waveIndex: $0,
                waveCount: 5)
        }
        XCTAssertEqual(phases[0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(phases[1], 0.3, accuracy: 0.0001)
        XCTAssertEqual(phases[2], 0.5, accuracy: 0.0001)
        XCTAssertEqual(phases[3], 0.7, accuracy: 0.0001)
        XCTAssertEqual(phases[4], 0.9, accuracy: 0.0001)
    }

    @MainActor
    func testCompactRingStatesRenderDistinctPixels() throws {
        let states: [(ring: Double, delta: Double?, mode: MenuBarPaceDisplayMode, connectivity: CodexConnectivityState, offlineMorph: CGFloat, offlinePulseOpacity: CGFloat)] = [
            (99, -1, .continuous, .reachable, 0, 1),
            (20, -18, .staged, .reachable, 0, 1),
            (50, 0, .staged, .reachable, 0, 1),
            (80, 18, .staged, .reachable, 0, 1),
            (35, -MenuBarPaceGlyph.percentPointsPerDay, .continuous, .reachable, 0, 1),
            (70, MenuBarPaceGlyph.fullScaleDeltaPercent, .continuous, .reachable, 0, 1),
            (70, nil, .continuous, .reachable, 0, 1),
            (0, 0, .staged, .unreachable, 1, 1),
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

        // Canonical SVG bar centers mapped into the 22pt view. Bitmap rows run
        // from the top, while the native renderer uses bottom-left coordinates.
        func sectorLuminance(_ index: Int, sourceY: CGFloat) -> Int {
            luminanceAt(x: centerX(for: index), y: Int((1 + sourceY * 20 / 410) * scale))
        }
        XCTAssertLessThan(sectorLuminance(1, sourceY: 282), sectorLuminance(1, sourceY: 171) - 100)
        XCTAssertLessThan(sectorLuminance(3, sourceY: 171), sectorLuminance(3, sourceY: 282) - 100)
        XCTAssertLessThan(sectorLuminance(2, sourceY: 227), sectorLuminance(2, sourceY: 171) - 100)
        XCTAssertGreaterThan(sectorLuminance(6, sourceY: 227), sectorLuminance(2, sourceY: 227) + 100,
                             "Unknown pace must not look like confirmed on-pace")
        XCTAssertGreaterThan(sectorLuminance(9, sourceY: 227), sectorLuminance(8, sourceY: 227) + 100,
                             "Offline dash should pulse without hiding the provider or quota")

        if let previewPath = ProcessInfo.processInfo.environment["AI_QUOTA_RENDER_PREVIEW_PATH"] {
            try pngData.write(to: URL(fileURLWithPath: previewPath), options: .atomic)
        }
    }

    @MainActor
    func testHoverPreservesKimiPaceAndProviderInitial() throws {
        let view = StatusBarCompactRingView(
            frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        let snapshot = MenuBarSnapshot(
            provider: .kimi,
            modelName: "Kimi",
            remainingPercent: 42,
            ringPercent: 42,
            paceDeltaPercent: -12,
            resetsAt: nil,
            state: .ready,
            isLowQuota: false,
            tooltip: "Kimi")
        view.setSnapshot(
            snapshot,
            connectivity: .unknown,
            accessibilityLabel: "Kimi")

        let normal = try renderedPNG(of: view)
        view.setHoveredForTesting(true)
        let hovered = try renderedPNG(of: view)
        view.setHoveredForTesting(false)
        let restored = try renderedPNG(of: view)

        XCTAssertEqual(normal, hovered)
        XCTAssertEqual(normal, restored)
    }

    @MainActor
    func testCompactStripAlwaysShowsEveryProviderInitial() {
        let view = StatusBarCompactRingsView(
            frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        let snapshots = [UsageProvider.codex, .kimi].map { provider in
            MenuBarSnapshot(
                provider: provider,
                modelName: provider.displayName,
                remainingPercent: 50,
                ringPercent: 50,
                paceDeltaPercent: 0,
                resetsAt: nil,
                state: .ready,
                isLowQuota: false,
                tooltip: provider.displayName)
        }
        view.setSnapshots(
            snapshots,
            codexConnectivity: .reachable,
            paceDisplayMode: .staged,
            isSelfTesting: false,
            activeTaskCounts: [:],
            accessibilityLabel: "Codex and Kimi")

        XCTAssertEqual(view.providerInitialCountForTesting, 2)
        view.setHoveredForTesting(true)
        XCTAssertEqual(view.providerInitialCountForTesting, 2)
        view.setHoveredForTesting(false)
        XCTAssertEqual(view.providerInitialCountForTesting, 2)
    }

    @MainActor
    func testCompactStripRoutesActivityCountsToMatchingProviderRings() {
        let view = StatusBarCompactRingsView()
        let snapshots = [UsageProvider.codex, .kimi].map { provider in
            MenuBarSnapshot(
                provider: provider,
                modelName: provider.displayName,
                remainingPercent: 50,
                ringPercent: 50,
                paceDeltaPercent: 0,
                resetsAt: nil,
                state: .ready,
                isLowQuota: false,
                tooltip: provider.displayName)
        }
        view.setSnapshots(
            snapshots,
            codexConnectivity: .reachable,
            paceDisplayMode: .staged,
            isSelfTesting: false,
            activeTaskCounts: [.codex: 2, .kimi: 3],
            accessibilityLabel: "Codex and Kimi")

        XCTAssertEqual(view.activeTaskCountsForTesting, [2, 3])
    }

    @MainActor
    func testCompactButtonFramesPreserveSizeAndAnimate() throws {
        let view = StatusBarCompactRingsView(
            frame: NSRect(x: 0, y: 0, width: 44, height: 22))
        let snapshot = MenuBarSnapshot(
            provider: .codex,
            modelName: "5h",
            remainingPercent: 65,
            ringPercent: 65,
            paceDeltaPercent: 5,
            resetsAt: nil,
            state: .ready,
            isLowQuota: false,
            tooltip: "Codex")
        view.setSnapshots(
            [snapshot],
            codexConnectivity: .reachable,
            paceDisplayMode: .staged,
            isSelfTesting: false,
            activeTaskCounts: [.codex: 1],
            accessibilityLabel: "Codex")

        let frames = view.renderedFrames(scale: 2, height: 22)
        let hoverFrames = view.renderedFrames(
            scale: 2,
            height: 22,
            showsProviderInitials: true)

        XCTAssertEqual(frames.count, 54)
        XCTAssertEqual(frames.first?.size.height, 22)
        XCTAssertEqual(hoverFrames.count, 1)
        XCTAssertNotEqual(
            try XCTUnwrap(frames.first?.tiffRepresentation),
            try XCTUnwrap(frames.dropFirst(5).first?.tiffRepresentation))
        XCTAssertEqual(
            try XCTUnwrap(frames.first?.tiffRepresentation),
            try XCTUnwrap(hoverFrames.first?.tiffRepresentation))

        let bitmap = try XCTUnwrap(
            frames.first?.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .first)
        var occupiedRows = Set<Int>()
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide
            where bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.01 {
                occupiedRows.insert(y)
            }
        }
        XCTAssertGreaterThanOrEqual(
            occupiedRows.count,
            30,
            "A 2x Retina ring must occupy its original ~16pt height")
    }

    @MainActor
    private func renderedPNG(
        of view: NSView
    ) throws -> Data {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func renderTaskRing(
        activeTaskCount: Int,
        orbitPhase: CGFloat,
        ringPercent: Double = 50
    ) throws -> NSBitmapImageRep {
        let size = NSSize(width: 22, height: 22)
        let scale: CGFloat = 4
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        bitmap.size = size
        let context = try XCTUnwrap(
            NSGraphicsContext(bitmapImageRep: bitmap))
        let view = StatusBarCompactRingView(
            frame: NSRect(origin: .zero, size: size))
        view.appearance = NSAppearance(
            named: .aqua)
        view.setSnapshot(
            MenuBarSnapshot(
                provider: .codex,
                modelName: "Weekly",
                remainingPercent: ringPercent,
                ringPercent: ringPercent,
                paceDeltaPercent: 0,
                resetsAt: Date().addingTimeInterval(3_600),
                state: .ready,
                isLowQuota: false,
                tooltip: "Preview"),
            connectivity: .reachable,
            activeTaskCount: activeTaskCount,
            accessibilityLabel: "Preview")
        view.setTaskOrbitPhaseForTesting(orbitPhase)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(
            rect: NSRect(origin: .zero, size: size))
            .fill()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func luminance(
        _ bitmap: NSBitmapImageRep,
        x: Int,
        y: Int
    ) throws -> CGFloat {
        let color = try XCTUnwrap(
            bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB))
        return color.redComponent
            + color.greenComponent
            + color.blueComponent
    }
}

#endif
