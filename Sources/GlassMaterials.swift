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
            // A shadow that knows when it is wanted: it burns the glass darker close round the
            // text, which does nothing to white, little to a pale page and a lot to a middling
            // one. So black ink on a white page stays clean, and wherever the glass is neither
            // dark nor light (a photo, a coloured bar) the ink still has an edge to stand on.
            // It lies under the ink on purpose: where the glass is middling the ink reads its
            // own shadow, finds it dark, and settles on white, instead of hovering between.
            Rectangle().fill(Color(white: style.inkShadow))
                .mask { content(.ink).blur(radius: 0.7).offset(y: 0.75) }
                .blendMode(.colorBurn)
            // Brightness only: over a coloured page the ink stays neutral.
            Rectangle().fill(Color(white: 0.5)).mask { content(.neutral) }.blendMode(.saturation)
            // Turned over: dark behind gives light ink.
            layer(.white, .difference)
            // Less the pivot, times the gain: everything darker than the pivot goes to white ink,
            // everything lighter to black, with a short ramp between.
            layer(Color(white: pivot + 0.5 / gain), .plusDarker)
            layer(Color(white: 1 - 1 / gain), .colorDodge)
            // Fainter text (labels, the unchosen) is drawn back toward the middle.
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
/// word is. With a 光效 it is the light's source: it takes 柔光's tint, or the hue 流光 is passing
/// through. Like the ink, it is made of blends rather than paint, so it shows on any page.
struct Lens: View {
    let size: CGSize
    let radius: CGFloat
    let style: LumenStyle
    let motion: FlowMotion

    var body: some View {
        switch style.effect {
        case .off: lens(glow: nil)
        case .soft: lens(glow: style.tint)
        case .flow:
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.paused)) { context in
                lens(glow: Spectrum.color(at: motion.time(context.date) / Spectrum.period, lightness: 0.74, chroma: 0.19))
            }
        }
    }

    /// No drop and no edge, only light fading out all round: a shape with an outline here reads as
    /// a box inside a box.
    private func lens(glow: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Hold the white base back when a 光效 supplies coloured light, so dark glass stays well
        // below the ink's turning point and the chosen word stays crisp white.
        let white = style.border ? 0.3 : (glow == nil ? 0.21 : 0.10)
        return ZStack {
            shape.fill(Color.white.opacity(white))
                .padding(.horizontal, 2)
                .blur(radius: 6)
                .blendMode(.plusLighter)
            // Held just short of full white, so on a light page the glow is soft, not a glare.
            shape.fill(Color(white: 0.94))
                .padding(.horizontal, 2)
                .blur(radius: 6)
                .blendMode(.multiply)
            if let glow {
                // The 光效's colour in the light: added as light rather than pigment, so it blooms
                // richly on dark glass and naturally yields to clean neutral glass on a light page.
                shape.fill(glow.opacity(0.28)).blur(radius: 7).blendMode(.screen)
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
/// The light drifts after the lens as it moves; it doesn't flare with keystrokes, so it stays steady.
struct GlassPlate: View {
    let style: LumenStyle
    let radius: CGFloat
    let motion: FlowMotion
    /// The lens, in the plate's coordinates.
    var light: CGRect?

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
        let pool = LightPool(style: s, light: light, time: time)
            .animation(motion.reduceMotion || !motion.shown ? nil : .spring(response: 0.55, dampingFraction: 0.9), value: light)
        return ZStack {
            GlassBackground(style: s, radius: radius)
            if s.effect != .off && s.bloom {
                // Light escaping the glass, only near where it pools. It lies over the glass and only
                // outside it: underneath, the glass would sample it and re-tint itself. Added as light
                // (.plusLighter), it blooms onto a dark page and vanishes cleanly on a light one
                // instead of turning into a coloured shadow.
                pool.mask { shape.stroke(lineWidth: 10).blur(radius: 6) }
                    .blur(radius: 8)
                    .offset(y: 3)
                    .mask { Outside(shape: shape) }
                    .opacity(1.05 * s.glowAmount)
                    .blendMode(.plusLighter)
            }
            if s.effect != .off {
                Group {
                    if s.bloom {
                        // A faint wash through the body of the glass, which stays clear,
                        pool.clipShape(shape)
                            .opacity(0.36 * s.glowAmount)
                            .blendMode(.screen)
                        // and more of it gathered along the edge, as cut glass carries light.
                        pool.mask { shape.strokeBorder(lineWidth: 7).blur(radius: 4) }
                            .clipShape(shape)
                            .opacity(1.0 * s.glowAmount)
                            .blendMode(.screen)
                    }
                    // The rim catches the light where it falls.
                    pool.mask { shape.strokeBorder(lineWidth: 1.5) }
                        .opacity(0.95)
                        .blendMode(.screen)
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
    let style: LumenStyle
    let light: CGRect?
    let time: TimeInterval

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
                if style.effect == .flow {
                    // The drifting pools need room; on the small switch the lens's light is enough.
                    ForEach(max(size.width, size.height) > 120 ? 1..<3 : 1..<1, id: \.self) { k in
                        let drift = time * 2 * .pi
                        let at = CGPoint(x: size.width * (0.5 + 0.42 * sin(drift / (17 + 5 * Double(k)) + 2.4 * Double(k))),
                                         y: size.height * (0.5 + 0.34 * cos(drift / (13 + 4 * Double(k)) + Double(k))))
                        glow(Spectrum.color(at: turn + Double(k) / 3, lightness: 0.74, chroma: 0.19), at: at,
                             radius: minor * 1.15, strength: 0.72, tall: isTall)
                    }
                    glow(Spectrum.color(at: turn, lightness: 0.74, chroma: 0.19), at: source, radius: reach, strength: 1, tall: isTall)
                } else {
                    glow(style.tint, at: source, radius: reach, strength: 1, tall: isTall)
                }
            }
        }
    }

    /// A pool of `color`, stretched along the plate's longer axis, fading to nothing at `radius`.
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
                // Reduce Transparency, Increase Contrast: a plain plate of the appearance's own tone.
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
            // Its shadow, outside only (under the glass it would be sampled and grey it), and
            // light: a heavy shadow makes glass look solid.
            shape.fill(Color.black.opacity(0.16))
                .blur(radius: 14)
                .offset(y: 7)
                .mask { Outside(shape: shape) }
            if s.border {
                shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1).blendMode(.difference)
            } else {
                // Light falling across the top of the glass, and along its edge: bright on top,
                // fading down the sides, fainter again inside the bottom edge where it reflects.
                // These only add light, so they show on a dark page; the last line is the reverse
                // of whatever it crosses, so the edge is drawn on a white page too.
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
        view.state = .active  // the panel is never key, so force the active look
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
