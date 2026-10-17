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

if flag("--deploy") || flag("--selftest") {
    LumaPaths.bootRime(logToStderr: true)
    let started = Date()
    Rime.shared.start(fullCheck: true, wait: true)
    print(String(format: "deployed in %.1fs", Date().timeIntervalSince(started)))
    if flag("--selftest") { selfTest() }
    exit(0)
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
