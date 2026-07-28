import Foundation

enum TranslateFeature: String, CaseIterable {
    case hidePinyin
    case hideGoogleSelectionToolbar
    case simplifyActionButtons
    case highlightSelectedLanguage

    var title: String {
        switch self {
        case .hidePinyin:
            return interfaceText("隐藏拼音与音译", "Hide Pinyin and Transliteration")
        case .hideGoogleSelectionToolbar:
            return interfaceText(
                "隐藏 Google 选词工具栏",
                "Hide Google Selection Toolbar"
            )
        case .simplifyActionButtons:
            return interfaceText(
                "精简左右操作按钮",
                "Simplify Source and Result Actions"
            )
        case .highlightSelectedLanguage:
            return interfaceText(
                "突出当前翻译语言",
                "Highlight Selected Translation Languages"
            )
        }
    }
}

struct TranslateFeaturePreferences {
    private static let keyPrefix = "translate.features."

    static func registerDefaults() {
        let defaults = Dictionary(
            uniqueKeysWithValues: TranslateFeature.allCases.map {
                (key(for: $0), true)
            }
        )
        UserDefaults.standard.register(defaults: defaults)
    }

    static func isEnabled(_ feature: TranslateFeature) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: feature))
    }

    static func set(_ feature: TranslateFeature, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key(for: feature))
    }

    static func restoreRecommendedSettings() {
        TranslateFeature.allCases.forEach { set($0, enabled: true) }
    }

    static var hidePinyin: Bool { isEnabled(.hidePinyin) }
    static var hideGoogleSelectionToolbar: Bool {
        isEnabled(.hideGoogleSelectionToolbar)
    }
    static var simplifyActionButtons: Bool {
        isEnabled(.simplifyActionButtons)
    }
    static var highlightSelectedLanguage: Bool {
        isEnabled(.highlightSelectedLanguage)
    }

    private static func key(for feature: TranslateFeature) -> String {
        keyPrefix + feature.rawValue
    }
}

enum TranslateWindowBehavior: String, CaseIterable {
    case keepOnTop
    case showOnAllSpaces

    var title: String {
        switch self {
        case .keepOnTop:
            return interfaceText(
                "在当前 Space 保持置顶",
                "Keep on Top in Current Space"
            )
        case .showOnAllSpaces:
            return interfaceText(
                "在所有 Space 显示",
                "Show on All Spaces"
            )
        }
    }
}

struct TranslateWindowPreferences {
    private static let keyPrefix = "translate.window."

    static func registerDefaults() {
        let defaults = Dictionary(
            uniqueKeysWithValues: TranslateWindowBehavior.allCases.map {
                (key(for: $0), false)
            }
        )
        UserDefaults.standard.register(defaults: defaults)
    }

    static func isEnabled(_ behavior: TranslateWindowBehavior) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: behavior))
    }

    static func set(_ behavior: TranslateWindowBehavior, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key(for: behavior))
    }

    static func restoreDefaults() {
        TranslateWindowBehavior.allCases.forEach { set($0, enabled: false) }
    }

    static var keepOnTop: Bool { isEnabled(.keepOnTop) }
    static var showOnAllSpaces: Bool { isEnabled(.showOnAllSpaces) }

    private static func key(for behavior: TranslateWindowBehavior) -> String {
        keyPrefix + behavior.rawValue
    }
}
