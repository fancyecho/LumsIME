import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PanelModel {
    enum Mode { case candidates, toast }

    var mode: Mode = .candidates
    var glow = LumaSettings.glow
    var glass = LumaSettings.glass
    var candidates: [RimeCandidateItem] = []
    var highlighted = 0
    /// Bumped only when the selection moves within an unchanged list, so the highlight
    /// glides on arrow keys but tracks the text exactly while typing.
    var moveToken = 0
    /// Which way the selection last moved: 1 right, -1 left.
    var moveDirection: CGFloat = 1
    /// How far the lens is drawn out along its way, 1 at rest.
    var lensStretch: CGFloat = 1
    var pageNo = 0
    var pageDirection: CGFloat = 1
    var hasPrev = false
    var hasNext = false
    var header = PinyinHeader()
    /// AI assist is waiting on the model for this input.
    var aiPending = false
    var toastChinese = true
    var visible = false
    /// The window has settled on screen, so the content may animate. Until then every change lands
    /// at once: an animation begun as the window is ordered in can leave SwiftUI waiting on a frame
    /// that never comes, and the panel stays up with nothing drawn until it is ordered in again.
    var live = false
    /// How far in the panel has come, 0 to 1: it rises a little and settles as it fades in. Set
    /// along with the window's fade, frame by frame, never by a SwiftUI animation, so even a
    /// panel that gets no animation frames is drawn (just a touch small).
    var entry: CGFloat = 1
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
    private var returnWork: DispatchWorkItem?
    private var liveWork: DispatchWorkItem?
    private var fadeTimer: Timer?
    private var stretchTimer: Timer?
    private var drawnCheck: DispatchWorkItem?

    /// The engine whose candidates are up. Every text field and app has its own engine but they
    /// share this panel; only the one showing candidates may take them down, so a field being left
    /// or a client activated in the background can't hide what's being typed elsewhere.
    private weak var owner: AnyObject?
    /// The owner wants its candidates on screen: shown and not hidden since.
    private var wanted = false
    private var lastCaret = NSRect.zero
    /// When the window was last ordered in, so a fresh window gets time to report it's on screen.
    private var orderedIn = Date.distantPast

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
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    private func dropFromScreen() {
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        returnWork?.cancel()
        liveWork?.cancel()
        fadeTimer?.invalidate()
        fadeTimer = nil
        stopStretch()
        model.visible = false
        model.live = false
        window.orderOut(nil)
    }

    /// A desktop switch (or a full-screen app coming or going) mid-word used to leave the panel down
    /// until the next key. Bring the candidates back on the new desktop once the switch settles,
    /// unless the input ended meanwhile.
    private func spaceChanged() {
        let composing = wanted && model.mode == .candidates && !model.candidates.isEmpty
        LumaSettings.debugLog("panel: desktop changed\(composing ? ", candidates up: bringing them back" : "")")
        dropFromScreen()
        guard composing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, !self.model.visible else { return }
            self.present(near: self.lastCaret)
        }
        returnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func setGlow(_ glow: LumaGlow) {
        LumaSettings.glow = glow
        model.glow = glow
    }

    func setGlass(_ glass: LumaGlass) {
        LumaSettings.glass = glass
        model.glass = glass
    }

    func show(_ st: RimeState, pending: Bool = false, near caret: NSRect, for owner: AnyObject,
              onSelect: @escaping (Int) -> Void) {
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        returnWork?.cancel()
        // Chromium-based apps (Electron, browsers) update the caret's place asynchronously and
        // report an empty rect while they catch up, often as the pinyin wraps to a new line. Mid-word,
        // keep to where the caret last was rather than jumping to the mouse.
        let continuing = wanted && self.owner === owner
        let caret = !plausible(caret) && continuing && plausible(lastCaret) ? lastCaret : caret
        self.owner = owner
        wanted = true
        lastCaret = caret
        model.onSelect = onSelect
        if st.pageNo != model.pageNo {
            model.pageDirection = st.pageNo > model.pageNo ? 1 : -1
        } else if st.candidates == model.candidates, st.highlighted != model.highlighted, model.visible {
            model.moveDirection = st.highlighted > model.highlighted ? 1 : -1
            model.moveToken &+= 1
            stretchLens()
        }
        model.mode = .candidates
        model.candidates = st.candidates
        model.highlighted = st.highlighted
        model.pageNo = st.pageNo
        model.hasPrev = st.pageNo > 0
        model.hasNext = !st.isLastPage
        model.aiPending = pending
        let selected = st.candidates.indices.contains(st.highlighted) ? st.candidates[st.highlighted] : nil
        model.header = PinyinHeader.make(preedit: st.preedit, candidate: selected?.text ?? "",
                                         corrected: selected?.corrected)
        present(near: caret)
    }

    /// Takes the candidates down, if `owner` is the engine that put them up.
    func hide(for owner: AnyObject) {
        guard model.mode == .candidates else { return }
        guard self.owner == nil || self.owner === owner else {
            LumaSettings.debugLog("panel: hide from another engine ignored")
            return
        }
        wanted = false
        returnWork?.cancel()
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
            // After the window has settled (see settle()), or the glide would be dropped.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime + 0.06, execute: glide)
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func present(near caret: NSRect) {
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Up by its flags but not where it can be seen: left on another desktop, or moved to another
        // display while attached to the first one's desktop (isVisible and isOnActiveSpace still say
        // yes then; only occlusion tells). Take it down so ordering it in lands by the caret.
        let target = screen(for: caret)
        if window.isVisible {
            let otherDesktop = !window.isOnActiveSpace
            let otherDisplay = window.screen != nil && target != nil && window.screen != target
            let unseen = Date().timeIntervalSince(orderedIn) > 0.4 && !window.occlusionState.contains(.visible)
            if otherDesktop || otherDisplay || unseen {
                LumaSettings.debugLog("panel: up but not on screen (desktop \(otherDesktop), display \(otherDisplay), unseen \(unseen)): ordering in again")
                dropFromScreen()
            }
        }
        place(near: caret)
        LumaSettings.debugLog("panel: at caret \(caret.integral) → window \(window.frame.origin), display \(target?.frame ?? .zero)"
                              + "\(plausible(caret) ? "" : " (caret unusable: by the mouse)"), up \(window.isVisible), seen \(window.occlusionState.contains(.visible))")
        if LumaSettings.debugging { checkDrawn(after: 0.35) }
        guard !model.visible || !window.isVisible else { return }
        // The fade is the window's own. The content is always drawn in full: its
        // being seen must not hang on a SwiftUI animation getting its frames as the window comes in.
        if !window.isVisible { fade(to: 0, over: 0) }
        window.orderFrontRegardless()
        orderedIn = Date()
        model.visible = true
        fade(to: 1, over: model.reduceMotion ? 0 : 0.2)
        settle()
    }

    private static let settleTime = 0.2

    /// Lets the content animate once the window is really on screen. If it never reports being
    /// seen, the candidates stay as they are, readable but still.
    private func settle(tries: Int = 0) {
        liveWork?.cancel()
        guard !model.live else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.visible, self.window.isVisible else { return }
            if self.window.occlusionState.contains(.visible) {
                self.model.live = true
            } else if tries < 10 {
                self.settle(tries: tries + 1)
            } else {
                LumaSettings.debugLog("panel: up but never reported seen: left without animation")
            }
        }
        liveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? Self.settleTime : 0.1), execute: work)
    }

    /// The window's fade, stepped by a plain timer and the clock: it asks nothing of the display or
    /// of an animation being picked up as the window comes in, so it always arrives.
    private func fade(to target: CGFloat, over duration: TimeInterval, easeIn: Bool = false) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let from = window.alphaValue
        guard duration > 0, from != target else {
            window.alphaValue = target
            model.entry = model.reduceMotion ? 1 : target
            return
        }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.fadeTimer === timer else { return timer.invalidate() }
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = easeIn ? t * t : 1 - (1 - t) * (1 - t)
                self.window.alphaValue = from + (target - from) * eased
                self.model.entry = self.model.reduceMotion ? 1 : self.window.alphaValue
                if t >= 1 {
                    timer.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// The lens drawn out like a drop as it moves, then gathering itself with a little give. Each
    /// frame is set outright from the clock, and the last sets it back to rest, so it can't stick.
    private func stretchLens() {
        stopStretch()
        guard model.live, !model.reduceMotion else { return }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.stretchTimer === timer else { return timer.invalidate() }
                let t = CACurrentMediaTime() - start
                if t >= 0.45 { return self.stopStretch() }
                let rise = 0.1
                self.model.lensStretch = t < rise
                    ? 1 + 0.16 * (1 - pow(1 - t / rise, 2))
                    : 1 + 0.16 * exp(-(t - rise) * 9) * cos((t - rise) * 16)
            }
        }
        stretchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopStretch() {
        stretchTimer?.invalidate()
        stretchTimer = nil
        model.lensStretch = 1
    }

    /// Diagnosis only (with debugKeys on): a moment after showing, whether the panel was actually
    /// drawn, read from the window's own pixels.
    private func checkDrawn(after delay: TimeInterval, again: Bool = false) {
        drawnCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.visible, self.window.isVisible else { return }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(self.window.windowNumber),
                                                      [.boundsIgnoreFraming, .nominalResolution]),
                  let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data) else {
                return LumaSettings.debugLog("panel: drawn? (no capture)")
            }
            var opaque = 0
            let row = image.bytesPerRow, step = image.bitsPerPixel / 8
            for y in stride(from: 0, to: image.height, by: 3) {
                for x in stride(from: 0, to: image.width, by: 3) where pixels[y * row + x * step + 3] > 40 { opaque += 1 }
            }
            guard opaque <= 20 else { return LumaSettings.debugLog("panel: drawn (\(opaque))\(again ? " on a second look" : "")") }
            LumaSettings.debugLog("panel: \(again ? "still " : "")NOTHING DRAWN while up (\(opaque)), alpha \(self.window.alphaValue), "
                                  + "live \(self.model.live), seen \(self.window.occlusionState.contains(.visible)), "
                                  + String(format: "%.2fs after ordering in", Date().timeIntervalSince(self.orderedIn)))
            // Once more, to tell a moment's gap from a panel that stays empty.
            if !again { self.checkDrawn(after: 0.3, again: true) }
        }
        drawnCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismiss() {
        guard model.visible || window.isVisible else { return }
        liveWork?.cancel()
        stopStretch()
        model.visible = false
        model.live = false
        fade(to: 0, over: 0.12, easeIn: true)
        // Two hides in a row (a commit, then a key that refreshes again) must not leave the first
        // order-out pending: show() cancels only the latest, and the stray one would take the panel
        // off screen under candidates still being typed. Check again when it fires, too.
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.window.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    /// A caret the app really reported: not the zero rect some apps give when they don't know, and
    /// on a display.
    private func plausible(_ caret: NSRect) -> Bool {
        caret.origin != .zero && NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(caret.origin) }
    }

    /// The caret, or the mouse for apps (terminals, Electron) that report no caret.
    private func caretOrMouse(_ caret: NSRect) -> NSRect {
        guard !plausible(caret) else { return caret }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 18, width: 0, height: 18)
    }

    private func screen(for caret: NSRect) -> NSScreen? {
        let rect = caretOrMouse(caret)
        return NSScreen.screens.first { $0.frame.contains(rect.origin) } ?? NSScreen.main
    }

    private func place(near caret: NSRect) {
        let rect = caretOrMouse(caret)
        guard let visible = screen(for: caret)?.visibleFrame else { return }

        // The last size measured may be the small 中 / A switch or a bar not yet filled; deciding by it
        // near the bottom of the screen would open the candidates downward, off the edge.
        let measured = model.contentSize == .zero ? CGSize(width: 420, height: 70) : model.contentSize
        let size = model.mode == .candidates ? CGSize(width: max(measured.width, 200), height: max(measured.height, 64)) : measured
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
        let live = model.live
        ZStack(alignment: model.flipped ? .bottomLeading : .topLeading) {
            Color.clear
            Group {
                switch model.mode {
                case .candidates: CandidateBar(model: model)
                case .toast: ToastView(model: model)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSize = $0 }
            // Rises toward the caret's side and settles as it fades in; sinks back as it fades out.
            .scaleEffect(0.965 + 0.035 * model.entry, anchor: model.flipped ? .bottomLeading : .topLeading)
            .offset(y: (1 - model.entry) * (model.flipped ? 6 : -6))
            .padding(CandidatePanel.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        animated ? .spring(response: 0.3, dampingFraction: 1) : nil
    }

    private var animated: Bool { model.live && !model.reduceMotion }

    var body: some View {
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: model.glow, glass: model.glass)
        let motion = FlowMotion(style: s, reduceMotion: model.reduceMotion, shown: model.live)
        VStack(alignment: .leading, spacing: s.headerSpacing) {
            HeaderLine(model: model, style: s)
                .padding(.horizontal, s.headerInset)
            HStack(alignment: .center, spacing: 0) {
                cells(s, motion)
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
        // Read the lens's place at the bar's level, so the glass knows where its light comes from.
        .backgroundPreferenceValue(CellFrameKey.self) { anchors in
            GeometryReader { proxy in
                GlassPlate(style: s, radius: s.radius, motion: motion,
                           light: anchors[model.highlighted].map { proxy[$0] })
                    .frame(width: model.barSize.width, height: model.barSize.height)
                    // Grow quickly so text never spills outside; settle gently when shrinking.
                    .animation(animated ? .spring(response: model.barGrowing ? 0.16 : 0.32, dampingFraction: 1) : nil,
                               value: model.barSize)
                    .frame(width: proxy.size.width, height: proxy.size.height,
                           alignment: model.flipped ? .bottomLeading : .topLeading)
            }
        }
    }

    private func cells(_ s: LumenStyle, _ motion: FlowMotion) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, item in
                    CandidateCell(item: item, selected: index == model.highlighted, style: s, animated: animated)
                        .anchorPreference(key: CellFrameKey.self, value: .bounds) { [index: $0] }
                        .contentShape(Rectangle())
                        .onTapGesture { if model.visible { model.onSelect?(index) } }
                }
            }
            .id(model.pageNo)
            .transition(.asymmetric(
                insertion: .offset(x: 14 * model.pageDirection).combined(with: .opacity),
                removal: .offset(x: -14 * model.pageDirection).combined(with: .opacity)))
        }
        .animation(animated ? .spring(response: 0.32, dampingFraction: 1) : nil, value: model.pageNo)
        .backgroundPreferenceValue(CellFrameKey.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors[model.highlighted] {
                    let rect = proxy[anchor]
                    // Concentric with the bar: its radius less the inset between them.
                    Lens(size: rect.size, radius: s.radius - s.outerPadding.bottom, style: s, motion: motion)
                        // Like a drop of liquid: it draws out along the way it is going and gathers
                        // itself again as it arrives.
                        // (Stepped by CandidatePanel.stretchLens(), not a SwiftUI keyframe animation:
                        // those could stop partway in this panel and leave the view stuck.)
                        .scaleEffect(x: model.lensStretch, y: 1 - (model.lensStretch - 1) * 0.6,
                                     anchor: model.moveDirection > 0 ? .trailing : .leading)
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
        HStack(spacing: 5) {
            (lead + Text(joint + h.rest).foregroundStyle(s.headerRest))
                .font(s.headerFont)
                .tracking(s.headerTracking)
                .lineLimit(1)
            if model.aiPending {
                // AI assist is thinking about this input.
                Image(systemName: "sparkle")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(s.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: model.live && !model.reduceMotion)
                    .transition(.opacity)
            }
        }
        .modifier(Halo(style: s, off: false))
        .animation(model.live ? .easeOut(duration: 0.2) : nil, value: model.aiPending)
    }
}

/// A soft halo of the opposite tone around text, so it holds against whatever shows through the
/// glass: a close one that firms up each stroke, and for 通透 a wider one that lifts the word off
/// a busy or contrary page behind.
private struct Halo: ViewModifier {
    let style: LumenStyle
    let off: Bool

    func body(content: Content) -> some View {
        let s = style
        content
            .shadow(color: off ? .clear : s.textShadow, radius: 1.2, y: s.dark ? 0.5 : 0)
            .shadow(color: off || !s.clearGlass ? .clear : s.textShadow.opacity(0.8), radius: 5)
    }
}

private struct CandidateCell: View {
    let item: RimeCandidateItem
    let selected: Bool
    let style: LumenStyle
    let animated: Bool

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
                    if item.ai {
                        // From AI assist: a small spark of the accent.
                        Image(systemName: "sparkle")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(s.accent)
                            .opacity(selected ? 1 : 0.7)
                            .offset(x: 7, y: 0)
                    } else if item.corrected != nil {
                        // A typo correction: a small accent dot, like an editor's mark.
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
        .modifier(Halo(style: s, off: selected && !s.dark))
        .padding(s.cellPadding)
        .animation(animated ? .easeOut(duration: 0.18) : nil, value: selected)
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

/// The lens of light under the glass that marks the current choice. With a 光效 it is the light's
/// source: its glow takes 柔光's tint, or the hue 流光 is passing through.
private struct Lens: View {
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
                lens(glow: Spectrum.color(at: motion.time(context.date) / Spectrum.period, dark: style.dark))
            }
        }
    }

    /// `glow` nil is the plain lens: a moonlit blue in the dark, an ink-blue shadow in the light.
    /// It is a drop of glass: lit from above along its top edge, and gathering its light (the glow's
    /// colour) in a caustic along the bottom, where a real lens would focus it.
    private func lens(glow: Color?) -> some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let caustic = (glow ?? (s.dark ? Color(hex: 0x96AAFF) : Color(hex: 0x6C8CFF)))
        return ZStack {
            if s.dark && s.bloom {
                Ellipse()
                    .fill(caustic.opacity(glow == nil ? 0.5 : 0.7))
                    .frame(width: size.width * 0.78, height: min(12, size.height * 0.5))
                    .blur(radius: 8)
                    .offset(y: size.height / 2 + 1)
                    .blendMode(.plusLighter)
            }
            shape
                .fill(s.dark
                      ? AnyShapeStyle(RadialGradient(colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                                     center: .top, startRadius: 0, endRadius: max(size.width, 40)))
                      : AnyShapeStyle(LinearGradient(colors: [.white.opacity(s.clearGlass ? 0.82 : 0.96), .white.opacity(s.clearGlass ? 0.5 : 0.82)],
                                                     startPoint: .top, endPoint: .bottom)))
                .overlay {
                    // The caustic, inside along the bottom edge.
                    if s.bloom {
                        shape.fill(LinearGradient(stops: [.init(color: caustic.opacity(0), location: 0.45),
                                                          .init(color: caustic.opacity(s.dark ? 0.32 : 0.22), location: 1)],
                                                  startPoint: .top, endPoint: .bottom))
                            .blendMode(s.dark ? .plusLighter : .normal)
                    }
                }
                .overlay {
                    if s.border {
                        shape.strokeBorder(s.dark ? Color.white.opacity(0.7) : Color.black.opacity(0.5), lineWidth: 1)
                    } else {
                        // Light along the top edge, a darker line along the bottom: a rounded edge.
                        shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(s.dark ? 0.5 : 1), location: 0),
                                                                  .init(color: .white.opacity(s.dark ? 0.06 : 0.2), location: 0.5),
                                                                  .init(color: (s.dark ? Color.white : Color.black).opacity(s.dark ? 0.12 : 0.08), location: 1)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                    }
                }
                .shadow(color: s.dark ? .black.opacity(0.5) : (glow.map { $0.opacity(s.bloom ? 0.4 : 0.2) } ?? Color(hex: 0x281E5A, opacity: 0.24)),
                        radius: s.dark ? 10 : 9, y: s.dark ? 6 : 5)
                .shadow(color: .black.opacity(s.dark ? 0 : 0.04), radius: 0.5, y: 0.5)
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
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: model.glow, glass: model.glass)
        let motion = FlowMotion(style: s, reduceMotion: model.reduceMotion, shown: model.live)
        let segment = Self.segment, inset = Self.inset
        let lensX = model.toastChinese ? 0 : segment.width
        HStack(spacing: 0) {
            glyph("中", font: .system(size: 12.5, weight: .medium), on: model.toastChinese, s)
            glyph("A", font: .system(size: 12, weight: .semibold, design: .rounded), on: !model.toastChinese, s)
        }
        .background(alignment: .leading) {
            Lens(size: segment, radius: segment.height / 2, style: s, motion: motion)
                .offset(x: lensX)
        }
        .padding(inset)
        .background {
            GlassPlate(style: s, radius: segment.height / 2 + inset, motion: motion,
                       light: CGRect(origin: CGPoint(x: inset + lensX, y: inset), size: segment))
        }
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

