import AppKit

/// Geometry from the supplied 367 × 410 SVG family, in a bottom-left coordinate system.
/// The provider letter, remaining arc, and pace are independent information channels.
enum QuotaSymbolRenderer {
    static let ringStartAngle = 38.0
    static let ringSweepAngle = 256.0

    enum Status { case ready, loading, setup, unavailable, failed, offline }
    static let warning = NSColor(srgbRed: 214/255, green: 160/255, blue: 10/255, alpha: 1)
    static let danger = NSColor(srgbRed: 194/255, green: 21/255, blue: 21/255, alpha: 1)

    static func draw(in rect: NSRect, initial: String, remaining: Double?,
                     signedFill: Double?, status: Status = .ready, lowQuota: Bool = false,
                     foreground: NSColor = .labelColor, track: NSColor? = nil,
                     offlineOpacity: CGFloat = 1, liveOpacity: CGFloat = 1) {
        let scale = min(rect.width / 367, rect.height / 410)
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX - 183.5 * scale, yBy: rect.midY - 205 * scale)
        transform.scale(by: scale)
        transform.concat()
        let muted = track ?? foreground.withAlphaComponent(0.18)
        let blocked = status == .offline || status == .failed || status == .unavailable
        let ringColor: NSColor = blocked ? danger : lowQuota ? warning : foreground
        arc(from: 0, to: 1, color: muted)
        if let remaining, remaining.isFinite, status != .setup, status != .loading {
            arc(from: 0, to: min(1, max(0, remaining)), color: ringColor.withAlphaComponent(liveOpacity))
        } else if status == .loading {
            arc(from: 0, to: 0.28, color: foreground.withAlphaComponent(0.5))
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 130, weight: .bold),
            .foregroundColor: foreground,
        ]
        let letter = initial as NSString
        let size = letter.size(withAttributes: attributes)
        letter.draw(at: NSPoint(x: 183.5 - size.width / 2, y: 286), withAttributes: attributes)
        if blocked {
            danger.withAlphaComponent(status == .offline ? offlineOpacity : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 88.5, y: 157.5, width: 190, height: 52), xRadius: 26, yRadius: 26).fill()
            return
        }
        let knownPace = status == .ready && signedFill?.isFinite == true
        let fill = knownPace ? signedFill! : 0
        let dot = NSBezierPath(ovalIn: NSRect(x: 164.5, y: 164.5, width: 38, height: 38))
        (knownPace ? foreground : muted).setFill()
        dot.fill()
        // Two broad annular sectors on each side. Four staged levels and
        // continuous mode share an angular fill that grows symmetrically.
        for upward in [true, false] {
            for (index, radii) in [(0, (42.0, 69.0)), (1, (82.0, 109.0))] {
                let (inner, outer) = radii
                let middle = upward ? 90.0 : 270.0
                muted.setFill()
                sector(inner: inner, outer: outer, middle: middle, fraction: 1).fill()
                let fraction = min(1, max(0, abs(fill) * 2 - Double(index)))
                if fraction > 0, (fill > 0) == upward {
                    foreground.setFill()
                    sector(inner: inner, outer: outer, middle: middle, fraction: fraction).fill()
                }
            }
        }
    }

    private static func sector(inner: Double, outer: Double, middle: Double, fraction: Double) -> NSBezierPath {
        let start = middle - 55 * fraction
        let end = middle + 55 * fraction
        let radians = start * .pi / 180
        let center = NSPoint(x: 183.5, y: 183.5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + cos(radians) * outer, y: center.y + sin(radians) * outer))
        path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.close()
        return path
    }

    static func arc(from start: Double, to end: Double, color: NSColor) {
        guard end > start else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: NSPoint(x: 183.5, y: 183.5), radius: 155.975,
                       startAngle: ringStartAngle - ringSweepAngle * start, endAngle: ringStartAngle - ringSweepAngle * end, clockwise: true)
        path.lineWidth = 55.05
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 菜单栏占位：所有供应商都被隐藏时显示。默认复刻 App 图标的完整
    /// 构图（哑色开环 + "A" + 中心点/翼瓣），视觉重量与相邻供应商环一致；
    /// `count` 非 nil 时改为中性细环 + 供应商数量。
    static func drawBrandMark(in rect: NSRect, count: Int? = nil) {
        if let count, count > 0 {
            let scale = min(rect.width / 367, rect.height / 410)
            guard scale > 0 else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX - 183.5 * scale, yBy: rect.midY - 205 * scale)
            transform.scale(by: scale)
            transform.concat()
            let foreground = NSColor.labelColor
            arc(from: 0, to: 1, color: foreground.withAlphaComponent(0.22))
            let text = "\(min(count, 99))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(
                    ofSize: count >= 10 ? 105 : 140, weight: .semibold),
                .foregroundColor: foreground,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(
                    x: 183.5 - size.width / 2,
                    y: 183.5 - size.height / 2),
                withAttributes: attributes)
            return
        }

        // 与 App 图标同构：哑色环 + 顶部 "A" + 中心点/翼瓣。
        draw(
            in: rect,
            initial: "A",
            remaining: nil,
            signedFill: nil,
            status: .ready)
    }
}
