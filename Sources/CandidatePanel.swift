import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PanelModel {
    enum Mode { case candidates, toast }

    var mode: Mode = .candidates
    var candidates: [RimeCandidateItem] = []
    var highlighted = 0
    /// Bumped only when the selection moves within an unchanged list, so the highlight
    /// glides on arrow keys but tracks the text exactly while typing.
    var moveToken = 0
    var pageNo = 0
    var pageDirection: CGFloat = 1
    var hasPrev = false
    var hasNext = false
    var header = PinyinHeader()
    var toastChinese = true
    var visible = false
    var flipped = false
    var contentSize: CGSize = .zero
    var barSize: CGSize = .zero
    var barGrowing = false
    var reduceMotion = false
    @ObservationIgnored var onSelect: ((Int) -> Void)?
}

/// A borderless, non-activating panel that floats next to the text caret.
///
/// The window is a fixed, oversized transparent canvas; the SwiftUI content inside it animates its
/// own size, so width changes and the highlight glide smoothly instead of the window snapping.
@MainActor
final class CandidatePanel {
    static let shared = CandidatePanel()
    static let margin: CGFloat = 44

    let model = PanelModel()
    private let window: NSPanel
    private let canvas = NSSize(width: 1600, height: 300)
    private var hideWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var glideWork: DispatchWorkItem?