/// The glass, lit by its 光效 from within. The lens is the light's source: light pools in the glass
/// around it, the rim catches it only where it falls, and a little escapes past the edge nearby.
/// The light drifts after the lens as it moves; it doesn't flare with keystrokes, so it stays steady.
private struct GlassPlate: View {
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
                // outside it: underneath, the glass would sample it and re-tint itself all at once
                // whenever the light crossed its threshold, a sudden brightening of the whole panel.
                // In the dark it is a glow hugging the edge. On a light page light can't brighten
                // anything, so it falls below the glass as a shadow in the light's colour.
                pool.mask { shape.stroke(lineWidth: 10).blur(radius: 6) }
                    .blur(radius: s.dark ? 6 : 9)
                    .offset(y: s.dark ? 0 : 5)
                    .mask { Outside(shape: shape) }
                    .opacity(s.dark ? 0.7 : 0.5)
            }
            if s.effect != .off {
                Group {
                    if s.bloom {
                        // A faint wash through the body of the glass, which stays clear,
                        pool.clipShape(shape)
                            .blendMode(s.dark ? .plusLighter : .normal)
                            .opacity(s.dark ? 0.26 : 0.34)
                        // and more of it gathered along the edge, as cut glass carries light.
                        pool.mask { shape.strokeBorder(lineWidth: 6).blur(radius: 4) }
                            .clipShape(shape)
                            .blendMode(s.dark ? .plusLighter : .normal)
                            .opacity(s.dark ? 0.6 : 0.55)
                    }
                    // The rim catches the light where it falls, and stays dark elsewhere.
                    pool.mask { shape.strokeBorder(lineWidth: 1.25) }
                        .opacity(s.dark ? 1 : 0.9)
                }
            }
        }
    }
}

