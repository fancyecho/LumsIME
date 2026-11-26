import Foundation

struct RimeCandidateItem: Equatable {
    let text: String
    let comment: String
    let label: String
    /// Pinyin of a typo correction (luma_typo.lua marks those comments with "\u{1}").
    var corrected: String? = nil
    /// Suggested by AI assist rather than (or as well as) the dictionary.
    var ai = false
    /// Assembled by Rime's sentence maker rather than found as a word (luma_kind.lua marks
    /// those comments with "\u{2}"): a guess, so an AI suggestion may outrank it.
    var composed = false
}

/// A snapshot of one Rime session after a key has been processed.
struct RimeState: Equatable {
    /// The keys typed, unlike `preedit`, which changes with the highlighted candidate.
    var input = ""
    var preedit = ""
    var caret = 0  // UTF-16 offset into `preedit`
    var candidates: [RimeCandidateItem] = []
    var highlighted = 0
    var pageNo = 0
    var pageSize = 7
    var isLastPage = true
    var isAscii = false

    var isComposing: Bool { !preedit.isEmpty }
}

/// Thread-safe Swift wrapper over librime's C function table with explicit lifecycle guards.
final class Rime {
    static let shared = Rime()

    /// Posted synchronously on the main thread right before `finalize()` tears down sessions.
    static let willResetNotification = Notification.Name("LumaRimeWillReset")
    /// Posted on the main thread after `redeploy()` / `start()` finishes maintenance.
    static let didDeployNotification = Notification.Name("LumaRimeDidDeploy")

    enum Lifecycle: Equatable {
        case idle, running, shuttingDown
    }

    private let api: RimeApi
    private var traits = RimeTraits()
    private let lock = NSRecursiveLock()
    private var lifecycle: Lifecycle = .idle
    private var allocatedStrings: [UnsafeMutablePointer<CChar>] = []

    private init() {
        api = rime_get_api().pointee
    }

    var isDeploying: Bool {
        lock.withLock {
            lifecycle == .running && api.is_maintenance_mode() != 0
        }
    }

    var isReady: Bool {
        lock.withLock {
            lifecycle == .running && api.is_maintenance_mode() == 0
        }
    }

