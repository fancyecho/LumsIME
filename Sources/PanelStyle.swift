import AppKit
import SwiftUI

/// Candidate bar orientation: horizontal row or vertical card.
enum LumaLayout: String, CaseIterable, Identifiable {
    case horizontal, vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontal: return L10n.t("layout.horizontal", fallback: "横排")
        case .vertical: return L10n.t("layout.vertical", fallback: "竖排")
        }
    }
}

/// The system accessibility settings the panel answers to.
struct PanelAccessibility {
    var increaseContrast = false
    var showBorders = false
    var reduceBrightEffects = false
    var reduceTransparency = false
}

extension EnvironmentValues {
    @Entry var panelAccessibility = PanelAccessibility()
}

/// Gathers the settings into one environment value, so each view builds its style from a single read.
struct AccessibilityReader: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        let access = PanelAccessibility(increaseContrast: contrast == .increased, showBorders: showBorders,
                                        reduceTransparency: reduceTransparency)
        if #available(macOS 26.4, *) {
            content.modifier(BrightEffectsReader(access: access))
        } else {
            content.environment(\.panelAccessibility, access)
        }
    }
}

@available(macOS 26.4, *)
private struct BrightEffectsReader: ViewModifier {
    @Environment(\.accessibilityReduceHighlightingEffects) private var reduceBrightEffects
    let access: PanelAccessibility

    func body(content: Content) -> some View {
        var access = access
        access.reduceBrightEffects = reduceBrightEffects
        return content.environment(\.panelAccessibility, access)
    }
}

/// The bar's text is drawn more than once. `.frame` lays it out, takes clicks and shows the marks
/// that keep their own colour; its text is clear. `.ink` draws the same text as a solid shape for
/// `Ink` to fill, and `.dim` draws it again by how far each piece falls short of full strength.
/// `.neutral` is `.ink` for the step that takes the colour out of the glass under the text, where a
/// fading glyph counts as more solid than it looks (see RevisedWord). `.light` lies over the
/// finished ink, for light that must not change what colour the ink takes.
enum Pass { case frame, ink, neutral, dim, light }

extension Pass {
    /// Text that takes the ink at `strength`, 0 to 1.
    func ink(_ strength: Double) -> Color {
        switch self {
        case .frame, .light: .clear
        case .ink, .neutral: .white
        case .dim: .white.opacity(1 - strength)
        }
    }
}

/// Whether 流光 is moving: only while the panel is up and settled on screen, and never under Reduce Motion or Reduce
/// Bright Effects (then the light holds still).
struct FlowMotion {
    let moving: Bool
    let shown: Bool
    let reduceMotion: Bool

    init(style: LumenStyle, reduceMotion: Bool, shown: Bool) {
        moving = style.effect == .flow && style.bloom && !reduceMotion
        self.shown = shown
        self.reduceMotion = reduceMotion
    }

    var paused: Bool { !moving || !shown }

    /// `--flow-at <seconds>` holds the clock there, so screenshots can be compared.
    private static let held = LumaSettings.argument("--flow-at").flatMap(TimeInterval.init)

    /// The flow's clock, in seconds; held at zero while it isn't moving.
    func time(_ date: Date) -> TimeInterval { moving ? Self.held ?? date.timeIntervalSinceReferenceDate : 0 }
}

/// 流光's colours: the whole colour wheel at one perceived lightness (OKLCH), a full turn every
/// few seconds. Equal lightness keeps the glow steady: yellow and green no longer flare brighter
/// than blue and violet as the hues go round.
enum Spectrum {
    static let period: TimeInterval = 12

