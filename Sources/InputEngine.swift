import AppKit

/// Where the engine writes text: an IMK client in production, an NSTextView in the playground.
@MainActor
protocol TextSink: AnyObject {
    func insert(_ text: String)
    func setMarked(_ text: NSAttributedString, caret: Int)
    func caretRect() -> NSRect
    func markedAttributes() -> [NSAttributedString.Key: Any]
}

/// Per-client input logic: feeds keys to a Rime session and reflects the result in the sink and panel.
@MainActor
final class InputEngine {
    weak var sink: TextSink?

    private var session: RimeSessionId = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    private var hasMarked = false
    private var lastAscii: Bool?

    func close() {
        if session != 0 { Rime.shared.destroy(session) }
        session = 0
        assistTask?.cancel()
    }

    private func ensureSession() -> Bool {
        if !Rime.shared.exists(session) {
            session = Rime.shared.createSession()
            applyOptions()
        }
        return session != 0
    }

    private var typoCorrection: Bool?

    func applyOptions() {
        guard Rime.shared.exists(session) else { return }
        let on = LumaSettings.typoCorrection
        Rime.shared.setOption(session, "luma_typo_off", !on)
        typoCorrection = on
    }

    func handle(_ event: NSEvent) -> Bool {
        guard ensureSession() else { return false }
        if typoCorrection != LumaSettings.typoCorrection { applyOptions() }  // toggled from the menu
        switch event.type {
        case .keyDown: return keyDown(event)
        case .flagsChanged: flagsChanged(event); return false
        default: return false
        }
    }

    /// A letter was typed with Shift held, so releasing Shift must not toggle 中/英.
    private var shiftUsedForLetter = false

