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
    var skin = LumaSettings.skin
    var showPinyin = LumaSettings.showPinyin
    var candidates: [RimeCandidateItem] = []
    var highlighted = 0
    /// Bumped only when the selection moves within an unchanged list, so the highlight
    /// glides on arrow keys but tracks the text exactly while typing.
    var moveToken = 0
    /// Which way the selection last moved: 1 right, -1 left.
    var moveDirection: CGFloat = 1
    /// How far the lens is drawn out along its way, 1 at rest.
    var lensStretch: CGFloat = 1
    /// A glint of light crossing the glass as the words change, 0 to 1 of the way; nil at rest.
    var glint: CGFloat?
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
    private var glintTimer: Timer?
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
        stopGlint()
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

    func setShowPinyin(_ show: Bool) {
        LumaSettings.showPinyin = show
        model.showPinyin = show
    }

    func setSkin(_ skin: LumaSkin) {
        LumaSettings.skin = skin
        model.skin = skin
        // Each skin has its own 光效.
        model.glow = LumaSettings.glow
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
        } else if st.candidates != model.candidates, model.visible, model.mode == .candidates {
            sendGlint()
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

    /// A glint of light across the glass's edge when the words change, as if each key sent light
    /// through it. One at a time: a key struck while one is crossing lets it finish, so fast typing
    /// is a steady shimmer rather than a flicker. Stepped from the clock like the lens's stretch,
    /// and its last frame always puts it away.
    private func sendGlint() {
        guard glintTimer == nil, model.live, !model.reduceMotion, model.glow == .flow, model.skin == .crystal else { return }
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.glintTimer === timer else { return timer.invalidate() }
                let t = (CACurrentMediaTime() - start) / 0.55
                if t >= 1 { return self.stopGlint() }
                self.model.glint = 1 - pow(1 - t, 2)
            }
        }
        glintTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopGlint() {
        glintTimer?.invalidate()
        glintTimer = nil
        model.glint = nil
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
        stopGlint()
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
    var reduceTransparency = false
}

extension EnvironmentValues {
    @Entry var panelAccessibility = PanelAccessibility()
}

