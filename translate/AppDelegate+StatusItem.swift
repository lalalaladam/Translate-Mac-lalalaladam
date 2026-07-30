//
//  AppDelegate+StatusItem.swift
//  translate
//

import Cocoa

extension AppDelegate {
    func showStatusBarMenu() {
        guard let button = statusBarItem.button else { return }

        let menu = NSMenu(title: "Translate")

        let toggleItem = NSMenuItem(
            title: interfaceText("显示或隐藏窗口", "Show or Hide Window"),
            action: #selector(togglePanelFromMenu),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        TranslateWindowBehavior.allCases.forEach { behavior in
            let item = NSMenuItem(
                title: behavior.title,
                action: #selector(toggleWindowBehaviorFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = behavior.rawValue
            item.state = TranslateWindowPreferences.isEnabled(behavior) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let shortcutsItem = NSMenuItem(
            title: interfaceText("快捷键设置…", "Shortcut Settings…"),
            action: #selector(showShortcutSettings),
            keyEquivalent: ""
        )
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: interfaceText("退出 Translate", "Quit Translate"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

}
