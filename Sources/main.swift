import Carbon
import Cocoa
import InputMethodKit

let arguments = CommandLine.arguments

func flag(_ name: String) -> Bool { arguments.contains(name) }

if flag("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print(status == noErr ? "registered" : "register failed: \(status)")
    exit(0)
}

if flag("--deploy") || flag("--selftest") || flag("--eval") || flag("--keys") {
    LumaPaths.bootRime(logToStderr: true)
    let started = Date()
    Rime.shared.start(fullCheck: true, wait: true)
    print(String(format: "deployed in %.1fs", Date().timeIntervalSince(started)))
    if flag("--selftest") { selfTest() }
    if let keys = LumaSettings.argument("--keys") { MainActor.assumeIsolated { probeKeys(keys) } }
    if let path = LumaSettings.argument("--eval") { evaluate(path) }
    exit(0)
}

if flag("--update") {
    // Headless update, also handy for scripts: checks GitHub and installs a newer release.
    LumaPaths.bootRime(logToStderr: false)
    Task {
        do {
            let release = try await Updater.fetchLatest()
            print("current \(Updater.currentVersion), latest \(release.version)")
            if Updater.isVersion(release.version, newerThan: Updater.currentVersion) || flag("--force") {
                try await Updater.install(release) { print($0) }
                print("updated to \(release.version)")
            } else {
                print("up to date")
            }
            exit(0)
        } catch {
            print("update failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared

if flag("--playground") || flag("--demo") || flag("--still") {
    LumaPaths.bootRime(logToStderr: true)
    Rime.shared.start(fullCheck: false, wait: true)
    app.setActivationPolicy(.regular)
    switch LumaSettings.argument("--appearance") {
    case "dark": app.appearance = NSAppearance(named: .darkAqua)
    case "light": app.appearance = NSAppearance(named: .aqua)
    default: break
    }
    let playground = MainActor.assumeIsolated { Playground(autoplay: flag("--demo")) }
    app.delegate = playground
    app.run()
} else {
    LumaPaths.bootRime(logToStderr: false)
    Rime.shared.start(fullCheck: false, wait: false)
    let info = Bundle.main.infoDictionary ?? [:]
    let server = IMKServer(name: info["InputMethodConnectionName"] as? String ?? "Luma_Connection",
                           bundleIdentifier: Bundle.main.bundleIdentifier)
    MainActor.assumeIsolated { Updater.shared.scheduleAutomaticCheck() }
    withExtendedLifetime(server) { app.run() }
}

func selfTest() {
    let rime = Rime.shared
    let session = rime.createSession()
    for input in ["nihao", "shijie", "jintiantianqizhenhao", "luma"] {
        let started = Date()
        for scalar in input.unicodeScalars { _ = rime.processKey(session, Int32(scalar.value), 0) }
        let st = rime.state(session)
        let ms = Date().timeIntervalSince(started) * 1000
        let list = st.candidates.map { "\($0.label).\($0.text)\($0.comment.isEmpty ? "" : "(\($0.comment))")" }
        print("\(input) [\(st.preedit)] \(String(format: "%.1fms", ms)): \(list.joined(separator: " "))")
        _ = rime.processKey(session, 0x20, 0)
        print("  commit → \(rime.consumeCommit(session) ?? "-")")
    }
    rime.destroy(session)
}

/// Reads `input<TAB>expected[<TAB>group]` lines and reports where `expected` ranks among the
/// first three pages of candidates, per group. Used to measure typo tolerance.
func evaluate(_ path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); return }
    let rime = Rime.shared
    let session = rime.createSession()
    if flag("--no-typo") { rime.setOption(session, "luma_typo_off", true) }
    struct Tally { var n = 0, top1 = 0, top3 = 0, top7 = 0, found = 0 }
    var groups: [String: Tally] = [:]
    var order: [String] = []
    var slowest = 0.0, total = 0.0
    let verbose = flag("--verbose")
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let f = line.split(separator: "\t").map(String.init)
        guard f.count >= 2 else { continue }
        let (input, expected, group) = (f[0], f[1], f.count > 2 ? f[2] : "all")
        rime.clearComposition(session)
        let started = Date()
        for scalar in input.unicodeScalars { _ = rime.processKey(session, Int32(scalar.value), 0) }
        var seen: [String] = []
        for page in 0..<3 {
            let st = rime.state(session)
            seen += st.candidates.map(\.text)
            if st.isLastPage || page == 2 { break }
            _ = rime.processKey(session, 0xff56, 0)  // Page_Down
        }
        let ms = Date().timeIntervalSince(started) * 1000
        total += ms; slowest = max(slowest, ms)
        if flag("--dump") { print("\(input)\t\(seen.prefix(3).joined(separator: " "))"); continue }
        let rank = (seen.firstIndex(of: expected) ?? -1) + 1
        if groups[group] == nil { order.append(group) }
        var t = groups[group, default: Tally()]
        t.n += 1
        if rank == 1 { t.top1 += 1 }
        if rank >= 1 && rank <= 3 { t.top3 += 1 }
        if rank >= 1 && rank <= 7 { t.top7 += 1 }
        if rank >= 1 { t.found += 1 }
        groups[group] = t
        if verbose || (rank != 1 && flag("--misses")) {
            print("\(group)\t\(input)\t\(expected)\trank=\(rank)\t\(seen.prefix(flag("--all") ? 99 : 5).joined(separator: " "))")
        }
    }
    rime.destroy(session)
    if flag("--dump") { return }
    func pct(_ a: Int, _ n: Int) -> String { String(format: "%5.1f%%", Double(a) * 100 / Double(max(n, 1))) }
    print("group\t\tn\ttop1\ttop3\ttop7\tany")
    for g in order {
        let t = groups[g]!
        print("\(g.padding(toLength: 14, withPad: " ", startingAt: 0))\t\(t.n)\t\(pct(t.top1, t.n))\t\(pct(t.top3, t.n))\t\(pct(t.top7, t.n))\t\(pct(t.found, t.n))")
    }
    let count = groups.values.reduce(0) { $0 + $1.n }
    print(String(format: "avg %.1fms, slowest %.1fms", total / Double(max(count, 1)), slowest))
}

/// Feeds a key sequence through InputEngine and prints what reaches the text field, e.g.
/// `--keys "S+H S+i ni hao space"`: `S+x` is x with Shift held (Shift pressed and released
/// around it), a bare word is typed letter by letter, `space`/`return`/`esc`/`left`/`right` are
/// keys, a single digit picks by number, and `wait` lets AI assist answer (two seconds). In the
/// printed menu, `>` marks the highlight, `✦` an AI suggestion, `~` a phrase Rime assembled
/// and `•` a typo correction.
@MainActor
func probeKeys(_ spec: String) {
    final class Sink: TextSink {
        var text = "", marked = ""
        func insert(_ t: String) { text += t; marked = "" }
        func setMarked(_ t: NSAttributedString, caret: Int) { marked = t.string }
        func caretRect() -> NSRect { .zero }
        func markedAttributes() -> [NSAttributedString.Key: Any] { [:] }
    }
    let sink = Sink()
    let engine = InputEngine()
    engine.sink = sink
    func send(_ type: NSEvent.EventType, _ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) {
        guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                       context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        if !engine.handle(e), type == .keyDown { sink.text += chars }  // unhandled keys reach the app
    }
    for token in spec.split(separator: " ").map(String.init) {
        switch token {
        case "space": send(.keyDown, " ", 49, [])
        case "return": send(.keyDown, "\r", 36, [])
        case "esc": send(.keyDown, "\u{1b}", 53, [])
        case "left": send(.keyDown, "\u{f702}", 123, [])
        case "right": send(.keyDown, "\u{f703}", 124, [])
        case "wait": RunLoop.main.run(until: Date().addingTimeInterval(2))
        case "shift": send(.flagsChanged, "", 56, .shift); send(.flagsChanged, "", 56, [])
        case _ where token.hasPrefix("K") && token.contains(":"):
            // K:<keycode> or KS:<keycode>: a real keyboard event, characters resolved by the
            // current keyboard layout, the way they arrive from the system.
            // Prefix letters after K: S = Shift, A = Option (alt), e.g. KAS:33.
            let mods = token.split(separator: ":")[0].dropFirst()
            let shift = mods.contains("S")
            guard let code = UInt16(token.split(separator: ":")[1]),
                  let cg = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { break }
            cg.flags = CGEventFlags(rawValue: (shift ? CGEventFlags.maskShift.rawValue : 0)
                                    | (mods.contains("A") ? CGEventFlags.maskAlternate.rawValue : 0))
            // Rebuild it the way the system delivers it: charactersIgnoringModifiers drops Shift too.
            guard let typed = NSEvent(cgEvent: cg), let plainCG = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let plain = NSEvent(cgEvent: plainCG),
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: typed.modifierFlags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: typed.characters ?? "",
                                           charactersIgnoringModifiers: plain.characters ?? "", isARepeat: false, keyCode: code)
            else { break }
            print("  event chars=[\(e.characters ?? "nil")] ignoring=[\(e.charactersIgnoringModifiers ?? "nil")] keysym=\(KeyMap.keysym(for: e).map { String($0, radix: 16) } ?? "nil")")
            if shift { send(.flagsChanged, "", 56, .shift) }
            if !engine.handle(e) { sink.text += e.characters ?? "" }
            if shift { send(.flagsChanged, "", 56, []) }
        case _ where token.hasPrefix("S+"):
            send(.flagsChanged, "", 56, .shift)
            for ch in token.dropFirst(2) { send(.keyDown, String(ch).uppercased(), 0xffff, .shift) }
            send(.flagsChanged, "", 56, [])
        default:
            for ch in token { send(.keyDown, String(ch), 0xffff, []) }
        }
        let model = CandidatePanel.shared.model
        let menu = model.visible || model.mode == .candidates && !model.candidates.isEmpty
            ? model.candidates.prefix(5).enumerated().map { ($0.offset == model.highlighted ? ">" : "") + ($0.element.ai ? "✦" : "") + ($0.element.composed ? "~" : "") + ($0.element.corrected != nil ? "•" : "") + $0.element.text }
            : []
        print("\(token.padding(toLength: 8, withPad: " ", startingAt: 0)) text=[\(sink.text)] marked=[\(sink.marked)] menu=\(menu)\(model.aiPending ? " (asking AI)" : "")")
    }
}
