import AppKit
import SwiftUI

/// The AI assist settings: the switch, which model to ask, its API key, and the words remembered.
@MainActor
final class AISettingsWindow {
    static let shared = AISettingsWindow()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = EditingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentViewController = NSHostingController(rootView: AISettingsView())
            w.title = "AI 辅助 · AI Assist"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = w
        }
        window?.center()
        // The input method is a background app; it has to come forward for the key field to type into.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The input method has no menu bar, so ⌘V and the other editing shortcuts never find an Edit menu
/// to carry them to the text field; send them down the responder chain directly.
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: Selector? = switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "x"): #selector(NSText.cut(_:))
        case (.command, "c"): #selector(NSText.copy(_:))
        case (.command, "v"): #selector(NSText.paste(_:))
        case (.command, "a"): #selector(NSText.selectAll(_:))
        case (.command, "z"): Selector(("undo:"))
        case ([.command, .shift], "z"): Selector(("redo:"))
        case (.command, "w"): #selector(NSWindow.performClose(_:))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private struct AISettingsView: View {
    @State private var enabled = AISettings.enabled
    @State private var provider = AISettings.provider
    @State private var baseURL = AISettings.customBaseURL
    @State private var model = AISettings.customModel
    @State private var key = AISettings.key(for: AISettings.provider)
    @State private var remembered = AIMemory.shared.count
    @State private var test = TestState.idle

    private enum TestState: Equatable {
        case idle, running, passed(String), failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    Text("启用 AI 辅助 · Enable AI Assist")
                    Text("打字停顿时，按拼音推测流行语和专业名词，作为带 ✦ 的候选出现。")
                }
            }

            Section("模型 · Model") {
                Picker("服务 · Service", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                if provider == .custom {
                    TextField("接口地址 · Base URL", text: $baseURL, prompt: Text("https://api.example.com/v1"))
                    TextField("模型名称 · Model", text: $model, prompt: Text("model-name"))
                } else {
                    LabeledContent("模型 ID · Model ID", value: provider.rawValue)
                }
                SecureField("API Key", text: $key, prompt: Text("sk-…"))
                HStack {
                    if provider.isDeepSeek, let url = URL(string: "https://platform.deepseek.com/api_keys") {
                        Link("获取 DeepSeek API Key", destination: url)
                    }
                    Spacer()
                    Button("测试连接 · Test") { runTest() }
                        .disabled(test == .running || key.isEmpty)
                }
                testResult
            }

            Section("本地记忆 · Remembered") {
                LabeledContent("已记住 · Words", value: "\(remembered)")
                HStack {
                    Text("选中过的 AI 候选会记在本机；再输入同样的拼音时直接排在第一位，不再联网。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除 · Clear") {
                        AIMemory.shared.clear()
                        remembered = 0
                    }
                    .disabled(remembered == 0)
                }
            }

            Section {
                Text("开启后，正在输入的拼音和本地候选会发送给所选服务，用于推测词语；已经上屏的文字不会发送。API Key 保存在本机 ~/Library/Luma，只有你的账户可以读取。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: enabled) { AISettings.enabled = enabled }
        .onChange(of: provider) {
            AISettings.provider = provider
            key = AISettings.key(for: provider)
            test = .idle
        }
        .onChange(of: baseURL) { AISettings.customBaseURL = baseURL }
        .onChange(of: model) { AISettings.customModel = model }
        .onChange(of: key) {
            AISettings.setKey(key, for: provider)
            test = .idle
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在连接… · Connecting…").foregroundStyle(.secondary)
            }
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    /// Asks the model about a well-known abbreviation, timing the round trip.
    private func runTest() {
        guard let config = AISettings.config(for: provider, key: key) else {
            test = .failed(AIError.notConfigured.localizedDescription)
            return
        }
        test = .running
        Task {
            let started = Date()
            do {
                let answer = try await AIClient.complete(pinyin: "yyds", hints: [], config: config)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                test = .passed("连接成功，用时 \(seconds) 秒：yyds → \(answer.first ?? "（无结果）")")
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
