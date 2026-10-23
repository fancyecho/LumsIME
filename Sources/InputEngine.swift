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

        let panel = CandidatePanel.shared
        if st.candidates.isEmpty {
            panel.hide()
        } else {
            panel.show(st, near: sink.caretRect()) { [weak self] index in self?.select(index) }
        }

        if let last = lastAscii, last != st.isAscii {
            panel.toast(st.isAscii ? "A" : "中", near: sink.caretRect())
        }
        lastAscii = st.isAscii
    }
}
