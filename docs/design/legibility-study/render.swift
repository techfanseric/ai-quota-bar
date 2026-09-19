import AppKit

func prototype(_ style: Int, rect: NSRect, letter: String, delta: Double?, low: Bool = false, offline: Bool = false, dark: Bool = false) {
    let fg = dark ? NSColor.white : NSColor(calibratedWhite: 0.22, alpha: 1)
    if style == 0 {
        QuotaSymbolRenderer.draw(in: rect, initial: letter, remaining: low ? 0.15 : 0.72,
            signedFill: delta, status: offline ? .offline : .ready, lowQuota: low, foreground: fg)
        return
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let scale = min(rect.width/367, rect.height/410)
    let t = NSAffineTransform()
    t.translateX(by: rect.midX-183.5*scale, yBy: rect.midY-205*scale)
    t.scale(by: scale); t.concat()
    let muted = fg.withAlphaComponent(dark ? 0.24 : 0.19)
    func arc(_ fraction: Double, color: NSColor) {
        let p = NSBezierPath()
        p.appendArc(withCenter: NSPoint(x:183.5,y:183.5),radius:155.975,startAngle:38,endAngle:38-256*fraction,clockwise:true)
        p.lineWidth=55.05; p.lineCapStyle = .round; color.setStroke(); p.stroke()
    }
    arc(1, color:muted)
    arc(low ? 0.15 : 0.72, color:offline ? QuotaSymbolRenderer.danger : low ? QuotaSymbolRenderer.warning : fg)
    let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:130,weight:.bold),.foregroundColor:fg]
    let text=letter as NSString
    text.draw(at:NSPoint(x:183.5-text.size(withAttributes:attrs).width/2,y:286),withAttributes:attrs)
    if offline {
        QuotaSymbolRenderer.danger.setFill()
        NSBezierPath(roundedRect:NSRect(x:88.5,y:157.5,width:190,height:52),xRadius:26,yRadius:26).fill()
        return
    }
    let magnitude = abs(delta ?? 0)
    func shape(_ p:NSBezierPath, active:Bool) { (active ? fg : muted).setFill(); p.fill() }
    if style == 1 {
        for (offset,width) in [(-80.0,176.0),(-40,102),(0,40),(40,102),(80,176)] {
            let active = delta != nil && (offset == 0 || ((delta! > 0) == (offset > 0) && magnitude > 0 && (abs(offset) == 40 || magnitude > 0.5)))
            shape(NSBezierPath(roundedRect:NSRect(x:183.5-width/2,y:183.5+offset-16,width:width,height:32),xRadius:6,yRadius:6),active:active)
        }
    } else {
        shape(NSBezierPath(ovalIn:NSRect(x:164.5,y:164.5,width:38,height:38)),active:delta != nil)
        for sign in [-1.0,1.0] {
            for (index,radii) in [(0,(42.0,69.0)),(1,(82.0,109.0))] {
                let (inner,outer)=radii
                let start=sign > 0 ? 35.0 : 215.0
                let end=start+110
                let a=start*Double.pi/180
                let p=NSBezierPath()
                p.move(to:NSPoint(x:183.5+cos(a)*outer,y:183.5+sin(a)*outer))
                p.appendArc(withCenter:NSPoint(x:183.5,y:183.5),radius:outer,startAngle:start,endAngle:end,clockwise:false)
                p.appendArc(withCenter:NSPoint(x:183.5,y:183.5),radius:inner,startAngle:end,endAngle:start,clockwise:true)
                p.close()
                shape(p,active:delta != nil && delta! * sign > 0 && (index == 0 || magnitude > 0.5))
            }
        }
    }
}

@main struct Study {
    static func main() throws {
        let root="/Users/ericyim/ai-quota-bar/docs/design/legibility-study"
        let cases:[(String,String,Double?,Bool,Bool)] = [("余量","K",1,false,false),("正常","C",0,false,false),("透支","M",-1,false,false),("低额度","M",-1,true,false),("断网","G",nil,false,true),("轻度余量","K",0.5,false,false)]
        func bitmap(_ w:Int,_ h:Int) -> NSBitmapImageRep {
            NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:w,pixelsHigh:h,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        }
        let sheet=bitmap(960,660)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:sheet)
        for dark in [false,true] {
            let base:CGFloat=dark ? 0 : 330
            (dark ? NSColor(calibratedWhite:0.12,alpha:1) : .white).setFill()
            NSBezierPath(rect:NSRect(x:0,y:base,width:960,height:330)).fill()
            let fg: NSColor=dark ? .white : .black
            for style in 0...2 {
                let y=base+CGFloat(2-style)*110
                let title=["现版 · 60° 开口","A · 加宽沙漏条","B · 双向扇形"][style]
                (title as NSString).draw(at:NSPoint(x:18,y:y+65),withAttributes:[.font:NSFont.systemFont(ofSize:16,weight:.semibold),.foregroundColor:fg])
                ((style==0 ? "当前 19 × 22 pt" : "104° 开口 · 字母上移") as NSString).draw(at:NSPoint(x:18,y:y+40),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:fg.withAlphaComponent(0.7)])
                for (index,item) in cases.enumerated() {
                    let x=CGFloat(index)*121+215
                    prototype(style,rect:NSRect(x:x,y:y+29,width:51,height:60),letter:item.1,delta:item.2,low:item.3,offline:item.4,dark:dark)
                    prototype(style,rect:NSRect(x:x+68,y:y+50,width:17,height:20),letter:item.1,delta:item.2,low:item.3,offline:item.4,dark:dark)
                    (item.0 as NSString).draw(at:NSPoint(x:x+7,y:y+8),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:fg])
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try sheet.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:root+"/comparison.png"))
        for dark in [false,true] { for style in 0...2 { for (index,item) in cases.enumerated() {
            let b=bitmap(38,44)
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:b)
            NSGraphicsContext.current!.cgContext.scaleBy(x:2,y:2)
            prototype(style,rect:NSRect(x:1,y:1,width:17,height:20),letter:item.1,delta:item.2,low:item.3,offline:item.4,dark:dark)
            NSGraphicsContext.restoreGraphicsState()
            try b.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:root+"/\(dark ? "dark" : "light")-\(style)-\(index).png"))
        }}}
    }
}
