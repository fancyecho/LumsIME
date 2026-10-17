import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PanelModel {
    enum Mode { case candidates, toast }

    var theme: LumaTheme = LumaSettings.theme
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
    var toastText = ""
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

    private init() {
        window = NSPanel(contentRect: NSRect(origin: .zero, size: canvas),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true

        let host = NSHostingView(rootView: PanelRoot(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: canvas)
        window.contentView = host
    }

    func setTheme(_ theme: LumaTheme) {
        LumaSettings.theme = theme
        model.theme = theme
    }

    func show(_ st: RimeState, near caret: NSRect, onSelect: @escaping (Int) -> Void) {
        hideWork?.cancel()
        toastWork?.cancel()
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
        let selected = st.candidates.indices.contains(st.highlighted) ? st.candidates[st.highlighted].text : ""
        model.header = PinyinHeader.make(preedit: st.preedit, candidate: selected,
                                         apostrophes: model.theme == .precision)
        present(near: caret)
    }

    func hide() {
        guard model.mode == .candidates else { return }
        dismiss()
    }

    /// Briefly shows a mode indicator (中 / A) at the caret.
    func toast(_ text: String, near caret: NSRect) {
        if model.mode == .candidates && model.visible { return }
        hideWork?.cancel()
        toastWork?.cancel()
        model.mode = .toast
        model.toastText = text
        model.visible = false
        present(near: caret)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func present(near caret: NSRect) {
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
    }
}

// MARK: - Candidate bar

private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct WordFrameKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct CandidateBar: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme

    private var glide: Animation? {
        model.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    var body: some View {
        let s = ThemeStyle(model.theme, dark: scheme == .dark)
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
            ThemeBackground(style: s)
                .frame(width: model.barSize.width, height: model.barSize.height)
                // Grow quickly so text never spills outside; settle gently when shrinking.
                .animation(model.reduceMotion ? nil
                           : .spring(response: model.barGrowing ? 0.16 : 0.32, dampingFraction: 1),
                           value: model.barSize)
        }
    }

    private func cells(_ s: ThemeStyle) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, item in
                    CandidateCell(item: item, index: index, selected: index == model.highlighted, style: s)
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
                if s.theme != .ink, let anchor = anchors[model.highlighted] {
                    SelectionMark(rect: proxy[anchor], style: s)
                        .animation(glide, value: model.moveToken)
                }
            }
        }
        .backgroundPreferenceValue(WordFrameKey.self) { anchors in
            GeometryReader { proxy in
                if s.theme == .ink, let anchor = anchors[model.highlighted] {
                    InkUnderline(rect: proxy[anchor], style: s)
                        .animation(glide, value: model.moveToken)
                }
            }
        }
    }
}

private struct HeaderLine: View {
    let model: PanelModel
    let style: ThemeStyle

    var body: some View {
        let s = style
        let h = model.header
        let joint = h.lead.isEmpty || h.rest.isEmpty ? "" : (s.theme == .precision ? "'" : "\u{2002}")
        HStack(spacing: 0) {
            (Text(h.lead).foregroundStyle(s.headerLead) + Text(joint + h.rest).foregroundStyle(s.headerRest))
                .font(s.headerFont)
                .tracking(s.headerTracking)
                .lineLimit(1)
            if s.theme == .precision {
                Spacer(minLength: 18)
                Text("\(model.highlighted + 1)/\(model.candidates.count)" + (model.hasNext ? "  ⇥" : ""))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(s.headerRest)
                    .monospacedDigit()
            }
        }
    }
}

private struct CandidateCell: View {
    let item: RimeCandidateItem
    let index: Int
    let selected: Bool
    let style: ThemeStyle

    var body: some View {
        let s = style
        HStack(alignment: s.theme == .precision ? .center : .firstTextBaseline, spacing: s.labelGap) {
            label(s)
            Text(item.text)
                .font(s.wordFont)
                .tracking(s.wordTracking)
                .foregroundStyle(selected ? s.wordSelected : s.word)
                .anchorPreference(key: WordFrameKey.self, value: .bounds) { [index: $0] }
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

    @ViewBuilder
    private func label(_ s: ThemeStyle) -> some View {
        if s.theme == .precision {
            Text(item.label)
                .font(s.labelFont)
                .foregroundStyle(selected ? Color.white : s.label)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(selected ? s.accent : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selected ? Color.clear : s.keycapStroke, lineWidth: 0.5))
        } else {
            Text(item.label)
                .font(s.labelFont)
                .monospacedDigit()
                .foregroundStyle(selected ? s.labelSelected : s.label)
        }
    }
}

private struct PageMark: View {
    let model: PanelModel
    let style: ThemeStyle

