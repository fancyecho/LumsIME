import AppKit

/// Where the engine writes text: an IMK client in production, an NSTextView in the playground.
@MainActor
protocol TextSink: AnyObject {
    func insert(_ text: String)
    func setMarked(_ text: NSAttributedString, caret: Int)
    func caretRect() -> NSRect
    func markedAttributes() -> [NSAttributedString.Key: Any]
    /// Up to `count` characters just before the caret (or the text being composed), read from
    /// the document; nil when the app doesn't share it.
    func textBeforeCaret(_ count: Int) -> String?
}

/// Per-client input logic: feeds keys to a Rime session and reflects the result in the sink and panel.
@MainActor
final class InputEngine {
    weak var sink: TextSink? {
        // Another text field: whatever Luma knew about the text before the caret is gone.
        didSet { if sink !== oldValue { context.reset() } }
    }

    private var session: RimeSessionId = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    private var hasMarked = false
    private var lastAscii: Bool?

    /// Luma's own record of the text before the caret, for apps that don't share theirs.
    private var context = TypingContext()
    /// The text before the caret as the current input began, from the document or Luma's record.
    private var compositionContext: String?

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
        let composing = Rime.shared.state(session).isComposing
        // Shift + letter with nothing being composed types the capital straight into the text,
        // like any keyboard. (rime-ice would otherwise open an English word menu for it.) While
        // composing, Rime keeps it so mixed input like "wo" + "I" still works.
        if flags.intersection([.shift, .control, .option, .command]) == .shift,
           let ch = event.characters, ch.count == 1, ch.first!.isASCII, ch.first!.isUppercase, !composing {
            shiftUsedForLetter = true
            context.append(ch)
            return false  // the app inserts the letter itself
        }
        // Option + key types the layout's symbol (Option+[ “, Option+Shift+[ ”, Option+3 £ …);
        // that belongs to the app. Commit what's being composed first, as punctuation does,
        // so the symbol lands after it instead of replacing the pinyin.
        if flags.contains(.option), flags.isDisjoint(with: [.command, .control]),
           let ch = event.characters, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
            if composing {
                Rime.shared.commitComposition(session)
                refresh()
            }
            context.append(ch)
            return false
        }
        guard let sym = KeyMap.keysym(for: event) else { return false }
        if composing && (0xff51...0xff54).contains(sym) { highlightTouched = true }  // ←↑→↓
        if flags.isDisjoint(with: [.command, .control, .option]), let handled = routeAroundArrangement(sym) {
            return handled
        }
        let handled = Rime.shared.processKey(session, sym, KeyMap.mask(flags))
        refresh()
        if !composing && !handled { followPassthrough(event, sym, flags) }
        // Command shortcuts always belong to the app; Rime only sees them so a held Shift won't toggle modes.
        return flags.contains(.command) ? false : handled
    }

    /// Keeps Luma's record of the text in step with a key that went straight to the app.
    private func followPassthrough(_ event: NSEvent, _ sym: Int32, _ flags: NSEvent.ModifierFlags) {
        guard flags.isDisjoint(with: [.command, .control]) else { return context.reset() }  // a shortcut can change anything
        switch sym {
        case 0xff08: context.deleteBackward()  // BackSpace
        case 0xff0d, 0xff8d: context.append("\n")  // Return, Enter
        case 0xff09, 0xff50...0xff57, 0xffff: context.reset()  // Tab, Home, arrows, Page Up/Down, End, Delete
        case 0xff1b: break  // Escape
        default:
            if let ch = event.characters, !ch.isEmpty, ch.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) {
                context.append(ch)
            }
        }
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
        case .ai(let k):
            commitSuggestion(k)
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
            didCommit(text)
        }

        let st = Rime.shared.state(session)
        if st.isComposing {
            // Read before the marked text goes in, so the caret is still where the input began.
            if compositionContext == nil { compositionContext = sink.textBeforeCaret(TypingContext.limit) ?? context.current }
            let (text, caret) = Syllables.respace(st.preedit, caret: st.caret)
            sink.setMarked(NSAttributedString(string: text, attributes: sink.markedAttributes()), caret: caret)
            hasMarked = true
        } else {
            compositionContext = nil
            if hasMarked {
                sink.setMarked(NSAttributedString(string: ""), caret: 0)
                hasMarked = false
            }
        }

        followAssist(st)
        showPanel(st)

        if let last = lastAscii, last != st.isAscii {
            CandidatePanel.shared.toast(chinese: !st.isAscii, near: sink.caretRect())
        }
        lastAscii = st.isAscii
    }

    /// Something reached the text: learn from it and remember it as what comes before the caret.
    private func didCommit(_ text: String) {
        if LumaSettings.learnHabits { HabitMemory.shared.record(text, after: compositionContext ?? context.current) }
        context.append(text)
    }

    // MARK: - Arranging the page

    /// What the panel shows, in order: Rime's candidates by their index on its page, and AI
    /// suggestions Rime doesn't have by their index among the suggestions.
    private enum Entry: Equatable { case rime(Int), ai(Int) }

    private var entries: [Entry] = []
    /// The panel's order differs from Rime's, or holds suggestions: keys go by the panel.
    private var arranged = false
    /// The highlighted suggestion, while the highlight is on one Rime doesn't have.
    private var aiHighlight: Int?
    /// The user moved the highlight; until then it stays on the first entry, so Space takes it.
    private var highlightTouched = false
    private var arrangedFor = ""

    private func showPanel(_ st: RimeState) {
        guard let sink else { return }
        let panel = CandidatePanel.shared
        guard !st.candidates.isEmpty else {
            entries = []
            arranged = false
            aiHighlight = nil
            panel.hide()
            return
        }
        if st.preedit + "#\(st.pageNo)" != arrangedFor {
            arrangedFor = st.preedit + "#\(st.pageNo)"
            highlightTouched = false
            aiHighlight = nil
        }
        let entries = arrange(st)
        self.entries = entries
        arranged = entries != st.candidates.indices.map(Entry.rime) || suggestions != nil

        var highlighted = st.highlighted
        if !highlightTouched, let first = entries.first {
            switch first {
            case .ai(let k):
                aiHighlight = k
            case .rime(let i):
                aiHighlight = nil
                if i != highlighted {
                    Rime.shared.highlightOnPage(session, i)
                    highlighted = i
                }
            }
        }
        if let k = aiHighlight, !entries.contains(.ai(k)) { aiHighlight = nil }

        var page = st
        page.candidates = entries.enumerated().map { n, entry in
            var item: RimeCandidateItem
            switch entry {
            case .rime(let i): item = st.candidates[i]
            case .ai(let k): item = RimeCandidateItem(text: suggestions!.texts[k], comment: "", label: "", ai: true)
            }
            if suggestions?.texts.contains(item.text) == true { item.ai = true }
            return RimeCandidateItem(text: item.text, comment: item.comment, label: arranged ? String(n + 1) : item.label,
                                     corrected: item.corrected, ai: item.ai, composed: item.composed)
        }
        page.highlighted = aiHighlight.flatMap { entries.firstIndex(of: .ai($0)) }
            ?? entries.firstIndex(of: .rime(highlighted)) ?? 0
        panel.show(page, pending: assistPending, near: sink.caretRect()) { [weak self] index in self?.choose(index) }
    }

    /// Lays out the first page. One entry leads, the one Space will take:
    ///   1. an AI suggestion the user picked before for this pinyin;
    ///   2. a word the user usually picks after the text before the caret;
    ///   3. the model's first reading, when Rime only assembled its first choice from pieces,
    ///      or the model was sure of it from the text before;
    ///   4. otherwise Rime's own first choice.
    /// The rest of the model's readings come right after it, then Rime's remaining candidates.
    /// A reading Rime already has moves up as Rime's own candidate, so picking it teaches Rime.
    private func arrange(_ st: RimeState) -> [Entry] {
        let order = st.candidates.indices.map(Entry.rime)
        guard st.pageNo == 0, st.caret >= st.preedit.utf16.count else { return order }
        let texts = st.candidates.map(\.text)

        let readings: [Entry] = suggestions?.texts.enumerated().map { k, text in
            texts.firstIndex(of: text).map(Entry.rime) ?? .ai(k)
        } ?? []
        let habit = LumaSettings.learnHabits ? compositionContext.flatMap { HabitMemory.shared.pick(texts, after: $0) } : nil

        let leader: Entry
        if let s = suggestions, s.remembered, let first = readings.first {
            leader = first
        } else if let habit {
            leader = .rime(habit)
        } else if let s = suggestions, let first = readings.first, first != .rime(0),
                  st.candidates[0].composed || (s.sure && s.withContext) {
            leader = first
        } else {
            leader = .rime(0)
        }
        let rest = order.filter { $0 != leader && !readings.contains($0) }
        return Array(([leader] + readings.filter { $0 != leader } + rest).prefix(9))
    }

    /// While the page is arranged differently from Rime's, digits pick by the panel's
    /// numbering, Space takes what the panel highlights, and ←/→ walk the panel's order.
    /// Returns nil for keys Rime should handle as usual.
    private func routeAroundArrangement(_ sym: Int32) -> Bool? {
        guard arranged else { return nil }
        let st = Rime.shared.state(session)
        switch sym {
        case 0x31...0x39:  // 1–9
            let index = Int(sym - 0x31)
            guard entries.indices.contains(index) else { return nil }
            choose(index)
            return true
        case 0x20:  // Space
            if let k = aiHighlight, let index = entries.firstIndex(of: .ai(k)) {
                choose(index)
                return true
            }
            noteChoice(st.candidates[safe: st.highlighted]?.text)
            return nil  // Rime takes its highlighted candidate
        case 0xff51, 0xff53:  // Left, Right
            let current = aiHighlight.flatMap { entries.firstIndex(of: .ai($0)) }
                ?? entries.firstIndex(of: .rime(st.highlighted)) ?? 0
            let target = current + (sym == 0xff53 ? 1 : -1)
            guard entries.indices.contains(target) else {
                aiHighlight = nil
                return nil  // past the ends: Rime turns the page
            }
            switch entries[target] {
            case .ai(let k):
                aiHighlight = k
            case .rime(let i):
                aiHighlight = nil
                Rime.shared.highlightOnPage(session, i)
            }
            showPanel(Rime.shared.state(session))
            return true
        default:
            return nil
        }
    }

    // MARK: - AI assist

    /// The model's readings of the pinyin being typed, or a reading the user picked before.
    private struct Suggestions {
        let pinyin: String
        let texts: [String]
        /// Picked before for this pinyin, so it leads, without asking the model.
        let remembered: Bool
        /// The model was sure of its first reading.
        let sure: Bool
        /// The model saw the text before the caret.
        let withContext: Bool
    }

    private var assistPinyin: String?
    private var suggestions: Suggestions?
    private var assistPending = false
    private var assistTask: Task<Void, Never>?

    /// The text before the caret the model may see, if the user allows it.
    private var assistContext: String? {
        guard AISettings.useContext, let text = compositionContext, !text.isEmpty else { return nil }
        return text
    }

    /// The pinyin worth asking about: plain letters with nothing picked yet and the caret at the
    /// end (moved back, the user is editing). Four letters or more on their own; with text
    /// before the caret to go on, a single syllable is enough.
    private func assistable(_ st: RimeState) -> String? {
        guard AISettings.config != nil, st.isComposing, !st.isAscii, st.caret >= st.preedit.utf16.count else { return nil }
        let letters = st.preedit.filter { $0 != " " && $0 != "'" }
        guard letters.allSatisfy({ $0.isASCII && $0.isLetter }),
              letters.count >= (assistContext == nil ? 4 : 2) else { return nil }
        return letters.lowercased()
    }

    /// Starts over whenever the pinyin changes: a remembered word or a recent answer shows at
    /// once; otherwise the model is asked after a short pause in typing (longer for short
    /// pinyin, which is often still being typed), and its answer is dropped if the pinyin has
    /// moved on by the time it arrives.
    private func followAssist(_ st: RimeState) {
        let pinyin = assistable(st)
        guard pinyin != assistPinyin else { return }
        assistTask?.cancel()
        assistPinyin = pinyin
        suggestions = nil
        assistPending = false
        guard let pinyin else { return }

        // A remembered pick leads straight away when there's nothing before the caret to weigh
        // it against. With text before, the same pinyin may mean something else, so the model
        // decides, told what the user picked before.
        let context = assistContext
        let remembered = pinyin.count >= 4 ? AIMemory.shared.lookup(pinyin) : nil
        if let remembered, context == nil {
            suggestions = Suggestions(pinyin: pinyin, texts: [remembered], remembered: true, sure: true, withContext: false)
            return
        }
        if let answer = AIAssist.shared.cached(pinyin, context: context) {
            take(answer, for: pinyin)
            return
        }
        let hints = st.candidates.prefix(5).map(\.text)
        assistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(pinyin.count < 4 ? 500 : 300))
            guard !Task.isCancelled, let self else { return }
            self.assistPending = true
            self.showPanel(Rime.shared.state(self.session))
            let answer = try? await AIAssist.shared.suggest(pinyin, hints: hints, picked: remembered, context: context)
            guard !Task.isCancelled, self.assistPinyin == pinyin else { return }
            self.assistPending = false
            if let answer { self.take(answer, for: pinyin) }
            self.showPanel(Rime.shared.state(self.session))
        }
    }

    private func take(_ answer: AIAnswer, for pinyin: String) {
        guard !answer.texts.isEmpty else { return }
        suggestions = Suggestions(pinyin: pinyin, texts: answer.texts, remembered: false,
                                  sure: answer.sure, withContext: answer.context != nil)
    }

    /// Keeps the memory honest: picking a reading of long pinyin strengthens it, passing over a
    /// remembered one wears it down.
    private func noteChoice(_ text: String?) {
        guard let s = suggestions, let text, s.pinyin.count >= 4 else { return }
        if s.texts.contains(text) {
            AIMemory.shared.remember(s.pinyin, text)
        } else if s.remembered, let remembered = s.texts.first {
            AIMemory.shared.wearDown(s.pinyin, remembered)
        }
    }

    private func commitSuggestion(_ k: Int) {
        guard let s = suggestions, let text = s.texts[safe: k], let sink else { return }
        noteChoice(text)
        Rime.shared.clearComposition(session)
        LumaSettings.debugLog("  commit [\(text)] (AI)")
        sink.insert(text)
        hasMarked = false
        didCommit(text)
        refresh()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
