import Foundation

/// Compatibility entry point (used by `--ai-settings`): opens the unified Preferences window
/// directly on the AI Assist tab.
@MainActor
final class AISettingsWindow {
    static let shared = AISettingsWindow()

    func show() {
        PreferencesWindow.shared.show(tab: .ai)
    }
}
