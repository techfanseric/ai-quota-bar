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
                     offlineOpacity: CGFloat = 1, liveOpacity: CGFloat = 1,
                     trend: [MenuBarRingTrendPoint]? = nil) {
        withCanvas(in: rect) {
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
            // The trend and the fan share the same inner disc, so only one of them
            // can be the inner channel. A weekly-only account has no short window to
            // be fast or slow against -- its shape is the only information left.
            //
            // The point-count floor is MenuBarRingTrend.minimumPoints (2), not 1: a
            // single sample has no line to draw, so it would only leave a lone dot
            // where the fan should be. Below the floor the fan keeps the disc, so a
            // week that is genuinely in deficit never looks blank.
            if let trend, trend.count >= MenuBarRingTrend.minimumPoints, status == .ready {
                drawTrend(trend, color: ringColor)
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
    }

    /// 把 367 × 410 的构图坐标系套到 rect 上执行 body。
    ///
    /// 环心 (183.5, 183.5) 落在 rect 的水平中点、垂直中点偏上 21.5 × scale
    /// 处 —— 菜单栏高度 22pt 时那点偏移不足 0.1pt，但整套几何（弧、扇形、
    /// 记号）都按它算，所以必须走同一个入口，不能各写一份。
    private static func withCanvas(in rect: NSRect, _ body: () -> Void) {
        let scale = min(rect.width / 367, rect.height / 410)
        guard scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX - 183.5 * scale, yBy: rect.midY - 205 * scale)
        transform.scale(by: scale)
        transform.concat()
        body()
    }

    /// Inner-disc plot box, in the same 367 × 410 space as everything else.
    /// Deliberately inset: the ring's inner edge sits at radius
    /// 155.975 − 55.05/2 ≈ 128.5 and the provider letter starts at y = 286, so a
    /// full-scale curve stops at 279.5 and can never touch either.
    static let trendPlotHalfWidth = 92.0
    static let trendPlotHalfHeight = 96.0
    static let trendClipRadius = 112.0

    /// Inner-disc trend sparkline: remaining percent over the window's own history.
    private static func drawTrend(_ values: [MenuBarRingTrendPoint], color: NSColor) {
        guard !values.isEmpty else { return }
        let points = values.map { value -> NSPoint in
            let x = min(1, max(0, value.x.isFinite ? value.x : 0))
            let y = min(1, max(0, value.y.isFinite ? value.y : 0))
            return NSPoint(
                x: 183.5 - trendPlotHalfWidth + trendPlotHalfWidth * 2 * x,
                y: 183.5 - trendPlotHalfHeight + trendPlotHalfHeight * 2 * y)
        }

        let clip = NSBezierPath(ovalIn: NSRect(
            x: 183.5 - trendClipRadius, y: 183.5 - trendClipRadius,
            width: trendClipRadius * 2, height: trendClipRadius * 2))
        clip.addClip()

        if points.count >= 2 {
            let line = NSBezierPath()
            line.move(to: points[0])
            for point in points.dropFirst() { line.line(to: point) }

            // A soft fill under the line gives the shape a readable mass at 22pt;
            // the stroke alone is a hairline that disappears against the ring.
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: points[0].x, y: 183.5 - trendPlotHalfHeight))
            for point in points { fill.line(to: point) }
            fill.line(to: NSPoint(x: points[points.count - 1].x, y: 183.5 - trendPlotHalfHeight))
            fill.close()
            color.withAlphaComponent(0.22).setFill()
            fill.fill()

            line.lineWidth = 9
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }

        // The live end cap replaces the center dot the fan layout uses: it points
        // at "now" instead of at the geometric center, which is the whole point.
        // One sample is a cap and nothing else -- still a curve row, just a short one.
        let end = points[points.count - 1]
        let cap = NSBezierPath(ovalIn: NSRect(x: end.x - 15, y: end.y - 15, width: 30, height: 30))
        color.setFill()
        cap.fill()
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

    /// 菜单栏占位的默认形态：哑色开环 + 中心一枚 OpenAI 连通性记号。
    ///
    /// **刻意做得不像「Codex 真掉线」。** 那一态是三重信号叠加 —— 整环变红、
    /// 中心一颗粗红药丸、呼吸脉冲动画；这里环**始终**保持哑色中性，只有中心记号
    /// 承载状态，且完全静态。形状、环色、动画三处都不同，所以缩到二十几像素
    /// 也不至于把「占位时顺手告诉你通不通」误读成「Codex 正在掉线」。
    ///
    /// 可达用中性 labelColor 而不是绿色：这个 App 的语义色只有警示琥珀与危险
    /// 红，绿色是全新的一种含义，引入它反而多一个要学的约定。
    static func drawConnectivityMark(in rect: NSRect, connectivity: CodexConnectivityState) {
        withCanvas(in: rect) {
            let foreground = NSColor.labelColor
            arc(from: 0, to: 1, color: foreground.withAlphaComponent(0.22))
            switch connectivity {
            case .reachable:
                strokeConnectivityGlyph(checkMark, color: foreground)
            case .unreachable:
                strokeConnectivityGlyph(crossMark, color: danger)
            case .unknown:
                // 首次探测还没回来：中性小圆点。同一形状原地换成勾/叉，不会
                // 在启动那一两秒闪一下别的东西出来。直径取 52 而非扇形布局中心点
                // 的 38 —— 缩到 22pt 时 38 只是一粒灰尘，看着像没画出来。
                foreground.withAlphaComponent(0.45).setFill()
                NSBezierPath(ovalIn: NSRect(x: 157.5, y: 157.5, width: 52, height: 52)).fill()
            }
        }
    }

    /// 记号笔画线宽。取 32 是量出来的：缩到 22pt 菜单栏高度后约 1.7pt，与环内
    /// 扇形布局那个 38 直径的中心点（约 2.0pt）同一量级；再细一档在真实尺寸下
    /// 就会糊成一根灰线，勾和叉都读不出来。
    static let connectivityGlyphLineWidth: CGFloat = 32

    /// 对勾。包围盒中心刻意压在环心 (183.5, 183.5)，而不是折线重心 —— 右侧
    /// 那笔明显更长，重心偏右下，不抬正就会看着往右下歪。
    static let checkMark: NSBezierPath = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 120, y: 179))
        path.line(to: NSPoint(x: 166, y: 133))
        path.line(to: NSPoint(x: 247, y: 234))
        return path
    }()

    /// 叉。两笔跨度与对勾的包围盒接近，缩到同一体量后读起来重量一致。
    static let crossMark: NSBezierPath = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 131, y: 131))
        path.line(to: NSPoint(x: 236, y: 236))
        path.move(to: NSPoint(x: 236, y: 131))
        path.line(to: NSPoint(x: 131, y: 236))
        return path
    }()

    private static func strokeConnectivityGlyph(_ path: NSBezierPath, color: NSColor) {
        path.lineWidth = connectivityGlyphLineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
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
            withCanvas(in: rect) {
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
            }
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
