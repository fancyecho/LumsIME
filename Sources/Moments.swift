import AppKit
import SwiftUI

// The panel's small moments: the light of a chosen word landing in the text, a flourish when
// what was written carries a feeling, and the cat that keeps an eye on the candidates.

extension LumaSettings {
    /// The cat peeking up from the end of the bar. `--cat off` hides it (for screenshots).
    static var companion: Bool {
        get {
            if let arg = argument("--cat") { return arg != "off" }
            return UserDefaults.standard.object(forKey: "companion") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "companion") }
    }

    /// 彩蛋: a flourish at the caret when what was committed carries a feeling (生日快乐, 晚安…).
    static var moments: Bool {
        get { UserDefaults.standard.object(forKey: "moments") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "moments") }
    }
}

/// A feeling in what was committed, and the flourish it gets at the caret.
enum Mood: String, CaseIterable {
    case celebrate, goodnight, love, cheer, laugh, thanks

    /// The first feeling `text` carries, in this order of precedence.
    static func of(_ text: String) -> Mood? {
        allCases.first { mood in mood.cues.contains { text.contains($0) } }
    }

    private var cues: [String] {
        switch self {
        case .celebrate: return ["生日快乐", "新年快乐", "节日快乐", "圣诞快乐", "中秋快乐", "恭喜", "祝贺", "🎉"]
        case .goodnight: return ["晚安", "好梦", "睡了"]
        case .love: return ["爱你", "喜欢你", "想你", "么么哒", "亲亲", "❤️"]
        case .cheer: return ["加油", "冲鸭", "你可以的", "必胜"]
        case .laugh: return ["哈哈哈", "笑死", "嘿嘿嘿", "😂"]
        case .thanks: return ["谢谢", "感谢", "多谢", "辛苦了"]
        }
    }

    /// How long its flourish plays after the light has landed, in seconds.
    var duration: Double {
        switch self {
        case .celebrate: return 1.15
        case .goodnight: return 1.5
        case .love: return 1.25
        case .cheer: return 0.8
        case .laugh: return 0.75
        case .thanks: return 0.85
        }
    }
}

/// Each flourish plays at most once a day, so it stays a surprise rather than a routine.
/// `--moments always` plays every one (for the playground and screenshots).
enum MomentMemory {
    private static let key = "moments.played"

    static func mayPlay(_ mood: Mood) -> Bool {
        if LumaSettings.argument("--moments") == "always" { return true }
        let defaults = UserDefaults.standard
        var played = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        guard played[mood.rawValue] != today else { return false }
        played[mood.rawValue] = today
        defaults.set(played, forKey: key)
        return true
    }
}

/// The light of a chosen word on its way into the text: it gathers where the word sat in the bar,
/// arcs over to the caret and settles into it, then plays the word's flourish if it has one.
/// Points are in the panel's own canvas (top left at zero).
struct Landing: Equatable {
    var from: CGRect
    var to: CGPoint
    var caretHeight: CGFloat
    var color: Color
    var mood: Mood?
    /// Seconds since the word was committed.
    var t: Double = 0

    static let flight = 0.34
    static let settle = 0.2

    /// How long the whole thing plays.
    var duration: Double { Self.flight + max(Self.settle, mood?.duration ?? 0) }
}

/// The cat's look, read from the word being typed.
enum CatFace: Equatable {
    case calm, happy, sleepy, surprised

    static func of(_ text: String) -> CatFace {
        if ["晚安", "好梦", "困", "睡", "累"].contains(where: text.contains) { return .sleepy }
        if ["哈哈", "嘿嘿", "开心", "太好了", "好耶", "真棒", "太棒", "喜欢", "爱你", "快乐"].contains(where: text.contains) { return .happy }
        if ["天哪", "天啊", "卧槽", "我靠", "震惊", "居然", "竟然", "不会吧"].contains(where: text.contains) { return .surprised }
        return .calm
    }
}

// MARK: - The landing and its flourishes

/// Plays landings in a window of their own, above the candidates and letting every click through.
/// Kept apart from the panel so the panel can fade as it always has (by the window's alpha, its
/// text never put in a group that would cut it off from the page it reads its ink from) while
/// the light flies on.
@MainActor
final class Lander {
    @MainActor @Observable final class Model {
        var landing: Landing?
    }

