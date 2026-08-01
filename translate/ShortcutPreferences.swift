import Foundation

import AppKit

import Carbon.HIToolbox

enum ShortcutAction: String, CaseIterable {
    case showHideWindow
    case closeWindow
    case minimizeWindow
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
        case .minimizeWindow:
            return interfaceText("最小化窗口", "Minimize Window")
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
        case .minimizeWindow:
            return ShortcutBinding(keyCode: kVK_ANSI_M, modifiers: [.command], keyEquivalent: "m")
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
            return ShortcutBinding(
                keyCode: kVK_ANSI_Z,
                modifiers: [.command, .shift],
                keyEquivalent: "z"
            )
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
        // Migrate the former built-in Command-R binding to the standard
        // Shift-Command-Z default shown in Shortcut Settings.
        if action == .redo,
           binding == ShortcutBinding(
               keyCode: kVK_ANSI_R,
               modifiers: [.command],
               keyEquivalent: "r"
           ) {
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