    var body: some View {
        let s = style
        if (model.hasPrev || model.hasNext) && s.theme != .precision {
            Group {
                if s.theme == .ink {
                    HStack(spacing: 3) {
                        Text("‹").opacity(model.hasPrev ? 1 : 0.3)
                        Text("›").opacity(model.hasNext ? 1 : 0.3)
                    }
                    .font(.custom("Avenir Next", size: 13).weight(.medium))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.up").opacity(model.hasPrev ? 1 : 0.3)
                        Image(systemName: "chevron.down").opacity(model.hasNext ? 1 : 0.3)
                    }
                    .font(.system(size: 7.5, weight: .bold))
                }
            }
            .foregroundStyle(s.headerRest)
            .padding(.leading, s.theme == .ink ? 6 : 2)
            .padding(.trailing, 7)
        }
    }
}

// MARK: - Selection marks

/// 墨: a vermilion rule under the chosen word, like a proofreader's mark.
private struct InkUnderline: View {
    let rect: CGRect
    let style: ThemeStyle

    var body: some View {
        Capsule()
            .fill(style.accent)
            .frame(width: rect.width, height: 1.5)
            .shadow(color: style.dark ? style.accent.opacity(0.6) : .clear, radius: 5)
            .offset(x: rect.minX, y: rect.maxY + 3)
    }
}

/// 光: a lens of light under the glass. 刻: a tinted, ruled cell.
private struct SelectionMark: View {
    let rect: CGRect
    let style: ThemeStyle

    var body: some View {
        let s = style
        Group {
            if s.theme == .lumen {
                lens(s)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(s.accent.opacity(s.dark ? 0.16 : 0.09))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(s.accent.opacity(s.dark ? 0.55 : 0.38), lineWidth: 0.5))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private func lens(_ s: ThemeStyle) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if s.dark {
            ZStack {
                Ellipse()
                    .fill(Color(hex: 0x96AAFF, opacity: 0.5))
                    .frame(width: rect.width * 0.78, height: 14)
                    .blur(radius: 9)
                    .offset(y: rect.height / 2 + 1)
                    .blendMode(.plusLighter)
                shape
                    .fill(RadialGradient(colors: [.white.opacity(0.26), .white.opacity(0.07)],
                                         center: .top, startRadius: 0, endRadius: max(rect.width, 40)))
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06)],
                                                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
            }
        } else {
            shape
                .fill(LinearGradient(colors: [.white, .white.opacity(0.84)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5))
                .shadow(color: Color(hex: 0x281E5A, opacity: 0.22), radius: 9, y: 5)
                .shadow(color: .black.opacity(0.04), radius: 0.5, y: 0.5)
        }
    }
}

// MARK: - Toast

private struct ToastView: View {
    let model: PanelModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = ThemeStyle(model.theme, dark: scheme == .dark)
        let chinese = model.toastText == "中"
        Group {
            switch s.theme {
            case .ink:
                Text(model.toastText)
                    .font(chinese ? .custom("Songti SC", size: 21) : .custom("Avenir Next", size: 18).weight(.medium))
                    .foregroundStyle(s.wordSelected)
                    .frame(width: 46, height: 46)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(s.accent).frame(width: 12, height: 1.5).padding(.bottom, 8)
                    }
                    .background(ThemeBackground(style: s, radius: 12))
            case .lumen:
                Text(model.toastText)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(s.wordSelected)
                    .frame(width: 46, height: 46)
                    .background(ThemeBackground(style: s, radius: 23))
            case .precision:
                HStack(spacing: 7) {
                    Circle().fill(s.accent).frame(width: 6, height: 6)
                    Text(chinese ? "中" : "EN")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(s.wordSelected)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(ThemeBackground(style: s, radius: 9))
            }
        }
        .contentTransition(.opacity)
    }
}

// MARK: - Materials

private struct ThemeBackground: View {
    let style: ThemeStyle
    var radius: CGFloat?

    var body: some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius ?? s.radius, style: .continuous)
        switch s.theme {
        case .ink:
            shape
                .fill(s.dark ? Color(hex: 0x1A1816, opacity: 0.84) : Color(hex: 0xFBF9F5, opacity: 0.88))
                .background(VisualEffectBackground().clipShape(shape))
                .overlay(shape.strokeBorder(s.dark ? Color(hex: 0xFFECD6, opacity: 0.11) : Color(hex: 0x46321E, opacity: 0.14),
                                            lineWidth: 0.5))
                .overlay(topSheen(shape, s.dark ? 0.07 : 0))
                .shadow(color: s.dark ? .black.opacity(0.55) : Color(hex: 0x46321E, opacity: 0.2), radius: 18, y: 10)
                .shadow(color: .black.opacity(s.dark ? 0.3 : 0.05), radius: 1, y: 0.5)
        case .lumen:
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(s.dark ? .regular.tint(.black.opacity(0.32)) : .regular, in: shape)
                    .overlay(topSheen(shape, s.dark ? 0.16 : 0.5))
            } else {
                shape
                    .fill(s.dark ? Color.black.opacity(0.42) : Color.white.opacity(0.45))
                    .background(VisualEffectBackground().clipShape(shape))
                    .overlay(topSheen(shape, s.dark ? 0.16 : 0.6))
                    .shadow(color: .black.opacity(s.dark ? 0.5 : 0.16), radius: 22, y: 12)
            }
        case .precision:
            shape
                .fill(s.dark ? Color(hex: 0x1E1E21, opacity: 0.97) : Color.white.opacity(0.97))
                .overlay(shape.strokeBorder(s.dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1), lineWidth: 0.5))
                .overlay(topSheen(shape, s.dark ? 0.05 : 0))
                .shadow(color: .black.opacity(s.dark ? 0.55 : 0.18), radius: 16, y: 9)
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

