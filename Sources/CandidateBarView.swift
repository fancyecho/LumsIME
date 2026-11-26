import AppKit
import SwiftUI

// MARK: - Root

struct PanelRoot: View {
    let model: PanelModel
    /// The window's canvas, top left at zero.
    static let space = "luma.panel"

    var body: some View {
        let live = model.live
        ZStack(alignment: model.flipped ? .bottomLeading : .topLeading) {
            Color.clear
            Group {
                switch model.mode {
                case .candidates: CandidateBar(model: model)
                case .toast: ToastView(model: model)
                case .status: StatusToastView(model: model)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
            // Rises toward the caret's side and settles as it fades in; sinks back as it fades out.
            .scaleEffect(0.965 + 0.035 * model.entry, anchor: model.flipped ? .bottomLeading : .topLeading)
            .offset(y: (1 - model.entry) * (model.flipped ? 6 : -6))
            .padding(CandidatePanel.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(Self.space))
        // Showing and hiding is the window's fade (CandidatePanel.present); nothing here animates
        // until the window has settled on screen.
        .transaction { transaction in
            if !live {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .modifier(AccessibilityReader())
    }
}

// MARK: - Candidate bar (horizontal & vertical)

private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CandidateBar: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelAccessibility) private var access

    private var glide: Animation? {
        animated ? .spring(response: 0.3, dampingFraction: 1) : nil
    }

    private var animated: Bool { model.live && !model.reduceMotion }

    var body: some View {
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: model.glow)
        let motion = FlowMotion(style: s, reduceMotion: model.reduceMotion, shown: model.live)
        content(s, motion, .frame)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                // (withAnimation here stalls rendering; the background animates itself below.)
                model.barGrowing = model.vertical
                    ? newSize.height > model.barSize.height || newSize.width > model.barSize.width
                    : newSize.width > model.barSize.width
                model.barSize = newSize
            }
            // Read the lens's place at the bar's level, so the glass knows where its light comes from.
            .backgroundPreferenceValue(CellFrameKey.self) { anchors in
                GeometryReader { proxy in
                    GlassPlate(style: s, radius: s.radius, motion: motion,
                               light: anchors[model.highlighted].map { proxy[$0] })
                        .frame(width: model.barSize.width, height: model.barSize.height)
                        // The cat rides the glass, not the words: when the bar grows or shrinks
                        // it moves with the glass's own edge, on the same spring, so it never
                        // jumps ahead of it with each key or stands outside it.
                        .overlay(alignment: .bottomTrailing) {
                            if model.companion {
                                catCompanion(s, motion)
                                    .padding(.trailing, 10)
                            }
                        }
                        // Room is taken at once, with the words that need it, so nothing spills past
                        // the edge and the cat arrives with it; it is given back gently.
                        .animation(animated && !model.barGrowing ? .spring(response: 0.32, dampingFraction: 1) : nil,
                                   value: model.barSize)
                        .frame(width: proxy.size.width, height: proxy.size.height,
                               alignment: model.flipped ? .bottomLeading : .topLeading)
                }
            }
            // The text itself, last, so it reads everything beneath it: glass, light and lens.
            .overlay { Ink(style: s) { content(s, motion, $0) } }
            // Over the ink, only while a correction plays: its light (see RevisedWord).
            .overlay {
                if !model.revised.isEmpty {
                    content(s, motion, .light)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// The cat bathed in a whisper of the glass's current light (rim light) so it belongs to
    /// the same optical world as the panel.
    @ViewBuilder
    private func catCompanion(_ s: LumenStyle, _ motion: FlowMotion) -> some View {
        let thinking = model.aiPending && model.laneStart == nil
        if s.effect == .flow {
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: motion.paused)) { context in
                let rim = Spectrum.color(at: motion.time(context.date) / Spectrum.period, lightness: 0.80, chroma: 0.18)
                CatView(look: catLook, face: catFace, thinking: thinking, rise: model.catRise,
                        moving: animated, accent: s.accent, rimColor: rim, rimStrength: 0.55)
                    .animation(animated ? .spring(response: 0.35, dampingFraction: 0.75) : nil, value: catLook)
            }
        } else {
            let rim: Color = s.effect == .soft ? s.tint : .white
            let strength: Double = s.effect == .soft ? 0.5 : 0.22
            CatView(look: catLook, face: catFace, thinking: thinking, rise: model.catRise,
                    moving: animated, accent: s.accent, rimColor: rim, rimStrength: strength)
                .animation(animated ? .spring(response: 0.35, dampingFraction: 0.75) : nil, value: catLook)
        }
    }

    /// The cat's view of the bar: where the chosen word is (-1 far to its left), and its face.
    private var catLook: CGFloat {
        let count = model.laneStart ?? model.candidates.count
        guard count > 1 else { return -0.3 }
        return -1 + 0.85 * CGFloat(min(model.highlighted, count - 1)) / CGFloat(count - 1)
    }

    private var catFace: CatFace {
        model.candidates.indices.contains(model.highlighted) ? CatFace.of(model.candidates[model.highlighted].text) : .calm
    }

    private func content(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        Group {
            if model.vertical {
                verticalContent(s, motion, pass)
            } else {
                horizontalContent(s, motion, pass)
            }
        }
        .fixedSize()
    }

    private func horizontalContent(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        VStack(alignment: .leading, spacing: s.headerSpacing) {
            if model.showPinyin {
                HeaderLine(model: model, style: s, pass: pass)
                    .padding(.horizontal, s.headerInset)
            }
            HStack(alignment: .center, spacing: 0) {
                horizontalCells(s, motion, pass)
                if !model.showPinyin && model.aiPending && model.laneStart == nil && !model.companion {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pass == .frame ? s.accent : .clear)
                        .symbolEffect(.pulse, options: .repeating, isActive: pass == .frame && model.live && !model.reduceMotion)
                        .padding(.horizontal, 4)
                }
                PageMark(model: model, pass: pass)
                if model.companion {
                    // Room for the cat, in every pass so they all lay out alike. The cat itself
                    // sits on the glass (see body), not here.
                    Color.clear.frame(width: CatView.size.width + 6, height: 1)
                }
            }
        }
        // Without the pinyin line the candidates sit evenly in the glass.
        .padding(model.showPinyin ? s.outerPadding : EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
    }

    private func verticalContent(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.showPinyin {
                HeaderLine(model: model, style: s, pass: pass)
                    .padding(.horizontal, s.headerInset)
            }
            verticalCells(s, motion, pass)
            if model.hasPrev || model.hasNext || model.companion || (!model.showPinyin && model.aiPending && model.laneStart == nil) {
                HStack(spacing: 6) {
                    if !model.showPinyin && model.aiPending && model.laneStart == nil && !model.companion {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(pass == .frame ? s.accent : .clear)
                            .symbolEffect(.pulse, options: .repeating, isActive: pass == .frame && model.live && !model.reduceMotion)
                            .padding(.leading, 8)
                    }
                    PageMark(model: model, pass: pass, horizontal: true)
                    Spacer(minLength: 8)
                    if model.companion {
                        Color.clear.frame(width: CatView.size.width + 6, height: 18)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(minWidth: 168)
        .padding(EdgeInsets(top: model.showPinyin ? 10 : 7, leading: 6, bottom: 7, trailing: 6))
    }

    /// A correction's light takes the colour the lens has: 流光's hue of the moment, 柔光's tint, or
    /// the accent with no 光效. A fixed blue over a pink or gold lens muddied both.
    private func correctionLight(_ s: LumenStyle, _ motion: FlowMotion) -> Color {
        switch s.effect {
        case .off: s.accent
        case .soft: s.lensTint
        case .flow: Spectrum.color(at: motion.time(Date()) / Spectrum.period)
        }
    }

    private func cell(_ index: Int, _ item: RimeCandidateItem, _ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        // The first word of the first page is the one Space takes nearly every time: it leads.
        let hero = index == 0 && model.pageNo == 0
        let revising = hero && !model.revised.isEmpty
        return CandidateCell(item: item, selected: index == model.highlighted, hero: hero,
                             vertical: model.vertical,
                             revised: hero ? model.revised : [:], reviseProgress: model.reviseProgress,
                             correctionLight: revising && pass == .light ? correctionLight(s, motion) : .clear,
                             style: s, pass: pass)
            .modifier(CellHit(index: index, model: model, pass: pass))
    }

    private func horizontalCells(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                let split = model.laneStart ?? model.candidates.count
                ForEach(Array(model.candidates.prefix(split).enumerated()), id: \.offset) { index, item in
                    cell(index, item, s, motion, pass)
                }
                if split < model.candidates.count {
                    HStack(spacing: 0) {
                        Capsule()
                            .fill(pass == .frame ? s.accent.opacity(0.45) : .clear)
                            .frame(width: 1, height: 16)
                            .padding(.horizontal, 3)
                        if model.laneCompact {
                            LaneSpark(selected: model.highlighted >= split, style: s, pass: pass)
                                .modifier(CellHit(index: split, model: model, pass: pass))
                        } else {
                            ForEach(Array(model.candidates.enumerated().dropFirst(split)), id: \.offset) { index, item in
                                cell(index, item, s, motion, pass)
                            }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.laneWidth = $0 }
                    .transition(.opacity)
                }
            }
            .id(model.pageNo)
            .transition(.asymmetric(
                insertion: .offset(x: 14 * model.pageDirection).combined(with: .opacity),
                removal: .offset(x: -14 * model.pageDirection).combined(with: .opacity)))
        }
        .animation(animated ? .spring(response: 0.32, dampingFraction: 1) : nil, value: model.pageNo)
        .backgroundPreferenceValue(CellFrameKey.self) { anchors in
            selectionOverlay(anchors: anchors, s: s, motion: motion, pass: pass, vertical: false)
        }
    }

    private func verticalCells(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 1) {
                let split = model.laneStart ?? model.candidates.count
                ForEach(Array(model.candidates.prefix(split).enumerated()), id: \.offset) { index, item in
                    cell(index, item, s, motion, pass)
                }
                if split < model.candidates.count {
                    Capsule()
                        .fill(pass == .frame ? s.accent.opacity(0.4) : .clear)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    ForEach(Array(model.candidates.enumerated().dropFirst(split)), id: \.offset) { index, item in
                        cell(index, item, s, motion, pass)
                    }
                }
            }
            .id(model.pageNo)
            .transition(.asymmetric(
                insertion: .offset(y: 10 * model.pageDirection).combined(with: .opacity),
                removal: .offset(y: -10 * model.pageDirection).combined(with: .opacity)))
        }
        .animation(animated ? .spring(response: 0.32, dampingFraction: 1) : nil, value: model.pageNo)
        .backgroundPreferenceValue(CellFrameKey.self) { anchors in
            selectionOverlay(anchors: anchors, s: s, motion: motion, pass: pass, vertical: true)
        }
    }

    private func selectionOverlay(anchors: [Int: Anchor<CGRect>], s: LumenStyle, motion: FlowMotion,
                                  pass: Pass, vertical: Bool) -> some View {
        GeometryReader { proxy in
            if pass == .frame {
                let corner = s.radius - s.outerPadding.bottom
                if let hovered = model.hovered, hovered != model.highlighted, let hAnchor = anchors[hovered] {
                    let hRect = proxy[hAnchor]
                    HoverHighlight(size: hRect.size, radius: corner)
                        .offset(x: hRect.minX, y: hRect.minY)
                        .animation(animated ? .easeOut(duration: 0.12) : nil, value: model.hovered)
                }
                if let anchor = anchors[model.highlighted] {
                    let rect = proxy[anchor]
                    let sx = vertical ? 1 - (model.lensStretch - 1) * 0.45 : model.lensStretch
                    let sy = vertical ? model.lensStretch : 1 - (model.lensStretch - 1) * 0.6
                    let anchorPoint: UnitPoint = vertical
                        ? (model.moveDirection > 0 ? .bottom : .top)
                        : (model.moveDirection > 0 ? .trailing : .leading)
                    Lens(size: rect.size, radius: corner, style: s, motion: motion)
                        .scaleEffect(x: sx, y: sy, anchor: anchorPoint)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(glide, value: model.moveToken)
                }
            }
        }
    }
}

// MARK: - Subviews

private struct HeaderLine: View {
    let model: PanelModel
    let style: LumenStyle
    let pass: Pass

    var body: some View {
        let s = style
        let h = model.header
        let joint = h.lead.isEmpty || h.rest.isEmpty ? "" : "\u{2002}"
        // Corrected syllables keep the accent's colour, so a fixed typo reads at a glance; the rest is ink.
        let lead = h.lead.enumerated().reduce(Text("")) { line, item in
            let (i, syllable) = item
            let color = syllable.corrected ? (pass == .frame ? s.accent : Color.clear) : pass.ink(s.headerLead)
            return line + Text(i == 0 ? "" : " ") + Text(syllable.text).foregroundStyle(color)
        }
        HStack(spacing: 5) {
            (lead + Text(joint + h.rest).foregroundStyle(pass.ink(s.headerRest)))
                .font(s.headerFont)
                .tracking(s.headerTracking)
                .lineLimit(1)
            if model.aiPending {
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(pass == .frame ? s.accent : .clear)
                    .symbolEffect(.pulse, options: .repeating, isActive: pass == .frame && model.live && !model.reduceMotion)
                    .transition(.opacity)
            }
        }
        .animation(model.live ? .easeOut(duration: 0.2) : nil, value: model.aiPending)
    }
}

private struct CandidateCell: View {
    let item: RimeCandidateItem
    let selected: Bool
    /// The lead word: slightly firmer than the rest.
    var hero = false
    var vertical = false
    var revised: [Int: Character] = [:]
    var reviseProgress: CGFloat = 1
    /// The colour of a correction's light: the 光效's own (see CandidateBar.correctionLight).
    var correctionLight: Color = .clear
    let style: LumenStyle
    let pass: Pass

    var body: some View {
        let s = style
        let font = hero ? s.heroFont : s.wordFont
        // Emoji keep their own colours: drawn as they are, not turned into ink.
        let ink = item.isEmoji ? (pass == .frame ? Color.primary : .clear)
            : pass.ink(selected ? 1 : hero ? max(s.word, s.heroIdle) : s.word)
        HStack(alignment: .firstTextBaseline, spacing: s.labelGap) {
            Text(item.label)
                .font(s.labelFont)
                .monospacedDigit()
                .frame(minWidth: vertical ? 10 : nil, alignment: .trailing)
                .foregroundStyle(pass.ink(selected ? s.labelSelected : s.label))
            Group {
                if revised.isEmpty {
                    Text(item.text).font(font).foregroundStyle(ink)
                } else {
                    RevisedWord(text: item.text, revised: revised, progress: reviseProgress, font: font, ink: ink,
                                light: correctionLight, pass: pass)
                }
            }
            .overlay(alignment: .topTrailing) {
                if pass == .frame {
                    if item.ai {
                        Image(systemName: "sparkle")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(s.accent)
                            .opacity(selected ? 1 : 0.8)
                            .offset(x: 7, y: 0)
                    } else if item.corrected != nil {
                        Circle()
                            .fill(s.accent)
                            .frame(width: 4, height: 4)
                            .opacity(selected ? 1 : 0.75)
                            .offset(x: 5, y: 2)
                    }
                }
            }
            if !item.comment.isEmpty {
                Text(item.comment)
                    .font(.system(size: 11))
                    .foregroundStyle(pass.ink(selected ? s.labelSelected : s.label))
            }
            if vertical {
                Spacer(minLength: 4)
            }
        }
        .lineLimit(1)
        .padding(vertical ? s.verticalCellPadding : s.cellPadding)
        .frame(maxWidth: vertical ? .infinity : nil, maxHeight: vertical ? nil : .infinity, alignment: .leading)
    }
}

/// The lead word with some of its characters just set right (focus-pull transition).
private struct RevisedWord: View {
    let text: String
    let revised: [Int: Character]
    let progress: CGFloat
    let font: Font
    let ink: Color
    let light: Color
    let pass: Pass

    private func solidity(_ shown: CGFloat) -> CGFloat { pass == .neutral ? min(1, shown * 4) : shown }

    private struct Run: Identifiable {
        let id: Int
        let text: String
        let before: String?
    }

    private var runs: [Run] {
        var runs: [Run] = []
        for (i, ch) in text.enumerated() {
            let was = revised[i]
            if let last = runs.last, (last.before != nil) == (was != nil) {
                runs[runs.count - 1] = Run(id: last.id, text: last.text + String(ch),
                                           before: last.before.map { $0 + String(was ?? ch) })
            } else {
                runs.append(Run(id: i, text: String(ch), before: was.map(String.init)))
            }
        }
        return runs
    }

    var body: some View {
        let p = Double(min(max(progress, 0), 1))
        let k = CGFloat(1 - pow(1 - min(1, p / 0.55), 3))
        let going = max(0, 1 - k / 0.5)
        let coming = min(1, max(0, (k - 0.08) / 0.62))
        let glow = sin(min(1, p / 0.85) * .pi) * pow(1 - p, 0.5)
        let blurGoing = 2 * min(1, k / 0.5)
        let blurComing = 2 * max(0, 1 - k / 0.7)
        HStack(spacing: 0) {
            ForEach(runs) { run in
                let word = Text(run.text).font(font).foregroundStyle(ink)
                if let before = run.before {
                    ZStack {
                        Text(before).font(font).foregroundStyle(ink)
                            .blur(radius: blurGoing)
                            .offset(y: -3.5 * k)
                            .opacity(Double(solidity(going)))
                        word
                            .blur(radius: blurComing)
                            .offset(y: 3.5 * (1 - k))
                            .opacity(Double(solidity(coming)))
                    }
                    .background {
                        if pass == .light {
                            Ellipse()
                                .fill(light)
                                .padding(.horizontal, -2)
                                .padding(.vertical, 2)
                                .blur(radius: 6)
                                .opacity(0.38 * glow)
                                .mask {
                                    ZStack {
                                        Rectangle().padding(-16)
                                        Text(before).font(font)
                                            .blur(radius: blurGoing)
                                            .offset(y: -3.5 * k)
                                            .opacity(Double(going))
                                            .blendMode(.destinationOut)
                                        Text(run.text).font(font)
                                            .blur(radius: blurComing)
                                            .offset(y: 3.5 * (1 - k))
                                            .opacity(Double(coming))
                                            .blendMode(.destinationOut)
                                    }
                                    .compositingGroup()
                                }
                                .blendMode(.plusLighter)
                        }
                    }
                } else {
                    word
                }
            }
        }
    }
}

/// Where a cell is, for the lens, hover and landing, and what a click on it picks.
private struct CellHit: ViewModifier {
    let index: Int
    let model: PanelModel
    let pass: Pass

    func body(content: Content) -> some View {
        if pass == .frame {
            content.anchorPreference(key: CellFrameKey.self, value: .bounds) { [index: $0] }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelRoot.space)) } action: { model.cellFrames[index] = $0 }
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        model.hovered = index
                    } else if model.hovered == index {
                        model.hovered = nil
                    }
                }
                .onTapGesture { if model.visible { model.onSelect?(index) } }
        } else {
            content
        }
    }
}

