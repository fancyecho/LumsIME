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

if flag("--deploy") || flag("--selftest") || flag("--eval") {
    LumaPaths.bootRime(logToStderr: true)
    let started = Date()
    Rime.shared.start(fullCheck: true, wait: true)
    print(String(format: "deployed in %.1fs", Date().timeIntervalSince(started)))
    if flag("--selftest") { selfTest() }
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
