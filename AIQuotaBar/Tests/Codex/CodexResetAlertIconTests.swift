import AppKit
import XCTest
@testable import AIQuotaBar

@MainActor
final class CodexResetAlertIconTests: XCTestCase {
    func testAlertUsesFixedRasterFramesWithDifferentBrightness() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let bright = try XCTUnwrap(CodexResetAlertIcon.image(bright: true, appearance: appearance))
        let dim = try XCTUnwrap(CodexResetAlertIcon.image(bright: false, appearance: appearance))
        XCTAssertEqual(bright.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(bright.representations.count, 1)
        XCTAssertTrue(bright.representations[0] is NSBitmapImageRep,
            "Replicant snapshots must use pre-rendered pixels, not a live drawing handler")
        let brightBitmap = try XCTUnwrap(bright.representations[0] as? NSBitmapImageRep)
        let dimBitmap = try XCTUnwrap(dim.representations[0] as? NSBitmapImageRep)
        XCTAssertNotEqual(brightBitmap.tiffRepresentation, dimBitmap.tiffRepresentation)
        let alpha = (0..<brightBitmap.pixelsWide).flatMap { x in
            (0..<brightBitmap.pixelsHigh).compactMap { y in brightBitmap.colorAt(x: x, y: y)?.alphaComponent }
        }
        XCTAssertGreaterThan(alpha.max() ?? 0, 0.8)
        XCTAssertLessThan(alpha.min() ?? 1, 0.01)
    }
}
