// Draws Luma's icons: a little cat peeking over a keyboard, and its silhouette for the menu bar.
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

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2), transform: nil)
}

// MARK: The cat
//
// Drawn in a unit box (x -1...1, y up), placed at `c` and scaled by `s`: a wide oval head and two
// big upright ears. Each ear is a triangle grown outward by a round stroke of radius `earGrow`,
// which makes the ears fuller and their tips soft. `earBase` is where the outer edge of each ear
// meets the head; pulling it in keeps the grown ear from bulging past the head at large sizes.

func catHead(_ c: CGPoint, _ s: CGFloat, earGrow: CGFloat, earBase: CGPoint = CGPoint(x: 0.86, y: 0.12)) -> CGPath {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    var cat = ellipse(p(0, -0.16), s, 0.80 * s)
    for side: CGFloat in [-1, 1] {
        let ear = CGMutablePath()
        ear.addLines(between: [p(side * earBase.x, earBase.y), p(side * 0.70, 0.88), p(side * 0.18, 0.50)])
        ear.closeSubpath()
        cat = cat.union(ear.union(ear.copy(strokingWithWidth: earGrow * 2 * s, lineCap: .round, lineJoin: .round, miterLimit: 1)))
    }
    return cat
}

// MARK: App icon (drawn on a 1024 canvas, scaled for each size)
//
// The cat peeks over the top of a keyboard: only its ears, crown and eyes show above the tray.

func drawAppIcon(_ ctx: CGContext, size: CGFloat) {
    let k = size / 1024
    ctx.scaleBy(x: k, y: k)

    // macOS icon grid: an 824pt rounded square centred on the canvas, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xF4F1EC))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [rgb(0xFBF9F5), rgb(0xECE7E0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // The cat, in vermilion, behind the keyboard.
    let c = CGPoint(x: 512, y: 548), s: CGFloat = 236
    let cat = catHead(c, s, earGrow: 0.10, earBase: CGPoint(x: 0.82, y: 0.14))
    ctx.saveGState()
    ctx.addPath(cat)
    ctx.clip()
    let fur = CGGradient(colorsSpace: space, colors: [rgb(0xFF9A6E), rgb(0xE85E44)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fur, start: CGPoint(x: 512, y: 790), end: CGPoint(x: 512, y: 440), options: [])
    ctx.restoreGState()
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
    ctx.addPath(ellipse(p(-0.38, 0.03), 0.10 * s, 0.14 * s))
    ctx.addPath(ellipse(p(0.38, 0.03), 0.10 * s, 0.14 * s))
    ctx.setFillColor(rgb(0x2A2224))
    ctx.fillPath()

    // The keyboard: a soft tray, lifted off the cat by a faint shadow, two rows of keys and a space bar.
    let trayRect = CGRect(x: 184, y: 184, width: 656, height: 330)
    let tray = CGPath(roundedRect: trayRect, cornerWidth: 96, cornerHeight: 96, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: rgb(0x5A3A2A, 0.18))
    ctx.addPath(tray)
    ctx.setFillColor(rgb(0xDDD8D0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tray)
    ctx.clip()
    let trayShade = CGGradient(colorsSpace: space, colors: [rgb(0xE6E1DA), rgb(0xD6D0C8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(trayShade, start: CGPoint(x: 512, y: trayRect.maxY), end: CGPoint(x: 512, y: trayRect.minY), options: [])
    ctx.restoreGState()

    let key: CGFloat = 62, gap: CGFloat = 30
    let left = 512 - (key * 6 + gap * 5) / 2
    for row in 0..<2 {
        for col in 0..<6 {
            let r = CGRect(x: left + CGFloat(col) * (key + gap), y: 392 - CGFloat(row) * (key + 26), width: key, height: key)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 18, cornerHeight: 18, transform: nil))
        }
    }
    ctx.addPath(CGPath(roundedRect: CGRect(x: 362, y: 234, width: 300, height: 48), cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()

    // A hairline along the edge so the light icon holds its shape on a white desktop.
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(rgb(0x000000, 0.06))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

func writePNG(size: Int, to url: URL, draw: (CGContext, CGFloat) -> Void) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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

// MARK: Menu-bar template (16 x 16 pt, one solid shape so it tints cleanly)
//
// The same cat as a silhouette with round eyes knocked out.

func drawMenuIcon(_ ctx: CGContext, color: CGColor) {
    let eyes = ellipse(CGPoint(x: 5.2, y: 7.2), 0.85, 1.15).union(ellipse(CGPoint(x: 10.8, y: 7.2), 0.85, 1.15))
    ctx.addPath(catHead(CGPoint(x: 8, y: 8.2), 7.2, earGrow: 0.12).subtracting(eyes))
    ctx.setFillColor(color)
    ctx.fillPath()
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
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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
