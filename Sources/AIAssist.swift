import Foundation

// MARK: - Settings

/// The language models AI assist can ask. DeepSeek is built in; anything that speaks the OpenAI
/// chat-completions format can be added as a custom service.
enum AIProvider: String, CaseIterable, Identifiable {
    case deepseekFlash = "deepseek-flash"
    case deepseekPro = "deepseek-v4-pro"
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseekFlash: return "DeepSeek V4.1 Flash (1017)"
        case .deepseekPro: return "DeepSeek V4 Pro"
        case .custom: return "自定义 · OpenAI 兼容 Custom"
        }
    }

    var isDeepSeek: Bool { self != .custom }

    /// Keys are kept per vendor, so switching between DeepSeek models keeps the same key.
    var keySlot: String { isDeepSeek ? "deepseek" : "custom" }
}

struct AIConfig: Sendable {
    let endpoint: URL
    let model: String
    let key: String
    /// DeepSeek answers in thinking mode unless told otherwise; that costs seconds per answer.
    let disableThinking: Bool
}

enum AISettings {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "aiAssist") }
        set { UserDefaults.standard.set(newValue, forKey: "aiAssist") }
    }

    static var provider: AIProvider {
        get { UserDefaults.standard.string(forKey: "aiProvider").flatMap(AIProvider.init) ?? .deepseekFlash }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }

    static var customBaseURL: String {
        get { UserDefaults.standard.string(forKey: "aiCustomBaseURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aiCustomBaseURL") }
    }

    static var customModel: String {
        get { UserDefaults.standard.string(forKey: "aiCustomModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aiCustomModel") }
    }

    // API keys live in a file only this account can read, not the keychain: the app is signed
    // ad hoc, so every update would otherwise bring up a keychain prompt mid-typing.
    private static var keysURL: URL { URL(fileURLWithPath: LumaPaths.user + "/ai_keys.json") }
    private static var keys: [String: String]?

    static func key(for provider: AIProvider) -> String {
        if keys == nil {
            keys = (try? Data(contentsOf: keysURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        }
        return keys?[provider.keySlot] ?? ""
    }

    static func setKey(_ key: String, for provider: AIProvider) {
        _ = self.key(for: provider)  // load what's there first
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keys?[provider.keySlot] = trimmed.isEmpty ? nil : trimmed
        guard let data = try? JSONEncoder().encode(keys ?? [:]) else { return }
        FileManager.default.createFile(atPath: keysURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// What to ask, or nil while AI assist is off or not set up. Screenshots, probes and
    /// evaluations never reach a model unless LUMA_AI_BASE_URL points them at one.
    static var config: AIConfig? {
        let env = ProcessInfo.processInfo.environment
        if let base = env["LUMA_AI_BASE_URL"] {
            let provider = env["LUMA_AI_PROVIDER"].flatMap(AIProvider.init) ?? .deepseekFlash
            return make(provider, baseURL: base, model: env["LUMA_AI_MODEL"] ?? provider.rawValue, key: env["LUMA_AI_KEY"] ?? "")
        }
        let tools = ["--still", "--demo", "--keys", "--eval", "--selftest"]
        guard enabled, !CommandLine.arguments.contains(where: tools.contains) else { return nil }
        return config(for: provider)
    }

    /// The configuration for `provider` as currently saved, whether or not AI assist is on.
    static func config(for provider: AIProvider, key: String? = nil) -> AIConfig? {
        let key = key ?? self.key(for: provider)
        if provider.isDeepSeek {
            return make(provider, baseURL: "https://api.deepseek.com", model: provider.rawValue, key: key)
        }
        return make(provider, baseURL: customBaseURL, model: customModel, key: key)
    }

    private static func make(_ provider: AIProvider, baseURL: String, model: String, key: String) -> AIConfig? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty, let url = URL(string: base), url.scheme?.hasPrefix("http") == true else { return nil }
        return AIConfig(endpoint: url, model: model, key: key, disableThinking: provider.isDeepSeek)
    }
}

// MARK: - Client

enum AIError: LocalizedError {
    case notConfigured, http(Int, String), badReply

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先填写 API Key 和模型 · Add an API key and model first"
        case .http(let code, let message): return "服务返回 HTTP \(code) · HTTP \(code)" + (message.isEmpty ? "" : "\n\(message)")
        case .badReply: return "没有读懂模型的回复 · Couldn't read the model's reply"
        }
    }
}