    private let window: NSPanel
    private let model = Model()
    private var timer: Timer?
    /// Room round the flight for the flourishes.
    private static let reach: CGFloat = 120

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        let host = NSHostingView(rootView: Root(model: model))
        host.sizingOptions = []
        window.contentView = host
    }

    /// From `from` (the chosen word's cell) to `to` (where the text ends), in screen coordinates.
    func fly(from: CGRect, to: CGPoint, caretHeight: CGFloat, color: Color, mood: Mood?) {
        let caret = CGRect(x: to.x, y: to.y - caretHeight / 2, width: 1, height: caretHeight)
        let area = from.union(caret).insetBy(dx: -Self.reach, dy: -Self.reach).integral
        window.setFrame(area, display: false)
        window.contentView?.frame = NSRect(origin: .zero, size: area.size)
        // The canvas runs top down.
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - area.minX, y: area.maxY - p.y) }
        let landing = Landing(from: CGRect(origin: local(CGPoint(x: from.minX, y: from.maxY)), size: from.size),
                              to: local(to), caretHeight: caretHeight, color: color, mood: mood)
        model.landing = landing
        window.alphaValue = 1
        window.orderFrontRegardless()
        timer?.invalidate()
        let start = CACurrentMediaTime()
        let duration = landing.duration
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.timer === timer else { return timer.invalidate() }
                let t = CACurrentMediaTime() - start
                if t >= duration { return self.stop() }
                self.model.landing?.t = t
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        model.landing = nil
        window.orderOut(nil)
    }

    private struct Root: View {
        let model: Model

        var body: some View {
            ZStack {
                Color.clear
                if let landing = model.landing { LandingLayer(landing: landing) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Draws a landing over the whole canvas, frame by frame from `landing.t`.
struct LandingLayer: View {
    let landing: Landing

    var body: some View {
        Canvas { context, _ in
            let l = landing
            Self.flight(l, in: &context)
            if let mood = l.mood {
                let t = l.t - Landing.flight
                if t >= 0 { Self.flourish(mood, t: t, at: l.to, height: l.caretHeight, in: &context) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Flight

    private static func flight(_ l: Landing, in context: inout GraphicsContext) {
        let start = CGPoint(x: l.from.midX, y: l.from.midY)
        // Over the top: an arc that lifts off the bar and comes down into the caret.
        let control = CGPoint(x: (start.x + l.to.x) / 2, y: min(start.y, l.to.y) - 26)
        func point(_ p: Double) -> CGPoint {
            let p = CGFloat(p), q = 1 - p
            return CGPoint(x: q * q * start.x + 2 * q * p * control.x + p * p * l.to.x,
                           y: q * q * start.y + 2 * q * p * control.y + p * p * l.to.y)
        }
        let t = l.t
        // 1. The lens's light gathers itself into a bead where the word was.
        let gather = min(1, t / 0.11)
        if gather < 1 {
            let w = l.from.width + (9 - l.from.width) * ease(gather)
            let h = l.from.height + (9 - l.from.height) * ease(gather)
            let rect = CGRect(x: start.x - w / 2, y: start.y - h / 2, width: w, height: h)
            glow(Path(roundedRect: rect, cornerRadius: min(w, h) / 2), l.color, strength: 0.35 + 0.5 * gather, blur: 5, in: &context)
        }
        // 2. It flies, trailing a little light behind it.
        let travel = (t - 0.07) / (Landing.flight - 0.07)
        if travel > 0 && travel < 1.05 {
            let p = smooth(min(1, travel))
            for k in stride(from: 6, through: 0, by: -1) {
                let back = max(0, p - Double(k) * 0.045)
                let r = 4.2 - Double(k) * 0.5
                let fade = (1 - Double(k) / 7) * (travel > 1 ? max(0, 1 - (travel - 1) * 20) : 1)
                bead(at: point(back), radius: r, color: l.color, strength: fade, core: k == 0, in: &context)
            }
        }
        // 3. Settling: the caret takes the light for a moment, and a soft ring opens round it.
        // (A laugh hops instead; see flourish.)
        let landed = t - Landing.flight + 0.02
        if landed > 0, l.mood != .laugh {
            let s = min(1, landed / Landing.settle)
            let ring = 3 + 9 * ease(s)
            glow(Path(ellipseIn: CGRect(x: l.to.x - ring, y: l.to.y - ring, width: ring * 2, height: ring * 2)),
                 l.color, strength: 0.7 * (1 - s), blur: 4, in: &context)
            let streak = CGRect(x: l.to.x - 1, y: l.to.y - l.caretHeight / 2, width: 2, height: l.caretHeight)
            context.fill(Path(roundedRect: streak, cornerRadius: 1), with: .color(.white.opacity(0.9 * (1 - s))))
            glow(Path(roundedRect: streak.insetBy(dx: -1.5, dy: -1), cornerRadius: 2), l.color, strength: 0.8 * (1 - s), blur: 3, in: &context)
        }
    }

    // MARK: Flourishes

    private static func flourish(_ mood: Mood, t: Double, at p: CGPoint, height: CGFloat, in context: inout GraphicsContext) {
        let top = CGPoint(x: p.x, y: p.y - height / 2)
        switch mood {
        case .celebrate: confetti(t: t, from: top, in: &context)
        case .goodnight: moon(t: t, above: top, in: &context)
        case .love: heart(t: t, above: top, in: &context)
        case .cheer: pulse(t: t, at: p, in: &context)
        case .laugh: hops(t: t, at: p, in: &context)
        case .thanks: sparkles(t: t, around: top, in: &context)
        }
    }

    /// 生日快乐: a handful of paper pieces tossed up from the caret, tumbling back down.
    private static func confetti(t: Double, from p: CGPoint, in context: inout GraphicsContext) {
        let count = 16
        for i in 0..<count {
            let r = { (k: Int) in noise(i * 7 + k) }
            let angle = (-150 + 120 * r(1)) * .pi / 180
            let speed = 110 + 90 * r(2)
            let delay = 0.04 * r(3)
            let tt = max(0, t - delay)
            let x = p.x + CGFloat(cos(angle) * speed * tt)
            let y = p.y + CGFloat(sin(angle) * speed * tt + 0.5 * 360 * tt * tt)
            let fade = max(0, min(1, (1.15 - t) / 0.35)) * min(1, tt * 12)
            var piece = context
            piece.translateBy(x: x, y: y)
            piece.rotate(by: .radians(r(4) * 6 + tt * (6 + 10 * r(5)) * (r(6) > 0.5 ? 1 : -1)))
            let w = 3.2 + 1.6 * r(7), h = 5.5 + 2.5 * r(8)
            let color = Spectrum.color(at: Double(i) / Double(count) + 0.08, lightness: 0.72, chroma: 0.17)
            piece.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 1),
                       with: .color(color.opacity(fade)))
        }
    }

    /// 晚安: a crescent moon rises from the caret, two stars twinkling beside it.
    private static func moon(t: Double, above p: CGPoint, in context: inout GraphicsContext) {
        let rise = ease(min(1, t / 0.6))
        let alpha = min(1, t / 0.25) * max(0, min(1, (1.5 - t) / 0.45))
        let c = CGPoint(x: p.x + 6, y: p.y - 6 - 14 * rise)
        let r: CGFloat = 8.5
        let disc = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
        let bite = CGPath(ellipseIn: CGRect(x: c.x - r + 5, y: c.y - r - 2.8, width: r * 2, height: r * 2), transform: nil)
        let crescent = Path(disc.subtracting(bite))
        let gold = Color(hex: 0xFFD36E)
        glow(crescent, gold, strength: 0.6 * alpha, blur: 5, in: &context)
        context.fill(crescent, with: .color(gold.opacity(alpha)))
        context.stroke(crescent, with: .color(Color(hex: 0xC7922E).opacity(0.5 * alpha)), lineWidth: 0.5)
        for (k, offset) in [(0, CGPoint(x: 14, y: -6)), (1, CGPoint(x: -8, y: -12))].map({ ($0.0, $0.1) }) {
            let twinkle = 0.5 + 0.5 * sin((t * 9 + Double(k) * 2.2))
            star(at: CGPoint(x: c.x + offset.x, y: c.y + offset.y), size: 2.6 + 1.2 * twinkle, color: gold,
                 alpha: alpha * (0.45 + 0.55 * twinkle), in: &context)
        }
    }

    /// 爱你: a heart floats up, beats once and fades.
    private static func heart(t: Double, above p: CGPoint, in context: inout GraphicsContext) {
        let rise = ease(min(1, t / 1.1))
        let alpha = min(1, t / 0.15) * max(0, min(1, (1.25 - t) / 0.4))
        let beat = 1 + 0.28 * exp(-pow((t - 0.32) / 0.07, 2))
        let c = CGPoint(x: p.x + 4 + 3 * sin(t * 6), y: p.y - 4 - 24 * rise)
        let size = 13.5 * beat
        let path = heartPath(center: c, size: size)
        let rose = Color(hex: 0xFF4F78)
        glow(path, rose, strength: 0.5 * alpha, blur: 4, in: &context)
        context.fill(path, with: .color(rose.opacity(alpha)))
        // A glint on its shoulder.
        context.fill(Path(ellipseIn: CGRect(x: c.x - size * 0.3, y: c.y - size * 0.28, width: size * 0.18, height: size * 0.13)),
                     with: .color(.white.opacity(0.7 * alpha)))
    }

    /// 加油: the caret's light beats outward twice, warm, like a pulse.
    private static func pulse(t: Double, at p: CGPoint, in context: inout GraphicsContext) {
        let warm = Color(hex: 0xFF8A3D)
        for k in 0..<2 {
            let s = (t - Double(k) * 0.22) / 0.55
            guard s > 0, s < 1 else { continue }
            let r = 4 + 18 * ease(s)
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(warm.opacity(0.85 * (1 - s))), lineWidth: 2.2 * (1 - s) + 0.4)
            glow(ring, warm, strength: 0.4 * (1 - s), blur: 3, in: &context)
        }
    }

    /// 哈哈哈: the light, landed, can't keep still: three little hops, each smaller.
    private static func hops(t: Double, at p: CGPoint, in context: inout GraphicsContext) {
        let color = Color(hex: 0xFFB020)
        let lengths = [0.24, 0.2, 0.17]
        let heights: [CGFloat] = [17, 10, 5]
        var start = 0.0, y: CGFloat = 0
        for (k, d) in lengths.enumerated() where t >= start {
            let s = min(1, (t - start) / d)
            y = -heights[k] * CGFloat(4 * s * (1 - s))
            start += d
        }
        let alpha = max(0, min(1, (0.75 - t) / 0.15))
        // Squashed a little as it touches down.
        let squash: CGFloat = y > -1.5 ? 1.25 : 1
        let r: CGFloat = 4.2
        let rect = CGRect(x: p.x - r * squash, y: p.y + y - r / squash, width: r * 2 * squash, height: r * 2 / squash)
        glow(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), color, strength: 0.6 * alpha, blur: 3, in: &context)
        context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
        context.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.55, dy: r * 0.55).offsetBy(dx: -0.8, dy: -0.8)),
                     with: .color(.white.opacity(0.8 * alpha)))
    }

    /// 谢谢: three small sparkles pop round the caret, one after another.
    private static func sparkles(t: Double, around p: CGPoint, in context: inout GraphicsContext) {
        let gold = Color(hex: 0xFFC53D)
        let places = [CGPoint(x: 9, y: -4), CGPoint(x: -6, y: -10), CGPoint(x: 15, y: -15)]
        for (k, offset) in places.enumerated() {
            let s = (t - Double(k) * 0.12) / 0.45
            guard s > 0, s < 1 else { continue }
            let size = 5.5 * CGFloat(sin(s * .pi))
            star(at: CGPoint(x: p.x + offset.x, y: p.y + offset.y), size: size, color: gold, alpha: 1, in: &context)
        }
    }

    // MARK: Drawing

    private static func bead(at p: CGPoint, radius r: Double, color: Color, strength: Double, core: Bool,
                             in context: inout GraphicsContext) {
        let r = CGFloat(max(0.6, r))
        glow(Path(ellipseIn: CGRect(x: p.x - r * 1.8, y: p.y - r * 1.8, width: r * 3.6, height: r * 3.6)), color,
             strength: 0.55 * strength, blur: 3.5, in: &context)
        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(0.9 * strength)))
        if core {
            let c = r * 0.5
            context.fill(Path(ellipseIn: CGRect(x: p.x - c, y: p.y - c, width: c * 2, height: c * 2)),
                         with: .color(.white.opacity(0.95 * strength)))
        }
    }

    /// `path` in `color`, softened into a glow.
    private static func glow(_ path: Path, _ color: Color, strength: Double, blur: CGFloat, in context: inout GraphicsContext) {
        guard strength > 0.01 else { return }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: blur))
            layer.fill(path, with: .color(color.opacity(min(1, strength))))
        }
    }

    /// A four-pointed sparkle.
    private static func star(at c: CGPoint, size: CGFloat, color: Color, alpha: Double, in context: inout GraphicsContext) {
        guard size > 0.3, alpha > 0.01 else { return }
        var path = Path()
        let w = size * 0.28
        path.move(to: CGPoint(x: c.x, y: c.y - size))
        path.addQuadCurve(to: CGPoint(x: c.x + size, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + size), control: CGPoint(x: c.x + w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x - size, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - size), control: CGPoint(x: c.x - w, y: c.y - w))
        glow(path, color, strength: 0.6 * alpha, blur: 2.5, in: &context)
        context.fill(path, with: .color(color.opacity(alpha)))
    }

    private static func heartPath(center c: CGPoint, size s: CGFloat) -> Path {
        var path = Path()
        let top = c.y - s * 0.22
        path.move(to: CGPoint(x: c.x, y: c.y + s * 0.5))
        path.addCurve(to: CGPoint(x: c.x - s * 0.5, y: top),
                      control1: CGPoint(x: c.x - s * 0.1, y: c.y + s * 0.3), control2: CGPoint(x: c.x - s * 0.5, y: c.y + s * 0.1))
        path.addArc(center: CGPoint(x: c.x - s * 0.25, y: top), radius: s * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addArc(center: CGPoint(x: c.x + s * 0.25, y: top), radius: s * 0.25, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.5),
                      control1: CGPoint(x: c.x + s * 0.5, y: c.y + s * 0.1), control2: CGPoint(x: c.x + s * 0.1, y: c.y + s * 0.3))
        path.closeSubpath()
        return path
    }

    /// A steady pseudo-random number in 0..<1 for `seed`, so each piece of confetti keeps its own path.
    private static func noise(_ seed: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 1013904223)
        x ^= x >> 13; x = x &* 0x5bd1e995; x ^= x >> 15
        return Double(x % 10_000) / 10_000
    }
}

