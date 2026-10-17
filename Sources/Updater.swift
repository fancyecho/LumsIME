import AppKit
import CryptoKit

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// The input method is a background process that every app types through, so nothing here is
/// modal: prompts are plain floating windows, and work happens off the main thread.
@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    nonisolated static let repo = "fancyecho/LumsIME"
    nonisolated static let homepage = URL(string: "https://github.com/\(repo)")!

    struct Release {
        let version: String
        let notes: String
        let zip: URL
        let sha256: String?
        let page: URL
    }

    enum UpdateError: LocalizedError {
        case noAsset, badResponse(Int), checksum, invalidBundle(String), command(String)

        var errorDescription: String? {
            switch self {
            case .noAsset: return "发布中没有 LumaIME.zip · The release has no LumaIME.zip"
            case .badResponse(let code): return "GitHub 返回 HTTP \(code) · GitHub returned HTTP \(code)"
            case .checksum: return "下载文件校验失败 · The download failed its checksum"
            case .invalidBundle(let why): return "安装包无效 · Invalid package: \(why)"
            case .command(let what): return "\(what) 执行失败 · \(what) failed"
            }
        }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private(set) var available: Release?
    private var window: NSWindow?
    private var busy = false

    // MARK: Checking

    /// Called at launch: checks quietly at most once a day, and only speaks up when there's news.
    func scheduleAutomaticCheck() {
        guard LumaSettings.autoCheckUpdates else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, LumaSettings.autoCheckUpdates else { return }
            if let last = LumaSettings.lastUpdateCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
            Task { await self.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        guard !busy else { return }
        do {
            let release = try await Self.fetchLatest()
            LumaSettings.lastUpdateCheck = Date()
            if Self.isVersion(release.version, newerThan: Self.currentVersion) {
                available = release
                if userInitiated || LumaSettings.skippedVersion != release.version {
                    present(.offer(release), focus: userInitiated)
                }
            } else if userInitiated {
                present(.upToDate)
            }
        } catch {
            if userInitiated { present(.failed(error, nil)) }
        }
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Luma/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let asset = payload.assets.first(where: { $0.name == "LumaIME.zip" }) else { throw UpdateError.noAsset }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        let sha = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, notes: payload.body ?? "", zip: asset.browser_download_url,
                       sha256: sha, page: payload.html_url)
    }

    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    /// Downloads, verifies and swaps in the new bundle, then compiles its dictionaries.
    /// The caller exits afterwards; macOS relaunches the input method on the next keystroke.
    nonisolated static func install(_ release: Release, log: @Sendable (String) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("LumaUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        log("下载 Downloading \(release.zip.absoluteString)")
        let (downloaded, response) = try await URLSession.shared.download(from: release.zip)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }
        let zip = work.appendingPathComponent("LumaIME.zip")
        try fm.moveItem(at: downloaded, to: zip)

        if let expected = release.sha256 {
            let digest = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError.checksum }
            log("校验通过 Checksum OK")
        }

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("LumaIME.app")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info else { throw UpdateError.invalidBundle("Info.plist") }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("bundle identifier")
        }
        guard info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError.invalidBundle("version")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        // Swap atomically; this process keeps running from the old files until it exits.
        let dest = Bundle.main.bundleURL
        log("安装 Installing → \(dest.path)")
        _ = try fm.replaceItemAt(dest, withItemAt: app)

        // Release the user dictionary while the new binary compiles, then pick the engine back up
        // (now reading the new shared data) so typing keeps working until this process exits.
        log("编译词库 Building dictionaries…")
        await MainActor.run { Rime.shared.shutdown() }
        defer { Task { @MainActor in Rime.shared.start(fullCheck: false, wait: false) } }
        try run(dest.appendingPathComponent("Contents/MacOS/LumaIME").path, ["--deploy"])
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.command(URL(fileURLWithPath: tool).lastPathComponent)
        }
        return process.terminationStatus
    }

    private func startInstall(_ release: Release) {
        guard !busy else { return }
        busy = true
        present(.installing(release))
        Task {
            do {
                try await Self.install(release)
                present(.done(release))
            } catch {
                busy = false
                present(.failed(error, release))
            }
        }
    }

    // MARK: Prompt window

    private enum Prompt {
        case offer(Release), upToDate, installing(Release), done(Release), failed(Error, Release?)
    }

    private var pending: Release?

    /// `focus` makes the prompt key (for things the user just asked for); automatic offers only float.
    private func present(_ prompt: Prompt, focus: Bool = true) {
        let alert = NSAlert()
        alert.icon = NSImage(named: "luma") ?? NSApp.applicationIconImage
        switch prompt {
        case .offer(let r):
            pending = r
            alert.messageText = "Luma 拼音 \(r.version) 可以更新了\nLuma \(r.version) is available"
            alert.informativeText = "当前版本 Current: \(Self.currentVersion)\n\n" + Self.trimNotes(r.notes)
            add(alert, "立即更新 Update Now", #selector(updateNow))
            add(alert, "稍后 Later", #selector(close))
            add(alert, "跳过此版本 Skip", #selector(skip))
        case .upToDate:
            alert.messageText = "已是最新版本\nYou're up to date"
            alert.informativeText = "Luma 拼音 \(Self.currentVersion)"
            add(alert, "好 OK", #selector(close))
        case .installing(let r):
            alert.messageText = "正在更新到 \(r.version)…\nUpdating to \(r.version)…"
            alert.informativeText = "下载、校验并编译词库，大约需要半分钟。\nDownloading, verifying and building dictionaries; about half a minute."
            let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 240, height: 16))
            spinner.style = .bar
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            alert.accessoryView = spinner
            add(alert, "后台进行 Hide", #selector(close))
        case .done(let r):
            alert.messageText = "已更新到 \(r.version)\nUpdated to \(r.version)"
            alert.informativeText = "新版本会在你下次打字时启动。\nThe new version starts the next time you type."
            add(alert, "完成 Done", #selector(finish))
        case .failed(let error, let r):
            pending = r
            alert.alertStyle = .warning
            alert.messageText = "更新失败\nUpdate failed"
            alert.informativeText = error.localizedDescription
            add(alert, "打开下载页 Open Releases", #selector(openReleases))
            add(alert, "关闭 Close", #selector(close))
        }
        alert.layout()

        window?.orderOut(nil)
        let w = alert.window
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.center()
        if let panel = w as? NSPanel {
            panel.styleMask.insert(.nonactivatingPanel)  // never pull focus away from the app being typed in
            panel.becomesKeyOnlyIfNeeded = !focus
        }
        if focus { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
        window = w
        retained = alert
    }

    private var retained: NSAlert?

    private func add(_ alert: NSAlert, _ title: String, _ action: Selector) {
        let button = alert.addButton(withTitle: title)
        button.target = self
        button.action = action
    }

    private static func trimNotes(_ notes: String) -> String {
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix { !$0.hasPrefix("**") && !$0.hasPrefix("```") }  // stop before install instructions
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func updateNow() {
        guard let r = pending else { return }
        startInstall(r)
    }

    @objc private func skip() {
        if let r = pending { LumaSettings.skippedVersion = r.version }
        close()
    }

    @objc private func openReleases() {
        NSWorkspace.shared.open(pending?.page ?? Self.homepage.appendingPathComponent("releases/latest"))
        close()
    }

    @objc private func close() {
        window?.orderOut(nil)
        window = nil
        retained = nil
    }

    @objc private func finish() {
        close()
        exit(0)
    }
}
