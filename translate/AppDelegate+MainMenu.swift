//
//  AppDelegate+MainMenu.swift
//  translate
//

import Cocoa

extension AppDelegate {
    func registerGlobalShortcut() {
        // Releasing the previous wrapper unregisters its Carbon hotkey before
        // the user-selected global show/hide binding is installed.
        hotKey = nil
        let binding = ShortcutPreferences.binding(for: .showHideWindow)
        hotKey = GlobalHotKey(
            keyCode: UInt32(binding.keyCode),
            modifiers: binding.carbonModifiers
        )
    }

    func applyShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
        let binding = ShortcutPreferences.binding(for: action)
        item.keyEquivalent = binding.keyEquivalent
        item.keyEquivalentModifierMask = binding.modifierFlags
    }

    func setupMainMenu() {
        featureMenuItems.removeAll()
        windowBehaviorMenuItems.removeAll()
        sourceLanguageMenuItems.removeAll()
        targetLanguageMenuItems.removeAll()
        sourceLanguageRootItem = nil
        targetLanguageRootItem = nil
        languageSummaryItem = nil

        let mainMenu = NSMenu(title: interfaceText("主菜单", "Main Menu"))

        let appMenuItem = NSMenuItem(title: "Translate", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Translate")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let aboutItem = NSMenuItem(
            title: interfaceText("关于 Translate", "About Translate"),
            action: #selector(showTranslateCustomAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: interfaceText("显示或隐藏窗口", "Show or Hide Window"),
            action: #selector(togglePanelFromMenu),
            keyEquivalent: ""
        )
        applyShortcut(.showHideWindow, to: toggleItem)
        toggleItem.target = self
        appMenu.addItem(toggleItem)
        appMenu.addItem(.separator())

        let copySourceItem = NSMenuItem(
            title: interfaceText("复制全部原文", "Copy All Source Text"),
            action: #selector(copyAllSourceFromMenu),
            keyEquivalent: ""
        )
        copySourceItem.target = self
        appMenu.addItem(copySourceItem)

        let copyTranslationItem = NSMenuItem(
            title: interfaceText("复制全部译文", "Copy All Translation"),
            action: #selector(copyAllTranslationFromMenu),
            keyEquivalent: ""
        )
        copyTranslationItem.target = self
        appMenu.addItem(copyTranslationItem)

        let swapItem = NSMenuItem(
            title: interfaceText("交换语言", "Swap Languages"),
            action: #selector(swapLanguagesFromMenu),
            keyEquivalent: ""
        )
        applyShortcut(.swapLanguages, to: swapItem)
        swapItem.target = self
        appMenu.addItem(swapItem)

        appMenu.addItem(.separator())
        let shortcutSettingsItem = NSMenuItem(
            title: interfaceText("快捷键设置…", "Shortcut Settings…"),
            action: #selector(showShortcutSettings),
            keyEquivalent: ""
        )
        shortcutSettingsItem.target = self
        appMenu.addItem(shortcutSettingsItem)

        appMenu.addItem(.separator())
        let hideItem = NSMenuItem(
            title: interfaceText("隐藏 Translate", "Hide Translate"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: ""
        )
        applyShortcut(.hideApplication, to: hideItem)
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: interfaceText("退出 Translate", "Quit Translate"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        applyShortcut(.quitApplication, to: quitItem)
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        addLanguageMenu(to: mainMenu)
        addInterfaceLanguageMenu(to: mainMenu)
        addWindowMenu(to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    func addWindowMenu(to mainMenu: NSMenu) {
        let windowTitle = interfaceText("窗口", "Window")
        let windowMenuItem = NSMenuItem(
            title: windowTitle,
            action: nil,
            keyEquivalent: ""
        )
        let windowMenu = NSMenu(title: windowTitle)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // FloatingPanel.close() hides and retains the window, so Command+W
        // never terminates the app and the global shortcut can show it again.
        let closeItem = NSMenuItem(
            title: interfaceText("关闭窗口", "Close Window"),
            action: #selector(closeWindowFromMenu(_:)),
            keyEquivalent: ""
        )
        applyShortcut(.closeWindow, to: closeItem)
        closeItem.target = self
        windowMenu.addItem(closeItem)

        let minimizeItem = NSMenuItem(
            title: interfaceText("最小化", "Minimize"),
            action: #selector(minimizeWindowFromMenu(_:)),
            keyEquivalent: ""
        )
        applyShortcut(.minimizeWindow, to: minimizeItem)
        minimizeItem.target = self
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(.separator())

        TranslateWindowBehavior.allCases.forEach { behavior in
            let item = NSMenuItem(
                title: behavior.title,
                action: #selector(toggleWindowBehaviorFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = behavior.rawValue
            item.state = TranslateWindowPreferences.isEnabled(behavior) ? .on : .off
            windowBehaviorMenuItems[behavior] = item
            windowMenu.addItem(item)
        }

        windowMenu.addItem(.separator())
        let restoreItem = NSMenuItem(
            title: interfaceText(
                "恢复默认窗口设置",
                "Restore Default Window Settings"
            ),
            action: #selector(restoreDefaultWindowBehaviors),
            keyEquivalent: ""
        )
        restoreItem.target = self
        windowMenu.addItem(restoreItem)
    }

    func addInterfaceLanguageMenu(to mainMenu: NSMenu) {
        let menuTitle = interfaceText("界面语言", "Interface Language")
        let menuItem = NSMenuItem(title: menuTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: menuTitle)
        menu.autoenablesItems = false
        menuItem.submenu = menu
        mainMenu.addItem(menuItem)

        AppInterfaceLanguage.allCases.forEach { language in
            let item = NSMenuItem(
                title: language.nativeTitle,
                action: #selector(setInterfaceLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == AppInterfaceLanguagePreferences.current ? .on : .off
            menu.addItem(item)
        }
    }

}
