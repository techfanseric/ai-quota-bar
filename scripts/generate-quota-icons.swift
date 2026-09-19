// Run: swiftc AIQuotaBar/Models/QuotaSymbolRenderer.swift scripts/generate-quota-icons.swift -o /tmp/generate-quota-icons && /tmp/generate-quota-icons
import AppKit

@main struct GenerateQuotaIcons {
    static func render(size: Int, path: String, tile: Bool = true) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let side = CGFloat(size)
        if tile {
            NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: side*0.05, y: side*0.05, width: side*0.9, height: side*0.9), xRadius: side*0.20, yRadius: side*0.20).fill()
        } else {
            NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        }
        QuotaSymbolRenderer.draw(in: NSRect(x: side*0.20, y: side*0.17, width: side*0.60, height: side*0.67),
            initial: "A", remaining: 0.75, signedFill: 0,
            foreground: NSColor(srgbRed: 61/255, green: 61/255, blue: 61/255, alpha: 1),
            track: NSColor(srgbRed: 216/255, green: 216/255, blue: 216/255, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    static func preview() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 340,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let cases: [(String, String, Double?, Double?, QuotaSymbolRenderer.Status, Bool)] = [
            ("Reserve", "K", 0.64, 1, .ready, false),
            ("Pace", "C", 0.9, 0, .ready, false),
            ("Deficit", "M", 0.6, -1, .ready, false),
            ("Low quota", "M", 0.12, -1, .ready, true),
            ("Offline", "C", 0.64, nil, .offline, false),
            ("Failed", "G", 0.64, nil, .failed, false),
            ("Loading", "C", nil, nil, .loading, false),
            ("Setup", "K", nil, nil, .setup, false),
            ("Unknown pace", "M", 0.64, nil, .ready, false),
        ]
        for dark in [false, true] {
            let y: CGFloat = dark ? 0 : 170
            let background = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .white
            let foreground = dark ? NSColor.white : NSColor(calibratedWhite: 0.24, alpha: 1)
            background.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: y, width: 1000, height: 170)).fill()
            for (index, item) in cases.enumerated() {
                let x = CGFloat(index) * 110 + 7
                QuotaSymbolRenderer.draw(in: NSRect(x: x+20, y: y+55, width: 65, height: 80),
                    initial: item.1, remaining: item.2, signedFill: item.3, status: item.4,
                    lowQuota: item.5, foreground: foreground)
                QuotaSymbolRenderer.draw(in: NSRect(x: x+42, y: y+26, width: 20, height: 20),
                    initial: item.1, remaining: item.2, signedFill: item.3, status: item.4,
                    lowQuota: item.5, foreground: foreground)
                (item.0 as NSString).draw(at: NSPoint(x: x+9, y: y+5), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: foreground])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/design/quota-symbol-states.png"))
    }
    static func favicon() throws {
        func point(_ radius: Double, _ angle: Double) -> String {
            let radians = angle * .pi / 180
            return "\(183.5 + cos(radians) * radius),\(226.5 - sin(radians) * radius)"
        }
        func arc(_ fraction: Double, _ color: String) -> String {
            let start = QuotaSymbolRenderer.ringStartAngle
            let sweep = QuotaSymbolRenderer.ringSweepAngle * fraction
            return "<path d=\"M\(point(155.975, start)) A155.975,155.975 0 \(sweep > 180 ? 1 : 0) 1 \(point(155.975, start-sweep))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"55.05\" stroke-linecap=\"round\"/>"
        }
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 367 410\">"
        svg += arc(1, "#D8D8D8") + arc(0.75, "#3D3D3D")
        svg += "<text x=\"183.5\" y=\"116\" text-anchor=\"middle\" font-family=\"Arial,sans-serif\" font-size=\"130\" font-weight=\"700\" fill=\"#3D3D3D\">A</text>"
        for middle in [90.0, 270.0] {
            for (inner, outer) in [(42.0, 69.0), (82.0, 109.0)] {
                let start = middle - 55, end = middle + 55
                svg += "<path d=\"M\(point(outer,start)) A\(outer),\(outer) 0 0 0 \(point(outer,end)) L\(point(inner,end)) A\(inner),\(inner) 0 0 1 \(point(inner,start)) Z\" fill=\"#D8D8D8\"/>"
            }
        }
        svg += "<circle cx=\"183.5\" cy=\"226.5\" r=\"19\" fill=\"#3D3D3D\"/></svg>"
        try svg.write(toFile: "cloudflare/public/favicon.svg", atomically: true, encoding: .utf8)
    }
    static func main() throws {
        try preview()
        try favicon()
        let root = "AIQuotaBar/Resources/Assets.xcassets/AppIcon.appiconset"
        for size in [16,32,128,256,512] {
            try render(size: size, path: "\(root)/icon_\(size)x\(size).png")
            try render(size: size*2, path: "\(root)/icon_\(size)x\(size)@2x.png")
        }
        try render(size: 1024, path: "docs/design/app-icon-master.png")
        try render(size: 512, path: "cloudflare/public/app-icon.png")
        for size in [192,512] {
            try render(size: size, path: "AIQuotaBar/Resources/MobileDashboard/icon-\(size).png", tile: false)
        }
        try render(size: 512, path: "AIQuotaBar/Resources/MobileDashboard/icon-maskable-512.png", tile: false)
        try render(size: 180, path: "AIQuotaBar/Resources/MobileDashboard/apple-touch-icon.png", tile: false)
    }
}