/// Gathers the settings into one environment value, so each view builds its style from a single read.
private struct AccessibilityReader: ViewModifier {
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

// MARK: - Candidate bar

private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The bar's text is drawn more than once. `.frame` lays it out, takes clicks and shows the marks
/// that keep their own colour; its text is clear. `.ink` draws the same text as a solid shape for
/// `Ink` to fill, and `.dim` draws it again by how far each piece falls short of full strength.
private enum Pass { case frame, ink, dim }

private extension Pass {
    /// Text that takes the ink at `strength`, 0 to 1.
    func ink(_ strength: Double) -> Color {
        switch self {
        case .frame: .clear
        case .ink: .white
        case .dim: .white.opacity(1 - strength)
        }
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
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: model.glow, glass: model.glass, skin: model.skin)
        let motion = FlowMotion(style: s, reduceMotion: model.reduceMotion, shown: model.live)
        content(s, motion, .frame)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
                // (withAnimation here stalls rendering; the background animates itself below.)
                model.barGrowing = newSize.width > model.barSize.width
                model.barSize = newSize
            }
            // Read the lens's place at the bar's level, so the glass knows where its light comes from.
            .backgroundPreferenceValue(CellFrameKey.self) { anchors in
                GeometryReader { proxy in
                    GlassPlate(style: s, radius: s.radius, motion: motion,
                               light: anchors[model.highlighted].map { proxy[$0] }, glint: model.glint)
                        .frame(width: model.barSize.width, height: model.barSize.height)
                        // Grow quickly so text never spills outside; settle gently when shrinking.
                        .animation(animated ? .spring(response: model.barGrowing ? 0.16 : 0.32, dampingFraction: 1) : nil,
                                   value: model.barSize)
                        .frame(width: proxy.size.width, height: proxy.size.height,
                               alignment: model.flipped ? .bottomLeading : .topLeading)
                }
            }
            // The text itself, last, so it reads everything beneath it: glass, light and lens.
            .overlay { Ink(style: s) { content(s, motion, $0) } }
    }

    private func content(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        VStack(alignment: .leading, spacing: s.headerSpacing) {
            if model.showPinyin {
                HeaderLine(model: model, style: s, pass: pass)
                    .padding(.horizontal, s.headerInset)
            }
            HStack(alignment: .center, spacing: 0) {
                cells(s, motion, pass)
                if !model.showPinyin && model.aiPending {
                    // AI assist is thinking about this input (the pinyin line shows it otherwise).
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(pass == .frame ? s.accent : .clear)
                        .symbolEffect(.pulse, options: .repeating, isActive: pass == .frame && model.live && !model.reduceMotion)
                        .padding(.horizontal, 4)
                }
                PageMark(model: model, pass: pass)
            }
        }
        // Without the pinyin line the candidates sit evenly in the glass.
        .padding(model.showPinyin ? s.outerPadding : EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
        .fixedSize()
    }

    private func cells(_ s: LumenStyle, _ motion: FlowMotion, _ pass: Pass) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(Array(model.candidates.enumerated()), id: \.offset) { index, item in
                    let cell = CandidateCell(item: item, selected: index == model.highlighted, style: s, pass: pass)
                    if pass == .frame {
                        cell.anchorPreference(key: CellFrameKey.self, value: .bounds) { [index: $0] }
                            .contentShape(Rectangle())
                            .onTapGesture { if model.visible { model.onSelect?(index) } }
                    } else {
                        cell
                    }
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
                if pass == .frame, let anchor = anchors[model.highlighted] {
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

/// Ink that answers to what is behind it. Whatever `content` draws becomes its shape, and each
/// point of it turns white where the glass beneath is dark and black where it is light, so the
/// text holds on any page, in either appearance, with nothing laid under it and no halo round it.
///
/// The window server does the work, a blend at a time against the live picture under the text:
/// take its brightness, turn it over, and stretch the middle until only black and white are left.
private struct Ink<Content: View>: View {
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
            layer(Color(white: 0.5), .saturation)
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
                // AI assist is thinking about this input.
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
    let style: LumenStyle
    let pass: Pass

    var body: some View {
        let s = style
        HStack(alignment: .firstTextBaseline, spacing: s.labelGap) {
            Text(item.label)
                .font(s.labelFont)
                .monospacedDigit()
                .foregroundStyle(pass.ink(selected ? s.labelSelected : s.label))
            Text(item.text)
                .font(s.wordFont)
                .foregroundStyle(pass.ink(selected ? 1 : s.word))
                .overlay(alignment: .topTrailing) {
                    if pass == .frame {
                        if item.ai {
                            // From AI assist: a small spark of the accent.
                            Image(systemName: "sparkle")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(s.accent)
                                .opacity(selected ? 1 : 0.8)
                                .offset(x: 7, y: 0)
                        } else if item.corrected != nil {
                            // A typo correction: a small accent dot, like an editor's mark.
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
        }
        .lineLimit(1)
        .fixedSize()
        .padding(s.cellPadding)
    }
}

private struct PageMark: View {
    let model: PanelModel
    let pass: Pass

    var body: some View {
        if model.hasPrev || model.hasNext {
            VStack(spacing: 2) {
                Image(systemName: "chevron.up").foregroundStyle(pass.ink(model.hasPrev ? 0.6 : 0.2))
                Image(systemName: "chevron.down").foregroundStyle(pass.ink(model.hasNext ? 0.6 : 0.2))
            }
            .font(.system(size: 7.5, weight: .bold))
            .padding(.leading, 2)
            .padding(.trailing, 7)
        }
    }
}

// MARK: - Lens

/// The lens that marks the current choice: a drop of glass lying on the plate. With a 光效 it is
/// the light's source: it takes 柔光's tint, or the hue 流光 is passing through.
///
/// Like the ink, it is made of blends rather than paint, so it shows on any page: its body pulls
/// what is under it a little toward the middle (a touch darker on a light page, lighter on a dark
/// one), its highlights only add light, and its edge line is the reverse of whatever it crosses.
private struct Lens: View {
    let size: CGSize
    let radius: CGFloat
    let style: LumenStyle
    let motion: FlowMotion

    var body: some View {
        switch style.effect {
        case .off: lens(glow: nil)
        case .soft: lens(glow: style.lensTint)
        case .flow:
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: motion.paused)) { context in
                lens(glow: Spectrum.color(at: motion.time(context.date) / Spectrum.period))
            }
        }
    }

    /// 磨砂's mark: no drop and no edge, only light behind the frosted glass where the chosen word
    /// is, fading out all round. A shape with an outline here reads as a box inside a box.
    private func glowLens(glow: Color?) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            shape.fill(Color.white.opacity(style.border ? 0.3 : 0.21))
                .padding(.horizontal, 2)
                .blur(radius: 6)
                .blendMode(.plusLighter)
            // Held just short of full white, so on a light page the glow is soft, not a glare.
            shape.fill(Color(white: 0.94))
                .padding(.horizontal, 2)
                .blur(radius: 6)
                .blendMode(.multiply)
            if let glow {
                // The 光效's colour in the light: a stain on a light page, a tint of glow on a dark one.
                shape.fill(glow.opacity(0.3)).blur(radius: 7).blendMode(.multiply)
                shape.fill(glow.opacity(0.1)).blur(radius: 7).blendMode(.plusLighter)
            }
            if style.border {
                shape.strokeBorder(Color.white.opacity(0.6), lineWidth: 1).blendMode(.difference)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private func lens(glow: Color?) -> some View {
        if style.softLens { glowLens(glow: glow) } else { dropLens(glow: glow) }
    }

    private func dropLens(glow: Color?) -> some View {
        let s = style
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack {
            if let glow, s.bloom {
                // Its light gathered beneath it, as a real lens focuses it: a glow on a dark page,
                // a shadow in the light's colour on a light one.
                Ellipse()
                    .fill(glow.opacity(0.75 * s.glowAmount))
                    .frame(width: size.width * 0.8, height: min(12, size.height * 0.5))
                    .blur(radius: 7)
                    .offset(y: size.height / 2)
                    .mask { Outside(shape: shape, reach: 24) }
            }
            // The drop's own shadow, round it only.
            shape.fill(Color.black.opacity(0.2))
                .blur(radius: 4)
                .offset(y: 2.5)
                .mask { Outside(shape: shape, reach: 24) }
            // Its body.
            shape.fill(Color.white.opacity(s.border ? 0.24 : 0.09)).blendMode(.difference)
            if let glow {
                // The light it carries, pooling toward the bottom. It stains what is under it
                // rather than painting over it: strong colour on a light page, where there is
                // brightness to spare, and a deep tint on a dark one, so the word on it stays
                // clearly on one side of the ink's turning point. A little of it also shines.
                shape.fill(LinearGradient(stops: [.init(color: glow.opacity(0.16), location: 0),
                                                  .init(color: glow.opacity(0.32), location: 1)],
                                          startPoint: .top, endPoint: .bottom))
                    .blendMode(.multiply)
                shape.fill(LinearGradient(stops: [.init(color: glow.opacity(0.04), location: 0.3),
                                                  .init(color: glow.opacity((s.bloom ? 0.2 : 0.1) * s.glowAmount), location: 1)],
                                          startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
            }
            // Light across its top, and along its edge: bright above, fainter where it reflects below.
            shape.fill(LinearGradient(stops: [.init(color: .white.opacity(0.13 * s.shine), location: 0),
                                              .init(color: .white.opacity(0), location: 0.6)],
                                      startPoint: .top, endPoint: .bottom))
                .blendMode(.plusLighter)
            shape.strokeBorder(LinearGradient(stops: [.init(color: .white.opacity(0.75 * s.shine), location: 0),
                                                      .init(color: .white.opacity(0.1 * s.shine), location: 0.5),
                                                      .init(color: .white.opacity(0.3 * s.shine), location: 1)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .blendMode(.plusLighter)
            shape.strokeBorder(Color.white.opacity(s.border ? 0.6 : 0.16), lineWidth: s.border ? 1 : 0.5)
                .blendMode(.difference)
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
        let s = LumenStyle(dark: scheme == .dark, access: access, effect: model.glow, glass: model.glass, skin: model.skin)
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
            .accessibilityLabel(model.toastChinese ? "中文" : "English")
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
    /// A glint crossing the plate, 0 to 1 of the way.
    var glint: CGFloat?

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
                // outside it: underneath, the glass would sample it and re-tint itself. On a dark
                // page it is a glow at the edge; on a light one, where light can't brighten
                // anything, the same colour reads as the glass's shadow.
                pool.mask { shape.stroke(lineWidth: 10).blur(radius: 6) }
                    .blur(radius: 8)
                    .offset(y: 3)
                    .mask { Outside(shape: shape) }
                    .opacity(0.6 * s.glowAmount)
            }
            if s.effect != .off {
                Group {
                    if s.bloom {
                        // A faint wash through the body of the glass, which stays clear,
                        pool.clipShape(shape)
                            .opacity(0.18 * s.glowAmount)
                        // and more of it gathered along the edge, as cut glass carries light.
                        pool.mask { shape.strokeBorder(lineWidth: 6).blur(radius: 4) }
                            .clipShape(shape)
                            .opacity(0.6 * s.glowAmount)
                    }
                    // The rim catches the light where it falls,
                    pool.mask { shape.strokeBorder(lineWidth: 1.25) }
                        .opacity(s.prism ? 1 : 0.7)
                    if s.effect == .flow && s.bloom && s.prism {
                        // and, as a cut edge does, splits it into its colours: the whole wheel
                        // runs round the rim, turning slowly, strongest where the light pools.
                        // Each colour is laid twice, as a stain and as a glow, so the rim is
                        // drawn in colour on a white page and lit in colour on a dark one.
                        // A glint crosses with each change of words: for a moment the rim there
                        // shows its colours in full, with a core of white light.
                        let band = glint.map { Glint(at: $0) }
                        let prism = shape.strokeBorder(AngularGradient(colors: Spectrum.wheel, center: .center,
                                                                       angle: .degrees(time / Spectrum.period * 360)),
                                                       lineWidth: 1.25)
                            .mask {
                                ZStack {
                                    Color.white.opacity(0.3)
                                    pool
                                    band
                                }
                            }
                        prism.blendMode(.multiply)
                        prism.blendMode(.plusLighter).opacity(0.85)
                        if let band {
                            shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1).mask { band }
                                .blendMode(.plusLighter)
                        }
                    }
                }
            }
        }
    }
}

/// A soft upright band of light, `at` of the way across (0 to 1), fading in as it sets out and
/// away as it arrives. Used as a mask.
private struct Glint: View {
    let at: CGFloat

    var body: some View {
        // From just off the leading edge to just off the trailing one.
        let x = -0.2 + 1.4 * at
        let strength = min(1, at * 6) * (1 - at)
        LinearGradient(stops: [.init(color: .clear, location: x - 0.18),
                               .init(color: .white.opacity(strength), location: x),
                               .init(color: .clear, location: x + 0.18)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// Everything around `shape`, out to `reach` beyond it (by default the panel's whole margin): a
/// mask for what must fall only outside.
private struct Outside: View {
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
                        glow(Spectrum.color(at: turn + Double(k) / 3), at: at,
                             radius: size.height * 1.1, strength: 0.55)
                    }
                    glow(Spectrum.color(at: turn), at: source, radius: reach, strength: 1)
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

    /// The wheel once round, a little deeper than the glow's colours, for the rim's dispersion.
    static let wheel: [Color] = (0...12).map { color(at: Double($0) / 12, lightness: 0.74, chroma: 0.19) }

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

/// The plate: clear glass that takes its tone from the page, not from the system's appearance.
///
/// It starts from the system's clear glass in its dark form, which passes what is behind it most
/// faithfully (light glass greys a dark page, and both grey a white one). A few blends then shape
/// its tone: dark pages are lifted a little so the glass stands off them, the middle is spread
/// apart, and a white page with text on it comes out white again instead of grey. So the glass is
/// dark on a dark page and light on a light one, whichever appearance the Mac is in, and the ink
/// (see `Ink`) follows it. It reads as glass by light at its edges, not by a fill.
private struct GlassBackground: View {
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
    let labelGap: CGFloat = 5
    let wordFont: Font = .system(size: 16)
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
    let inkPivot: Double
    let inkGain: Double
    /// How strongly the shadow under the ink burns (lower burns more).
    let inkShadow: Double
    /// How bright the highlights on the glass and the lens are, 1 for cut crystal.
    let shine: Double
    /// How much of the 光效's light shows, 1 in full.
    let glowAmount: Double
    /// The rim splits light into its colours.
    let prism: Bool
    /// The chosen word is marked by a soft light with no edge, rather than a drop of glass.
    let softLens: Bool
    /// The blends that shape the glass's tone, in order.
    let tone: [(mode: BlendMode, level: Double)]
    /// A plain opaque plate instead of glass (Reduce Transparency, Increase Contrast).
    let solid: Bool
    /// A clearly visible edge on the panel and the selection (Increase Contrast, Show Borders).
    let border: Bool
    /// Light that blooms past a shape's edge; off under Reduce Bright Effects.
    let bloom: Bool
    /// 光效, and 柔光's colour: the accent colour chosen in System Settings.
    let effect: LumaGlow
    let tint = Color(nsColor: .controlAccentColor)
    /// The same, paler, for the lens: it stains what is under it, and a full accent colour would
    /// stain a white page dark enough to put the word on it in doubt.
    let lensTint = Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.45, of: .white) ?? .controlAccentColor)

    init(dark: Bool, access: PanelAccessibility = .init(), effect: LumaGlow = .off, glass: LumaGlass = .clear,
         skin: LumaSkin = .frost) {
        self.dark = dark
        self.effect = effect
        border = access.increaseContrast || access.showBorders
        bloom = !access.reduceBrightEffects
        solid = access.increaseContrast || access.reduceTransparency
        // The lens, not faintness, marks the choice, so unchosen words keep most of their strength.
        let firm = access.increaseContrast
        // (磨砂 has only a light behind the chosen word, so the others step back a little more.)
        word = firm ? 0.95 : skin == .frost ? 0.74 : 0.86
        label = firm ? 0.8 : 0.55
        labelSelected = firm ? 0.9 : 0.72
        headerLead = firm ? 1 : 0.9
        headerRest = firm ? 0.8 : 0.5
        inkGain = 12
        var tone: [(mode: BlendMode, level: Double)]
        switch skin {
        case .frost:
            // 磨砂: frosted glass in the manner of a system material. The same glass that takes
            // its tone from the page, but held back at both ends: a white page comes through as a
            // soft off-white rather than full white, a dark one as a quiet deep grey, and the
            // highlights are a hint, not a gleam. Nothing glints or shows a spectrum. Its brightness
            // is capped, so over a page that is part white and part grey the plate is one even tone.
            inkPivot = 0.58
            inkShadow = 0.8
            shine = 0.28
            glowAmount = 0.5
            prism = false
            softLens = true
            tone = [(.softLight, 0.2), (.colorDodge, 0.375), (.multiply, 0.93), (.plusLighter, 0.045), (.darken, 0.855)]
        case .crystal:
            // 晶透 通透: close to what is behind, lifted a little off black, and white where the page is.
            inkPivot = 0.64
            inkShadow = 0.7
            shine = 1
            glowAmount = 1
            prism = true
            softLens = false
            tone = [(.softLight, 0.2), (.colorDodge, 0.375), (.plusLighter, 0.04)]
        }
        if skin == .crystal && glass == .frosted {
            // 柔雾: the same glass, a little firmer and held just short of pure white and of
            // black, like milk glass: the plate keeps an edge of its own even on a white page.
            tone += [(.plusDarker, 0.9), (.colorDodge, 0.2), (.lighten, 0.2), (.darken, 0.955)]
        }
        self.tone = tone
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