/// Everything around `shape`, out to the edge of the panel's margin: a mask for what must fall
/// only outside the glass.
private struct Outside: View {
    let shape: RoundedRectangle

    var body: some View {
        ZStack {
            Rectangle().padding(-CandidatePanel.margin)
            shape.blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

/// Soft pools of light in the glass: one around the lens, and for 流光 two more in the hues to
/// come, drifting slowly through the glass like an aurora.
private struct LightPool: View {
    let style: LumenStyle
    let light: CGRect?
    let time: TimeInterval

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let lens = light ?? CGRect(x: size.width * 0.15, y: 0, width: min(80, size.width * 0.3), height: size.height)
            let source = CGPoint(x: lens.midX, y: lens.midY + lens.height * 0.15)
            let turn = time / Spectrum.period
            // Sized to the glass, so a small plate (the 中 / A switch) isn't flooded.
            let reach = max(lens.width * 0.9, min(48, size.height * 0.9))
            ZStack {
                if style.effect == .flow {
                    // The drifting pools need room; on the small switch the lens's light is enough.
                    ForEach(size.width > 120 ? 1..<3 : 1..<1, id: \.self) { k in
                        let drift = time * 2 * .pi
                        let at = CGPoint(x: size.width * (0.5 + 0.42 * sin(drift / (17 + 5 * Double(k)) + 2.4 * Double(k))),
                                         y: size.height * (0.5 + 0.3 * cos(drift / (13 + 4 * Double(k)) + Double(k))))
                        glow(Spectrum.color(at: turn + Double(k) / 3, dark: style.dark), at: at,
                             radius: size.height * 1.1, strength: 0.55)
                    }
                    glow(Spectrum.color(at: turn, dark: style.dark), at: source, radius: reach, strength: 1)
                } else {
                    glow(style.tint, at: source, radius: reach, strength: 1)
                }
            }
        }
    }

    /// A pool of `color`, widest along the glass, fading to nothing at `radius`.
    private func glow(_ color: Color, at point: CGPoint, radius: CGFloat, strength: Double) -> some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: color.opacity(strength), location: 0),
                                         .init(color: color.opacity(strength * 0.4), location: 0.45),
                                         .init(color: color.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(x: 1.6, y: 1)
            .position(point)
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
    static func color(at turn: Double, dark: Bool) -> Color {
        let (lightness, chroma) = dark ? (0.78, 0.14) : (0.8, 0.14)
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

private struct GlassBackground: View {
    let style: LumenStyle
    let radius: CGFloat

    var body: some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) {
                // 通透 is the system's glass as it comes: it already blurs what lies behind and adjusts
                // its brightness to keep text legible, and in the dark it lifts a little off the page
                // rather than going black. It reads as glass by light at its edges, not by a fill: a
                // bright line along the top, a fainter one where light reflects inside the bottom
                // edge, and a breath of sheen across the top. The text carries its own halo.
                // 柔雾 lays a veil of the scheme's own tone over it, for a calmer, more even panel.
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .overlay { shape.fill(s.veil) }
                    .overlay {
                        // Sheen: light falling across the top of the glass.
                        shape.fill(LinearGradient(stops: [.init(color: .white.opacity(s.dark ? 0.07 : 0.22), location: 0),
                                                          .init(color: .white.opacity(0), location: 0.4)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                    .overlay { rim(shape) }
                    .overlay {
                        // Its shadow, outside only (under the glass it would be sampled and grey it),
                        // and light: a heavy shadow makes glass look solid.
                        shape.fill(Color.black.opacity(s.dark ? 0.3 : 0.1))
                            .blur(radius: 14)
                            .offset(y: 7)
                            .mask { Outside(shape: shape) }
                    }
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

    /// The edge of the glass, lit from above: bright along the top, fading down the sides, and a
    /// fainter line again inside the bottom edge where the light reflects. On a light page a faint
    /// dark line beneath keeps the edge from melting into white.
    private func rim(_ shape: RoundedRectangle) -> some View {
        let s = style
        return ZStack {
            if !s.dark {
                shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
            }
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(s.dark ? 0.42 : 0.95), location: 0),
                                                      .init(color: .white.opacity(s.dark ? 0.08 : 0.3), location: 0.38),
                                                      .init(color: .white.opacity(s.dark ? 0.04 : 0.15), location: 0.62),
                                                      .init(color: .white.opacity(s.dark ? 0.16 : 0.55), location: 1)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: s.dark ? 0.75 : 1)
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
    /// Under the text, so it holds against whatever shows through the glass.
    let textShadow: Color
    /// Laid over the glass: toward white in the light, toward black in the dark.
    let veil: LinearGradient
    /// 通透: the glass bare but for light at its edges, and the text haloed.
    let clearGlass: Bool
    /// A clearly visible edge on the panel and the selection (Increase Contrast, Show Borders).
    let border: Bool
    /// Light that blooms past a shape's edge; off under Reduce Bright Effects.
    let bloom: Bool
    /// 光效, and 柔光's colour: the accent colour chosen in System Settings.
    let effect: LumaGlow
    let tint = Color(nsColor: .controlAccentColor)

    init(dark: Bool, access: PanelAccessibility = .init(), effect: LumaGlow = .off, glass: LumaGlass = .frosted) {
        self.dark = dark
        self.effect = effect
        border = access.increaseContrast || access.showBorders
        bloom = !access.reduceBrightEffects
        // Glass shifts with whatever is behind it, so dimmed text keeps enough strength to read;
        // the lens, not faintness, marks the choice. Increase Contrast firms everything up.
        let firm = access.increaseContrast
        // 通透 leaves the glass bare but for a breath of veil, and the text holds its own instead:
        // stronger, with a halo of the opposite tone. Increase Contrast always gets the full veil.
        let clear = glass == .clear && !firm
        clearGlass = clear
        if dark {
            word = .white.opacity(firm ? 0.92 : clear ? 0.88 : 0.8); wordSelected = .white
            label = .white.opacity(firm ? 0.75 : 0.5); labelSelected = .white.opacity(firm ? 0.9 : 0.72)
            headerLead = .white.opacity(firm ? 1 : 0.9); headerRest = .white.opacity(firm ? 0.75 : 0.45)
            accent = Color(hex: 0xA5B6FF)
            textShadow = .black.opacity(clear ? 0.65 : 0.4)
            veil = LinearGradient(colors: [.black.opacity(firm ? 0.7 : clear ? 0 : 0.4), .black.opacity(firm ? 0.76 : clear ? 0 : 0.52)],
                                  startPoint: .top, endPoint: .bottom)
        } else {
            word = .black.opacity(firm ? 0.9 : clear ? 0.82 : 0.74); wordSelected = Color(hex: 0x0B0B0D)
            label = .black.opacity(firm ? 0.72 : 0.46); labelSelected = .black.opacity(firm ? 0.85 : 0.55)
            headerLead = .black.opacity(firm ? 1 : 0.84); headerRest = .black.opacity(firm ? 0.72 : 0.42)
            accent = Color(hex: 0x0A6CFF)
            textShadow = clear ? .white.opacity(0.85) : .clear
            veil = LinearGradient(colors: [.white.opacity(firm ? 0.85 : clear ? 0 : 0.64), .white.opacity(firm ? 0.8 : clear ? 0 : 0.5)],
                                  startPoint: .top, endPoint: .bottom)
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