    /// The colour `turn` of the way round the wheel (any number; only the fraction counts).
    static func color(at turn: Double, lightness: Double = 0.78, chroma: Double = 0.15) -> Color {
        let hue = turn * 2 * .pi
        let a = chroma * cos(hue), b = chroma * sin(hue)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return Color(.sRGBLinear,
                     red: clamp(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     green: clamp(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     blue: clamp(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}

/// 光 Lumen: clear glass, a lens of light under the chosen word, and ink that follows the page.
struct LumenStyle {
    /// The Mac's appearance. The glass and the ink take their tone from the page instead; this
    /// only decides the plain plate used when transparency is off.
    let dark: Bool

    let radius: CGFloat = 15
    let outerPadding = EdgeInsets(top: 10, leading: 6, bottom: 6, trailing: 6)
    let headerInset: CGFloat = 9
    let headerSpacing: CGFloat = 3
    let cellPadding = EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9)
    let verticalCellPadding = EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 14)
    let labelGap: CGFloat = 5
    let wordFont: Font = .system(size: 15)
    /// The lead word, the one Space takes: slightly larger and firmer, without competing against
    /// the glowing lens when the highlight moves to another candidate.
    let heroFont: Font = .system(size: 16, weight: .medium)
    /// How strongly the lead word takes the ink when the highlight has moved off it: steps back
    /// cleanly so the highlighted word always remains the single visual focus.
    let heroIdle: Double = 0.76
    let labelFont: Font = .system(size: 9, weight: .medium)
    let headerFont: Font = .system(size: 10, weight: .medium)
    let headerTracking: CGFloat = 0.8

    /// How strongly each kind of text takes the ink, 0 to 1 (the chosen word takes it in full).
    let word: Double
    let label: Double
    let labelSelected: Double
    let headerLead: Double
    let headerRest: Double
    /// Marks that keep their own colour (AI, corrections): one that holds on light and dark alike.
    let accent = Color(hex: 0x5B7BFF)

    /// The brightness of the glass at which the ink turns from white to black, and how sharply.
    let inkPivot: Double = 0.58
    let inkGain: Double = 12
    /// How strongly the shadow under the ink burns (lower burns more).
    let inkShadow: Double = 0.8
    /// How bright the highlights on the glass are: a hint, not a gleam.
    let shine: Double = 0.28
    /// How much of the 光效's light shows, 1 in full.
    let glowAmount: Double = 0.5
    /// The blends that shape the glass's tone, in order: frosted glass in the manner of a system
    /// material, taking its tone from the page but held back at both ends. A white page comes
    /// through as a soft off-white rather than full white, a dark one as a quiet deep grey, and its
    /// brightness is capped, so over a page that is part white and part grey the plate is one even tone.
    let tone: [(mode: BlendMode, level: Double)] = [(.softLight, 0.2), (.colorDodge, 0.375), (.multiply, 0.93),
                                                    (.plusLighter, 0.045), (.darken, 0.855)]
    /// A plain opaque plate instead of glass (Reduce Transparency, Increase Contrast).
    let solid: Bool
    /// A clearly visible edge on the panel and the selection (Increase Contrast, Show Borders).
    let border: Bool
    /// Light that blooms past a shape's edge; off under Reduce Bright Effects.
    let bloom: Bool
    /// 光效: 柔光 shifts between warm golden sunlight by day and serene silvery moonlight by night.
    let effect: LumaGlow
    /// Soft glow primary colour: airy goose-yellow sunlight by day, serene silvery-blue moonlight by night.
    var softTint: Color { dark ? Color(hex: 0x9EC2FA) : Color(hex: 0xFFF099) }
    /// Soft glow luminous core colour.
    var softCore: Color { dark ? Color(hex: 0xDCEBFF) : Color(hex: 0xFFFBE6) }
    /// Soft glow edge/rim colour.
    var softRim: Color { dark ? Color(hex: 0xC8DFFF) : Color(hex: 0xF7E37A) }
    /// Soft glow ambient aura colour.
    var softAura: Color { dark ? Color(hex: 0x7CA8F2) : Color(hex: 0xFFF2A6) }
    let tint = Color(nsColor: .controlAccentColor)
    /// The same, paler, for correction light when needed.
    var lensTint: Color { dark ? Color(hex: 0xC4DCFF) : Color(hex: 0xF5BE38) }

    init(dark: Bool, access: PanelAccessibility = .init(), effect: LumaGlow = .off) {
        self.dark = dark
        self.effect = effect
        border = access.increaseContrast || access.showBorders
        bloom = !access.reduceBrightEffects
        solid = access.increaseContrast || access.reduceTransparency
        // Only a soft light marks the chosen word, so the others step back a little to let it lead.
        let firm = access.increaseContrast
        word = firm ? 0.95 : 0.74
        label = firm ? 0.8 : 0.55
        labelSelected = firm ? 0.9 : 0.72
        headerLead = firm ? 1 : 0.9
        headerRest = firm ? 0.8 : 0.5
    }
}

extension Character {
    /// A Chinese character (the unified ideographs and their first extension).
    var isHan: Bool {
        guard let v = unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
    }
}

extension RimeCandidateItem {
    /// A candidate drawn in colour (an emoji), which ink would flatten to a silhouette.
    var isEmoji: Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}
