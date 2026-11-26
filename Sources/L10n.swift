import Foundation

/// Lightweight localization helper backed by `zh-Hans.lproj` and `en.lproj`.
enum L10n {
    private static let bundle: Bundle = {
        let preferred = Locale.preferredLanguages.first ?? "zh-Hans"
        let lang = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return .main
    }()

    static func t(_ key: String, fallback: String) -> String {
        bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
    }

    static func f(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        String(format: t(key, fallback: fallback), arguments: args)
    }
}
