import AppKit
import XCTest
@testable import AIQuotaBar

@MainActor
final class StepAwayDimStatusIconTests: XCTestCase {
    func testTemplateQuotaRemainsLegibleInLightAndDarkAppearances() throws {
        let base = try XCTUnwrap(NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil))
        base.size = NSSize(width: 18, height: 18)
        base.isTemplate = true
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let result = StepAwayDimStatusIcon.image(addingTo: base, appearance: appearance)
            let bitmap = try XCTUnwrap(result.representations.first as? NSBitmapImageRep)
            let center = try XCTUnwrap(bitmap.colorAt(x: 18, y: 26)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(center.alphaComponent, 0.8)
            if name == .darkAqua {
                XCTAssertGreaterThan(center.redComponent, 0.8)
            } else {
                XCTAssertLessThan(center.redComponent, 0.2)
            }
        }
    }

    func testBadgeKeepsQuotaAndAlertPixelsAndHasNativeResolutionRepresentations() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for bright in [true, false] {
                let base = try XCTUnwrap(CodexResetAlertIcon.image(bright: bright, appearance: appearance))
                let result = StepAwayDimStatusIcon.image(addingTo: base, appearance: appearance, scale: 3)
                XCTAssertEqual(result.size, NSSize(width: 37, height: 22))
                XCTAssertFalse(result.isTemplate)
                XCTAssertEqual(Set(result.representations.map(\.pixelsWide)), [37, 74, 111])
                XCTAssertTrue(result.representations.allSatisfy { $0 is NSBitmapImageRep })
                let bitmap = try XCTUnwrap(result.representations.first { $0.pixelsWide == 74 } as? NSBitmapImageRep)
                let original = try XCTUnwrap(base.representations.first as? NSBitmapImageRep)
                for x in 0..<36 {
                    for y in 0..<36 {
                        XCTAssertEqual(bitmap.colorAt(x: x, y: y + 8), original.colorAt(x: x, y: y))
                    }
                }
                let badgeColors = (36..<74).flatMap { x in
                    (0..<44).compactMap { y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
                }
                XCTAssertTrue(badgeColors.contains {
                    $0.alphaComponent > 0.9 && $0.redComponent > 0.9
                        && $0.greenComponent > 0.9 && $0.blueComponent > 0.9
                }, "The white moon must remain visible during both alert animation phases")
                XCTAssertTrue(badgeColors.contains {
                    $0.alphaComponent > 0.9 && $0.redComponent < 0.1
                        && $0.greenComponent < 0.1 && $0.blueComponent < 0.1
                }, "The moon must sit on a black screen in either appearance")
                XCTAssertTrue(badgeColors.allSatisfy {
                    abs($0.redComponent - $0.greenComponent) < 0.02
                        && abs($0.greenComponent - $0.blueComponent) < 0.02
                }, "Dim is a monochrome screen status, without a colored quota arc")
            }
        }
    }

    func testDetailedLayoutAddsAndRemovesIndicatorWithoutLosingText() {
        let view = StatusBarContentView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        view.showDetailed(line1: "60%", line2: "2h")
        let normalWidth = view.preferredWidth
        view.isDimmingActive = true
        view.setFrameSize(NSSize(width: view.preferredWidth, height: 22))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.preferredWidth, normalWidth + StepAwayDimStatusIcon.width)
        let badge = view.subviews.compactMap { $0 as? NSImageView }.first
        XCTAssertEqual(badge?.isHidden, false)
        XCTAssertNotNil(badge?.image)
        XCTAssertEqual(badge?.frame.minX, normalWidth)
        view.isDimmingActive = false
        XCTAssertEqual(view.preferredWidth, normalWidth)
        XCTAssertEqual(badge?.isHidden, true)
    }

    func testAlertCacheInvalidatesWhenDimmingChanges() throws {
        let item = NSStatusBar.system.statusItem(withLength: 26)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        XCTAssertNotEqual(CodexResetAlertRenderState(button: button),
            CodexResetAlertRenderState(button: button, isDimmingActive: true))
    }
}