/// The AI lane folded down at the screen's edge: just its spark (8 or Tab still takes it).
private struct LaneSpark: View {
    let selected: Bool
    let style: LumenStyle
    let pass: Pass

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: style.labelGap) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(pass == .frame ? style.accent : .clear)
        }
        .fixedSize()
        .padding(style.cellPadding)
    }
}

/// Clickable page indicator chevrons.
private struct PageMark: View {
    let model: PanelModel
    let pass: Pass
    var horizontal = false

    @State private var hoverPrev = false
    @State private var hoverNext = false

    var body: some View {
        if model.hasPrev || model.hasNext {
            Group {
                if horizontal {
                    HStack(spacing: 6) {
                        arrow("chevron.left", enabled: model.hasPrev, hovered: $hoverPrev, delta: -1)
                        arrow("chevron.right", enabled: model.hasNext, hovered: $hoverNext, delta: 1)
                    }
                    .padding(.leading, 8)
                } else {
                    VStack(spacing: 1) {
                        arrow("chevron.up", enabled: model.hasPrev, hovered: $hoverPrev, delta: -1)
                        arrow("chevron.down", enabled: model.hasNext, hovered: $hoverNext, delta: 1)
                    }
                    .padding(.leading, 2)
                    .padding(.trailing, 7)
                }
            }
            .font(.system(size: 7.5, weight: .bold))
        }
    }