private func ease(_ t: Double) -> CGFloat { CGFloat(1 - pow(1 - min(max(t, 0), 1), 3)) }
private func smooth(_ t: Double) -> Double { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }

// MARK: - The cat

/// Luma's cat, as on the icon, peeking up from behind the bottom edge of the bar: only its ears,
/// crown and eyes show. Its eyes follow the chosen word, it blinks now and then, looks up while AI
/// assist thinks, and its face follows the word being typed.
struct CatView: View {
    /// Where the chosen word is, -1 (far to its left) to 0 (right by it).
    let look: CGFloat
    let face: CatFace
    let thinking: Bool
    /// 0 hidden behind the edge, 1 fully up.
    let rise: CGFloat
    /// Blinking and the thinking glance are allowed to move.
    let moving: Bool
    let accent: Color

    static let size = CGSize(width: 30, height: 38)
    /// The drawing's scale: the shapes below are laid out for a head 21 points wide.
    private static let scale: CGFloat = 1.18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moving)) { context in
            cat(time: moving ? context.date.timeIntervalSinceReferenceDate : 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cat(time: TimeInterval) -> some View {
        let w = Self.size.width, h = Self.size.height
        // The head's middle sits just above the bar's bottom edge, so its eyes and crown show and
        // the rest is behind the edge, as on the icon.
        let center = CGPoint(x: w / 2, y: h - 1)
        // A blink every few seconds, never in step with a fixed beat.
        let cycle = time.truncatingRemainder(dividingBy: 4.7)
        let blink = face == .calm && !thinking && cycle < 0.13 ? 0.12 : 1.0
        let glance: CGFloat = thinking ? CGFloat(sin(time * 2.4)) * 0.8 : 0
        let eyeShift = CGPoint(x: thinking ? 1 + glance : look * 1.6, y: thinking ? -1.1 : 0)
        let earLift: CGFloat = face == .surprised ? 1.6 : 0
        return ZStack {
            CatHead(center: center, earLift: earLift)
                .fill(LinearGradient(colors: [Color(hex: 0xFF9A6E), Color(hex: 0xE85E44)], startPoint: .top, endPoint: .bottom))
            // Inner ears, a little lighter.
            CatInnerEars(center: center, earLift: earLift)
                .fill(Color(hex: 0xFFC3A6).opacity(0.55))
            if face == .happy || face == .sleepy {
                CatEyes(center: center, shift: eyeShift, face: face, blink: 1)
                    .stroke(Color(hex: 0x2A1714), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            } else {
                CatEyes(center: center, shift: eyeShift, face: face, blink: blink)
                    .fill(Color(hex: 0x2A1714))
            }
        }
        .scaleEffect(Self.scale, anchor: UnitPoint(x: center.x / w, y: center.y / h))
        .overlay {
            if face == .sleepy && moving {
                let drift = time.truncatingRemainder(dividingBy: 2.2) / 2.2
                Text("z")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0xF07050).opacity(sin(drift * .pi)))
                    .position(x: w - 3, y: 7 - 5 * drift)
            }
            if thinking {
                // Pale above and deep below, so it shows on dark glass as well as light.
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xC4CFFF), accent], startPoint: .top, endPoint: .bottom))
                    .shadow(color: accent.opacity(0.8), radius: 2)
                    .opacity(0.6 + 0.4 * sin(time * 4))
                    .position(x: w - 3, y: 6)
            }
        }
        .offset(y: (1 - rise) * (h - 4))
    }
}

