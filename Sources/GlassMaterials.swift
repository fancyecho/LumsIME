import AppKit
import SwiftUI

/// Ink that answers to what is behind it. Whatever `content` draws becomes its shape, and each
/// point of it turns white where the glass beneath is dark and black where it is light, so the
/// text holds on any page, in either appearance, with nothing laid under it and no halo round it.
///
/// The window server does the work, a blend at a time against the live picture under the text:
/// take its brightness, turn it over, and stretch the middle until only black and white are left.
struct Ink<Content: View>: View {
    let style: LumenStyle
    /// The text, as a solid shape (`.ink`) and by its faintness (`.dim`).
    @ViewBuilder let content: (Pass) -> Content

    var body: some View {
        let pivot = style.inkPivot, gain = style.inkGain
        ZStack {
            Rectangle().fill(Color(white: style.inkShadow))
                .mask { content(.ink).blur(radius: 0.7).offset(y: 0.75) }
                .blendMode(.colorBurn)
            Rectangle().fill(Color(white: 0.5)).mask { content(.neutral) }.blendMode(.saturation)
            layer(.white, .difference)
            layer(Color(white: pivot + 0.5 / gain), .plusDarker)
            layer(Color(white: 1 - 1 / gain), .colorDodge)
            Rectangle().fill(Color(white: pivot)).mask { content(.dim) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func layer(_ color: Color, _ mode: BlendMode) -> some View {
        Rectangle().fill(color).mask { content(.ink) }.blendMode(mode)
    }
}

/// The lens that marks the current choice: a soft light behind the frosted glass where the chosen
/// word is. With 柔光 it uses dual-optics blending (silvery-blue `.screen` moonlight + goose-yellow
/// `.multiply` sunlight) so dark pages automatically glow with moonlight and light pages automatically
/// glow with warm sunlight—regardless of the Mac's system appearance.
struct Lens: View {
    let size: CGSize
    let radius: CGFloat
    let style: LumenStyle
    let motion: FlowMotion
    /// Smooth glow envelope (0...1): stays full while appearing so the lens never flashes as a
    /// plain white `.off` pill first, and drops off quickly on dismiss so WindowServer's offscreen
    /// fade-out never pops the colour.
    var glowLevel: Double = 1

    var body: some View {
        switch style.effect {
        case .off:
            lens(mode: .off)
        case .soft:
            lens(mode: .soft)
        case .flow:
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.paused)) { context in
                let hue = Spectrum.color(at: motion.time(context.date) / Spectrum.period, lightness: 0.74, chroma: 0.19)
                lens(mode: .flow(hue))
            }
        }
    }

    private enum LensMode {
        case off, soft, flow(Color)
    }

    private func lens(mode: LensMode) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let g = min(max(glowLevel, 0), 1)
        let white: Double = {
            if style.border { return 0.3 }
            switch mode {
            case .off: return 0.21
            case .soft: return 0.06
            case .flow: return 0.10
            }
        }()
        return ZStack {
            if case .soft = mode {
                // Dual-optics soft glow aligned with v0.8.1 on BOTH light and dark pages:
                // 1) Low-RGB `.colorDodge` lifts light glass (`0.855`) to radiant goose-yellow
                //    `(1.0, 0.99, 0.89)` while barely moving dark glass (`0.18 → 0.25`);
                // 2) Soft goose-yellow halo (`.multiply`) adds the airy outer edge on light glass;
                // 3) Moonlight (`.lighten`) sets dark glass to serene silvery-blue `(0.36, 0.40, 0.47)`
                //    (safely below `inkPivot = 0.58`) while having literally zero effect on light glass.
                shape.fill(style.sunLensDodge.opacity(g))
                    .padding(.horizontal, 1)
                    .blur(radius: 6)
                    .blendMode(.colorDodge)
                shape.fill(style.sunTint.opacity(0.22 * g))
                    .blur(radius: 9)
                    .blendMode(.multiply)
                shape.fill(style.moonLens.opacity(0.95 * g))
                    .padding(.horizontal, 2)
                    .blur(radius: 7)
                    .blendMode(.lighten)
            } else {
                shape.fill(Color.white.opacity(white))
                    .padding(.horizontal, 2)
                    .blur(radius: 6)
                    .blendMode(.plusLighter)
                // Held just short of full white, so on a light page the glow is soft, not a glare.
                shape.fill(Color(white: 0.94))
                    .padding(.horizontal, 2)
                    .blur(radius: 6)
                    .blendMode(.multiply)
                if case .flow(let glow) = mode {
                    shape.fill(glow.opacity(0.28 * g))
                        .blur(radius: 7)
                        .blendMode(.screen)
                }
            }
            if style.border {
                shape.strokeBorder(Color.white.opacity(0.6), lineWidth: 1).blendMode(.difference)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Subtle hover highlight under an unselected candidate when pointed at with the mouse.
struct HoverHighlight: View {
    let size: CGSize
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(Color.white.opacity(0.08)).blendMode(.plusLighter)
            shape.fill(Color(white: 0.96)).blendMode(.multiply)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// The glass, lit by its 光效 from within. The lens is the light's source: light pools in the glass
/// around it, the rim catches it only where it falls, and a little escapes past the edge nearby.
struct GlassPlate: View {
    let style: LumenStyle
    let radius: CGFloat
    let motion: FlowMotion
    /// The lens, in the plate's coordinates.
    var light: CGRect?
    /// Inside-glass glow strength (1 while showing, drops rapidly on dismiss).
    var glowLevel: Double = 1
    /// Outside-glass aura strength (zeroed on dismiss and ramped softly on appear so offscreen
    /// window fading never flashes additive halos against transparent pixels).
    var outerGlowLevel: Double = 1

    var body: some View {
        if style.effect == .flow {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.paused)) { context in
                plate(time: motion.time(context.date))
            }
        } else {
            plate(time: 0)
        }
    }

    private func plate(time: TimeInterval) -> some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let g = min(max(glowLevel, 0), 1)
        let og = min(max(outerGlowLevel, 0), 1)
        let anim: Animation? = motion.reduceMotion || !motion.shown ? nil : .spring(response: 0.55, dampingFraction: 0.9)
        let flowOrMoon = LightPool(style: s, light: light, time: time, kind: s.effect == .flow ? .flow : .moon)
            .animation(anim, value: light)
        let sun = LightPool(style: s, light: light, time: time, kind: .sun)
            .animation(anim, value: light)
        return ZStack {
            GlassBackground(style: s, radius: radius)
            if s.effect != .off && s.bloom && og > 0.005 {
                if s.effect == .soft {
                    // Outer moonlight aura via `.lighten`: blooms onto dark pages while staying
                    // strictly invisible on both pure white and light-grey pages.
                    LightPool(style: s, light: light, time: time, kind: .moon, rimOverride: s.moonAura)
                        .animation(anim, value: light)
                        .mask { shape.stroke(lineWidth: 10).blur(radius: 6) }
                        .blur(radius: 8)
                        .offset(y: 3)
                        .mask { Outside(shape: shape) }
                        .opacity(1.15 * s.glowAmount * og)
                        .blendMode(.lighten)
                    // Multiplicative goose-yellow sun-halo: visible on light pages, invisible on dark pages.
                    sun.mask { shape.stroke(lineWidth: 12).blur(radius: 7) }
                        .blur(radius: 10)
                        .offset(y: 2)
                        .mask { Outside(shape: shape) }
                        .opacity(0.28 * s.glowAmount * og)
                        .blendMode(.multiply)
                } else {
                    flowOrMoon.mask { shape.stroke(lineWidth: 10).blur(radius: 6) }
                        .blur(radius: 8)
                        .offset(y: 3)
                        .mask { Outside(shape: shape) }
                        .opacity(1.05 * s.glowAmount * og)
                        .blendMode(.plusLighter)
                }
            }
            if s.effect != .off && g > 0.005 {
                if s.effect == .soft {
                    let sunDodge = LightPool(style: s, light: light, time: time, kind: .sun, rimOverride: s.sunPoolDodge)
                        .animation(anim, value: light)
                    let moonPool = LightPool(style: s, light: light, time: time, kind: .moon, rimOverride: s.moonPool)
                        .animation(anim, value: light)
                    let moonBevel = LightPool(style: s, light: light, time: time, kind: .moon, rimOverride: s.moonBevel)
                        .animation(anim, value: light)
                    Group {
                        // 1) Light-surface goose-yellow sunlight (runs first while dark glass is still dark):
                        //    low-RGB `.colorDodge` lifts light glass to radiant cream-yellow without darkening,
                        //    then `.multiply` adds delicate pale-yellow saturation.
                        if s.bloom {
                            sunDodge.clipShape(shape)
                                .opacity(0.65 * g)
                                .blendMode(.colorDodge)
                            sun.clipShape(shape)
                                .opacity(0.18 * s.glowAmount * g)
                                .blendMode(.multiply)
                            sunDodge.mask { shape.strokeBorder(lineWidth: 6).blur(radius: 4) }
                                .clipShape(shape)
                                .opacity(0.75 * g)
                                .blendMode(.colorDodge)
                            sun.mask { shape.strokeBorder(lineWidth: 6).blur(radius: 4) }
                                .clipShape(shape)
                                .opacity(0.32 * s.glowAmount * g)
                                .blendMode(.multiply)
                        }
                        LightPool(style: s, light: light, time: time, kind: .sun, rimOverride: s.sunRimDodge)
                            .animation(anim, value: light)
                            .mask { shape.strokeBorder(lineWidth: 1.4) }
                            .opacity(0.85 * g)
                            .blendMode(.colorDodge)
                        LightPool(style: s, light: light, time: time, kind: .sun, rimOverride: s.sunRim)
                            .animation(anim, value: light)
                            .mask { shape.strokeBorder(lineWidth: 1.4) }
                            .opacity(0.48 * g)
                            .blendMode(.multiply)

                        // 2) Dark-surface silvery-blue moonlight via `.lighten`:
                        //    lights dark glass cleanly and leaves sunlit glass completely untouched.
                        if s.bloom {
                            moonPool.clipShape(shape)
                                .opacity(0.60 * g)
                                .blendMode(.lighten)
                            moonBevel.mask { shape.strokeBorder(lineWidth: 7).blur(radius: 4) }
                                .clipShape(shape)
                                .opacity(0.78 * g)
                                .blendMode(.lighten)
                        }
                        LightPool(style: s, light: light, time: time, kind: .moon, rimOverride: s.moonRim)
                            .animation(anim, value: light)
                            .mask { shape.strokeBorder(lineWidth: 1.5) }
                            .opacity(0.88 * g)
                            .blendMode(.lighten)
                    }
                } else {
                    Group {
                        if s.bloom {
                            flowOrMoon.clipShape(shape)
                                .opacity(0.36 * s.glowAmount * g)
                                .blendMode(.screen)
                            flowOrMoon.mask { shape.strokeBorder(lineWidth: 7).blur(radius: 4) }
                                .clipShape(shape)
                                .opacity(1.0 * s.glowAmount * g)
                                .blendMode(.screen)
                        }
                        flowOrMoon.mask { shape.strokeBorder(lineWidth: 1.5) }
                            .opacity(0.95 * g)
                            .blendMode(.screen)
                    }
                }
            }
        }
    }
}

/// Everything around `shape`, out to `reach` beyond it (by default the panel's whole margin): a
/// mask for what must fall only outside.
struct Outside: View {
    let shape: RoundedRectangle
    var reach = CandidatePanel.margin

    var body: some View {
        ZStack {
            Rectangle().padding(-reach)
            shape.blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// Soft pools of light in the glass: one around the lens, and for 流光 two more in the hues to
/// come, drifting slowly through the glass like an aurora.
struct LightPool: View {
    enum Kind { case flow, moon, sun }

    let style: LumenStyle
    let light: CGRect?
    let time: TimeInterval
    var kind: Kind = .flow
    var rimOverride: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let isTall = size.height > size.width * 1.1
            let lens = light ?? CGRect(x: size.width * 0.15, y: 0, width: min(80, size.width * 0.3), height: min(36, size.height))
            let source = CGPoint(x: lens.midX, y: lens.midY + (isTall ? 0 : lens.height * 0.15))
            let turn = time / Spectrum.period
            let minor = min(size.width, size.height)
            let reach = max(min(lens.width, 110) * 0.85, min(60, minor * 0.95))
            ZStack {
                switch kind {
                case .flow:
                    ForEach(max(size.width, size.height) > 120 ? 1..<3 : 1..<1, id: \.self) { k in
                        let drift = time * 2 * .pi
                        let at = CGPoint(x: size.width * (0.5 + 0.42 * sin(drift / (17 + 5 * Double(k)) + 2.4 * Double(k))),
                                         y: size.height * (0.5 + 0.34 * cos(drift / (13 + 4 * Double(k)) + Double(k))))
                        glow(Spectrum.color(at: turn + Double(k) / 3, lightness: 0.74, chroma: 0.19), at: at,
                             radius: minor * 1.15, strength: 0.72, tall: isTall)
                    }
                    glow(Spectrum.color(at: turn, lightness: 0.74, chroma: 0.19), at: source, radius: reach, strength: 1, tall: isTall)
                case .moon:
                    glow(rimOverride ?? style.moonTint, at: source, radius: reach * 1.15, strength: 1, tall: isTall)
                    if rimOverride == nil {
                        glow(style.moonAura, at: source, radius: reach * 1.6, strength: 0.28, tall: isTall)
                    }
                case .sun:
                    glow(rimOverride ?? style.sunTint, at: source, radius: reach * 1.15, strength: 1, tall: isTall)
                    if rimOverride == nil {
                        glow(style.sunAura, at: source, radius: reach * 1.6, strength: 0.48, tall: isTall)
                    }
                }
            }
        }
    }

    private func glow(_ color: Color, at point: CGPoint, radius: CGFloat, strength: Double, tall: Bool) -> some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: color.opacity(strength), location: 0),
                                         .init(color: color.opacity(strength * 0.4), location: 0.45),
                                         .init(color: color.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(x: tall ? 1.15 : 1.6, y: tall ? 1.45 : 1)
            .position(point)
    }
}

/// The plate: clear glass that takes its tone from the page, not from the system's appearance.
struct GlassBackground: View {
    let style: LumenStyle
    let radius: CGFloat

    var body: some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if s.solid {
                shape.fill(s.dark ? Color(white: 0.13) : Color(white: 0.97))
            } else if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(.clear, in: shape)
                    .environment(\.colorScheme, .dark)
                ForEach(Array(s.tone.enumerated()), id: \.offset) { _, step in
                    shape.fill(Color(white: step.level)).blendMode(step.mode)
                }
            } else {
                VisualEffectBackground().clipShape(shape)
            }
            shape.fill(Color.black.opacity(0.16))
                .blur(radius: 14)
                .offset(y: 7)
                .mask { Outside(shape: shape) }
            if s.border {
                shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1).blendMode(.difference)
            } else {
                shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.09 * s.shine), location: 0),
                                                  .init(color: .white.opacity(0), location: 0.45)],
                                          startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
                shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.5 * s.shine), location: 0),
                                                          .init(color: .white.opacity(0.08 * s.shine), location: 0.4),
                                                          .init(color: .white.opacity(0.05 * s.shine), location: 0.62),
                                                          .init(color: .white.opacity(0.2 * s.shine), location: 1)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    .blendMode(.plusLighter)
                shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5).blendMode(.difference)
            }
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
