// Draws the SIP Anywhere app icon (1024×1024 PNG) with Core Graphics.
// Usage: swift scripts/make_icon.swift <output.png>
// The artwork is original (no SF Symbols, which Apple does not allow in app icons).

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Body: macOS icon grid (824 pt rounded square centred in 1024), soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x1F9D6B))
ctx.fillPath()
ctx.restoreGState()

// Gradient fill: fresh green at the top to deep teal at the bottom.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x4BD58A), color(0x14A37A), color(0x0B6F78)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Subtle highlight in the upper half.
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 520), options: [])
ctx.restoreGState()

// Handset, drawn upright (earpiece on top, mouthpiece at the bottom, both facing right,
// handle curving on the left) and then tilted 45° like the classic phone glyph.
let center = CGPoint(x: 478, y: 482)
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: .pi / 4)
ctx.scaleBy(x: 0.70, y: 0.70)
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x003C33, 0.30))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // one shadow for the whole handset
ctx.setFillColor(color(0xFFFFFF))
// Ear and mouth pieces.
for y in [CGFloat(300), -460] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: -40, y: y, width: 230, height: 160),
                       cornerWidth: 70, cornerHeight: 70, transform: nil))
    ctx.fillPath()
}
// Curved handle joining them on the left.
let handle = CGMutablePath()
handle.move(to: CGPoint(x: 30, y: 380))
handle.addCurve(to: CGPoint(x: 30, y: -380),
                control1: CGPoint(x: -230, y: 260), control2: CGPoint(x: -230, y: -260))
ctx.addPath(handle.copy(strokingWithWidth: 150, lineCap: .round, lineJoin: .round, miterLimit: 10))
ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

// "Over the internet" waves in the free upper-right corner.
ctx.saveGState()
ctx.setLineCap(.round)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: color(0x003C33, 0.25))
for (index, r) in [CGFloat(225), 315].enumerated() {
    ctx.setStrokeColor(color(0xFFFFFF, index == 0 ? 1 : 0.75))
    ctx.setLineWidth(54)
    ctx.addArc(center: center, radius: r, startAngle: .pi * 0.06, endAngle: .pi * 0.44, clockwise: false)
    ctx.strokePath()
}
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