private struct CatHead: Shape {
    let center: CGPoint
    let earLift: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = center
        var path = Path(ellipseIn: CGRect(x: c.x - 10.5, y: c.y - 9, width: 21, height: 18))
        for side: CGFloat in [-1, 1] {
            // A soft triangle: outer foot on the head's shoulder, tip up and out, inner foot by the crown.
            let outer = CGPoint(x: c.x + side * 9.8, y: c.y - 3.5)
            let tip = CGPoint(x: c.x + side * 8.2, y: c.y - 16.5 - earLift)
            let inner = CGPoint(x: c.x + side * 2.6, y: c.y - 8.6)
            path.move(to: outer)
            path.addQuadCurve(to: tip, control: CGPoint(x: c.x + side * 10.2, y: c.y - 11))
            path.addQuadCurve(to: inner, control: CGPoint(x: c.x + side * 5.6, y: c.y - 13.2 - earLift * 0.5))
            path.closeSubpath()
        }
        return path
    }
}

private struct CatInnerEars: Shape {
    let center: CGPoint
    let earLift: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = center
        var path = Path()
        for side: CGFloat in [-1, 1] {
            path.move(to: CGPoint(x: c.x + side * 8.4, y: c.y - 8.2))
            path.addQuadCurve(to: CGPoint(x: c.x + side * 7.9, y: c.y - 13.8 - earLift),
                              control: CGPoint(x: c.x + side * 8.9, y: c.y - 11))
            path.addQuadCurve(to: CGPoint(x: c.x + side * 4.6, y: c.y - 9.6),
                              control: CGPoint(x: c.x + side * 6, y: c.y - 11.8 - earLift * 0.5))
            path.closeSubpath()
        }
        return path
    }
}

