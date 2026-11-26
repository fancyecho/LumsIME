import Foundation

/// Automated unit & regression tests run via `LumaIME --test` (used by `scripts/test.sh` and CI).
@MainActor
func runUnitTests() {
    var passed = 0
    var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            print("FAIL: \(name)")
        }
    }

    // 1. Syllables splitting & respace caret preservation
    check(Syllables.split("jintiantianqi") == ["jin", "tian", "tian", "qi"], "Syllables.split full phrase")
    check(Syllables.split("zhongg") == ["zhong", "g"], "Syllables.split trailing prefix")
    let (spaced, caretMid) = Syllables.respace("jin tian qizhenhao", caret: 12)
    check(spaced == "jin tian qi zhen hao", "Syllables.respace text")
    check(caretMid == 13, "Syllables.respace caret inside next syllable (got \(caretMid))")
    let (_, caretEnd) = Syllables.respace("jin tian qizhenhao", caret: 18)
    check(caretEnd == 20, "Syllables.respace caret at end shifts by +2 spaces (got \(caretEnd))")

    // 2. PinyinHeader tone & correction flags
    let header = PinyinHeader.make(preedit: "mie you shi jian", candidate: "没有时间", corrected: "mei you shi jian")
    check(header.lead.count == 4, "PinyinHeader syllable count")
    check(header.lead.first?.corrected == true, "PinyinHeader flags corrected first syllable")
    check(header.lead.dropFirst().allSatisfy { !$0.corrected }, "PinyinHeader keeps untouched syllables clear")

    // 3. Updater version comparison
    check(Updater.isVersion("0.8.0", newerThan: "0.7.2"), "Updater newer minor")
    check(Updater.isVersion("0.7.10", newerThan: "0.7.2"), "Updater numeric patch")
    check(!Updater.isVersion("0.7.2", newerThan: "0.7.2"), "Updater equal")
    check(!Updater.isVersion("0.7.1", newerThan: "0.7.2"), "Updater older")
    check(Updater.isVersion("1.0", newerThan: "0.9.9"), "Updater different segment count")

    // 4. AI endpoint HTTPS enforcement vs localhost exemption (preserve user settings)
    let savedModel = AISettings.customModel
    let savedBaseURL = AISettings.customBaseURL
    let savedExcluded = UserDefaults.standard.stringArray(forKey: "aiExcludedApps")
    defer {
        AISettings.customModel = savedModel
        AISettings.customBaseURL = savedBaseURL
        if let savedExcluded {
            UserDefaults.standard.set(savedExcluded, forKey: "aiExcludedApps")
        } else {
            UserDefaults.standard.removeObject(forKey: "aiExcludedApps")
        }
    }
    AISettings.customModel = "test-model"
    AISettings.customBaseURL = "http://example.com/v1"
    var gotInsecure = false
    do {
        _ = try AISettings.validatedConfig(for: .custom, key: "sk-test")
    } catch AIError.insecureEndpoint {
        gotInsecure = true
    } catch {}
    check(gotInsecure, "AISettings rejects remote http:// endpoint")

    AISettings.customBaseURL = "http://localhost:11434/v1"
    check((try? AISettings.validatedConfig(for: .custom, key: "sk-test")) != nil, "AISettings allows http://localhost")
    AISettings.customBaseURL = "http://127.0.0.1:8000/v1"
    check((try? AISettings.validatedConfig(for: .custom, key: "sk-test")) != nil, "AISettings allows http://127.0.0.1")
    AISettings.customBaseURL = "https://api.example.com/v1"
    check((try? AISettings.validatedConfig(for: .custom, key: "sk-test")) != nil, "AISettings allows https:// remote")

    // 5. AI per-app exclusion defaults
    AISettings.resetExcludedApps()
    check(AISettings.isExcluded("com.apple.Terminal"), "Terminal excluded by default")
    check(AISettings.isExcluded("com.1password.1password"), "1Password excluded by default")
    check(!AISettings.isExcluded("com.apple.Notes"), "Notes allowed by default")

    // 6. Private atomic file persistence (0o600)
    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("luma-priv-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmpURL) }
    LumaPaths.writePrivate(Data("{\"ok\":true}".utf8), to: tmpURL)
    let attrs = try? FileManager.default.attributesOfItem(atPath: tmpURL.path)
    let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue
    check(perms == 0o600, "LumaPaths.writePrivate sets 0600 permissions (got \(String(describing: perms)))")

    // 7. HabitMemory learning & contextual promotion
    HabitMemory.shared.clear()
    HabitMemory.shared.record("试验", after: "开展研究")
    check(HabitMemory.shared.pick(["实验", "试验"], after: "开展研究") == nil, "HabitMemory threshold requires 2 picks")
    HabitMemory.shared.record("试验", after: "开展研究")
    check(HabitMemory.shared.pick(["实验", "试验"], after: "开展研究") == 1, "HabitMemory promotes after 2 picks")
    check(HabitMemory.shared.pick(["实验", "试验"], after: "科学") == nil, "HabitMemory does not bleed across contexts")
    HabitMemory.shared.clear()

    // 8. AIMemory remember & wearDown
    AIMemory.shared.clear()
    AIMemory.shared.remember("daishuyuzishi", "代数余子式")
    check(AIMemory.shared.lookup("daishuyuzishi") == "代数余子式", "AIMemory remembers pick")
    AIMemory.shared.wearDown("daishuyuzishi", "代数余子式")
    check(AIMemory.shared.lookup("daishuyuzishi") == nil, "AIMemory wears down to nil")
    AIMemory.shared.clear()

    // 9. Rime lifecycle safety: shutdown guards session queries without crashing
    Rime.shared.shutdown()
    check(!Rime.shared.isReady, "Rime not ready after shutdown")
    check(Rime.shared.createSession() == 0, "Rime refuses createSession while shut down")
    check(!Rime.shared.processKey(1, 0x61, 0), "Rime ignores processKey while shut down")
    Rime.shared.start(fullCheck: false, wait: true)
    check(Rime.shared.isReady, "Rime ready again after restart")

    print("unit tests: \(passed) passed, \(failed) failed")
    if failed > 0 { exit(1) }
}
