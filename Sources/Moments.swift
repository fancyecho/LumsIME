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

    /// 上屏光点: the light of a committed word flying from the bar into the text.
    static var landingLight: Bool {
        get { UserDefaults.standard.object(forKey: "landingLight") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "landingLight") }
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
        case .celebrate: return 1.4
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
/// Points are on the screen (y up), so landings that overlap keep their places while the window
/// they play in grows to hold them all.
struct Landing: Equatable {
    var from: CGRect
    /// Where the text ends, as best known: corrected (see `toBefore`) when the app reports its
    /// caret again once it has laid the text out.
    var to: CGPoint
    /// Where it was heading before the last correction, and when that came: the light glides over
    /// rather than jumping.
    var toBefore: CGPoint?
    var retargeted: Double = 0
    var caretHeight: CGFloat
    /// Where the committed text begins on its line, for the light to run back along it; nil when
    /// that isn't known (or the text wrapped onto another line).
    var textStart: CGFloat?
    var color: Color
    var mood: Mood?
    /// When it began, on CACurrentMediaTime's clock.
    var start: Double
    /// The light flies (上屏光点 on); otherwise only the flourish plays, at the caret.
    var flies = true

    static let flight = 0.34
    /// How long a correction of the destination takes to glide over.
    static let glide = 0.14
    /// How long a landing without a flourish takes to settle: long enough to come to rest, not to linger.
    static let settle = 0.62
    /// Room round it for the flourishes.
    static let reach: CGFloat = 120

    /// How long the whole thing plays.
    var duration: Double { Self.flight + max(Self.settle, mood?.duration ?? 0) }

    /// Where it plays, flourishes included.
    var area: CGRect {
        var caret = CGRect(x: to.x, y: to.y - caretHeight / 2, width: 1, height: caretHeight)
        if let toBefore { caret = caret.union(CGRect(x: toBefore.x, y: toBefore.y - caretHeight / 2, width: 1, height: caretHeight)) }
        if let textStart { caret = caret.union(CGRect(x: textStart, y: caret.minY, width: 1, height: caretHeight)) }
        return from.union(caret).insetBy(dx: -Self.reach, dy: -Self.reach)
    }
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
/// the light flies on. Words committed in quick succession each play to the end: a new landing
/// joins the ones still under way instead of cutting them off.
@MainActor
final class Lander {
    @MainActor @Observable final class Model {
        var landings: [Landing] = []
        /// The window's top left corner on the screen.
        var origin: CGPoint = .zero
        var now: Double = 0
    }

    private let window: NSPanel
    private let model = Model()
    private var timer: Timer?

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

    /// From `from` (the chosen word's cell) to `to` (where the text ends), on the screen. With
    /// `flies` off only the flourish plays, at once. Returns the landing's id, for `retarget`.
    @discardableResult
    func fly(from: CGRect, to: CGPoint, caretHeight: CGFloat, textStart: CGFloat?, color: Color, mood: Mood?,
             flies: Bool = true) -> Double {
        let now = CACurrentMediaTime()
        // Without its flight, the flourish starts now, where it would have after one.
        let landing = Landing(from: from, to: to, caretHeight: caretHeight, textStart: textStart, color: color, mood: mood,
                              start: flies ? now : now - Landing.flight, flies: flies)
        // A few at most: typing that fast, the oldest have done their part.
        model.landings = Array(model.landings.suffix(3)) + [landing]
        model.now = now
        fit()
        window.alphaValue = 1
        window.orderFrontRegardless()
        guard timer == nil else { return landing.start }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.timer === timer else { return timer.invalidate() }
                let now = CACurrentMediaTime()
                self.model.landings.removeAll { now - $0.start >= $0.duration }
                if self.model.landings.isEmpty { return self.stop() }
                self.model.now = now
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return landing.start
    }

    /// The app has said again where its caret is, now that it has laid the text out: the landing
    /// `id` heads there instead, gliding over from where it was going.
    func retarget(_ id: Double, to: CGPoint) {
        guard let i = model.landings.firstIndex(where: { $0.start == id }) else { return }
        let now = CACurrentMediaTime()
        var landing = model.landings[i]
        guard abs(landing.to.x - to.x) > 0.5 || abs(landing.to.y - to.y) > 0.5 else { return }
        landing.toBefore = LandingLayer.Frame.heading(landing, now: now)
        landing.to = to
        landing.retargeted = now
        model.landings[i] = landing
        fit()
    }