/// The eyes: ovals (squeezed shut to blink), wide for surprise, and as lines (stroked) for a smile
/// (^ ^) or sleep (– –); those faces fill nothing.
private struct CatEyes: Shape {
    let center: CGPoint
    let shift: CGPoint
    let face: CatFace
    let blink: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for side: CGFloat in [-1, 1] {
            let e = CGPoint(x: center.x + side * 4.3 + shift.x, y: center.y - 4.3 + shift.y)
            switch face {
            case .calm, .surprised:
                let w: CGFloat = face == .surprised ? 3.4 : 2.7
                let h: CGFloat = (face == .surprised ? 3.8 : 3.3) * CGFloat(blink)
                path.addEllipse(in: CGRect(x: e.x - w / 2, y: e.y - h / 2, width: w, height: h))
            case .happy:
                path.move(to: CGPoint(x: e.x - 1.7, y: e.y + 0.7))
                path.addQuadCurve(to: CGPoint(x: e.x + 1.7, y: e.y + 0.7), control: CGPoint(x: e.x, y: e.y - 2))
            case .sleepy:
                path.move(to: CGPoint(x: e.x - 1.6, y: e.y + 0.3))
                path.addQuadCurve(to: CGPoint(x: e.x + 1.6, y: e.y + 0.3), control: CGPoint(x: e.x, y: e.y + 1.3))
            }
        }
        return path
    }
}
