import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PanelModel {
    enum Mode { case candidates, toast, status }

    var mode: Mode = .candidates
    var statusText = ""
    var glow = LumaSettings.glow
    var vertical = LumaSettings.layout == .vertical
    var showPinyin = LumaSettings.showPinyin
    var candidates: [RimeCandidateItem] = []
    var highlighted = 0
    var hovered: Int? = nil
    /// Bumped only when the selection moves within an unchanged list, so the highlight
    /// glides on arrow keys but tracks the text exactly while typing.
    var moveToken = 0
    /// Which way the selection last moved: 1 right/down, -1 left/up.
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
    /// Where the AI lane begins among `candidates`: the model's words at the end of the bar,
    /// taken with Tab. nil when there are none.
    var laneStart: Int?
    /// The lane didn't fit before the screen's edge: just its spark shows, Tab still takes it.
    var laneCompact = false
    var laneWidth: CGFloat = 0
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
    var contentSize: CGSize = .zero {
        didSet { if contentSize != oldValue { onResize?() } }
    }
    @ObservationIgnored var onResize: (() -> Void)?
    var barSize: CGSize = .zero
    var barGrowing = false
    var reduceMotion = false
    /// Characters of the first candidate that the last key set right (more of the sentence made
    /// the sentence maker reread what came before), with what each was before, and how far the
    /// change has come, 0 to 1.
    var revised: [Int: Character] = [:]
    var reviseProgress: CGFloat = 1
    /// The cat at the end of the bar, and how far it has peeked up, 0 to 1.
    var companion = LumaSettings.companion
    var catRise: CGFloat = 1
    /// Where each cell is on the window's canvas (top left at zero), for a landing to start from.
    /// Not observed: it is read only when a word is committed.
    @ObservationIgnored var cellFrames: [Int: CGRect] = [:]
    @ObservationIgnored var onSelect: ((Int) -> Void)?
    @ObservationIgnored var onPage: ((Int) -> Void)?
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
    private var canvas: NSSize
    private var hideWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var glideWork: DispatchWorkItem?
    private var returnWork: DispatchWorkItem?
    private var liveWork: DispatchWorkItem?
    private var fadeTimer: Timer?
    private var stretchTimer: Timer?
    private var reviseTimer: Timer?
    private var catTimer: Timer?
    private var drawnCheck: DispatchWorkItem?
    /// The first candidate as last shown, and the keys it was shown for, to tell when a key has
    /// set right characters already on screen.
    private var lastHero: (input: String, text: String)?
    /// When the panel last went down: back within moments, the cat is already up.
    private var lastDismissed = Date.distantPast
    /// The light of a committed word, on its way into the text (a window of its own).
    private let lander = Lander()

    /// The engine whose candidates are up. Every text field and app has its own engine but they
    /// share this panel; only the one showing candidates may take them down, so a field being left
    /// or a client activated in the background can't hide what's being typed elsewhere.
    private weak var owner: AnyObject?
    /// The owner wants its candidates on screen: shown and not hidden since.
    private var wanted = false
    private var lastCaret = NSRect.zero
    /// Where the bar's left edge was put for the word being typed, and the caret it was put by.
    /// While the word goes on it stays there, moving only left, and only when the candidates
    /// themselves would run off the screen; the AI lane never moves it.
    private var anchor: (caretX: CGFloat, x: CGFloat)?
    private var laneTexts: [String] = []
    /// When the window was last ordered in, so a fresh window gets time to report it's on screen.
    private var orderedIn = Date.distantPast

    private static func canvasSize(vertical: Bool) -> NSSize {
        vertical ? NSSize(width: 520, height: 480) : NSSize(width: 1280, height: 196)
    }

    private init() {
        canvas = Self.canvasSize(vertical: model.vertical)
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
        model.onResize = { [weak self] in self?.contentResized() }

        // Switching desktops takes the panel down at once, so it never lingers on the old one.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanged() }
        }
    }

    private func updateCanvasSize() {
        let next = Self.canvasSize(vertical: model.vertical)
        guard canvas != next else { return }
        canvas = next
        var frame = window.frame
        frame.size = next
        window.setFrame(frame, display: false)
        window.contentView?.frame = NSRect(origin: .zero, size: next)
        model.barSize = .zero
        model.contentSize = .zero
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
        stopRevise()
        lander.stop()
        model.visible = false
        model.live = false
        model.hovered = nil
        lastDismissed = Date()
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

    func setLayout(_ layout: LumaLayout) {
        LumaSettings.layout = layout
        model.vertical = layout == .vertical
        anchor = nil
        updateCanvasSize()
        if wanted && model.visible { place(near: lastCaret) }
    }

    func setShowPinyin(_ show: Bool) {
        LumaSettings.showPinyin = show
        model.showPinyin = show
    }

    func setCompanion(_ on: Bool) {
        LumaSettings.companion = on
        model.companion = on
    }

    /// A word went into the text: the light under it flies from the bar to where the text landed,
    /// and plays its flourish if it carries a feeling. `pick` is the panel entry it was picked
    /// from, if not the highlighted one (a number key, a click); `caret` is the caret after it.
    func land(_ text: String, pick: Int?, at caret: NSRect, for owner: AnyObject) {
        flown = nil
        let index = pick ?? model.highlighted
        guard self.owner === owner, model.mode == .candidates, model.visible, window.isVisible, !model.reduceMotion,
              text.unicodeScalars.contains(where: { !$0.isASCII }),
              let cell = model.cellFrames[index], model.candidates.indices.contains(index) else { return }
        let mood = LumaSettings.moments ? Mood.of(text).flatMap { MomentMemory.mayPlay($0) ? $0 : nil } : nil
        // With the light off, a flourish still plays; with neither, nothing does.
        guard LumaSettings.landingLight || mood != nil else { return }
        let frame = window.frame
        let from = CGRect(x: frame.minX + cell.minX, y: frame.maxY - cell.maxY, width: cell.width, height: cell.height)
        let estimate = plausible(lastCaret)
            ? NSRect(x: lastCaret.minX + CGFloat(text.count) * max(12, lastCaret.height * 0.82), y: lastCaret.minY,
                     width: 1, height: lastCaret.height)
            : nil
        var target = caret
        if !plausible(target) || abs(target.minX - lastCaret.minX) < 0.5 {
            guard let estimate else { return }
            target = estimate
        } else if let estimate, abs(target.midY - lastCaret.midY) < max(4, target.height / 2),
                  target.minX - lastCaret.minX < (estimate.minX - lastCaret.minX) * 0.7 {
            target = estimate
        }
        let sameLine = plausible(lastCaret) && abs(lastCaret.midY - target.midY) < max(4, target.height / 2)
            && target.minX > lastCaret.minX
        let color: Color = model.glow == .flow
            ? Spectrum.color(at: Date().timeIntervalSinceReferenceDate / Spectrum.period, lightness: 0.72, chroma: 0.17)
            : Color(nsColor: .controlAccentColor)
        let id = lander.fly(from: from, to: CGPoint(x: target.minX, y: target.midY), caretHeight: min(max(target.height, 14), 40),
                            textStart: sameLine ? lastCaret.minX : nil, color: color, mood: mood, flies: LumaSettings.landingLight)
        flown = (id, ObjectIdentifier(owner), plausible(lastCaret) ? lastCaret : nil, plausible(caret) ? caret.minX : nil, CACurrentMediaTime())
        LumaSettings.debugLog("land: \(text.count) chars from x \(Int(lastCaret.minX)), caret said x \(Int(caret.minX)) y \(Int(caret.midY))"
                              + ", estimate x \(estimate.map { Int($0.minX) } ?? -1) → heading x \(Int(target.minX))")
    }

    private var flown: (id: Double, owner: ObjectIdentifier, start: NSRect?, said: CGFloat?, at: Double)?

    func refineLanding(for owner: AnyObject, caret: () -> NSRect) {
        guard let f = flown, f.owner == ObjectIdentifier(owner), self.owner === owner else { return }
        let elapsed = CACurrentMediaTime() - f.at
        guard elapsed < 0.5 else { return }
        let now = caret()
        guard plausible(now) else { return }
        if let start = f.start {
            guard abs(now.midY - start.midY) < max(4, start.height / 2), now.minX > start.minX + 0.5 else { return }
        }
        if let said = f.said, abs(now.minX - said) < 0.5, elapsed < 0.25 { return }
        LumaSettings.debugLog(String(format: "land: caret at %.2fs x %d", CACurrentMediaTime() - f.at, Int(now.minX)))
        lander.retarget(f.id, to: CGPoint(x: now.minX, y: now.midY))
    }

    func show(_ st: RimeState, pending: Bool = false, lane: Int? = nil, near caret: NSRect, for owner: AnyObject,
              onSelect: @escaping (Int) -> Void, onPage: @escaping (Int) -> Void = { _ in }) {
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        returnWork?.cancel()
        let continuing = wanted && self.owner === owner
        let caret = !plausible(caret) && continuing && plausible(lastCaret) ? lastCaret : caret
        if !continuing { anchor = nil }
        self.owner = owner
        wanted = true
        lastCaret = caret
        model.onSelect = onSelect
        model.onPage = onPage
        if st.pageNo != model.pageNo {
            model.pageDirection = st.pageNo > model.pageNo ? 1 : -1
            model.hovered = nil
        } else if st.candidates == model.candidates, st.highlighted != model.highlighted, model.visible {
            model.moveDirection = st.highlighted > model.highlighted ? 1 : -1
            model.moveToken &+= 1
            stretchLens()
        } else if st.candidates != model.candidates {
            model.hovered = nil
        }
        noteRevision(st, continuing: continuing)
        model.mode = .candidates
        model.candidates = st.candidates
        model.highlighted = st.highlighted
        model.pageNo = st.pageNo
        model.hasPrev = st.pageNo > 0
        model.hasNext = !st.isLastPage
        model.aiPending = pending
        let texts = lane.map { st.candidates[$0...].map(\.text) } ?? []
        if texts != laneTexts {
            laneTexts = texts
            model.laneCompact = false
            if lane == nil { model.laneWidth = 0 }
        }
        model.laneStart = lane
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
        anchor = nil
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
        model.toastChinese = model.reduceMotion ? chinese : !chinese
        model.visible = false
        present(near: caret)
        if !model.reduceMotion {
            let glide = DispatchWorkItem { [weak self] in
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { self?.model.toastChinese = chinese }
            }
            glideWork = glide
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleTime + 0.06, execute: glide)
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Briefly shows a calm status pill (e.g. while dictionaries are deploying on first launch).
    func status(_ text: String, near caret: NSRect) {
        if model.mode == .candidates && model.visible { return }
        hideWork?.cancel()
        toastWork?.cancel()
        glideWork?.cancel()
        model.mode = .status
        model.statusText = text
        model.visible = false
        present(near: caret)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func present(near caret: NSRect) {
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        if !window.isVisible { fade(to: 0, over: 0) }
        window.orderFrontRegardless()
        orderedIn = Date()
        if model.mode == .candidates { peekCat() }
        model.visible = true
        fade(to: 1, over: model.reduceMotion ? 0 : 0.2)
        settle()
    }

    private static let settleTime = 0.2

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

    private func noteRevision(_ st: RimeState, continuing: Bool) {
        let hero = st.pageNo == 0 ? st.candidates.first?.text : nil
        let last = continuing ? lastHero : nil
        lastHero = hero.map { (st.input, $0) }
        guard let hero, let last, model.live, !model.reduceMotion else { return stopRevise() }
        let old = Array(last.text), new = Array(hero)
        if st.input.count > last.input.count, st.input.hasPrefix(last.input), old != new {
            let settled = min(new.count > old.count ? old.count : old.count - 1, new.count)
            let changed = (0..<max(0, settled)).filter { old[$0] != new[$0] }
            if !changed.isEmpty, changed.count <= max(1, min(3, old.count / 2)), changed.allSatisfy({ new[$0].isHan }) {
                model.revised = Dictionary(uniqueKeysWithValues: changed.map { ($0, old[$0]) })
                return startRevise()
            }
        }
        let still = model.revised.filter { i, _ in i < new.count && i < old.count && new[i] == old[i] }
        if still.isEmpty { stopRevise() } else { model.revised = still }
    }

    private func startRevise() {
        reviseTimer?.invalidate()
        let start = CACurrentMediaTime()
        model.reviseProgress = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.reviseTimer === timer else { return timer.invalidate() }
                let t = (CACurrentMediaTime() - start) / 0.65
                if t >= 1 { return self.stopRevise() }
                self.model.reviseProgress = t
            }
        }
        reviseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRevise() {
        reviseTimer?.invalidate()
        reviseTimer = nil
        if !model.revised.isEmpty { model.revised = [:] }
        model.reviseProgress = 1
    }

    private func peekCat() {
        catTimer?.invalidate()
        catTimer = nil
        guard model.companion, !model.reduceMotion, Date().timeIntervalSince(lastDismissed) > 6 else {
            model.catRise = 1
            return
        }
        model.catRise = 0
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.catTimer === timer else { return timer.invalidate() }
                let t = (CACurrentMediaTime() - start - 0.28) / 0.42
                guard t > 0 else { return }
                if t >= 1 {
                    timer.invalidate()
                    self.catTimer = nil
                    self.model.catRise = 1
                    return
                }
                let c = 1.9, u = t - 1
                self.model.catRise = 1 + (c + 1) * u * u * u + c * u * u
            }
        }
        catTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

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
            if !again { self.checkDrawn(after: 0.3, again: true) }
        }
        drawnCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismiss() {
        guard model.visible || window.isVisible else { return }
        liveWork?.cancel()
        stopStretch()
        stopRevise()
        model.visible = false
        model.live = false
        model.hovered = nil
        lastDismissed = Date()
        fade(to: 0, over: 0.12, easeIn: true)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.window.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func plausible(_ caret: NSRect) -> Bool {
        caret.origin != .zero && NSScreen.screens.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(caret.origin) }
    }

    private func caretOrMouse(_ caret: NSRect) -> NSRect {
        guard !plausible(caret) else { return caret }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 18, width: 0, height: 18)
    }

    private func screen(for caret: NSRect) -> NSScreen? {
        let rect = caretOrMouse(caret)
        return NSScreen.screens.first { $0.frame.contains(rect.origin) } ?? NSScreen.main
    }

    private func contentResized() {
        guard model.mode == .candidates, wanted, let visible = window.screen?.visibleFrame else { return }
        let right = window.frame.minX + Self.margin + model.contentSize.width
        if right > visible.maxX - 2 {
            if !model.vertical && model.laneStart != nil && !model.laneCompact {
                model.laneCompact = true
            } else {
                place(near: lastCaret)
            }
            return
        }
        // In vertical mode, also re-check vertical flip if the card grew taller than expected.
        if model.vertical && !model.flipped {
            let bottom = window.frame.maxY - Self.margin - model.contentSize.height
            if bottom < visible.minY { place(near: lastCaret) }
        }
    }

    private func place(near caret: NSRect) {
        let rect = caretOrMouse(caret)
        guard let visible = screen(for: caret)?.visibleFrame else { return }

        let fallback = model.vertical ? CGSize(width: 210, height: 260) : CGSize(width: 420, height: 70)
        let measured = model.contentSize == .zero ? fallback : model.contentSize
        let defaultBarHeight: CGFloat = model.vertical
            ? CGFloat(max(model.candidates.count, 5)) * 32 + (model.showPinyin ? 48 : 34)
            : (model.showPinyin ? 62 : 46)
        let barHeight = model.barSize.height > 0 ? model.barSize.height : defaultBarHeight
        let size = model.mode == .candidates ? CGSize(width: max(measured.width, model.vertical ? 176 : 200), height: barHeight) : measured
        let gap: CGFloat = 6
        let margin = Self.margin

        var x = rect.minX - 12
        if model.mode == .candidates, let anchor, abs(anchor.caretX - rect.minX) < 1 { x = anchor.x }
        let lane = !model.vertical && model.laneStart != nil && !model.laneCompact ? model.laneWidth : 0
        x = min(x, visible.maxX - (size.width - lane) - 4)
        x = max(x, visible.minX + 4)
        if model.mode == .candidates { anchor = (rect.minX, x) }

        let fitsBelow = rect.minY - gap - size.height >= visible.minY
        model.flipped = !fitsBelow
        let y = fitsBelow
            ? rect.minY - gap + margin - canvas.height
            : rect.maxY + gap - margin
        window.setFrameOrigin(NSPoint(x: x - margin, y: y))
    }
}