    @ViewBuilder
    private func arrow(_ systemName: String, enabled: Bool, hovered: Binding<Bool>, delta: Int) -> some View {
        let strength = enabled ? (hovered.wrappedValue ? 0.95 : 0.6) : 0.2
        let icon = Image(systemName: systemName)
            .foregroundStyle(pass.ink(strength))
            .padding(2)
            .contentShape(Rectangle())
        if pass == .frame && enabled {
            icon
                .onHover { hovered.wrappedValue = $0 }
                .onTapGesture { if model.visible { model.onPage?(delta) } }
        } else {
            icon
        }
    }
}

// MARK: - Toast & Status

/// The 中 / A switch: both modes on a small glass capsule, the lens resting on the active one.
struct ToastView: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelAccessibility) private var access

    private static let segment = CGSize(width: 26, height: 22)
    private static let inset: CGFloat = 3

    var body: some View {
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: model.glow)
        let motion = FlowMotion(style: s, reduceMotion: model.reduceMotion, shown: model.live)
        let segment = Self.segment, inset = Self.inset
        let lensX = model.toastChinese ? 0 : segment.width
        glyphs(.frame, s)
            .background(alignment: .leading) {
                Lens(size: segment, radius: segment.height / 2, style: s, motion: motion)
                    .offset(x: lensX)
            }
            .padding(inset)
            .background {
                GlassPlate(style: s, radius: segment.height / 2 + inset, motion: motion,
                           light: CGRect(origin: CGPoint(x: inset + lensX, y: inset), size: segment))
            }
            .overlay { Ink(style: s) { glyphs($0, s).padding(inset) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.toastChinese
                                ? L10n.t("toast.chinese", fallback: "中文")
                                : L10n.t("toast.english", fallback: "英文"))
    }

    private func glyphs(_ pass: Pass, _ s: LumenStyle) -> some View {
        HStack(spacing: 0) {
            glyph("中", font: .system(size: 12.5, weight: .medium), on: model.toastChinese, pass, s)
            glyph("A", font: .system(size: 12, weight: .semibold, design: .rounded), on: !model.toastChinese, pass, s)
        }
    }

    private func glyph(_ text: String, font: Font, on: Bool, _ pass: Pass, _ s: LumenStyle) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(pass.ink(on ? 1 : s.label))
            .frame(width: Self.segment.width, height: Self.segment.height)
    }
}

/// A calm frosted-glass status pill shown when the engine is deploying dictionaries.
struct StatusToastView: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelAccessibility) private var access

    var body: some View {
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: .off)
        let motion = FlowMotion(style: s, reduceMotion: model.reduceMotion, shown: model.live)
        let inset = EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 12)
        label(.frame, s)
            .padding(inset)
            .background { GlassPlate(style: s, radius: 13, motion: motion) }
            .overlay { Ink(style: s) { label($0, s).padding(inset) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.statusText)
    }

    private func label(_ pass: Pass, _ s: LumenStyle) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pass == .frame ? s.accent : .clear)
                .frame(width: 5.5, height: 5.5)
            Text(model.statusText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(pass.ink(0.9))
                .lineLimit(1)
        }
        .fixedSize()
    }
}
