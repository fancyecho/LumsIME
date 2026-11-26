import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Single source of truth shared between the input menu and the Preferences window so toggling
/// anything from either place stays immediately in sync.
@MainActor
@Observable
final class PreferencesStore {
    static let shared = PreferencesStore()

    var glow: LumaGlow = LumaSettings.glow
    var layout: LumaLayout = LumaSettings.layout
    var showPinyin: Bool = LumaSettings.showPinyin
    var landingLight: Bool = LumaSettings.landingLight
    var companion: Bool = LumaSettings.companion
    var moments: Bool = LumaSettings.moments

    var grammarEnabled: Bool = LumaSettings.grammarModel
    var typoCorrection: Bool = LumaSettings.typoCorrection
    var emoji: Bool = LumaSettings.emoji
    var learnHabits: Bool = LumaSettings.learnHabits

    var aiEnabled: Bool = AISettings.enabled
    var aiProvider: AIProvider = AISettings.provider
    var aiBaseURL: String = AISettings.customBaseURL
    var aiModel: String = AISettings.customModel
    var aiKey: String = AISettings.key(for: AISettings.provider)
    var aiUseContext: Bool = AISettings.useContext
    var excludedApps: [String] = AISettings.excludedApps

    var autoCheckUpdates: Bool = LumaSettings.autoCheckUpdates

    var rememberedCount: Int = AIMemory.shared.count
    var habitsCount: Int = HabitMemory.shared.count
    var isDeploying: Bool = Rime.shared.isDeploying

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AIMemory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberedCount = AIMemory.shared.count }
        })
        observers.append(nc.addObserver(forName: HabitMemory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.habitsCount = HabitMemory.shared.count }
        })
        observers.append(nc.addObserver(forName: Rime.willResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDeploying = true }
        })
        observers.append(nc.addObserver(forName: Rime.didDeployNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDeploying = Rime.shared.isDeploying }
        })
    }

    /// Re-reads persisted values and live counters whenever the Preferences window opens.
    func refresh() {
        glow = LumaSettings.glow
        layout = LumaSettings.layout
        showPinyin = LumaSettings.showPinyin
        landingLight = LumaSettings.landingLight
        companion = LumaSettings.companion
        moments = LumaSettings.moments
        grammarEnabled = LumaSettings.grammarModel
        typoCorrection = LumaSettings.typoCorrection
        emoji = LumaSettings.emoji
        learnHabits = LumaSettings.learnHabits
        aiEnabled = AISettings.enabled
        aiProvider = AISettings.provider
        aiBaseURL = AISettings.customBaseURL
        aiModel = AISettings.customModel
        aiKey = AISettings.key(for: AISettings.provider)
        aiUseContext = AISettings.useContext
        excludedApps = AISettings.excludedApps
        autoCheckUpdates = LumaSettings.autoCheckUpdates
        rememberedCount = AIMemory.shared.count
        habitsCount = HabitMemory.shared.count
        isDeploying = Rime.shared.isDeploying
    }

    func setGlow(_ value: LumaGlow) {
        glow = value
        CandidatePanel.shared.setGlow(value)
    }

    func setLayout(_ value: LumaLayout) {
        layout = value
        CandidatePanel.shared.setLayout(value)
    }

    func setShowPinyin(_ value: Bool) {
        showPinyin = value
        CandidatePanel.shared.setShowPinyin(value)
    }

    func setLandingLight(_ value: Bool) {
        landingLight = value
        LumaSettings.landingLight = value
    }

    func setCompanion(_ value: Bool) {
        companion = value
        CandidatePanel.shared.setCompanion(value)
    }

    func setMoments(_ value: Bool) {
        moments = value
        LumaSettings.moments = value
    }

    func setGrammarEnabled(_ value: Bool) {
        grammarEnabled = value
        GrammarModel.shared.setEnabled(value)
    }

    func setTypoCorrection(_ value: Bool) {
        typoCorrection = value
        LumaSettings.typoCorrection = value
    }

    func setEmoji(_ value: Bool) {
        emoji = value
        LumaSettings.emoji = value
    }

    func setLearnHabits(_ value: Bool) {
        learnHabits = value
        LumaSettings.learnHabits = value
    }

    func setAIEnabled(_ value: Bool) {
        aiEnabled = value
        AISettings.enabled = value
    }

    func setAIProvider(_ value: AIProvider) {
        aiProvider = value
        AISettings.provider = value
        aiKey = AISettings.key(for: value)
    }

    func setAIBaseURL(_ value: String) {
        aiBaseURL = value
        AISettings.customBaseURL = value
    }

    func setAIModel(_ value: String) {
        aiModel = value
        AISettings.customModel = value
    }

    func setAIKey(_ value: String) {
        aiKey = value
        AISettings.setKey(value, for: aiProvider)
    }

    func setAIUseContext(_ value: Bool) {
        aiUseContext = value
        AISettings.useContext = value
    }

    func addExcludedApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !excludedApps.contains(trimmed) else { return }
        excludedApps.append(trimmed)
        AISettings.excludedApps = excludedApps
    }

    func removeExcludedApp(_ bundleID: String) {
        excludedApps.removeAll { $0 == bundleID }
        AISettings.excludedApps = excludedApps
    }

    func resetExcludedApps() {
        AISettings.resetExcludedApps()
        excludedApps = AISettings.excludedApps
    }

    func setAutoCheckUpdates(_ value: Bool) {
        autoCheckUpdates = value
        LumaSettings.autoCheckUpdates = value
    }

    func redeploy() {
        isDeploying = true
        Rime.shared.redeploy()
    }
}