    private init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: canvas),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above full-screen apps, like Squirrel. (Don't set isFloatingPanel: it resets the level.)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        // Not sticky: an ordered-out window comes back on whichever Space is active, so the panel
        // appears on the desktop being typed in. A sticky window can stay tied to the Spaces that
        // existed when it was created.
        window.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: PanelRoot(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: canvas)
        window.contentView = host

        // Switching desktops takes the panel down at once, so it never lingers on the old one.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropFromScreen() }
        }
    }

    private func dropFromScreen() {
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        model.visible = false
        window.orderOut(nil)
    }

    func show(_ st: RimeState, near caret: NSRect, onSelect: @escaping (Int) -> Void) {
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        model.onSelect = onSelect
        if st.pageNo != model.pageNo {
            model.pageDirection = st.pageNo > model.pageNo ? 1 : -1
        } else if st.candidates == model.candidates, st.highlighted != model.highlighted, model.visible {
            model.moveToken &+= 1
        }
        model.mode = .candidates
        model.candidates = st.candidates
        model.highlighted = st.highlighted
        model.pageNo = st.pageNo
        model.hasPrev = st.pageNo > 0
        model.hasNext = !st.isLastPage
        let selected = st.candidates.indices.contains(st.highlighted) ? st.candidates[st.highlighted] : nil
        model.header = PinyinHeader.make(preedit: st.preedit, candidate: selected?.text ?? "",
                                         corrected: selected?.corrected)
        present(near: caret)
    }

    func hide() {
        guard model.mode == .candidates else { return }
        dismiss()
    }

    /// Briefly shows the 中 / A switch at the caret, the lens gliding over to the new mode.
    func toast(chinese: Bool, near caret: NSRect) {
        if model.mode == .candidates && model.visible { return }
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        model.mode = .toast
        model.toastChinese = model.reduceMotion ? chinese : !chinese  // start on the mode being left
        model.visible = false
        present(near: caret)
        if !model.reduceMotion {
            let glide = DispatchWorkItem { [weak self] in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { self?.model.toastChinese = chinese }
            }
            glideWork = glide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: glide)
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func present(near caret: NSRect) {
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Still up from another desktop: take it down so ordering it in lands on this one.
        if window.isVisible && !window.isOnActiveSpace { dropFromScreen() }
        place(near: caret)
        guard !model.visible || !window.isVisible else { return }
        window.orderFrontRegardless()
        if model.reduceMotion {
            model.visible = true
        } else {
            withAnimation(.easeOut(duration: 0.2)) { model.visible = true }
        }
    }

    private func dismiss() {
        guard model.visible || window.isVisible else { return }
        withAnimation(.easeIn(duration: 0.12)) { model.visible = false }
        let work = DispatchWorkItem { [weak self] in self?.window.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func place(near caret: NSRect) {
        var rect = caret
        if rect.origin == .zero && rect.size.width <= 1 {
            // Some apps (terminals, Electron) report no caret; fall back to the mouse.
            let mouse = NSEvent.mouseLocation
            rect = NSRect(x: mouse.x, y: mouse.y - 18, width: 0, height: 18)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(rect.origin) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = model.contentSize == .zero ? CGSize(width: 420, height: 70) : model.contentSize
        let gap: CGFloat = 6
        let margin = Self.margin

        var x = rect.minX - 12
        x = min(x, visible.maxX - size.width - 4)
        x = max(x, visible.minX + 4)

        let fitsBelow = rect.minY - gap - size.height >= visible.minY
        model.flipped = !fitsBelow
        let y = fitsBelow
            ? rect.minY - gap + margin - canvas.height  // content's top edge hangs under the caret
            : rect.maxY + gap - margin                  // content's bottom edge sits above the caret
        window.setFrameOrigin(NSPoint(x: x - margin, y: y))
    }
}

// MARK: - Root

private struct PanelRoot: View {
    let model: PanelModel

    var body: some View {
        let anchor: UnitPoint = model.flipped ? .bottomLeading : .topLeading
        let still = model.visible || model.reduceMotion
        ZStack(alignment: model.flipped ? .bottomLeading : .topLeading) {
            Color.clear
            Group {
                switch model.mode {
                case .candidates: CandidateBar(model: model)
                case .toast: ToastView(model: model)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
            .scaleEffect(still ? 1 : 0.985, anchor: anchor)
            .blur(radius: still ? 0 : 6)
            .offset(y: still ? 0 : (model.flipped ? 5 : -5))
            .opacity(model.visible ? 1 : 0)
            .padding(CandidatePanel.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(AccessibilityReader())
    }
}

/// The system accessibility settings the panel answers to.
struct PanelAccessibility {
    var increaseContrast = false
    var showBorders = false
    var reduceBrightEffects = false
}

extension EnvironmentValues {
    @Entry var panelAccessibility = PanelAccessibility()
}

/// Gathers the settings into one environment value, so each view builds its style from a single read.
private struct AccessibilityReader: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders

    @ViewBuilder
    func body(content: Content) -> some View {
        let access = PanelAccessibility(increaseContrast: contrast == .increased, showBorders: showBorders)
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

// MARK: - Candidate bar

private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct CandidateBar: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelAccessibility) private var access

    private var glide: Animation? {
        model.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    var body: some View {
        let s = LumenStyle(dark: scheme == .dark, access: access)
        VStack(alignment: .leading, spacing: s.headerSpacing) {
            HeaderLine(model: model, style: s)
                .padding(.horizontal, s.headerInset)
            HStack(alignment: .center, spacing: 0) {
                cells(s)
                PageMark(model: model, style: s)
            }
        }
        .padding(s.outerPadding)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            // (withAnimation here stalls rendering; the background animates itself below.)
            model.barGrowing = newSize.width > model.barSize.width
            model.barSize = newSize
        }
        .background(alignment: model.flipped ? .bottomLeading : .topLeading) {
            GlassBackground(style: s, radius: s.radius)
                .frame(width: model.barSize.width, height: model.barSize.height)
                // Grow quickly so text never spills outside; settle gently when shrinking.
                .animation(model.reduceMotion ? nil
                           : .spring(response: model.barGrowing ? 0.16 : 0.32, dampingFraction: 1),
                           value: model.barSize)
        }
    }

    private func cells(_ s: LumenStyle) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, item in
                    CandidateCell(item: item, selected: index == model.highlighted, style: s)
                        .anchorPreference(key: CellFrameKey.self, value: .bounds) { [index: $0] }
                        .contentShape(Rectangle())
                        .onTapGesture { model.onSelect?(index) }
                }
            }
            .id(model.pageNo)
            .transition(.asymmetric(
                insertion: .offset(x: 14 * model.pageDirection).combined(with: .opacity),
                removal: .offset(x: -14 * model.pageDirection).combined(with: .opacity)))
        }
        .animation(model.reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1), value: model.pageNo)
        .backgroundPreferenceValue(CellFrameKey.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[model.highlighted] {
                    let rect = proxy[anchor]
                    // Concentric with the bar: its radius less the inset between them.
                    Lens(size: rect.size, radius: s.radius - s.outerPadding.bottom, style: s)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(glide, value: model.moveToken)
                }
            }
        }
    }
}

