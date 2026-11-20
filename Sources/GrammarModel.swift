import CryptoKit
import Foundation

/// The grammar model, 万象语法模型 (wanxiang-lts-zh-hans.gram, CC BY 4.0, by amzxyz): it tells
/// Rime's sentence maker which words go together, so 我们开个会吧 comes out instead of 把, and
/// 这个价格太贵了 instead of 这个家个. Support/rime/luma.yaml names it, and octagram looks for it in
/// the user folder.
///
/// At 390 MB it isn't bundled: it's downloaded once in the background, checked against its SHA-256,
/// and then Rime is restarted to load it. Until then the sentence maker works as it did without one.
@MainActor
final class GrammarModel: NSObject {
    static let shared = GrammarModel()

    nonisolated static let fileName = "wanxiang-lts-zh-hans.gram"
    nonisolated static let source = URL(string: "https://github.com/amzxyz/rime-wanxiang-data/releases/download/LTS/wanxiang-lts-zh-hans.gram")!
    nonisolated static let byteCount: Int64 = 390_786_092
    nonisolated static let sha256 = "e9ddd501b7d536bc5ea1346f8f900ae49a719a05be349e0a17cb27e717143ca5"
    nonisolated static var path: String { LumaPaths.user + "/" + fileName }

    enum State: Equatable {
        case absent, downloading(Double), verifying, ready, failed
    }

    private(set) var state: State
    private var session: URLSession?

    private override init() {
        state = FileManager.default.fileExists(atPath: Self.path) ? .ready : .absent
        super.init()
    }

    /// For the input menu: "语法模型 · 下载中 42%" and the like.
    var menuTitle: String {
        let base = "语法模型 Grammar Model"
        switch state {
        case .ready, .absent: return base
        case .downloading(let done): return "\(base) · 下载中 \(Int(done * 100))%"
        case .verifying: return "\(base) · 校验中 Verifying"
        case .failed: return "\(base) · 下载失败，点击重试 Failed, click to retry"
        }
    }

    /// At launch: fetches the model if it's wanted and missing, once typing has settled down.
    func scheduleDownload() {
        guard LumaSettings.grammarModel, state == .absent || state == .failed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.download() }
    }

    /// The menu item: on fetches the model; off cancels a download, or removes the file (390 MB)
    /// and restarts Rime without it.
    func toggle() {
        switch state {
        case .absent, .failed:
            LumaSettings.grammarModel = true
            download()
        case .ready, .downloading, .verifying:
            LumaSettings.grammarModel = false
            session?.invalidateAndCancel()
            session = nil
            let loaded = state == .ready
            try? FileManager.default.removeItem(atPath: Self.path)
            state = .absent
            if loaded { Rime.shared.redeploy() }
        }
    }

    func download() {
        guard LumaSettings.grammarModel, session == nil, state != .ready else { return }
        state = .downloading(0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: Self.source).resume()
    }

    private func finish(_ result: State) {
        session?.finishTasksAndInvalidate()
        session = nil
        guard LumaSettings.grammarModel else {  // switched off while it was finishing
            try? FileManager.default.removeItem(atPath: Self.path)
            state = .absent
            return
        }
        state = result
        if result == .ready { Rime.shared.redeploy() }
    }

    /// Streams the file through SHA-256 rather than mapping all 390 MB at once.
    nonisolated static func digest(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension GrammarModel: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten written: Int64, totalBytesExpectedToWrite _: Int64) {
        let done = min(1, Double(written) / Double(Self.byteCount))
        Task { @MainActor in
            if case .downloading = self.state { self.state = .downloading(done) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns, so verify and move it here, off the main thread.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in self.state = .verifying }
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        guard status == 200, size == Self.byteCount, Self.digest(of: location) == Self.sha256 else {
            Task { @MainActor in self.finish(.failed) }
            return
        }
        let target = URL(fileURLWithPath: Self.path)
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: location, to: target)
            Task { @MainActor in self.finish(.ready) }
        } catch {
            Task { @MainActor in self.finish(.failed) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        Task { @MainActor in
            if self.session === session { self.finish(.failed) }
        }
    }
}
