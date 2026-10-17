import Foundation

struct RimeCandidateItem: Equatable {
    let text: String
    let comment: String
    let label: String
}

/// A snapshot of one Rime session after a key has been processed.
struct RimeState: Equatable {
    var preedit = ""
    var caret = 0  // UTF-16 offset into `preedit`
    var candidates: [RimeCandidateItem] = []
    var highlighted = 0
    var pageNo = 0
    var isLastPage = true
    var isAscii = false

    var isComposing: Bool { !preedit.isEmpty }
}

/// Thin Swift wrapper over librime's C function table.
final class Rime {
    static let shared = Rime()

    private let api: RimeApi
    private var traits = RimeTraits()

    private init() {
        api = rime_get_api().pointee
    }

    func setup(sharedDir: String, userDir: String, logToStderr: Bool) {
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

    /// Initializes the engine. `wait` blocks until deployment (dictionary compilation) is done.
    func start(fullCheck: Bool, wait: Bool) {
        api.initialize(&traits)
        if api.start_maintenance(fullCheck ? 1 : 0) != 0, wait {
            api.join_maintenance_thread()
        }
    }

    /// Releases the engine (and its lock on the user dictionary) before another process deploys.
    func shutdown() { api.finalize() }

    func redeploy() {
        api.finalize()
        start(fullCheck: true, wait: false)
    }

    var isDeploying: Bool { api.is_maintenance_mode() != 0 }

    // MARK: Sessions

    func createSession() -> RimeSessionId {
        let s = api.create_session()
        if s != 0 {
            // Candidates are laid out in a row, so Left/Right should move the highlight, not the caret.
            api.set_option(s, "_horizontal", 1)
            api.set_option(s, "_linear", 1)
        }
        return s
    }
    func exists(_ s: RimeSessionId) -> Bool { s != 0 && api.find_session(s) != 0 }
    func destroy(_ s: RimeSessionId) { _ = api.destroy_session(s) }

    func processKey(_ s: RimeSessionId, _ keysym: Int32, _ mask: Int32) -> Bool {
        api.process_key(s, keysym, mask) != 0
    }

    func selectOnPage(_ s: RimeSessionId, _ index: Int) {
        _ = api.select_candidate_on_current_page(s, index)
    }

    func commitComposition(_ s: RimeSessionId) { _ = api.commit_composition(s) }
    func clearComposition(_ s: RimeSessionId) { api.clear_composition(s) }

    func consumeCommit(_ s: RimeSessionId) -> String? {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.stride - MemoryLayout<Int32>.stride)
        guard api.get_commit(s, &commit) != 0 else { return nil }
        defer { _ = api.free_commit(&commit) }
        return commit.text.map { String(cString: $0) }
    }

    func state(_ s: RimeSessionId) -> RimeState {
        var st = RimeState()

        var ctx = RimeContext()
        ctx.data_size = Int32(MemoryLayout<RimeContext>.stride - MemoryLayout<Int32>.stride)
        if api.get_context(s, &ctx) != 0 {
            defer { _ = api.free_context(&ctx) }
            let comp = ctx.composition
            if comp.length > 0, let p = comp.preedit {
                st.preedit = String(cString: p)
                st.caret = utf16Offset(p, Int(comp.cursor_pos))
            }
            let menu = ctx.menu
            st.pageNo = Int(menu.page_no)
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
                st.candidates.append(RimeCandidateItem(
                    text: c.text.map { String(cString: $0) } ?? "",
                    comment: c.comment.map { String(cString: $0) } ?? "",
                    label: label))
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

    // MARK: Helpers

    private func cString(_ s: String) -> UnsafePointer<CChar> {
        UnsafePointer(strdup(s)!)  // lives for the whole process, as librime expects
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
        let dir = NSHomeDirectory() + "/Library/Luma"
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

    static func bootRime(logToStderr: Bool) {
        Rime.shared.setup(sharedDir: shared, userDir: user, logToStderr: logToStderr)
    }
}