    func setup(sharedDir: String, userDir: String, logToStderr: Bool) {
        lock.withLock {
            freeAllocatedStrings()
            traits = RimeTraits()
            traits.data_size = Int32(MemoryLayout<RimeTraits>.stride - MemoryLayout<Int32>.stride)
            traits.shared_data_dir = cString(sharedDir)
            traits.user_data_dir = cString(userDir)
            traits.distribution_name = cString("Luma")
            traits.distribution_code_name = cString("Luma")
            traits.distribution_version = cString(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
            traits.app_name = cString("rime.luma")
            traits.min_log_level = 1
            traits.log_dir = logToStderr ? cString("") : nil
            api.setup(&traits)
        }
    }

    /// Initializes the engine. `wait` blocks until deployment (dictionary compilation) is done.
    func start(fullCheck: Bool, wait: Bool) {
        lock.withLock {
            guard lifecycle != .running else { return }
            api.initialize(&traits)
            lifecycle = .running
            let started = api.start_maintenance(fullCheck ? 1 : 0) != 0
            if started && wait {
                api.join_maintenance_thread()
            } else if started {
                watchDeployment()
            }
        }
    }

    /// Releases the engine (and its lock on the user dictionary) before another process deploys.
    /// Must be called on the main thread when active InputEngines exist so they can detach first.
    func shutdown() {
        notifyWillReset()
        lock.withLock {
            guard lifecycle == .running else { return }
            lifecycle = .shuttingDown
            if api.is_maintenance_mode() != 0 {
                api.join_maintenance_thread()
            }
            api.finalize()
            lifecycle = .idle
        }
    }

    func redeploy() {
        notifyWillReset()
        lock.withLock {
            if lifecycle == .running {
                lifecycle = .shuttingDown
                if api.is_maintenance_mode() != 0 {
                    api.join_maintenance_thread()
                }
                api.finalize()
                lifecycle = .idle
            }
            api.initialize(&traits)
            lifecycle = .running
            if api.start_maintenance(1) != 0 {
                watchDeployment()
            } else {
                notifyDidDeploy()
            }
        }
    }

    private func notifyWillReset() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.willResetNotification, object: self)
        } else {
            DispatchQueue.main.sync {
                NotificationCenter.default.post(name: Self.willResetNotification, object: self)
            }
        }
    }

    private func notifyDidDeploy() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didDeployNotification, object: self)
        }
    }

    private func watchDeployment() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while self.isDeploying {
                Thread.sleep(forTimeInterval: 0.25)
            }
            self.notifyDidDeploy()
        }
    }

    // MARK: Sessions

    func createSession() -> RimeSessionId {
        lock.withLock {
            guard lifecycle == .running, api.is_maintenance_mode() == 0 else { return 0 }
            let s = api.create_session()
            if s != 0 {
                // Horizontal bar uses linear Left/Right selection; vertical card uses Up/Down.
                let horizontal: Int32 = LumaSettings.layout == .horizontal ? 1 : 0
                api.set_option(s, "_horizontal", horizontal)
                api.set_option(s, "_linear", horizontal)
            }
            return s
        }
    }

    func exists(_ s: RimeSessionId) -> Bool {
        lock.withLock {
            guard lifecycle == .running, s != 0 else { return false }
            return api.find_session(s) != 0
        }
    }

    func destroy(_ s: RimeSessionId) {
        lock.withLock {
            guard lifecycle == .running, s != 0 else { return }
            _ = api.destroy_session(s)
        }
    }

    func processKey(_ s: RimeSessionId, _ keysym: Int32, _ mask: Int32) -> Bool {
        lock.withLock {
            guard lifecycle == .running, s != 0, api.is_maintenance_mode() == 0 else { return false }
            return api.process_key(s, keysym, mask) != 0
        }
    }

    func selectOnPage(_ s: RimeSessionId, _ index: Int) {
        lock.withLock {
            guard lifecycle == .running, s != 0, api.is_maintenance_mode() == 0 else { return }
            _ = api.select_candidate_on_current_page(s, index)
        }
    }

    func highlightOnPage(_ s: RimeSessionId, _ index: Int) {
        lock.withLock {
            guard lifecycle == .running, s != 0, api.is_maintenance_mode() == 0 else { return }
            _ = api.highlight_candidate_on_current_page(s, index)
        }
    }

    func setOption(_ s: RimeSessionId, _ name: String, _ value: Bool) {
        lock.withLock {
            guard lifecycle == .running, s != 0 else { return }
            api.set_option(s, name, value ? 1 : 0)
        }
    }

    func commitComposition(_ s: RimeSessionId) {
        lock.withLock {
            guard lifecycle == .running, s != 0 else { return }
            _ = api.commit_composition(s)
        }
    }

    func clearComposition(_ s: RimeSessionId) {
        lock.withLock {
            guard lifecycle == .running, s != 0 else { return }
            api.clear_composition(s)
        }
    }

    func consumeCommit(_ s: RimeSessionId) -> String? {
        lock.withLock {
            guard lifecycle == .running, s != 0 else { return nil }
            var commit = RimeCommit()
            commit.data_size = Int32(MemoryLayout<RimeCommit>.stride - MemoryLayout<Int32>.stride)
            guard api.get_commit(s, &commit) != 0 else { return nil }
            defer { _ = api.free_commit(&commit) }
            return commit.text.map { String(cString: $0) }
        }
    }

    func state(_ s: RimeSessionId) -> RimeState {
        lock.withLock {
            var st = RimeState()
            guard lifecycle == .running, s != 0 else { return st }

            var ctx = RimeContext()
            ctx.data_size = Int32(MemoryLayout<RimeContext>.stride - MemoryLayout<Int32>.stride)
            if api.get_context(s, &ctx) != 0 {
                defer { _ = api.free_context(&ctx) }
                if let raw = api.get_input(s) { st.input = String(cString: raw) }
                let comp = ctx.composition
                if comp.length > 0, let p = comp.preedit {
                    st.preedit = String(cString: p)
                    st.caret = utf16Offset(p, Int(comp.cursor_pos))
                }
                let menu = ctx.menu
                st.pageNo = Int(menu.page_no)
                if menu.page_size > 0 { st.pageSize = Int(menu.page_size) }
                st.isLastPage = menu.is_last_page != 0
                st.highlighted = Int(menu.highlighted_candidate_index)
                let selectKeys = menu.select_keys.map { Array(String(cString: $0)) }
                for i in 0..<Int(menu.num_candidates) {
                    let c = menu.candidates[i]
                    let label: String
                    if let labels = ctx.select_labels, let l = labels[i] {
                        label = String(cString: l)
                    } else if let keys = selectKeys, i < keys.count {
                        label = String(keys[i])
                    } else {
                        label = String((i + 1) % 10)
                    }
                    var comment = c.comment.map { String(cString: $0) } ?? ""
                    let composed = comment.hasPrefix("\u{2}")
                    if composed { comment.removeFirst() }
                    var corrected: String?
                    if comment.hasPrefix("\u{1}") {
                        corrected = String(comment.dropFirst())
                        comment = ""
                    }
                    st.candidates.append(RimeCandidateItem(
                        text: c.text.map { String(cString: $0) } ?? "",
                        comment: comment, label: label, corrected: corrected, composed: composed))
                }
            }

            var status = RimeStatus()
            status.data_size = Int32(MemoryLayout<RimeStatus>.stride - MemoryLayout<Int32>.stride)
            if api.get_status(s, &status) != 0 {
                st.isAscii = status.is_ascii_mode != 0
                _ = api.free_status(&status)
            }
            return st
        }
    }

    // MARK: Helpers

    private func cString(_ s: String) -> UnsafePointer<CChar> {
        let ptr = strdup(s)!
        allocatedStrings.append(ptr)
        return UnsafePointer(ptr)
    }

    private func freeAllocatedStrings() {
        for ptr in allocatedStrings { free(ptr) }
        allocatedStrings.removeAll()
    }

    private func utf16Offset(_ p: UnsafePointer<CChar>, _ byteOffset: Int) -> Int {
        let n = min(byteOffset, strlen(p))
        let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: n)
        return String(decoding: bytes, as: UTF8.self).utf16.count
    }
}

enum LumaPaths {
    static var shared: String {
        Bundle.main.sharedSupportPath ?? (Bundle.main.bundlePath + "/Contents/SharedSupport")
    }

    static var user: String {
        // LUMA_USER_DIR lets tests deploy into a scratch folder instead of the real one.
        let dir = ProcessInfo.processInfo.environment["LUMA_USER_DIR"] ?? (NSHomeDirectory() + "/Library/Luma")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let custom = dir + "/default.custom.yaml"
        if !fm.fileExists(atPath: custom) {
            let yaml = """
            # Luma 默认配置，可自行修改后在菜单栏选择「重新部署」
            patch:
              schema_list:
                - schema: rime_ice
              menu/page_size: 7

            """
            try? yaml.write(toFile: custom, atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Atomically writes `data` to `url` with owner-only (`0o600`) permissions so keys and
    /// typing records are never partially written or readable by other local accounts.
    static func writePrivate(_ data: Data, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url.path) != 0 {
            _ = try? fm.replaceItemAt(url, withItemAt: tmp)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func bootRime(logToStderr: Bool) {
        Rime.shared.setup(sharedDir: shared, userDir: user, logToStderr: logToStderr)
    }
}