    /// The window over every landing under way, with room for their flourishes.
    private func fit() {
        guard let first = model.landings.first else { return }
        let area = model.landings.dropFirst().reduce(first.area) { $0.union($1.area) }.integral
        if window.frame != area {
            window.setFrame(area, display: false)
            window.contentView?.frame = NSRect(origin: .zero, size: area.size)
        }
        model.origin = CGPoint(x: area.minX, y: area.maxY)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        model.landings = []
        window.orderOut(nil)
    }

    private struct Root: View {
        let model: Model

        var body: some View {
            ZStack {
                Color.clear
                if !model.landings.isEmpty {
                    LandingLayer(landings: model.landings, origin: model.origin, now: model.now)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Draws landings over the whole canvas, frame by frame from the clock.
struct LandingLayer: View {
    let landings: [Landing]
    /// The canvas's top left corner on the screen.
    let origin: CGPoint
    let now: Double

    /// A landing on the canvas (top down) at one moment.
    struct Frame {
        let from: CGRect
        let to: CGPoint
        let height: CGFloat
        let textStart: CGFloat?
        let color: Color
        let mood: Mood?
        let flies: Bool
        /// Seconds since the word was committed.
        let t: Double

        /// Where the landing is heading at `now`, on the screen: partway from its old destination
        /// to its corrected one while it glides over.
        static func heading(_ l: Landing, now: Double) -> CGPoint {
            guard let before = l.toBefore else { return l.to }
            let k = CGFloat(smooth((now - l.retargeted) / Landing.glide))
            return CGPoint(x: before.x + (l.to.x - before.x) * k, y: before.y + (l.to.y - before.y) * k)
        }

        init(_ l: Landing, origin: CGPoint, now: Double) {
            from = CGRect(x: l.from.minX - origin.x, y: origin.y - l.from.maxY, width: l.from.width, height: l.from.height)
            let heading = Self.heading(l, now: now)
            to = CGPoint(x: heading.x - origin.x, y: origin.y - heading.y)
            flies = l.flies
            height = l.caretHeight
            textStart = l.textStart.map { $0 - origin.x }
            color = l.color
            mood = l.mood
            t = now - l.start
        }
    }

    var body: some View {
        Canvas { context, _ in
            for landing in landings {
                let f = Frame(landing, origin: origin, now: now)
                if f.flies { Self.flight(f, in: &context) }
                if let mood = f.mood {
                    let t = f.t - Landing.flight
                    if t >= 0 { Self.flourish(mood, t: t, at: f.to, height: f.height, in: &context) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Flight

    private static func flight(_ l: Frame, in context: inout GraphicsContext) {
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
        // 2. It flies, trailing a little light behind it, and slows as it comes in.
        let travel = (t - 0.07) / (Landing.flight - 0.07)
        if travel > 0 && travel < 1.08 {
            let p = smooth(min(1, travel))
            let gone = travel > 1 ? smooth((travel - 1) / 0.08) : 0
            for k in stride(from: 6, through: 0, by: -1) {
                let back = max(0, p - Double(k) * 0.045)
                let r = 4.2 - Double(k) * 0.5
                let fade = (1 - Double(k) / 7) * (1 - gone)
                bead(at: point(back), radius: r, color: l.color, strength: fade, core: k == 0, in: &context)
            }
        }
        // 3. Settling. (A laugh hops instead; see flourish.)
        let s = t - Landing.flight + 0.02
        guard s > 0, l.mood != .laugh else { return }
        // The caret takes the light: it flares, stretches a little, and lets it go slowly.
        let flare = pow(1 - smooth(s / 0.5), 1.6)
        if flare > 0.005 {
            let h = l.height * CGFloat(1 + 0.16 * flare)
            let streak = CGRect(x: l.to.x - 1, y: l.to.y - h / 2, width: 2, height: h)
            glow(Path(roundedRect: streak.insetBy(dx: -1.5, dy: -1), cornerRadius: 2), l.color, strength: 0.85 * flare, blur: 3, in: &context)
            context.fill(Path(roundedRect: streak, cornerRadius: 1), with: .color(.white.opacity(0.9 * flare)))
        }
        // A soft ring opens round it and thins away.
        let open = min(1, s / 0.55)
        let ring = 3 + 11 * ease(open)
        glow(Path(ellipseIn: CGRect(x: l.to.x - ring, y: l.to.y - ring, width: ring * 2, height: ring * 2)),
             l.color, strength: 0.55 * pow(1 - smooth(open), 2), blur: 4, in: &context)
        // With no flourish to follow, the light runs back along the word it brought, just under
        // it, and fades as it reaches the start: the word is set, and the moment closes.
        guard l.mood == nil, let textStart = l.textStart else { return }
        let width = l.to.x - textStart
        guard width > 6, width < 900 else { return }
        let run = (s - 0.05) / 0.42
        guard run > 0, run < 1.4 else { return }
        let front = l.to.x - width * CGFloat(smooth(min(1, run)))
        let tail = min(l.to.x, front + min(52, width * 0.8))
        let strength = min(1, run * 6) * (1 - smooth((run - 0.55) / 0.8))
        guard strength > 0.01, tail > front + 0.5 else { return }
        let y = l.to.y + l.height / 2 + 1.5
        var line = Path()
        line.move(to: CGPoint(x: front, y: y))
        line.addLine(to: CGPoint(x: tail, y: y))
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [l.color.opacity(0.9 * strength), l.color.opacity(0)]),
            startPoint: CGPoint(x: front, y: y), endPoint: CGPoint(x: tail, y: y))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2.5))
            layer.stroke(line, with: shading, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
        }
        context.stroke(line, with: shading, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        // Its leading point, brightest.
        bead(at: CGPoint(x: front, y: y), radius: 1.6, color: l.color, strength: strength, core: true, in: &context)
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

    /// 生日快乐: a handful of paper tossed up from the caret. The air takes it: it slows, hangs,
    /// and drifts down fluttering, each piece turning over as it tumbles (a shade darker on its back).
    private static func confetti(t: Double, from p: CGPoint, in context: inout GraphicsContext) {
        let count = 18
        let drag = 3.4, gravity = 240.0
        let terminal = gravity / drag
        for i in 0..<count {
            let r = { (k: Int) in noise(i * 11 + k) }
            let tt = max(0, t - 0.05 * r(3))
            let alpha = min(1, tt * 14) * (1 - smooth((t - 1.0) / 0.4))
            guard alpha > 0.01 else { continue }
            let angle = (-155 + 130 * r(1)) * .pi / 180
            let speed = 230 + 120 * r(2)
            // Thrown against the air: x and y with linear drag, falling toward a gentle terminal speed.
            let slowed = (1 - exp(-drag * tt)) / drag
            var x = p.x + CGFloat(cos(angle) * speed * slowed)
            let y = p.y + CGFloat(terminal * tt + (sin(angle) * speed - terminal) * slowed)
            x += CGFloat(sin(tt * (7 + 5 * r(4)) + r(5) * 6) * (2 + 3 * r(6)) * min(1, tt * 2.5))
            let color = Spectrum.color(at: Double(i) / Double(count) + 0.08, lightness: 0.72, chroma: 0.17)
            var piece = context
            piece.translateBy(x: x, y: y)
            if r(7) < 0.28 {
                // A round dot: nothing to turn over.
                let d = 2.6 + 1.2 * r(8)
                piece.fill(Path(ellipseIn: CGRect(x: -d / 2, y: -d / 2, width: d, height: d)), with: .color(color.opacity(alpha)))
                continue
            }
            piece.rotate(by: .radians(r(9) * 6 + tt * (2 + 3 * r(10)) * (r(11) > 0.5 ? 1 : -1)))
            let turn = cos(tt * (9 + 8 * r(12)) + r(13) * 6)
            let w = (3.4 + 1.6 * r(14)) * CGFloat(max(0.15, abs(turn))), h = 6 + 2.5 * r(15)
            let shape = Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 1)
            piece.fill(shape, with: .color(color.opacity(alpha)))
            if turn < 0 { piece.fill(shape, with: .color(.black.opacity(0.22 * alpha))) }
        }
    }

    /// 晚安: a crescent moon rises from the caret, two stars twinkling beside it.
    private static func moon(t: Double, above p: CGPoint, in context: inout GraphicsContext) {
        let rise = ease(min(1, t / 0.6))
        let alpha = min(1, t / 0.25) * (1 - smooth((t - 1.05) / 0.45))
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
        let alpha = min(1, t / 0.15) * (1 - smooth((t - 0.85) / 0.4))
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
            let fade = pow(1 - s, 1.6)
            context.stroke(ring, with: .color(warm.opacity(0.85 * fade)), lineWidth: 2.2 * (1 - s) + 0.4)
            glow(ring, warm, strength: 0.4 * fade, blur: 3, in: &context)
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
        let alpha = 1 - smooth((t - 0.58) / 0.17)
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
        // A blink every few seconds: the lids ease shut and open again, and now and then it blinks twice.
        let period = 4.7
        let cycle = time.truncatingRemainder(dividingBy: period)
        func lid(_ at: Double) -> Double {
            let s = (cycle - at) / 0.17
            return s > 0 && s < 1 ? sin(s * .pi) : 0
        }
        let shut = Int(time / period) % 3 == 1 ? max(lid(0), lid(0.26)) : lid(0)
        let blink = face == .calm && !thinking ? 1 - 0.88 * shut : 1
        // Every so often the right ear flicks, as if at a sound, and settles.
        let e = (time + 2.1).truncatingRemainder(dividingBy: 7.3)
        let flick = e < 0.6 ? CGFloat(sin(e / 0.42 * .pi * 2) * exp(-e * 3.2)) : 0
        let glance: CGFloat = thinking ? CGFloat(sin(time * 2.4)) * 0.8 : 0
        let eyeShift = CGPoint(x: thinking ? 1 + glance : look * 1.6, y: thinking ? -1.1 : 0)
        let earLift: CGFloat = face == .surprised ? 1.6 : 0
        return ZStack {
            CatHead(center: center, earLift: earLift, flick: flick)
                .fill(LinearGradient(colors: [Color(hex: 0xFF9A6E), Color(hex: 0xE85E44)], startPoint: .top, endPoint: .bottom))
            // Inner ears, a little lighter.
            CatInnerEars(center: center, earLift: earLift, flick: flick)
                .fill(Color(hex: 0xFFC3A6).opacity(0.55))
            // One face gives way to the next rather than snapping to it.
            ZStack {
                if face == .happy || face == .sleepy {
                    CatEyes(center: center, shift: eyeShift, face: face, blink: 1)
                        .stroke(Color(hex: 0x2A1714), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .transition(.opacity)
                } else {
                    CatEyes(center: center, shift: eyeShift, face: face, blink: blink)
                        .fill(Color(hex: 0x2A1714))
                        .transition(.opacity)
                }
            }
            .id(face)
            .animation(moving ? .easeInOut(duration: 0.22) : nil, value: face)
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
    /// The right ear's flick, -1 to 1.
    var flick: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = center
        var head = Path(ellipseIn: CGRect(x: c.x - 10.5, y: c.y - 9, width: 21, height: 18))
        for side: CGFloat in [-1, 1] {
            // A soft triangle: outer foot on the head's shoulder, tip up and out, inner foot by the crown.
            let outer = CGPoint(x: c.x + side * 9.8, y: c.y - 3.5)
            let twitch = side > 0 ? flick : 0
            let tip = CGPoint(x: c.x + side * 8.2 + twitch * 3.4, y: c.y - 16.5 - earLift + abs(twitch) * 2.6)
            let inner = CGPoint(x: c.x + side * 2.6, y: c.y - 8.6)
            var ear = Path()
            ear.move(to: outer)
            ear.addQuadCurve(to: tip, control: CGPoint(x: c.x + side * 10.2, y: c.y - 11))
            ear.addQuadCurve(to: inner, control: CGPoint(x: c.x + side * 5.6, y: c.y - 13.2 - earLift * 0.5))
            ear.closeSubpath()
            // Joined as one outline: added as a second subpath, the mirrored ear winds the other way
            // from the head and the fill drops out where they overlap, leaving a seam at its foot.
            head = head.union(ear)
        }
        return head
    }
}

private struct CatInnerEars: Shape {
    let center: CGPoint
    let earLift: CGFloat
    var flick: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = center
        var path = Path()
        for side: CGFloat in [-1, 1] {
            path.move(to: CGPoint(x: c.x + side * 8.4, y: c.y - 8.2))
            let twitch = side > 0 ? flick : 0
            path.addQuadCurve(to: CGPoint(x: c.x + side * 7.9 + twitch * 2.8, y: c.y - 13.8 - earLift + abs(twitch) * 2.2),
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
