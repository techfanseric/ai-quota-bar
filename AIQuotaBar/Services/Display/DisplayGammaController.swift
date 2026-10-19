import CoreGraphics
import Foundation

/// Preserve the existing calibration (and other apps' current color table).
struct DisplayGammaTable: Codable, Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    var isValid: Bool {
        !red.isEmpty && red.count == green.count && red.count == blue.count
            && (red + green + blue).allSatisfy { $0.isFinite }
    }
    var peak: Float { (red + green + blue).max() ?? 0 }
    /// GPU tables are quantized; ignore insignificant round-trip differences.
    func approximatelyMatches(_ other: Self, tolerance: Float = 0.002) -> Bool {
        guard isValid, other.isValid, red.count == other.red.count else { return false }
        return zip(red + green + blue, other.red + other.green + other.blue)
            .allSatisfy { abs($0 - $1) <= tolerance }
    }

    func scaled(by factor: Float) -> Self {
        let scale = factor.isFinite ? min(1, max(0, factor)) : 1
        return Self(red: red.map { $0 * scale }, green: green.map { $0 * scale },
                    blue: blue.map { $0 * scale })
    }
}

protocol DisplayGammaControlling: AnyObject {
    func read(displayID: CGDirectDisplayID) -> DisplayGammaTable?
    @discardableResult func apply(_ table: DisplayGammaTable, displayID: CGDirectDisplayID) -> Bool
}

final class DisplayGammaController: DisplayGammaControlling {
    func read(displayID: CGDirectDisplayID) -> DisplayGammaTable? {
        let capacity = min(4096, max(256, CGDisplayGammaTableCapacity(displayID)))
        var red = [Float](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count) == .success,
              count > 0, count <= capacity else { return nil }
        let table = DisplayGammaTable(red: Array(red.prefix(Int(count))),
            green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
        return table.isValid ? table : nil
    }

    @discardableResult
    func apply(_ table: DisplayGammaTable, displayID: CGDirectDisplayID) -> Bool {
        guard table.isValid else { return false }
        return CGSetDisplayTransferByTable(displayID, UInt32(table.red.count),
            table.red, table.green, table.blue) == .success
    }
}

/// MonitorControl's default combined scale: the lower half extends below
/// minimum hardware brightness using gamma, with a 15% software floor.
struct DisplayDimPlan: Equatable {
    let hardwarePercent: Double
    let gammaFactor: Float

    init(targetPercent: Double, builtin: Bool) {
        let value = targetPercent.isFinite ? min(100, max(0, targetPercent)) : 0
        hardwarePercent = builtin ? value : max(0, (value - 50) * 2)
        gammaFactor = builtin || value >= 50 ? 1 : Float(0.15 + 0.85 * value / 50)
    }
}