private struct HeaderLine: View {
    let model: PanelModel
    let style: LumenStyle

    var body: some View {
        let s = style
        let h = model.header
        let joint = h.lead.isEmpty || h.rest.isEmpty ? "" : "\u{2002}"
        // Corrected syllables take the accent, so a fixed typo reads at a glance.
        let lead = h.lead.enumerated().reduce(Text("")) { line, item in
            let (i, syllable) = item
            return line + Text(i == 0 ? "" : " ").foregroundStyle(s.headerLead)
                + Text(syllable.text).foregroundStyle(syllable.corrected ? s.accent : s.headerLead)
        }
        (lead + Text(joint + h.rest).foregroundStyle(s.headerRest))
            .font(s.headerFont)
            .tracking(s.headerTracking)
            .lineLimit(1)
    }
}

private struct CandidateCell: View {
    let item: RimeCandidateItem
    let selected: Bool
    let style: LumenStyle

    var body: some View {
        let s = style
        HStack(alignment: .firstTextBaseline, spacing: s.labelGap) {
            Text(item.label)
                .font(s.labelFont)
                .monospacedDigit()
                .foregroundStyle(selected ? s.labelSelected : s.label)
            Text(item.text)
                .font(s.wordFont)
                .foregroundStyle(selected ? s.wordSelected : s.word)
                .overlay(alignment: .topTrailing) {
                    // A typo correction: a small accent dot, like an editor's mark.
                    if item.corrected != nil {
                        Circle()
                            .fill(s.accent)
                            .frame(width: 4, height: 4)
                            .opacity(selected ? 1 : 0.65)
                            .offset(x: 5, y: 2)
                    }
                }
            if !item.comment.isEmpty {
                Text(item.comment)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? s.labelSelected : s.label)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(s.cellPadding)
        .animation(.easeOut(duration: 0.18), value: selected)
    }
}

private struct PageMark: View {
    let model: PanelModel
    let style: LumenStyle

    var body: some View {
        if model.hasPrev || model.hasNext {
            VStack(spacing: 2) {
                Image(systemName: "chevron.up").opacity(model.hasPrev ? 1 : 0.3)
                Image(systemName: "chevron.down").opacity(model.hasNext ? 1 : 0.3)
            }
            .font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(style.headerRest)
            .padding(.leading, 2)
            .padding(.trailing, 7)
        }
    }
}

// MARK: - Lens

/// The lens of light under the glass that marks the current choice.
private struct Lens: View {
    let size: CGSize
    let radius: CGFloat
    let style: LumenStyle

    var body: some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if s.dark {
                ZStack {
                    if s.glow {
                        Ellipse()
                            .fill(Color(hex: 0x96AAFF, opacity: 0.5))
                            .frame(width: size.width * 0.78, height: min(12, size.height * 0.5))
                            .blur(radius: 8)
                            .offset(y: size.height / 2 + 1)
                            .blendMode(.plusLighter)
                    }
                    shape
                        .fill(RadialGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)],
                                             center: .top, startRadius: 0, endRadius: max(size.width, 40)))
                        .overlay {
                            if s.border {
                                shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                            } else {
                                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06)],
                                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                            }
                        }
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                }
            } else {
                shape
                    .fill(LinearGradient(colors: [.white, .white.opacity(0.84)], startPoint: .top, endPoint: .bottom))
                    .overlay { shape.strokeBorder(Color.black.opacity(s.border ? 0.5 : 0.05), lineWidth: s.border ? 1 : 0.5) }
                    .shadow(color: Color(hex: 0x281E5A, opacity: 0.22), radius: 9, y: 5)
                    .shadow(color: .black.opacity(0.04), radius: 0.5, y: 0.5)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Toast

/// The 中 / A switch: both modes on a small glass capsule, the lens resting on the active one.
private struct ToastView: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelAccessibility) private var access

    private static let segment = CGSize(width: 26, height: 22)
    private static let inset: CGFloat = 3

    var body: some View {
        let s = LumenStyle(dark: scheme == .dark, access: access)
        let segment = Self.segment
        HStack(spacing: 0) {
            glyph("中", font: .system(size: 12.5, weight: .medium), on: model.toastChinese, s)
            glyph("A", font: .system(size: 12, weight: .semibold, design: .rounded), on: !model.toastChinese, s)
        }
        .background(alignment: .leading) {
            Lens(size: segment, radius: segment.height / 2, style: s)
                .offset(x: model.toastChinese ? 0 : segment.width)
        }
        .padding(Self.inset)
        .background { GlassBackground(style: s, radius: segment.height / 2 + Self.inset) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.toastChinese ? "中文" : "English")
    }

    private func glyph(_ text: String, font: Font, on: Bool, _ s: LumenStyle) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(on ? s.wordSelected : s.label)
            .frame(width: Self.segment.width, height: Self.segment.height)
    }
}

