import Foundation

/// Luma's own record of the text just before the caret, for apps that don't share their
/// document. Kept in step with what Luma commits and the keys that go straight to the app, and
/// let go whenever the caret may have gone somewhere else: another field, a navigation key, a
/// shortcut, or a long enough pause that the user may have clicked away.
struct TypingContext {
    static let limit = 40
    private static let idle: TimeInterval = 180

    private var recent = ""
    private var lastActivity = Date.distantPast

    /// What's known to come before the caret; empty when nothing is.
    var current: String {
        Date().timeIntervalSince(lastActivity) > Self.idle ? "" : recent
    }

    mutating func append(_ text: String) {
        recent = String((current + text).suffix(Self.limit))
        lastActivity = Date()
    }

    mutating func deleteBackward() {
        recent = current
        if !recent.isEmpty { recent.removeLast() }
        lastActivity = Date()
    }

    mutating func reset() {
        recent = ""
    }
}

/// Which word the user tends to pick after which: "研究" then 试验 rather than 实验. Rime already
/// learns which word a reading usually means; this adds what came just before. A habit seen
/// at least twice lifts its word to the front of the page, silently, the way phone keyboards do.
@MainActor
final class HabitMemory {
    static let shared = HabitMemory()

    private static let threshold = 2
    private static let ceiling = 20
    private static let capacity = 5000
    private var url: URL { URL(fileURLWithPath: LumaPaths.user + "/habits.json") }
    private lazy var pairs: [String: [String: Int]] =
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String: Int]].self, from: $0) } ?? [:]
    private var saveWork: DispatchWorkItem?

    var count: Int { pairs.values.reduce(0) { $0 + $1.count } }

    /// The page index of the candidate the user usually picks after `before`, when that isn't
    /// already the first one.
    func pick(_ texts: [String], after before: String) -> Int? {
        guard let key = Self.key(before), let seen = pairs[key], let top = texts.first else { return nil }
        let floor = max(Self.threshold, (seen[top] ?? 0) + 1)
        let best = texts.indices.dropFirst().max { (seen[texts[$0]] ?? 0) < (seen[texts[$1]] ?? 0) }
        guard let best, (seen[texts[best]] ?? 0) >= floor else { return nil }
        return best
    }

    func record(_ text: String, after before: String) {
        guard let key = Self.key(before), text.count <= 8,
              text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) else { return }
        pairs[key, default: [:]][text] = min((pairs[key]?[text] ?? 0) + 1, Self.ceiling)
        if pairs.count > Self.capacity {
            // Forget the tenth of contexts seen least.
            let weakest = pairs.sorted { $0.value.values.reduce(0, +) < $1.value.values.reduce(0, +) }
            for (key, _) in weakest.prefix(Self.capacity / 10) { pairs[key] = nil }
        }
        scheduleSave()
    }

    func clear() {
        pairs = [:]
        scheduleSave()
    }

    /// The last one or two Chinese characters before the caret, or nil at a sentence boundary.
    private static func key(_ before: String) -> String? {
        let tail = before.reversed().prefix { $0.unicodeScalars.allSatisfy { $0.properties.isIdeographic } }
        return tail.isEmpty ? nil : String(tail.prefix(2).reversed())
    }

    /// Writes now anything still waiting to be saved.
    func flush() {
        guard let work = saveWork else { return }
        work.cancel()
        saveWork = nil
        save()
    }

    /// Commits come every few words, so writes are gathered up.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.save()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pairs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