enum AIClient {
    private static let instructions = """
    你是中文拼音输入法里的选词助手。用户正在用全拼输入，拼音可能有错字母、漏字母，也可能是首字母缩写（如 yyds）。\
    请推测用户最可能想打出的中文词语或短句，特别留意网络流行语、专业术语、产品名和人名。
    规则：
    - 每个结果都要对应整段拼音，不多不少。
    - 按可能性从高到低排列，最多 3 个，互不相同。
    - 本地候选只供参考，可能是错的。
    - 只输出 json，格式为 {"candidates": ["…"]}
    示例：
    拼音：yyds → {"candidates": ["永远的神"]}
    拼音：shenjingwangluo → {"candidates": ["神经网络"]}
    """

    /// Asks the model for up to three readings of `pinyin`, most likely first.
    static func complete(pinyin: String, hints: [String], config: AIConfig) async throws -> [String] {
        var request = URLRequest(url: config.endpoint, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": "拼音：\(pinyin)\n本地候选：\(hints.isEmpty ? "无" : hints.joined(separator: "、"))"],
            ],
            "temperature": 0.2,
            "max_tokens": 120,
            "response_format": ["type": "json_object"],
            "stream": false,
        ]
        if config.disableThinking { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Failure: Decodable { struct Detail: Decodable { let message: String? }; let error: Detail? }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error?.message ?? ""
            throw AIError.http(status, message)
        }

        struct Reply: Decodable {
            struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message }
            let choices: [Choice]
        }
        struct Answer: Decodable { let candidates: [String] }
        guard let content = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(content.utf8)) else { throw AIError.badReply }
        var seen = Set<String>()
        return answer.candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 24 && !$0.contains("\n") && seen.insert($0).inserted }
    }
}

// MARK: - Assist

/// Answers for the pinyin being typed. Recent answers are kept in memory, so backspacing and
/// retyping never asks twice.
@MainActor
final class AIAssist {
    static let shared = AIAssist()

    private var answers: [String: [String]] = [:]
    private var order: [String] = []

    func cached(_ pinyin: String) -> [String]? { answers[pinyin] }

    func suggest(_ pinyin: String, hints: [String]) async throws -> [String] {
        guard let config = AISettings.config else { throw AIError.notConfigured }
        let texts = try await AIClient.complete(pinyin: pinyin, hints: hints, config: config)
        answers[pinyin] = texts
        order.append(pinyin)
        if order.count > 300 { answers[order.removeFirst()] = nil }
        return texts
    }
}

/// AI candidates the user picked, by the pinyin they were typed with. A remembered word comes up
/// first, straight away and without asking the model; picking something else instead wears it
/// down until it's forgotten.
@MainActor
final class AIMemory {
    static let shared = AIMemory()

    private static let ceiling = 5
    private var url: URL { URL(fileURLWithPath: LumaPaths.user + "/ai_memory.json") }
    private lazy var words: [String: [String: Int]] =
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String: Int]].self, from: $0) } ?? [:]

    var count: Int { words.values.reduce(0) { $0 + $1.count } }

    func lookup(_ pinyin: String) -> String? {
        words[pinyin]?.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    func remember(_ pinyin: String, _ text: String) {
        words[pinyin, default: [:]][text] = min((words[pinyin]?[text] ?? 0) + 1, Self.ceiling)
        save()
    }

    func wearDown(_ pinyin: String, _ text: String) {
        guard let score = words[pinyin]?[text] else { return }
        words[pinyin]?[text] = score > 1 ? score - 1 : nil
        if words[pinyin]?.isEmpty == true { words[pinyin] = nil }
        save()
    }

    func clear() {
        words = [:]
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(words) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
