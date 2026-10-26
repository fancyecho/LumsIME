import AppKit

/// A standalone window that drives the same engine and panel without installing the input method.
/// `--playground` lets you type; `--demo` also auto-types a short script; `--still` sets up a
/// backdrop and freezes on one state for screenshots, printing the rect to capture.
@MainActor
final class Playground: NSObject, NSApplicationDelegate {
    private let autoplay: Bool
    private let still = CommandLine.arguments.contains("--still")
    private var window: NSWindow!
    private var textView: PlaygroundTextView!

    init(autoplay: Bool) {
        self.autoplay = autoplay
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if still {
            setUpStill()
        } else {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = "Luma Playground"
            let scroll = makeTextArea(frame: window.contentLayoutRect, fontSize: 22)
            scroll.autoresizingMask = [.width, .height]
            window.contentView = scroll
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--check-updates") {
            Task { await Updater.shared.check(userInitiated: true) }
        }
        if CommandLine.arguments.contains("--ai-settings") {
            AISettingsWindow.shared.show()
        }
        if still {
            // `--type <pinyin>` freezes on any input instead of the default scene; `--toast en|zh` on
            // the 中 / A switch (one Shift leaves Chinese; a second, once that toast is gone, returns).
            let toast = LumaSettings.argument("--toast").map { ($0 == "zh" ? [Step.shift, .pause(1.4)] : []) + [.shift, .pause(0.4), .capture] }
            let script = toast ?? LumaSettings.argument("--type").map { [Step.type($0), .pause(1.0), .capture] } ?? Self.stillScript
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.play(script) }
        } else if autoplay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.play(Self.script) }
        }
    }

    private func makeTextArea(frame: NSRect, fontSize: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = !still
        scroll.drawsBackground = false
        textView = PlaygroundTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 26, height: 30)
        scroll.documentView = textView
        return scroll
    }

    /// A wallpaper-like backdrop with a translucent document card, so the panel's material has
    /// something to show through.
    private func setUpStill() {
        let size = NSSize(width: 820, height: 330)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let backdrop = NSHostingView(rootView: Backdrop())
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        container.addSubview(backdrop)
        window.contentView = container

        let card = NSVisualEffectView(frame: NSRect(x: 34, y: size.height - 52 - 128, width: size.width - 68, height: 128))
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        let scroll = makeTextArea(frame: card.bounds, fontSize: 21)
        textView.drawsBackground = false
        card.addSubview(scroll)
        container.addSubview(card)
        textView.string = "好的设计，"
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        window.center()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private enum Step { case type(String), key(UInt16), shift, pause(Double), capture }

    private static let script: [Step] = [
        .type("nihao"), .pause(0.5), .key(49), .pause(0.4),
        .type("shijie"), .pause(0.4), .key(124), .pause(0.35), .key(124), .pause(0.35), .key(123), .pause(0.35), .key(123), .pause(0.5), .key(49), .pause(0.4),
        .type("jintiantianqizhenhao"), .pause(0.6), .type("="), .pause(0.7), .type("-"), .pause(0.6), .key(49), .pause(0.4),
        .type("woxiangzuoyigeshurufa"), .pause(0.6), .key(49), .pause(0.5),
        .shift, .pause(0.6), .type(" hello"), .pause(0.6), .shift, .pause(0.8),
    ]

    private static let stillScript: [Step] = [
        .type("jintiantianqizhenhao"), .pause(0.3), .key(124), .pause(0.9), .capture,
    ]

    private func play(_ steps: [Step]) {
        guard let step = steps.first else { return }
        let rest = Array(steps.dropFirst())
        switch step {
        case .pause(let seconds):
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { self.play(rest) }
        case .capture:
            // screencapture -R wants top-left-origin coordinates.
            let f = window.frame
            let top = (NSScreen.screens.first?.frame.height ?? 0) - f.maxY
            FileHandle.standardError.write("CAPTURE \(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))\n".data(using: .utf8)!)
        case .shift:
            send(type: .flagsChanged, flags: .shift, keyCode: 56)
            send(type: .flagsChanged, flags: [], keyCode: 56)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.play(rest) }
        case .key(let code):
            send(chars: "", keyCode: code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.play(rest) }
        case .type(let text):
            guard let first = text.first else { play(rest); return }
            send(chars: String(first), keyCode: 0xffff)
            let remaining = String(text.dropFirst())
            DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0.07...0.14)) {
                self.play(remaining.isEmpty ? rest : [.type(remaining)] + rest)
            }
        }
    }

    private func send(type: NSEvent.EventType = .keyDown, flags: NSEvent.ModifierFlags = [], chars: String = "", keyCode: UInt16) {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: keyCode) else { return }
        if type == .flagsChanged { textView.flagsChanged(with: event) } else { textView.keyDown(with: event) }
    }
}

final class PlaygroundTextView: NSTextView, TextSink {
    private let engine = InputEngine()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        engine.sink = self
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        engine.sink = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func keyDown(with event: NSEvent) {
        if !engine.handle(event) { super.keyDown(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        _ = engine.handle(event)
        super.flagsChanged(with: event)
    }

    override func resignFirstResponder() -> Bool {
        engine.commitPending()
        return super.resignFirstResponder()
    }

    func insert(_ text: String) {
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func setMarked(_ text: NSAttributedString, caret: Int) {
        setMarkedText(text, selectedRange: NSRange(location: caret, length: 0),
                      replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func caretRect() -> NSRect {
        let range = hasMarkedText() ? markedRange() : selectedRange()
        return firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
    }

    func markedAttributes() -> [NSAttributedString.Key: Any] {
        [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor.controlAccentColor]
    }
}

import SwiftUI

private struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Color(hex: dark ? 0x0A0A12 : 0xF3EEE8)
            blob(dark ? 0x3B2B70 : 0xFFD6BD, at: UnitPoint(x: 0.12, y: 0.0), size: 520)
            blob(dark ? 0x0D5361 : 0xC4E4FF, at: UnitPoint(x: 0.95, y: 1.0), size: 560)
            blob(dark ? 0x6D2A4D : 0xE6D2FF, at: UnitPoint(x: 0.75, y: 0.1), size: 420)
        }
        .ignoresSafeArea()
    }

    private func blob(_ hex: UInt32, at point: UnitPoint, size: CGFloat) -> some View {
        RadialGradient(colors: [Color(hex: hex), Color(hex: hex, opacity: 0)], center: point, startRadius: 0, endRadius: size)
    }
}
