import Foundation

enum AppInterfaceLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-CN"
    case english = "en"

    static let initial: AppInterfaceLanguage = .simplifiedChinese

    var nativeTitle: String {
        switch self {
        case .simplifiedChinese: return "中文（简体）"
        case .english: return "English"
        }
    }

    var googleLocale: String { rawValue }
}

struct AppInterfaceLanguagePreferences {
    private static let languageKey = "translate.interface.language"
    private static let chineseDefaultMigrationKey = "translate.interface.language.chinese-default-v1"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            languageKey: AppInterfaceLanguage.initial.rawValue
        ])

        // Earlier customized builds could leave English persisted, which then
        // overrides the registered Chinese default forever. Apply this default
        // correction once; later choices made by the user remain untouched.
        if !UserDefaults.standard.bool(forKey: chineseDefaultMigrationKey) {
            UserDefaults.standard.set(
                AppInterfaceLanguage.simplifiedChinese.rawValue,
                forKey: languageKey
            )
            UserDefaults.standard.set(true, forKey: chineseDefaultMigrationKey)
        }
    }

    static var current: AppInterfaceLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: languageKey),
              let language = AppInterfaceLanguage(rawValue: rawValue) else {
            return .initial
        }
        return language
    }

    static func set(_ language: AppInterfaceLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
    }
}

func interfaceText(_ simplifiedChinese: String, _ english: String) -> String {
    AppInterfaceLanguagePreferences.current == .simplifiedChinese
        ? simplifiedChinese
        : english
}
