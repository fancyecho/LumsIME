import Foundation

enum LumaTheme: String, CaseIterable {
    case ink, lumen, precision

    var title: String {
        switch self {
        case .ink: return "墨 Ink"
        case .lumen: return "光 Lumen"
        case .precision: return "刻 Precision"
        }
    }
}

enum LumaSettings {
    private static let themeKey = "theme"

    static var theme: LumaTheme {
        get {
            if let arg = argument("--theme"), let t = LumaTheme(rawValue: arg) { return t }
            return UserDefaults.standard.string(forKey: themeKey).flatMap(LumaTheme.init) ?? .lumen
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }

    /// Smart typo correction (see Support/rime/lua/luma_typo.lua).
    static var typoCorrection: Bool {
        get { UserDefaults.standard.object(forKey: "typoCorrection") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "typoCorrection") }
    }

    static var autoCheckUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }

    static var lastUpdateCheck: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "skippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "skippedVersion") }
    }

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// The small reading line above the candidates: tone-marked pinyin for the highlighted
/// candidate, followed by the raw syllables it doesn't cover yet. Syllables a typo correction
/// changed are flagged so the panel can tint them.
struct PinyinHeader: Equatable {
    struct Syllable: Equatable {
        var text: String
        var corrected = false
    }

    var lead: [Syllable] = []
    var rest = ""
    var separator = " "

    static func make(preedit: String, candidate: String, corrected: String? = nil,
                     apostrophes: Bool) -> PinyinHeader {
        // Rime shows already-selected segments as Hanzi at the front; keep only the raw syllables.
        // When a shorter candidate is highlighted, Rime leaves the uncovered tail as one chunk
        // ("qizhenhao"), so re-split every chunk into syllables.
        let raw = preedit
            .split(whereSeparator: { $0 == " " || $0 == "'" })
            .map(String.init)
            .filter { $0.unicodeScalars.allSatisfy { $0.isASCII || $0 == "ü" } }
            .flatMap(Syllables.split)
        let separator = apostrophes ? "'" : " "

        let hanzi = candidate.unicodeScalars.filter { $0.properties.isIdeographic }
        guard !hanzi.isEmpty, hanzi.count == candidate.unicodeScalars.count else {
            return PinyinHeader(rest: raw.joined(separator: separator), separator: separator)
        }

        // For a correction, what the word really reads takes the place of what was typed.
        let intended = corrected?.split(separator: " ").map(String.init)
        let toned = tonedSyllables(candidate)
        var lead: [Syllable] = []
        for (i, syllable) in toned.enumerated() {
            let typed = i < raw.count ? raw[i] : nil
            let reading = intended.flatMap { i < $0.count ? $0[i] : nil } ?? typed
            var fixed = false
            if let typed, let intended, i < intended.count {
                let a = plain(intended[i]), b = plain(typed)
                fixed = !(a == b || (i == raw.count - 1 && a.hasPrefix(b)))
            }
            let text: String
            if let reading, !plain(syllable).hasPrefix(plain(reading)) {
                text = reading  // polyphone the transform got wrong; trust the reading
            } else {
                text = apostrophes ? (reading ?? plain(syllable)) : syllable
            }
            lead.append(Syllable(text: text, corrected: fixed))
        }
        let rest = raw.count > toned.count ? raw[toned.count...].joined(separator: separator) : ""
        return PinyinHeader(lead: lead, rest: rest, separator: separator)
    }

    private static var cache: [String: [String]] = [:]

    private static func tonedSyllables(_ text: String) -> [String] {
        if let hit = cache[text] { return hit }
        let s = NSMutableString(string: text)
        CFStringTransform(s, nil, kCFStringTransformMandarinLatin, false)
        var parts = (s as String).split(separator: " ").map(String.init)
        if parts.count != text.count {
            // Whole-phrase transform merged or split syllables; fall back to per-character.
            parts = text.map { ch -> String in
                let one = NSMutableString(string: String(ch))
                CFStringTransform(one, nil, kCFStringTransformMandarinLatin, false)
                return one as String
            }
        }
        if cache.count > 2000 { cache.removeAll() }
        cache[text] = parts
        return parts
    }

    private static func plain(_ s: String) -> String {
        (s.applyingTransform(.stripDiacritics, reverse: false) ?? s)
            .lowercased()
            .replacingOccurrences(of: "v", with: "u")
    }
}

/// Pinyin syllables, read from the bundled single-character dictionary rather than hard-coded.
enum Syllables {
    private static let all: Set<String> = {
        let path = LumaPaths.shared + "/cn_dicts/8105.dict.yaml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var set = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count >= 2, !line.hasPrefix("#") { set.insert(String(fields[1])) }
        }
        return set
    }()

    private static let prefixes: Set<String> = {
        var set = Set<String>()
        for syllable in all {
            for n in 1...syllable.count { set.insert(String(syllable.prefix(n))) }
        }
        return set
    }()

    /// Re-spaces collapsed chunks in a preedit ("jin tian qizhenhao" → "jin tian qi zhen hao"),
    /// moving a UTF-16 caret along with the inserted spaces.
    static func respace(_ preedit: String, caret: Int) -> (String, Int) {
        var out = ""
        var newCaret = caret
        var consumed = 0  // UTF-16 units of the original preedit already copied
        var chunk = ""
        func flush() {
            guard !chunk.isEmpty else { return }
            let pieces = chunk.unicodeScalars.allSatisfy({ $0.isASCII }) ? split(chunk) : [chunk]
            var offset = 0
            for (i, piece) in pieces.enumerated() {
                if i > 0 {
                    out += " "
                    if caret > consumed + offset { newCaret += 1 }
                }
                out += piece
                offset += piece.utf16.count
            }
            consumed += chunk.utf16.count
            chunk = ""
        }
        for ch in preedit {
            if ch == " " || ch == "'" {
                flush()
                out.append(ch)
                consumed += 1
            } else {
                chunk.append(ch)
            }
        }
        flush()
        return (out, newCaret)
    }

    /// Splits a chunk into the fewest whole syllables, letting the last piece be a syllable
    /// still being typed. Returns the chunk unchanged when no split fits.
    static func split(_ chunk: String) -> [String] {
        let lower = chunk.lowercased()
        guard !all.isEmpty, chunk.count > 1, !all.contains(lower) else { return [chunk] }
        let chars = Array(chunk)
        let n = chars.count
        // best[i]: fewest pieces covering chars[i...]
        var best = [[String]?](repeating: nil, count: n + 1)
        best[n] = []
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: min(n, i + 6), to: i, by: -1) {
                let piece = String(chars[i..<j])
                let key = piece.lowercased()
                guard all.contains(key) || (j == n && prefixes.contains(key)), let tail = best[j] else { continue }
                if best[i] == nil || tail.count + 1 < best[i]!.count { best[i] = [piece] + tail }
            }
        }
        return best[0] ?? [chunk]
    }
}
