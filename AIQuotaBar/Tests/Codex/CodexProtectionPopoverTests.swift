import AppKit
import SwiftUI
import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexProtectionPopoverTests: XCTestCase {
    func testCompactProtectionControlsRenderInsidePopoverWidth() throws {
        let suiteName = "CodexProtectionPopoverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: ClosedLidModeManager.enabledKey)

        let missingHelper = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let coordinator = CodexSleepProtectionCoordinator(
            defaults: defaults,
            assertionController: PopoverPowerAssertionController(),
            hookInstaller: CodexHookInstaller(
                hooksURL: missingHelper.appendingPathComponent("hooks.json"),
                helperURL: missingHelper.appendingPathComponent("AIQuotaBarHook")
            ),
            localActivityProvider: nil,
            closedLidModeManager: ClosedLidModeManager(
                defaults: defaults,
                bundle: .main
            ),
            workspaceNotificationCenter: NotificationCenter()
        )
        coordinator.start()
        defer {
            coordinator.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let size = NSSize(
            width: ClashPopoverLayout.width,
            height: 140)
        let hostingView = NSHostingView(
            rootView: CodexProtectionPopoverView(
                coordinator: coordinator,
                closedLidModeManager: coordinator.closedLidModeManager,
                language: .simplifiedChinese
            )
            .frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let png = try XCTUnwrap(
            bitmap.representation(using: .png, properties: [:])
        )
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "aiquotabar-codex-protection-popover.png"
            )
        try png.write(to: outputURL, options: .atomic)

        XCTAssertEqual(
            hostingView.fittingSize.width,
            ClashPopoverLayout.width,
            accuracy: 1)
        XCTAssertEqual(hostingView.fittingSize.height, 140, accuracy: 1)
        XCTAssertGreaterThan(png.count, 8_000)
    }
}

private final class PopoverPowerAssertionController:
    PowerAssertionControlling
{
    var isHoldingAssertions = false

    func acquire(
        keepDisplayAwake: Bool,
        declareUserActivity: Bool
    ) throws {
        isHoldingAssertions = true
    }

    func update(
        keepDisplayAwake: Bool,
        declareUserActivity: Bool
    ) throws {
        isHoldingAssertions = true
    }

    func release() {
        isHoldingAssertions = false
    }
}
