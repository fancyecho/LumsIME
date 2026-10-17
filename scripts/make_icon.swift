// Renders the menu-bar template icon: a rounded square with a knocked-out "拼".
import AppKit

let size = NSSize(width: 16, height: 16)
final class IconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5).fill()
        ctx.setBlendMode(.destinationOut)
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let text = NSAttributedString(string: "拼", attributes: [.font: font, .foregroundColor: NSColor.black])
        let s = text.size()
        text.draw(at: NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2 + 0.3))
        ctx.endTransparencyLayer()
    }
}
let view = IconView(frame: NSRect(origin: .zero, size: size))
try! view.dataWithPDF(inside: view.bounds).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
