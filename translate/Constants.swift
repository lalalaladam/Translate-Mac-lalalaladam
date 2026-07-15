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
    
    static let SOURCE_LANGUAGE = "en"
    static let TRANSLATION_LANGUAGE = "tr"
    
    // Command + backslash is registered at the Carbon level so it continues
    // to work while another application is active.
    static let keyCode: UInt32 = UInt32(kVK_ANSI_Backslash)
    static let carbonModifiers: UInt32 = UInt32(cmdKey)
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