// MARK: - Materials

private struct GlassBackground: View {
    let style: LumenStyle
    let radius: CGFloat

    var body: some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(s.dark ? .regular.tint(.black.opacity(0.32)) : .regular, in: shape)
                    .overlay { topSheen(shape, s.dark ? 0.16 : 0.5) }
            } else {
                shape
                    .fill(s.dark ? Color.black.opacity(0.42) : Color.white.opacity(0.45))
                    .background { VisualEffectBackground().clipShape(shape) }
                    .overlay { topSheen(shape, s.dark ? 0.16 : 0.6) }
                    .shadow(color: .black.opacity(s.dark ? 0.5 : 0.16), radius: 22, y: 12)
            }
        }
        .overlay {
            if s.border {
                shape.strokeBorder(s.dark ? Color.white.opacity(0.5) : Color.black.opacity(0.45), lineWidth: 1)
            }
        }
    }

    /// A hairline of light along the top edge, fading out by mid-height.
    private func topSheen(_ shape: RoundedRectangle, _ opacity: Double) -> some View {
        shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(opacity), location: 0),
                                                  .init(color: .clear, location: 0.45)],
                                          startPoint: .top, endPoint: .bottom),
                           lineWidth: 0.5)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active  // the panel is never key, so force the active look
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Style tokens

/// 光 Lumen: glass, with a lens of light under the chosen word.
struct LumenStyle {
    let dark: Bool

    let radius: CGFloat = 15
    let outerPadding = EdgeInsets(top: 10, leading: 6, bottom: 6, trailing: 6)
    let headerInset: CGFloat = 9
    let headerSpacing: CGFloat = 3
    let cellPadding = EdgeInsets(top: 5, leading: 9, bottom: 6, trailing: 9)
    let labelGap: CGFloat = 5
    let wordFont: Font = .system(size: 16)
    let labelFont: Font = .system(size: 9, weight: .medium)
    let headerFont: Font = .system(size: 10, weight: .medium)
    let headerTracking: CGFloat = 0.8

    let word: Color
    let wordSelected: Color
    let label: Color
    let labelSelected: Color
    let headerLead: Color
    let headerRest: Color
    let accent: Color
    /// A clearly visible edge on the panel and the selection (Increase Contrast, Show Borders).
    let border: Bool
    /// Light that blooms past a shape's edge; off under Reduce Bright Effects.
    let glow: Bool

    init(dark: Bool, access: PanelAccessibility = .init()) {
        self.dark = dark
        border = access.increaseContrast || access.showBorders
        glow = !access.reduceBrightEffects
        // Glass shifts with whatever is behind it, so dimmed text keeps enough strength to read;
        // the lens, not faintness, marks the choice. Increase Contrast firms everything up.
        let firm = access.increaseContrast
        if dark {
            word = .white.opacity(firm ? 0.85 : 0.6); wordSelected = .white
            label = .white.opacity(firm ? 0.7 : 0.45); labelSelected = .white.opacity(firm ? 0.9 : 0.7)
            headerLead = .white.opacity(firm ? 1 : 0.86); headerRest = .white.opacity(firm ? 0.7 : 0.36)
            accent = Color(hex: 0x96AAFF)
        } else {
            word = .black.opacity(firm ? 0.85 : 0.6); wordSelected = Color(hex: 0x0B0B0D)
            label = .black.opacity(firm ? 0.7 : 0.45); labelSelected = .black.opacity(firm ? 0.85 : 0.55)
            headerLead = .black.opacity(firm ? 1 : 0.82); headerRest = .black.opacity(firm ? 0.7 : 0.36)
            accent = Color(hex: 0x0A6CFF)
        }
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