/// Unified multi-tab Preferences window for Luma.
@MainActor
final class PreferencesWindow {
    static let shared = PreferencesWindow()

    enum Tab: Hashable {
        case appearance, input, ai, updates
    }

    @MainActor @Observable final class Router {
        var tab: Tab = .appearance
    }

    private let router = Router()
    private var window: NSWindow?

    func show(tab: Tab? = nil) {
        if let tab { router.tab = tab }
        PreferencesStore.shared.refresh()
        if window == nil {
            let w = EditingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.contentViewController = NSHostingController(rootView: PreferencesView(store: .shared, router: router))
            w.title = L10n.t("prefs.title", fallback: "Luma 偏好设置")
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = w
        }
        window?.center()
        // The input method is a background app; it has to come forward for fields to accept input.
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

// MARK: - Root Tabs

private struct PreferencesView: View {
    let store: PreferencesStore
    let router: PreferencesWindow.Router

    var body: some View {
        TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
            AppearanceTab(store: store)
                .tabItem { Label(L10n.t("prefs.tab.appearance", fallback: "外观"), systemImage: "sparkles") }
                .tag(PreferencesWindow.Tab.appearance)

            InputTab(store: store, grammar: .shared)
                .tabItem { Label(L10n.t("prefs.tab.input", fallback: "输入"), systemImage: "keyboard") }
                .tag(PreferencesWindow.Tab.input)

            AITab(store: store)
                .tabItem { Label(L10n.t("prefs.tab.ai", fallback: "AI 辅助"), systemImage: "wand.and.stars") }
                .tag(PreferencesWindow.Tab.ai)

            UpdatesTab(store: store)
                .tabItem { Label(L10n.t("prefs.tab.updates", fallback: "更新"), systemImage: "arrow.triangle.2.circlepath") }
                .tag(PreferencesWindow.Tab.updates)
        }
        .frame(width: 520, height: 500)
    }
}

// MARK: - Appearance Tab

private struct AppearanceTab: View {
    let store: PreferencesStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.t("prefs.glow", fallback: "光效模式"), selection: Binding(get: { store.glow }, set: { store.setGlow($0) })) {
                    ForEach(LumaGlow.allCases) { glow in
                        Text(glow.title).tag(glow)
                    }
                }
                .pickerStyle(.segmented)
                Text(L10n.t("prefs.glow.footer", fallback: "深色背景上柔光或流光自然亮起；浅色背景上自动隐退为素净玻璃。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.t("prefs.section.glow", fallback: "光效"))
            }

            Section(L10n.t("prefs.section.panel", fallback: "候选栏与微动效")) {
                Picker(L10n.t("prefs.layout", fallback: "候选排布"),
                       selection: Binding(get: { store.layout }, set: { store.setLayout($0) })) {
                    ForEach(LumaLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: Binding(get: { store.showPinyin }, set: { store.setShowPinyin($0) })) {
                    Text(L10n.t("prefs.show_pinyin", fallback: "候选框显示拼音"))
                    Text(L10n.t("prefs.show_pinyin.desc", fallback: "在候选词上方显示带声调的拼音（输入框内已有预编辑拼音）。"))
                }
                Toggle(isOn: Binding(get: { store.landingLight }, set: { store.setLandingLight($0) })) {
                    Text(L10n.t("prefs.landing_light", fallback: "上屏光点"))
                    Text(L10n.t("prefs.landing_light.desc", fallback: "选词上屏时，光点从候选框飞入光标并轻扫刚输入的词。"))
                }
                Toggle(isOn: Binding(get: { store.companion }, set: { store.setCompanion($0) })) {
                    Text(L10n.t("prefs.companion", fallback: "小猫"))
                    Text(L10n.t("prefs.companion.desc", fallback: "停顿后从候选框右下角探出头，视线随选词移动。"))
                }
                Toggle(isOn: Binding(get: { store.moments }, set: { store.setMoments($0) })) {
                    Text(L10n.t("prefs.moments", fallback: "彩蛋"))
                    Text(L10n.t("prefs.moments.desc", fallback: "输入「生日快乐」「晚安」等词语时在光标旁轻放微动效，每种每天最多一次。"))
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Input Tab

private struct InputTab: View {
    let store: PreferencesStore
    let grammar: GrammarModel

    var body: some View {
        Form {
            Section(L10n.t("prefs.section.smart", fallback: "组句与纠错")) {
                Toggle(isOn: Binding(get: { store.grammarEnabled }, set: { store.setGrammarEnabled($0) })) {
                    HStack(spacing: 8) {
                        Text(L10n.t("prefs.grammar", fallback: "万象语法模型"))
                        Text(grammar.statusText)
                            .font(.caption)
                            .foregroundStyle(grammar.state == .failed ? .orange : .secondary)
                    }
                    Text(L10n.t("prefs.grammar.desc", fallback: "约 390 MB，后台下载并校验 SHA-256，显著提升长句与虚词准确度；关闭时自动删除。"))
                }
                if case .downloading(let progress) = grammar.state {
                    ProgressView(value: progress)
                } else if grammar.state == .failed {
                    HStack {
                        Spacer()
                        Button(L10n.t("prefs.grammar.retry", fallback: "重试")) {
                            GrammarModel.shared.download()
                        }
                    }
                }
                Toggle(isOn: Binding(get: { store.typoCorrection }, set: { store.setTypoCorrection($0) })) {
                    Text(L10n.t("prefs.typo", fallback: "智能纠错"))
                    Text(L10n.t("prefs.typo.desc", fallback: "自动识别字母颠倒、相邻键误触、重复按键、漏字母、平翘舌与前后鼻音。"))
                }
                Toggle(L10n.t("prefs.emoji", fallback: "Emoji 候选"),
                       isOn: Binding(get: { store.emoji }, set: { store.setEmoji($0) }))
            }

            Section(L10n.t("prefs.section.habits", fallback: "本地习惯")) {
                Toggle(isOn: Binding(get: { store.learnHabits }, set: { store.setLearnHabits($0) })) {
                    Text(L10n.t("prefs.habits", fallback: "学习接字习惯"))
                    Text(L10n.t("prefs.habits.desc", fallback: "记住你在某个词后面常接哪个词，下次自动置顶。纯本地学习，不联网。"))
                }
                LabeledContent(L10n.t("prefs.habits.learned", fallback: "已学词条")) {
                    HStack {
                        Text("\(store.habitsCount)")
                            .monospacedDigit()
                        Button(L10n.t("prefs.clear", fallback: "清除")) {
                            HabitMemory.shared.clear()
                        }
                        .disabled(store.habitsCount == 0)
                    }
                }
            }

            Section(L10n.t("prefs.section.dict", fallback: "词库与配置")) {
                HStack {
                    Button(L10n.t("prefs.open_config", fallback: "打开配置目录")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: LumaPaths.user))
                    }
                    Spacer()
                    if store.isDeploying {
                        ProgressView().controlSize(.small)
                        Text(L10n.t("prefs.redeploy.running", fallback: "正在重新部署…"))
                            .foregroundStyle(.secondary)
                    } else {
                        Button(L10n.t("prefs.redeploy", fallback: "重新部署")) {
                            store.redeploy()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Tab

private struct AITab: View {
    let store: PreferencesStore
    @State private var test = TestState.idle

    private enum TestState: Equatable {
        case idle, running, passed(String), failed(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.aiEnabled }, set: { store.setAIEnabled($0) })) {
                    Text(L10n.t("prefs.ai.enable", fallback: "启用 AI 辅助"))
                    Text(L10n.t("prefs.ai.enable.desc", fallback: "打字停顿时按拼音推测流行语、人名和专业名词，固定排在候选栏右侧（8/9/0 或 Tab），不打乱已有候选。"))
                }
            }

            Section(L10n.t("prefs.ai.section.model", fallback: "模型")) {
                Picker(L10n.t("prefs.ai.service", fallback: "服务"),
                       selection: Binding(get: { store.aiProvider }, set: {
                           store.setAIProvider($0)
                           test = .idle
                       })) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                if store.aiProvider == .custom {
                    TextField(L10n.t("prefs.ai.base_url", fallback: "接口地址"),
                              text: Binding(get: { store.aiBaseURL }, set: { store.setAIBaseURL($0); test = .idle }),
                              prompt: Text("https://api.example.com/v1"))
                    TextField(L10n.t("prefs.ai.model", fallback: "模型名称"),
                              text: Binding(get: { store.aiModel }, set: { store.setAIModel($0); test = .idle }),
                              prompt: Text("model-name"))
                } else {
                    LabeledContent(L10n.t("prefs.ai.model_id", fallback: "模型 ID"), value: store.aiProvider.rawValue)
                }
                SecureField("API Key",
                            text: Binding(get: { store.aiKey }, set: { store.setAIKey($0); test = .idle }),
                            prompt: Text("sk-…"))
                HStack {
                    if store.aiProvider.isDeepSeek, let url = URL(string: "https://platform.deepseek.com/api_keys") {
                        Link(L10n.t("prefs.ai.get_key", fallback: "获取 DeepSeek API Key"), destination: url)
                    }
                    Spacer()
                    Button(L10n.t("prefs.ai.test", fallback: "测试连接")) { runTest() }
                        .disabled(test == .running || store.aiKey.isEmpty)
                }
                testResult
            }

            Section(L10n.t("prefs.ai.section.context", fallback: "上文与隐私")) {
                Toggle(isOn: Binding(get: { store.aiUseContext }, set: { store.setAIUseContext($0) })) {
                    Text(L10n.t("prefs.ai.use_context", fallback: "参考上文"))
                    Text(L10n.t("prefs.ai.use_context.desc", fallback: "把光标前最多 40 个字发给模型以提高准确度。切换输入框、移动光标或停顿 3 分钟后清空。"))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("prefs.ai.excluded", fallback: "在这些应用中禁用 AI 辅助"))
                    Text(L10n.t("prefs.ai.excluded.desc", fallback: "密码管理器与终端默认已加入，防止敏感内容随上文发送。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(store.excludedApps, id: \.self) { bundleID in
                                ExcludedAppRow(bundleID: bundleID) {
                                    store.removeExcludedApp(bundleID)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 100)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))

                    HStack {
                        Button(L10n.t("prefs.ai.excluded.add", fallback: "添加应用…")) { pickAppToExclude() }
                        Spacer()
                        Button(L10n.t("prefs.ai.excluded.reset", fallback: "恢复默认")) { store.resetExcludedApps() }
                    }
                }
            }

            Section(L10n.t("prefs.ai.section.memory", fallback: "本地记忆")) {
                LabeledContent(L10n.t("prefs.ai.picks", fallback: "记住的 AI 候选")) {
                    HStack {
                        Text("\(store.rememberedCount)")
                            .monospacedDigit()
                        Button(L10n.t("prefs.clear", fallback: "清除")) {
                            AIMemory.shared.clear()
                        }
                        .disabled(store.rememberedCount == 0)
                    }
                }
                Text(L10n.t("prefs.ai.picks.desc", fallback: "选中过的 AI 候选会记在本机，无上文时直接置顶且不再联网。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(L10n.t("prefs.ai.privacy_note", fallback: "开启 AI 辅助后，正在输入的拼音、本地候选及开启「参考上文」时光标前最多 40 字会发送至所选服务。API Key 与本地记忆均以仅本人可读权限（0600）保存在 ~/Library/Luma。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("prefs.ai.testing", fallback: "正在连接…")).foregroundStyle(.secondary)
            }
        case .passed(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func pickAppToExclude() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.level = .floating + 1
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bid = Bundle(url: url)?.bundleIdentifier {
                    store.addExcludedApp(bid)
                }
            }
        }
    }

    private func runTest() {
        let config: AIConfig
        do {
            config = try AISettings.validatedConfig(for: store.aiProvider, key: store.aiKey)
        } catch {
            test = .failed(error.localizedDescription)
            return
        }
        test = .running
        Task {
            let started = Date()
            do {
                let answer = try await AIClient.complete(pinyin: "yyds", hints: [], config: config)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                let word = answer.texts.first ?? L10n.t("prefs.ai.test_empty", fallback: "（无结果）")
                test = .passed(L10n.f("prefs.ai.test_ok", fallback: "连接成功，用时 %@ 秒：yyds → %@", seconds, word))
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    private var appInfo: (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }

    var body: some View {
        let info = appInfo
        HStack(spacing: 8) {
            if let icon = info.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "app")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            Text(info.name)
                .lineLimit(1)
            if info.name != bundleID {
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Updates Tab

private struct UpdatesTab: View {
    let store: PreferencesStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let icon = NSImage(named: "luma") ?? NSApp.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Luma 拼音")
                            .font(.headline)
                        Text("\(L10n.t("prefs.updates.current", fallback: "当前版本")) \(Updater.currentVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section(L10n.t("prefs.updates.section", fallback: "软件更新")) {
                Toggle(L10n.t("prefs.updates.auto", fallback: "自动检查更新"),
                       isOn: Binding(get: { store.autoCheckUpdates }, set: { store.setAutoCheckUpdates($0) }))
                HStack {
                    Button(L10n.t("prefs.updates.check_now", fallback: "立即检查更新")) {
                        Task { await Updater.shared.check(userInitiated: true) }
                    }
                    Spacer()
                    Button(L10n.t("prefs.updates.homepage", fallback: "访问项目主页")) {
                        NSWorkspace.shared.open(Updater.homepage)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
