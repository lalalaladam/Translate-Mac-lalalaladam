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
            return "隐藏拼音与音译"
        case .hideGoogleSelectionToolbar:
            return "隐藏 Google 选词工具栏"
        case .simplifyActionButtons:
            return "精简左右操作按钮"
        case .highlightSelectedLanguage:
            return "突出当前翻译语言"
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
