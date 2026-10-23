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
        let current = LumaSettings.theme
        let themes: [(LumaTheme, Selector)] = [
            (.ink, #selector(useInk(_:))), (.lumen, #selector(useLumen(_:))), (.precision, #selector(usePrecision(_:))),
        ]
        for (theme, action) in themes {
            let item = menu.addItem(withTitle: "主题 · \(theme.title)", action: action, keyEquivalent: "")
            item.state = theme == current ? .on : .off
        }
        menu.addItem(.separator())
        let typo = menu.addItem(withTitle: "智能纠错 Typo Correction", action: #selector(toggleTypoCorrection(_:)), keyEquivalent: "")
        typo.state = LumaSettings.typoCorrection ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "重新部署 Redeploy", action: #selector(redeploy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "打开配置目录 Open Config Folder", action: #selector(openUserDir(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "项目主页 Homepage", action: #selector(openHomepage(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let available = MainActor.assumeIsolated { Updater.shared.available?.version }
        let check = available.map { "更新到 \($0)… Update to \($0)…" } ?? "检查更新… Check for Updates…"
        menu.addItem(withTitle: check, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        let auto = menu.addItem(withTitle: "自动检查更新 Check Automatically", action: #selector(toggleAutoCheck(_:)), keyEquivalent: "")
        auto.state = LumaSettings.autoCheckUpdates ? .on : .off
        let about = menu.addItem(withTitle: "Luma 拼音 \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        return menu
    }

    @objc func checkForUpdates(_ sender: Any?) {
        _ = MainActor.assumeIsolated { Task { await Updater.shared.check(userInitiated: true) } }
    }

    @objc func toggleTypoCorrection(_ sender: Any?) {
        LumaSettings.typoCorrection.toggle()
    }

    @objc func toggleAutoCheck(_ sender: Any?) {
        LumaSettings.autoCheckUpdates.toggle()
    }

    @objc func useInk(_ sender: Any?) { setTheme(.ink) }
    @objc func useLumen(_ sender: Any?) { setTheme(.lumen) }
    @objc func usePrecision(_ sender: Any?) { setTheme(.precision) }

    private func setTheme(_ theme: LumaTheme) {
        MainActor.assumeIsolated { CandidatePanel.shared.setTheme(theme) }
    }

    @objc func openHomepage(_ sender: Any?) {
        NSWorkspace.shared.open(Updater.homepage)
    }

    @objc func redeploy(_ sender: Any?) {
        Rime.shared.redeploy()
    }

    @objc func openUserDir(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: LumaPaths.user))
    }

    @MainActor
    private func bind(_ client: IMKTextInput) -> InputEngine {
        let engine = self.engine ?? InputEngine()
        self.engine = engine
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
