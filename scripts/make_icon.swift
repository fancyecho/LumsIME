// Draws Luma's line-art icons: "a line of light", concentric arcs rising over a single rule.
//   swift scripts/make_icon.swift <out-dir> [--preview]
// Writes <out-dir>/AppIcon.iconset (for iconutil) and <out-dir>/menu.pdf (menu-bar template).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let preview = CommandLine.arguments.contains("--preview")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func arc(_ ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, color: CGColor, inset: CGFloat) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.addArc(center: center, radius: radius, startAngle: inset, endAngle: .pi - inset, clockwise: false)
    ctx.strokePath()
}

func ring(_ ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat, color: CGColor, lower: Bool) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    ctx.addArc(center: center, radius: radius, startAngle: lower ? .pi : 0, endAngle: lower ? 2 * .pi : .pi, clockwise: false)
    ctx.strokePath()
}

func line(_ ctx: CGContext, y: CGFloat, from x0: CGFloat, to x1: CGFloat, width: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: x0, y: y))
    ctx.addLine(to: CGPoint(x: x1, y: y))
    ctx.strokePath()
}

// MARK: App icon (drawn on a 1024 canvas, scaled for each size)

func drawAppIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024
    ctx.scaleBy(x: k, y: k)

    // macOS icon grid: an 824pt rounded square centred on the canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x15141B))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x2A2736), rgb(0x121117)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    let horizon: CGFloat = 496
    let center = CGPoint(x: 512, y: horizon)
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFB48A, 0.30), rgb(0xFF8A6A, 0.08), rgb(0xFF8A6A, 0)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 360, options: [])

    // A ring of light cut by the rule: bright above, its reflection faint below.
    let warm: UInt32 = 0xFBF3EA
    arc(ctx, center: center, radius: 132, width: 15, color: rgb(warm, 0.96), inset: 0)
    ring(ctx, center: center, radius: 132, width: 15, color: rgb(warm, 0.20), lower: true)
    arc(ctx, center: center, radius: 226, width: 7, color: rgb(warm, 0.30), inset: 0.22)

    // The rule: vermilion, with a little bloom.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: rgb(0xFF6A4A, 0.75))
    line(ctx, y: horizon, from: 232, to: 792, width: 15, color: rgb(0xEC6A4C))
    ctx.restoreGState()

    // A hairline of light along the top edge.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

func writePNG(size: Int, to url: URL, draw: (CGContext, CGFloat) -> Void) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(ctx, CGFloat(size))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        writePNG(size: base * scale, to: iconset.appendingPathComponent(name), draw: drawAppIcon)
    }
}

// MARK: Menu-bar template (16 x 16 pt, strokes only so it tints cleanly)

func drawMenuIcon(_ ctx: CGContext, color: CGColor) {
    let center = CGPoint(x: 8, y: 6.6)
    arc(ctx, center: center, radius: 4.1, width: 1.4, color: color, inset: 0)
    ring(ctx, center: center, radius: 4.1, width: 1.2, color: color.copy(alpha: 0.42)!, lower: true)
    arc(ctx, center: center, radius: 6.9, width: 1.1, color: color.copy(alpha: 0.5)!, inset: 0.26)
    line(ctx, y: center.y, from: 1.4, to: 14.6, width: 1.4, color: color)
}

var box = CGRect(x: 0, y: 0, width: 16, height: 16)
let pdf = CGContext(out.appendingPathComponent("menu.pdf") as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil)
drawMenuIcon(pdf, color: rgb(0x000000))
pdf.endPDFPage()
pdf.closePDF()

// MARK: Preview sheet

if preview {
    writePNG(size: 1024, to: out.appendingPathComponent("preview-app.png"), draw: drawAppIcon)
    // Menu icon at 2x on light and dark menu bars, plus an 8x enlargement.
    let w = 520, h = 200
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(rgb(0xEDEBEF)); ctx.fill(CGRect(x: 0, y: 100, width: 160, height: 100))
    ctx.setFillColor(rgb(0x2B2A30)); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 160, y: 0, width: 360, height: 200))
    for (y, c) in [(134, rgb(0x000000, 0.85)), (34, rgb(0xFFFFFF, 0.9))] {
        ctx.saveGState(); ctx.translateBy(x: 64, y: CGFloat(y)); ctx.scaleBy(x: 2, y: 2)
        drawMenuIcon(ctx, color: c); ctx.restoreGState()
    }
    ctx.saveGState(); ctx.translateBy(x: 276, y: 36); ctx.scaleBy(x: 8, y: 8)
    drawMenuIcon(ctx, color: rgb(0x000000)); ctx.restoreGState()
    let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("preview-menu.png") as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}
