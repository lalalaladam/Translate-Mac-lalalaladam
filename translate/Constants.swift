//
//  Constants.swift
//  translate
//
//  Created by Minan on 21.01.2023.
//

import Foundation
import AppKit
import Carbon.HIToolbox

struct Constants {
    static let WIDTH = 550
    static let HEIGHT = 360
    
    // Command + backslash is registered at the Carbon level so it continues
    // to work while another application is active.
    static let keyCode: UInt32 = UInt32(kVK_ANSI_Backslash)
    static let carbonModifiers: UInt32 = UInt32(cmdKey)
}

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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            languageKey: AppInterfaceLanguage.initial.rawValue
        ])
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

enum TranslateLanguage: String, CaseIterable {
    case automatic = "auto"
    case english = "en"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case german = "de"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case russian = "ru"
    case arabic = "ar"
    case turkish = "tr"
    case vietnamese = "vi"
    case thai = "th"
    case indonesian = "id"
    case malay = "ms"
    case hindi = "hi"
    case dutch = "nl"
    case polish = "pl"
    case ukrainian = "uk"

    static let initialSource: TranslateLanguage = .english
    static let initialTarget: TranslateLanguage = .simplifiedChinese

    var title: String {
        switch AppInterfaceLanguagePreferences.current {
        case .simplifiedChinese:
            switch self {
            case .automatic: return "自动检测"
            case .english: return "英语"
            case .simplifiedChinese: return "中文（简体）"
            case .traditionalChinese: return "中文（繁体）"
            case .japanese: return "日语"
            case .korean: return "韩语"
            case .french: return "法语"
            case .german: return "德语"
            case .spanish: return "西班牙语"
            case .portuguese: return "葡萄牙语"
            case .italian: return "意大利语"
            case .russian: return "俄语"
            case .arabic: return "阿拉伯语"
            case .turkish: return "土耳其语"
            case .vietnamese: return "越南语"
            case .thai: return "泰语"
            case .indonesian: return "印度尼西亚语"
            case .malay: return "马来语"
            case .hindi: return "印地语"
            case .dutch: return "荷兰语"
            case .polish: return "波兰语"
            case .ukrainian: return "乌克兰语"
            }
        case .english:
            switch self {
            case .automatic: return "Detect language"
            case .english: return "English"
            case .simplifiedChinese: return "Chinese (Simplified)"
            case .traditionalChinese: return "Chinese (Traditional)"
            case .japanese: return "Japanese"
            case .korean: return "Korean"
            case .french: return "French"
            case .german: return "German"
            case .spanish: return "Spanish"
            case .portuguese: return "Portuguese"
            case .italian: return "Italian"
            case .russian: return "Russian"
            case .arabic: return "Arabic"
            case .turkish: return "Turkish"
            case .vietnamese: return "Vietnamese"
            case .thai: return "Thai"
            case .indonesian: return "Indonesian"
            case .malay: return "Malay"
            case .hindi: return "Hindi"
            case .dutch: return "Dutch"
            case .polish: return "Polish"
            case .ukrainian: return "Ukrainian"
            }
        }
    }

    var canBeTarget: Bool {
        self != .automatic
    }
}

struct TranslateLanguagePreferences {
    private static let sourceKey = "translate.languages.source"
    private static let targetKey = "translate.languages.target"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            sourceKey: TranslateLanguage.initialSource.rawValue,
            targetKey: TranslateLanguage.initialTarget.rawValue
        ])
    }

    static var source: TranslateLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: sourceKey),
              let language = TranslateLanguage(rawValue: rawValue) else {
            return .initialSource
        }
        return language
    }

    static var target: TranslateLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: targetKey),
              let language = TranslateLanguage(rawValue: rawValue),
              language.canBeTarget else {
            return .initialTarget
        }
        return language
    }

    static func set(source: TranslateLanguage, target: TranslateLanguage) {
        guard target.canBeTarget else { return }
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
        UserDefaults.standard.set(target.rawValue, forKey: targetKey)
    }

    static func restoreInitialPair() {
        set(source: .initialSource, target: .initialTarget)
    }
}

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