    private func keyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift + letter with nothing being composed types the capital straight into the text,
        // like any keyboard. (rime-ice would otherwise open an English word menu for it.) While
        // composing, Rime keeps it so mixed input like "wo" + "I" still works.
        if flags.intersection([.shift, .control, .option, .command]) == .shift,
           let ch = event.characters, ch.count == 1, ch.first!.isASCII, ch.first!.isUppercase,
           !Rime.shared.state(session).isComposing {
            shiftUsedForLetter = true
            return false  // the app inserts the letter itself
        }
        // Option + key types the layout's symbol (Option+[ “, Option+Shift+[ ”, Option+3 £ …);
        // that belongs to the app. Commit what's being composed first, as punctuation does,
        // so the symbol lands after it instead of replacing the pinyin.
        if flags.contains(.option), flags.isDisjoint(with: [.command, .control]),
           let ch = event.characters, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            if Rime.shared.state(session).isComposing {
                Rime.shared.commitComposition(session)
                refresh()
            }
            return false
        }
        guard let sym = KeyMap.keysym(for: event) else { return false }
        if flags.isDisjoint(with: [.command, .control, .option]), let handled = routeAroundSuggestion(sym) {
            return handled
        }
        let handled = Rime.shared.processKey(session, sym, KeyMap.mask(flags))
        refresh()
        // Command shortcuts always belong to the app; Rime only sees them so a held Shift won't toggle modes.
        return flags.contains(.command) ? false : handled
    }

    private func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let changed = flags.symmetricDifference(lastFlags)
        lastFlags = flags
        guard let (sym, flag) = KeyMap.modifier(event.keyCode) else { return }
        let mask = KeyMap.mask(flags)
        if flag == .capsLock {
            _ = Rime.shared.processKey(session, sym, mask)
            _ = Rime.shared.processKey(session, sym, mask | RimeMask.release)
        } else {
            guard changed.contains(flag) else { return }
            let pressed = flags.contains(flag)
            if flag == .shift && pressed { shiftUsedForLetter = false }
            // Rime never saw the capitals typed with Shift held, so it would take this release
            // for a lone Shift tap and switch to English; skip it.
            if flag == .shift && !pressed && shiftUsedForLetter {
                shiftUsedForLetter = false
                return
            }
            _ = Rime.shared.processKey(session, sym, mask | (pressed ? 0 : RimeMask.release))
        }
        refresh()
    }

    func select(_ index: Int) {
        guard ensureSession() else { return }
        Rime.shared.selectOnPage(session, index)
        refresh()
    }

    /// Picks the panel's `index`th entry, which may be an AI suggestion rather than Rime's.
    private func choose(_ index: Int) {
        guard entries.indices.contains(index) else { return select(index) }
        switch entries[index] {
        case .suggestion:
            commitSuggestion()
        case .rime(let i):
            noteChoice(Rime.shared.state(session).candidates[safe: i]?.text)
            select(i)
        }
    }

    /// Commits whatever is being composed, e.g. when focus leaves the text field.
    func commitPending() {
        guard Rime.shared.exists(session), Rime.shared.state(session).isComposing else {
            CandidatePanel.shared.hide()
            return
        }
        Rime.shared.commitComposition(session)
        refresh()
    }

    func refresh() {
        guard let sink else { return }
        if let text = Rime.shared.consumeCommit(session) {
            LumaSettings.debugLog("  commit [\(text)]")
            sink.insert(text)
            hasMarked = false
        }

        let st = Rime.shared.state(session)
        if st.isComposing {
            let (text, caret) = Syllables.respace(st.preedit, caret: st.caret)
            sink.setMarked(NSAttributedString(string: text, attributes: sink.markedAttributes()), caret: caret)
            hasMarked = true
        } else if hasMarked {
            sink.setMarked(NSAttributedString(string: ""), caret: 0)
            hasMarked = false
        }

        followAssist(st)
        showPanel(st)

        if let last = lastAscii, last != st.isAscii {
            CandidatePanel.shared.toast(chinese: !st.isAscii, near: sink.caretRect())
        }
        lastAscii = st.isAscii
    }

    private func showPanel(_ st: RimeState) {
        guard let sink else { return }
        let panel = CandidatePanel.shared
        guard !st.candidates.isEmpty else {
            entries = []
            suggestionSlot = nil
            panel.hide()
            return
        }
        let (page, entries) = arrange(st)
        self.entries = entries
        panel.show(page, pending: assistPending, near: sink.caretRect()) { [weak self] index in self?.choose(index) }
    }

    // MARK: - AI assist

    /// What AI assist offers for the pinyin being typed.
    private struct Suggestion {
        let pinyin: String
        let text: String
        /// Picked before, so it comes first, without asking the model.
        let remembered: Bool
        /// Goes first: remembered, or Rime's own first choice is only a phrase it assembled.
        let leads: Bool
    }

    private enum Entry: Equatable { case rime(Int), suggestion }

    private var assistPinyin: String?
    private var suggestion: Suggestion?
    private var suggestionHighlighted = false
    private var assistPending = false
    private var assistTask: Task<Void, Never>?
    /// The page the panel shows, in order: Rime's candidates, plus the suggestion when there is one.
    private var entries: [Entry] = []
    /// Where the suggestion sits in `entries`, whether as its own entry or as Rime's candidate.
    private var suggestionSlot: Int?

    /// The pinyin worth asking about: plain letters with nothing picked yet, long enough that the
    /// dictionary might miss it, and the caret at the end (moved back, the user is editing).
    private func assistable(_ st: RimeState) -> String? {
        guard AISettings.config != nil, st.isComposing, !st.isAscii, st.caret >= st.preedit.utf16.count else { return nil }
        let letters = st.preedit.filter { $0 != " " && $0 != "'" }
        guard letters.count >= 4, letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return letters.lowercased()
    }

    /// Starts over whenever the pinyin changes: a remembered word or a recent answer shows at
    /// once; otherwise the model is asked after a short pause in typing, and its answer is dropped
    /// if the pinyin has moved on by the time it arrives.
    private func followAssist(_ st: RimeState) {
        let pinyin = assistable(st)
        guard pinyin != assistPinyin else { return }
        assistTask?.cancel()
        assistPinyin = pinyin
        suggestion = nil
        suggestionHighlighted = false
        assistPending = false
        guard let pinyin else { return }

        if let text = AIMemory.shared.lookup(pinyin) {
            offer(text, for: pinyin, remembered: true, st)
            return
        }
        if let answer = AIAssist.shared.cached(pinyin) {
            if let text = answer.first { offer(text, for: pinyin, remembered: false, st) }
            return
        }
        let hints = st.candidates.prefix(5).map(\.text)
        assistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.assistPending = true
            self.showPanel(Rime.shared.state(self.session))
            let answer = try? await AIAssist.shared.suggest(pinyin, hints: hints)
            guard !Task.isCancelled, self.assistPinyin == pinyin else { return }
            self.assistPending = false
            let now = Rime.shared.state(self.session)
            if let text = answer?.first { self.offer(text, for: pinyin, remembered: false, now) }
            self.showPanel(now)
        }
    }

    /// Takes `text` as the suggestion and decides its place. Rime's first choice stays first
    /// when it's a word, from the dictionary or typed before; one it only assembled from
    /// pieces gives way. A suggestion that goes first is highlighted, unless the user has
    /// already moved the highlight.
    private func offer(_ text: String, for pinyin: String, remembered: Bool, _ st: RimeState) {
        let top = st.pageNo == 0 ? st.candidates.first : nil
        let leads = remembered || (top?.composed == true && top?.text != text)
        suggestion = Suggestion(pinyin: pinyin, text: text, remembered: remembered, leads: leads)
        suggestionHighlighted = leads && st.highlighted == 0
    }

    /// Lays out the first page with the suggestion in it: first when it leads, otherwise second,
    /// after Rime's best guess. A suggestion Rime already has moves up to that place as Rime's
    /// own candidate, so picking it also teaches Rime.
    private func arrange(_ st: RimeState) -> (RimeState, [Entry]) {
        var page = st
        var entries = st.candidates.indices.map(Entry.rime)
        suggestionSlot = nil
        guard let s = suggestion, st.pageNo == 0, !st.candidates.isEmpty else {
            suggestionHighlighted = false
            return (page, entries)
        }

        var slot = s.leads ? 0 : 1
        var item = RimeCandidateItem(text: s.text, comment: "", label: "", ai: true)
        var entry = Entry.suggestion
        if let i = page.candidates.firstIndex(where: { $0.text == s.text }) {
            item = page.candidates.remove(at: i)
            item.ai = true
            entry = entries.remove(at: i)
            slot = min(slot, i)  // never pushed further down than Rime had it
        }
        slot = min(slot, page.candidates.count)
        page.candidates.insert(item, at: slot)
        entries.insert(entry, at: slot)
        page.candidates = page.candidates.enumerated().map { i, c in
            RimeCandidateItem(text: c.text, comment: c.comment, label: String(i + 1), corrected: c.corrected, ai: c.ai)
        }
        suggestionSlot = slot
        page.highlighted = suggestionHighlighted ? slot : entries.firstIndex(of: .rime(st.highlighted)) ?? 0
        return (page, entries)
    }

    /// While a suggestion is on the page, digits pick by the panel's numbering, Space takes what
    /// the panel highlights, and ←/→ walk the panel's order. Returns nil for keys Rime should
    /// handle as usual.
    private func routeAroundSuggestion(_ sym: Int32) -> Bool? {
        guard let slot = suggestionSlot else { return nil }
        let st = Rime.shared.state(session)
        switch sym {
        case 0x31...0x39:  // 1–9
            let index = Int(sym - 0x31)
            guard entries.indices.contains(index) else { return nil }
            choose(index)
            return true
        case 0x20:  // Space
            if suggestionHighlighted {
                choose(slot)
                return true
            }
            noteChoice(st.candidates[safe: st.highlighted]?.text)
            return nil
        case 0xff51, 0xff53:  // Left, Right
            let current = suggestionHighlighted ? slot : entries.firstIndex(of: .rime(st.highlighted)) ?? 0
            let target = current + (sym == 0xff53 ? 1 : -1)
            guard entries.indices.contains(target) else {
                suggestionHighlighted = false
                return nil  // past the ends: Rime turns the page
            }
            suggestionHighlighted = target == slot
            if case .rime(let i) = entries[target] { Rime.shared.highlightOnPage(session, i) }
            showPanel(Rime.shared.state(session))
            return true
        default:
            return nil
        }
    }

    /// Keeps the memory honest: picking the suggestion strengthens it, passing over a
    /// remembered one wears it down.
    private func noteChoice(_ text: String?) {
        guard let s = suggestion, let text else { return }
        if text == s.text {
            AIMemory.shared.remember(s.pinyin, s.text)
        } else if s.remembered {
            AIMemory.shared.wearDown(s.pinyin, s.text)
        }
    }

    private func commitSuggestion() {
        guard let s = suggestion, let sink else { return }
        AIMemory.shared.remember(s.pinyin, s.text)
        Rime.shared.clearComposition(session)
        LumaSettings.debugLog("  commit [\(s.text)] (AI)")
        sink.insert(s.text)
        hasMarked = false
        refresh()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
