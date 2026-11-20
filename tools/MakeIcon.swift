// Генерирует Resources/AppIcon.icns:  swiftc tools/MakeIcon.swift -o /tmp/mkicon && /tmp/mkicon
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    let cs = CGColorSpaceCreateDeviceRGB()
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                             CGFloat(hex & 255) / 255, a])!
    }
    func grad(_ cols: [CGColor]) -> CGGradient { CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: nil)! }

    let body = NSBezierPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)

    // тень
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: c(0x000000, 0.4))
    ctx.setFillColor(c(0x101218)); ctx.addPath(body.cgPath); ctx.fillPath()
    ctx.restoreGState()

    // фон
    ctx.saveGState(); ctx.addPath(body.cgPath); ctx.clip()
    ctx.drawLinearGradient(grad([c(0x2A2F3C), c(0x0A0C11)]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(grad([c(0x3B82F6, 0.28), c(0x3B82F6, 0)]), startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])
    ctx.restoreGState()

    // тонкая обводка
    ctx.saveGState()
    ctx.addPath(body.cgPath); ctx.setStrokeColor(c(0xFFFFFF, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()

    // кольцо-индикатор
    let center = CGPoint(x: 512, y: 512), r: CGFloat = 270
    let a0 = CGFloat.pi * 1.25                         // 225°
    let full = CGFloat.pi * 1.5                        // 270°
    let value: CGFloat = 0.72
    func arc(_ sweep: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addArc(center: center, radius: r, startAngle: a0, endAngle: a0 - sweep, clockwise: true)
        return p
    }
    ctx.saveGState()
    ctx.addPath(arc(full)); ctx.setLineWidth(58); ctx.setLineCap(.round)
    ctx.setStrokeColor(c(0xFFFFFF, 0.1)); ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: c(0x22D3EE, 0.55))
    ctx.addPath(arc(full * value)); ctx.setLineWidth(58); ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([c(0x34D399), c(0x22D3EE), c(0x3B82F6), c(0x8B5CF6)]),
                           start: CGPoint(x: 250, y: 300), end: CGPoint(x: 780, y: 780), options: [])
    ctx.restoreGState()

    // пульс-линия
    let pts: [(CGFloat, CGFloat)] = [(350, 470), (410, 470), (450, 560), (500, 400), (552, 590), (590, 470), (674, 470)]
    let line = CGMutablePath()
    for (i, p) in pts.enumerated() { i == 0 ? line.move(to: CGPoint(x: p.0, y: p.1)) : line.addLine(to: CGPoint(x: p.0, y: p.1)) }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 24, color: c(0xFFFFFF, 0.5))
    ctx.addPath(line); ctx.setStrokeColor(c(0xFFFFFF, 0.96)); ctx.setLineWidth(26)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