// MARK: - Theme tokens

struct ThemeStyle {
    let theme: LumaTheme
    let dark: Bool

    var radius: CGFloat = 12
    var outerPadding = EdgeInsets()
    var headerInset: CGFloat = 8
    var headerSpacing: CGFloat = 4
    var cellPadding = EdgeInsets()
    var labelGap: CGFloat = 5
    var wordFont: Font = .system(size: 18)
    var wordTracking: CGFloat = 0
    var labelFont: Font = .system(size: 10)
    var headerFont: Font = .system(size: 11)
    var headerTracking: CGFloat = 0

    var word = Color.primary
    var wordSelected = Color.primary
    var label = Color.secondary
    var labelSelected = Color.primary
    var headerLead = Color.primary
    var headerRest = Color.secondary
    var accent = Color.accentColor
    var keycapStroke = Color.clear

    init(_ theme: LumaTheme, dark: Bool) {
        self.theme = theme
        self.dark = dark
        switch theme {
        case .ink:
            radius = 12
            outerPadding = EdgeInsets(top: 12, leading: 8, bottom: 11, trailing: 8)
            headerInset = 8
            headerSpacing = 3
            cellPadding = EdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
            wordFont = .custom("Songti SC", size: 20)
            wordTracking = 0.4
            labelFont = .custom("Avenir Next", size: 10).weight(.medium)
            headerFont = .custom("Avenir Next", size: 11).weight(.medium)
            headerTracking = 0.8
            if dark {
                word = Color(hex: 0xF4EADD, opacity: 0.4); wordSelected = Color(hex: 0xF6EDE1)
                label = Color(hex: 0xF4EADD, opacity: 0.28); labelSelected = Color(hex: 0xE6684D)
                headerLead = Color(hex: 0xEFE6DA); headerRest = Color(hex: 0x847B72); accent = Color(hex: 0xE6684D)
            } else {
                word = Color(hex: 0x201A14, opacity: 0.42); wordSelected = Color(hex: 0x1F1A15)
                label = Color(hex: 0x201A14, opacity: 0.32); labelSelected = Color(hex: 0xB4412C)
                headerLead = Color(hex: 0x3B332B); headerRest = Color(hex: 0x9A9086); accent = Color(hex: 0xB4412C)
            }
        case .lumen:
            radius = 18
            outerPadding = EdgeInsets(top: 12, leading: 7, bottom: 7, trailing: 7)
            headerInset = 11
            headerSpacing = 4
            cellPadding = EdgeInsets(top: 7, leading: 12, bottom: 8, trailing: 12)
            wordFont = .system(size: 18)
            labelFont = .system(size: 10, weight: .medium)
            headerFont = .system(size: 10.5, weight: .medium)
            headerTracking = 0.9
            if dark {
                word = .white.opacity(0.42); wordSelected = .white
                label = .white.opacity(0.28); labelSelected = .white.opacity(0.7)
                headerLead = .white.opacity(0.86); headerRest = .white.opacity(0.36); accent = Color(hex: 0x96AAFF)
            } else {
                word = .black.opacity(0.42); wordSelected = Color(hex: 0x0B0B0D)
                label = .black.opacity(0.26); labelSelected = .black.opacity(0.55)
                headerLead = .black.opacity(0.82); headerRest = .black.opacity(0.36); accent = Color(hex: 0x0A6CFF)
            }
        case .precision:
            radius = 10
            outerPadding = EdgeInsets(top: 10, leading: 6, bottom: 6, trailing: 6)
            headerInset = 6
            headerSpacing = 5
            cellPadding = EdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 10)
            labelGap = 7
            wordFont = .system(size: 16)
            labelFont = .system(size: 10, weight: .semibold, design: .monospaced)
            headerFont = .system(size: 11, weight: .medium, design: .monospaced)
            headerTracking = 0.2
            if dark {
                word = Color(hex: 0xB5B5BC); wordSelected = .white
                label = Color(hex: 0x8A8A92); labelSelected = .white
                headerLead = Color(hex: 0xD8D8DE); headerRest = Color(hex: 0x6F6F76)
                accent = Color(hex: 0x7B74FF); keycapStroke = .white.opacity(0.18)
            } else {
                word = Color(hex: 0x5C5C63); wordSelected = Color(hex: 0x0B0B0D)
                label = Color(hex: 0x8E8E95); labelSelected = .white
                headerLead = Color(hex: 0x2C2C30); headerRest = Color(hex: 0xA1A1A8)
                accent = Color(hex: 0x5E57E6); keycapStroke = .black.opacity(0.16)
            }
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
