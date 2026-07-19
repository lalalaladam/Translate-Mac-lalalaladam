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
    case listenTranslation
    case stopSpeaking
    case swapLanguages
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
        case .listenTranslation:
            return interfaceText("朗读译文", "Listen to Translation")
        case .stopSpeaking:
            return interfaceText("停止朗读", "Stop Speaking")
        case .swapLanguages:
            return interfaceText("交换语言", "Swap Languages")
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
            return ShortcutBinding(keyCode: kVK_ANSI_9, modifiers: [.command], keyEquivalent: "9")
        case .listenTranslation:
            return ShortcutBinding(keyCode: kVK_ANSI_0, modifiers: [.command], keyEquivalent: "0")
        case .stopSpeaking:
            return ShortcutBinding(keyCode: kVK_ANSI_Period, modifiers: [.command], keyEquivalent: ".")
        case .swapLanguages:
            return ShortcutBinding(
                keyCode: kVK_ANSI_S,
                modifiers: [.command, .shift],
                keyEquivalent: "s"
            )
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
    case afrikaans = "af"
    case albanian = "sq"
    case amharic = "am"
    case english = "en"
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case armenian = "hy"
    case assamese = "as"
    case aymara = "ay"
    case azerbaijani = "az"
    case bambara = "bm"
    case basque = "eu"
    case belarusian = "be"
    case bengali = "bn"
    case bhojpuri = "bho"
    case bosnian = "bs"
    case bulgarian = "bg"
    case catalan = "ca"
    case cebuano = "ceb"
    case corsican = "co"
    case croatian = "hr"
    case czech = "cs"
    case danish = "da"
    case dhivehi = "dv"
    case dogri = "doi"
    case dutch = "nl"
    case esperanto = "eo"
    case estonian = "et"
    case ewe = "ee"
    case filipino = "tl"
    case finnish = "fi"
    case japanese = "ja"
    case korean = "ko"
    case french = "fr"
    case frisian = "fy"
    case galician = "gl"
    case georgian = "ka"
    case german = "de"
    case greek = "el"
    case guarani = "gn"
    case gujarati = "gu"
    case haitianCreole = "ht"
    case hausa = "ha"
    case hawaiian = "haw"
    case hebrew = "iw"
    case hmong = "hmn"
    case hungarian = "hu"
    case icelandic = "is"
    case igbo = "ig"
    case ilocano = "ilo"
    case irish = "ga"
    case spanish = "es"
    case portuguese = "pt"
    case italian = "it"
    case javanese = "jw"
    case kannada = "kn"
    case kazakh = "kk"
    case khmer = "km"
    case kinyarwanda = "rw"
    case konkani = "gom"
    case krio = "kri"
    case kurdish = "ku"
    case kurdishSorani = "ckb"
    case kyrgyz = "ky"
    case lao = "lo"
    case latin = "la"
    case latvian = "lv"
    case lingala = "ln"
    case lithuanian = "lt"
    case luganda = "lg"
    case luxembourgish = "lb"
    case macedonian = "mk"
    case maithili = "mai"
    case malagasy = "mg"
    case malay = "ms"
    case malayalam = "ml"
    case maltese = "mt"
    case maori = "mi"
    case marathi = "mr"
    case meiteilon = "mni-Mtei"
    case mizo = "lus"
    case mongolian = "mn"
    case myanmar = "my"
    case nepali = "ne"
    case norwegian = "no"
    case nyanja = "ny"
    case odia = "or"
    case oromo = "om"
    case pashto = "ps"
    case persian = "fa"
    case polish = "pl"
    case punjabi = "pa"
    case quechua = "qu"
    case romanian = "ro"
    case russian = "ru"
    case samoan = "sm"
    case sanskrit = "sa"
    case scotsGaelic = "gd"
    case sepedi = "nso"
    case serbian = "sr"
    case sesotho = "st"
    case shona = "sn"
    case sindhi = "sd"
    case sinhala = "si"
    case slovak = "sk"
    case slovenian = "sl"
    case somali = "so"
    case sundanese = "su"
    case swahili = "sw"
    case swedish = "sv"
    case tajik = "tg"
    case tamil = "ta"
    case tatar = "tt"
    case telugu = "te"
    case arabic = "ar"
    case turkish = "tr"
    case vietnamese = "vi"
    case thai = "th"
    case indonesian = "id"
    case hindi = "hi"
    case tigrinya = "ti"
    case tsonga = "ts"
    case turkmen = "tk"
    case twi = "ak"
    case ukrainian = "uk"
    case urdu = "ur"
    case uyghur = "ug"
    case uzbek = "uz"
    case welsh = "cy"
    case xhosa = "xh"
    case yiddish = "yi"
    case yoruba = "yo"
    case zulu = "zu"

    static let initialSource: TranslateLanguage = .english
    static let initialTarget: TranslateLanguage = .simplifiedChinese

    var title: String {
        let names = Self.names[self] ?? (rawValue, rawValue)
        return AppInterfaceLanguagePreferences.current == .simplifiedChinese
            ? names.chinese
            : names.english
    }

    private static let names: [TranslateLanguage: (chinese: String, english: String)] = [
        .automatic: ("自动检测", "Detect language"), .afrikaans: ("南非荷兰语", "Afrikaans"),
        .albanian: ("阿尔巴尼亚语", "Albanian"), .amharic: ("阿姆哈拉语", "Amharic"),
        .arabic: ("阿拉伯语", "Arabic"), .armenian: ("亚美尼亚语", "Armenian"),
        .assamese: ("阿萨姆语", "Assamese"), .aymara: ("艾马拉语", "Aymara"),
        .azerbaijani: ("阿塞拜疆语", "Azerbaijani"), .bambara: ("班巴拉语", "Bambara"),
        .basque: ("巴斯克语", "Basque"), .belarusian: ("白俄罗斯语", "Belarusian"),
        .bengali: ("孟加拉语", "Bengali"), .bhojpuri: ("博杰普尔语", "Bhojpuri"),
        .bosnian: ("波斯尼亚语", "Bosnian"), .bulgarian: ("保加利亚语", "Bulgarian"),
        .catalan: ("加泰罗尼亚语", "Catalan"), .cebuano: ("宿务语", "Cebuano"),
        .simplifiedChinese: ("中文（简体）", "Chinese (Simplified)"),
        .traditionalChinese: ("中文（繁体）", "Chinese (Traditional)"),
        .corsican: ("科西嘉语", "Corsican"), .croatian: ("克罗地亚语", "Croatian"),
        .czech: ("捷克语", "Czech"), .danish: ("丹麦语", "Danish"),
        .dhivehi: ("迪维希语", "Dhivehi"), .dogri: ("多格拉语", "Dogri"),
        .dutch: ("荷兰语", "Dutch"), .english: ("英语", "English"),
        .esperanto: ("世界语", "Esperanto"), .estonian: ("爱沙尼亚语", "Estonian"),
        .ewe: ("埃维语", "Ewe"), .filipino: ("菲律宾语", "Filipino"),
        .finnish: ("芬兰语", "Finnish"), .french: ("法语", "French"),
        .frisian: ("弗里西语", "Frisian"), .galician: ("加利西亚语", "Galician"),
        .georgian: ("格鲁吉亚语", "Georgian"), .german: ("德语", "German"),
        .greek: ("希腊语", "Greek"), .guarani: ("瓜拉尼语", "Guarani"),
        .gujarati: ("古吉拉特语", "Gujarati"), .haitianCreole: ("海地克里奥尔语", "Haitian Creole"),
        .hausa: ("豪萨语", "Hausa"), .hawaiian: ("夏威夷语", "Hawaiian"),
        .hebrew: ("希伯来语", "Hebrew"), .hindi: ("印地语", "Hindi"),
        .hmong: ("苗语", "Hmong"), .hungarian: ("匈牙利语", "Hungarian"),
        .icelandic: ("冰岛语", "Icelandic"), .igbo: ("伊博语", "Igbo"),
        .ilocano: ("伊洛卡诺语", "Ilocano"), .indonesian: ("印度尼西亚语", "Indonesian"),
        .irish: ("爱尔兰语", "Irish"), .italian: ("意大利语", "Italian"),
        .japanese: ("日语", "Japanese"), .javanese: ("爪哇语", "Javanese"),
        .kannada: ("卡纳达语", "Kannada"), .kazakh: ("哈萨克语", "Kazakh"),
        .khmer: ("高棉语", "Khmer"), .kinyarwanda: ("卢旺达语", "Kinyarwanda"),
        .konkani: ("孔卡尼语", "Konkani"), .korean: ("韩语", "Korean"),
        .krio: ("克里奥尔语", "Krio"), .kurdish: ("库尔德语", "Kurdish"),
        .kurdishSorani: ("库尔德语（索拉尼）", "Kurdish (Sorani)"), .kyrgyz: ("吉尔吉斯语", "Kyrgyz"),
        .lao: ("老挝语", "Lao"), .latin: ("拉丁语", "Latin"), .latvian: ("拉脱维亚语", "Latvian"),
        .lingala: ("林加拉语", "Lingala"), .lithuanian: ("立陶宛语", "Lithuanian"),
        .luganda: ("卢干达语", "Luganda"), .luxembourgish: ("卢森堡语", "Luxembourgish"),
        .macedonian: ("马其顿语", "Macedonian"), .maithili: ("迈蒂利语", "Maithili"),
        .malagasy: ("马达加斯加语", "Malagasy"), .malay: ("马来语", "Malay"),
        .malayalam: ("马拉雅拉姆语", "Malayalam"), .maltese: ("马耳他语", "Maltese"),
        .maori: ("毛利语", "Māori"), .marathi: ("马拉地语", "Marathi"),
        .meiteilon: ("曼尼普尔语", "Meiteilon (Manipuri)"), .mizo: ("米佐语", "Mizo"),
        .mongolian: ("蒙古语", "Mongolian"), .myanmar: ("缅甸语", "Myanmar (Burmese)"),
        .nepali: ("尼泊尔语", "Nepali"), .norwegian: ("挪威语", "Norwegian"),
        .nyanja: ("齐切瓦语", "Nyanja (Chichewa)"), .odia: ("奥里亚语", "Odia"),
        .oromo: ("奥罗莫语", "Oromo"), .pashto: ("普什图语", "Pashto"),
        .persian: ("波斯语", "Persian"), .polish: ("波兰语", "Polish"),
        .portuguese: ("葡萄牙语", "Portuguese"), .punjabi: ("旁遮普语", "Punjabi"),
        .quechua: ("克丘亚语", "Quechua"), .romanian: ("罗马尼亚语", "Romanian"),
        .russian: ("俄语", "Russian"), .samoan: ("萨摩亚语", "Samoan"),
        .sanskrit: ("梵语", "Sanskrit"), .scotsGaelic: ("苏格兰盖尔语", "Scots Gaelic"),
        .sepedi: ("北索托语", "Sepedi"), .serbian: ("塞尔维亚语", "Serbian"),
        .sesotho: ("塞索托语", "Sesotho"), .shona: ("绍纳语", "Shona"),
        .sindhi: ("信德语", "Sindhi"), .sinhala: ("僧伽罗语", "Sinhala"),
        .slovak: ("斯洛伐克语", "Slovak"), .slovenian: ("斯洛文尼亚语", "Slovenian"),
        .somali: ("索马里语", "Somali"), .spanish: ("西班牙语", "Spanish"),
        .sundanese: ("巽他语", "Sundanese"), .swahili: ("斯瓦希里语", "Swahili"),
        .swedish: ("瑞典语", "Swedish"), .tajik: ("塔吉克语", "Tajik"),
        .tamil: ("泰米尔语", "Tamil"), .tatar: ("鞑靼语", "Tatar"),
        .telugu: ("泰卢固语", "Telugu"), .thai: ("泰语", "Thai"),
        .tigrinya: ("提格利尼亚语", "Tigrinya"), .tsonga: ("聪加语", "Tsonga"),
        .turkish: ("土耳其语", "Turkish"), .turkmen: ("土库曼语", "Turkmen"),
        .twi: ("契维语", "Twi"), .ukrainian: ("乌克兰语", "Ukrainian"),
        .urdu: ("乌尔都语", "Urdu"), .uyghur: ("维吾尔语", "Uyghur"),
        .uzbek: ("乌兹别克语", "Uzbek"), .vietnamese: ("越南语", "Vietnamese"),
        .welsh: ("威尔士语", "Welsh"), .xhosa: ("科萨语", "Xhosa"),
        .yiddish: ("意第绪语", "Yiddish"), .yoruba: ("约鲁巴语", "Yoruba"),
        .zulu: ("祖鲁语", "Zulu")
    ]

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
