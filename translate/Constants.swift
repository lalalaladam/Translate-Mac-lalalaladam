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
}

enum ShortcutAction: String, CaseIterable {
    case showHideWindow
    case closeWindow
    case hideApplication
    case quitApplication
    case selectAllSource
    case listenSource
    case swapLanguages
    case applySpellingCorrection
    case moveFocusOut
    case undo
    case redo
    case cut
    case copy
    case paste

    var title: String {
        switch self {
        case .showHideWindow:
            return interfaceText("显示或隐藏窗口", "Show or Hide Window")
        case .closeWindow:
            return interfaceText("关闭窗口", "Close Window")
        case .hideApplication:
            return interfaceText("隐藏应用", "Hide Application")
        case .quitApplication:
            return interfaceText("退出应用", "Quit Application")
        case .selectAllSource:
            return interfaceText("选中全部原文", "Select All Source Text")
        case .listenSource:
            return interfaceText("朗读原文", "Listen to Source Text")
        case .swapLanguages:
            return interfaceText("交换语言", "Swap Languages")
        case .applySpellingCorrection:
            return interfaceText("应用 Google 拼写修正", "Apply Google Spelling Correction")
        case .moveFocusOut:
            return interfaceText("将焦点移出翻译窗口", "Move Focus out of Translation Window")
        case .undo:
            return interfaceText("撤销", "Undo")
        case .redo:
            return interfaceText("重做", "Redo")
        case .cut:
            return interfaceText("剪切", "Cut")
        case .copy:
            return interfaceText("复制所选文字", "Copy Selected Text")
        case .paste:
            return interfaceText("粘贴", "Paste")
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .showHideWindow:
            return ShortcutBinding(keyCode: kVK_ANSI_Backslash, modifiers: [.command], keyEquivalent: "\\")
        case .closeWindow:
            return ShortcutBinding(keyCode: kVK_ANSI_W, modifiers: [.command], keyEquivalent: "w")
        case .hideApplication:
            return ShortcutBinding(keyCode: kVK_ANSI_H, modifiers: [.command], keyEquivalent: "h")
        case .quitApplication:
            return ShortcutBinding(keyCode: kVK_ANSI_Q, modifiers: [.command], keyEquivalent: "q")
        case .selectAllSource:
            return ShortcutBinding(keyCode: kVK_ANSI_A, modifiers: [.command], keyEquivalent: "a")
        case .listenSource:
            return ShortcutBinding(keyCode: kVK_ANSI_L, modifiers: [.command], keyEquivalent: "l")
        case .swapLanguages:
            return ShortcutBinding(keyCode: kVK_ANSI_S, modifiers: [.command], keyEquivalent: "s")
        case .applySpellingCorrection:
            return ShortcutBinding(keyCode: kVK_Return, modifiers: [.command], keyEquivalent: "\r")
        case .moveFocusOut:
            return ShortcutBinding(keyCode: kVK_Tab, modifiers: [], keyEquivalent: "\t")
        case .undo:
            return ShortcutBinding(keyCode: kVK_ANSI_Z, modifiers: [.command], keyEquivalent: "z")
        case .redo:
            return ShortcutBinding(keyCode: kVK_ANSI_R, modifiers: [.command], keyEquivalent: "r")
        case .cut:
            return ShortcutBinding(keyCode: kVK_ANSI_X, modifiers: [.command], keyEquivalent: "x")
        case .copy:
            return ShortcutBinding(keyCode: kVK_ANSI_C, modifiers: [.command], keyEquivalent: "c")
        case .paste:
            return ShortcutBinding(keyCode: kVK_ANSI_V, modifiers: [.command], keyEquivalent: "v")
        }
    }

    var isGlobal: Bool {
        self == .showHideWindow
    }
}

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt16
    let modifierFlagsRawValue: UInt
    let keyEquivalent: String

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, keyEquivalent: String) {
        self.keyCode = UInt16(keyCode)
        self.modifierFlagsRawValue = Self.normalized(modifiers).rawValue
        self.keyEquivalent = keyEquivalent.lowercased()
    }

    init(event: NSEvent) {
        self.init(
            keyCode: Int(event.keyCode),
            modifiers: event.modifierFlags,
            keyEquivalent: event.charactersIgnoringModifiers ?? ""
        )
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }

    var displayText: String {
        var text = ""
        let modifiers = modifierFlags
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyDisplayName(keyCode: keyCode, fallback: keyEquivalent)
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifierFlags.contains(.command) { result |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { result |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { result |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    func matches(_ event: NSEvent) -> Bool {
        keyCode == event.keyCode && modifierFlags == Self.normalized(event.modifierFlags)
    }

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .option, .control, .shift])
    }

    private static func keyDisplayName(keyCode: UInt16, fallback: String) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return fallback.isEmpty ? "Key \(keyCode)" : fallback.uppercased()
        }
    }
}

struct ShortcutPreferences {
    private static let key = "translate.shortcuts.bindings"

    static func registerDefaults() {}

    static func binding(for action: ShortcutAction) -> ShortcutBinding {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data),
              let binding = saved[action.rawValue] else {
            return action.defaultBinding
        }
        return binding
    }

    static func set(_ binding: ShortcutBinding, for action: ShortcutAction) -> Bool {
        guard !ShortcutAction.allCases.contains(where: {
            $0 != action && Self.binding(for: $0) == binding
        }) else {
            return false
        }

        var bindings = savedBindings()
        bindings[action.rawValue] = binding
        guard let data = try? JSONEncoder().encode(bindings) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    static func restoreDefaults() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func action(matching event: NSEvent, includingGlobal: Bool = false) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            (includingGlobal || !$0.isGlobal) && binding(for: $0).matches(event)
        }
    }

    private static func savedBindings() -> [String: ShortcutBinding] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let bindings = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) else {
            return [:]
        }
        return bindings
    }
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
