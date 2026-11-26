import Carbon
import InputMethodKit

@objc(LumaInputController)
final class LumaInputController: IMKInputController {
    private var engine: InputEngine?
    private var sink: ClientSink?

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        return MainActor.assumeIsolated {
            let handled = bind(client).handle(event)
            LumaSettings.debugLog({
                func show(_ s: String?) -> String {
                    (s ?? "nil").unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? String(format: "\\u{%x}", $0.value) : String($0) }.joined()
                }
                let type = event.type == .keyDown ? "down" : event.type == .flagsChanged ? "flags" : "\(event.type.rawValue)"
                let chars = event.type == .keyDown ? " chars=[\(show(event.characters))] ignoring=[\(show(event.charactersIgnoringModifiers))]" : ""
                let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                let layout = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyInputSourceID) }
                    .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
                return "\(type) code=\(event.keyCode) flags=\(String(event.modifierFlags.rawValue, radix: 16))\(chars) handled=\(handled) app=\(client.bundleIdentifier() ?? "?") layout=\(layout)"
            }())
            return handled
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        if let client = sender as? IMKTextInput {
            MainActor.assumeIsolated { _ = bind(client) }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        MainActor.assumeIsolated { engine?.commitPending() }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        MainActor.assumeIsolated {
            if let client = sender as? IMKTextInput { _ = bind(client) }
            engine?.commitPending()
        }
    }

    override func inputControllerWillClose() {
        MainActor.assumeIsolated { engine?.close() }
        super.inputControllerWillClose()
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu()

        // High-frequency appearance choice: Glow
        menu.addItem(.sectionHeader(title: L10n.t("glow.section", fallback: "光效")))
        let current = LumaSettings.glow
        let glows: [(LumaGlow, Selector)] = [
            (.off, #selector(useGlowOff(_:))),
            (.soft, #selector(useGlowSoft(_:))),
            (.flow, #selector(useGlowFlow(_:))),
        ]
        for (glow, action) in glows {
            let item = menu.addItem(withTitle: glow.title, action: action, keyEquivalent: "")
            item.state = glow == current ? .on : .off
        }

        menu.addItem(.separator())

        // High-frequency quick toggles
        let typo = menu.addItem(withTitle: L10n.t("menu.typo", fallback: "智能纠错"), action: #selector(toggleTypoCorrection(_:)), keyEquivalent: "")
        typo.state = LumaSettings.typoCorrection ? .on : .off
        let ai = menu.addItem(withTitle: L10n.t("menu.ai_assist", fallback: "AI 辅助"), action: #selector(toggleAIAssist(_:)), keyEquivalent: "")
        ai.state = AISettings.enabled ? .on : .off

        // Surface grammar model download progress or failure directly when active.
        let model = MainActor.assumeIsolated { (GrammarModel.shared.menuTitle, GrammarModel.shared.state) }
        switch model.1 {
        case .downloading, .verifying, .failed:
            let item = menu.addItem(withTitle: model.0, action: #selector(grammarAction(_:)), keyEquivalent: "")
            item.state = model.1 == .failed ? .off : .mixed
        case .ready, .absent:
            break
        }

        menu.addItem(.separator())

        // Unified settings & actions
        menu.addItem(withTitle: L10n.t("menu.preferences", fallback: "偏好设置…"), action: #selector(openPreferences(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L10n.t("menu.redeploy", fallback: "重新部署"), action: #selector(redeploy(_:)), keyEquivalent: "")
        let available = MainActor.assumeIsolated { Updater.shared.available?.version }
        let checkTitle = available.map { L10n.f("menu.update_to", fallback: "更新到 %@…", $0) }
            ?? L10n.t("menu.check_updates", fallback: "检查更新…")
        menu.addItem(withTitle: checkTitle, action: #selector(checkForUpdates(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        let about = menu.addItem(withTitle: "Luma 拼音 \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        return menu
    }

    @objc func useGlowOff(_ sender: Any?) { MainActor.assumeIsolated { PreferencesStore.shared.setGlow(.off) } }
    @objc func useGlowSoft(_ sender: Any?) { MainActor.assumeIsolated { PreferencesStore.shared.setGlow(.soft) } }
    @objc func useGlowFlow(_ sender: Any?) { MainActor.assumeIsolated { PreferencesStore.shared.setGlow(.flow) } }

    @objc func toggleTypoCorrection(_ sender: Any?) {
        MainActor.assumeIsolated { PreferencesStore.shared.setTypoCorrection(!LumaSettings.typoCorrection) }
    }

    @objc func toggleAIAssist(_ sender: Any?) {
        MainActor.assumeIsolated {
            let next = !AISettings.enabled
            PreferencesStore.shared.setAIEnabled(next)
            // Switched on with nothing to talk to yet: open Preferences directly on the AI tab.
            if next && AISettings.config == nil {
                PreferencesWindow.shared.show(tab: .ai)
            }
        }
    }

    @objc func grammarAction(_ sender: Any?) {
        MainActor.assumeIsolated {
            if GrammarModel.shared.state == .failed {
                GrammarModel.shared.download()
            } else {
                PreferencesWindow.shared.show(tab: .input)
            }
        }
    }

    @objc func openPreferences(_ sender: Any?) {
        MainActor.assumeIsolated { PreferencesWindow.shared.show() }
    }

    @objc func redeploy(_ sender: Any?) {
        MainActor.assumeIsolated { PreferencesStore.shared.redeploy() }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        _ = MainActor.assumeIsolated { Task { await Updater.shared.check(userInitiated: true) } }
    }

    @MainActor
    private func bind(_ client: IMKTextInput) -> InputEngine {
        let engine = self.engine ?? InputEngine()
        self.engine = engine
        engine.clientBundleID = client.bundleIdentifier()
        if sink?.client !== (client as AnyObject) {
            let sink = ClientSink(client: client, controller: self)
            self.sink = sink
            engine.sink = sink
        }
        return engine
    }
}

@MainActor
private final class ClientSink: TextSink {
    let client: IMKTextInput
    weak var controller: IMKInputController?

    init(client: IMKTextInput, controller: IMKInputController) {
        self.client = client
        self.controller = controller
    }

    private var noReplacement: NSRange { NSRange(location: NSNotFound, length: NSNotFound) }

    func insert(_ text: String) {
        client.insertText(text, replacementRange: noReplacement)
    }

    func setMarked(_ text: NSAttributedString, caret: Int) {
        client.setMarkedText(text, selectionRange: NSRange(location: caret, length: 0), replacementRange: noReplacement)
    }

    func caretRect() -> NSRect {
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    func textBeforeCaret(_ count: Int) -> String? {
        let marked = client.markedRange()
        let end = marked.location != NSNotFound && marked.length > 0 ? marked.location : client.selectedRange().location
        // At the very start, or an app that can't say where the caret is: nothing to go on.
        guard end != NSNotFound, end > 0 else { return nil }
        let start = max(0, end - count)
        guard let text = client.attributedSubstring(from: NSRange(location: start, length: end - start))?.string,
              !text.isEmpty else { return nil }
        return String(text.suffix(count))
    }

    func markedAttributes() -> [NSAttributedString.Key: Any] {
        let fallback: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        guard let raw = controller?.mark(forStyle: kTSMHiliteSelectedRawText, at: NSRange(location: 0, length: 0)) else {
            return fallback
        }
        var attrs: [NSAttributedString.Key: Any] = [:]
        for (key, value) in raw {
            if let name = key.base as? String { attrs[NSAttributedString.Key(name)] = value }
        }
        return attrs.isEmpty ? fallback : attrs
    }
}
