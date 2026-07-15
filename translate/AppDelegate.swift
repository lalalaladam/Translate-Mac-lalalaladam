//
//  AppDelegate.swift
//  translate
//
//  Created by Minan on 15.01.2023.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    public var panel: FloatingPanel!
    public var hotKey: GlobalHotKey? {
        didSet {
            guard let hotKey = hotKey else {
                return
            }
            
            hotKey.keyDownHandler = { [weak self] in
                self?.panel.toggle()
            }
        }
    }
    
    var statusBar: NSStatusBar!
    var statusBarItem: NSStatusItem!
    private var featureMenuItems: [TranslateFeature: NSMenuItem] = [:]
    private var windowBehaviorMenuItems: [TranslateWindowBehavior: NSMenuItem] = [:]
    private var sourceLanguageMenuItems: [TranslateLanguage: NSMenuItem] = [:]
    private var targetLanguageMenuItems: [TranslateLanguage: NSMenuItem] = [:]
    private var sourceLanguageRootItem: NSMenuItem?
    private var targetLanguageRootItem: NSMenuItem?
    private var languageSummaryItem: NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // AppKit only registers a panel as eligible for another application's
        // full-screen Space while the owning app uses the accessory policy.
        // Create the panel in that policy, then immediately restore normal
        // Dock and menu-bar behavior before anything is presented.
        let restoreRegularPolicy = NSApp.activationPolicy() == .regular
        if restoreRegularPolicy {
            NSApp.setActivationPolicy(.accessory)
        }
        defer {
            if restoreRegularPolicy {
                NSApp.setActivationPolicy(.regular)
            }
        }

        AppInterfaceLanguagePreferences.registerDefaults()
        TranslateFeaturePreferences.registerDefaults()
        TranslateLanguagePreferences.registerDefaults()
        TranslateWindowPreferences.registerDefaults()
        setupMainMenu()
        panel = FloatingPanel()
        
        statusBar = NSStatusBar()
        statusBarItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem.button {
            button.image = NSImage(named: "icon")
            button.action = #selector(statusBarItemPressed)
        }
        
        // Register Command + backslash at the system level.  This event is
        // delivered even when another application is in front.
        hotKey = GlobalHotKey(
            keyCode: Constants.keyCode,
            modifiers: Constants.carbonModifiers
        )

        // A cold launch should behave like a normal app: show its window once
        // the customized page is ready instead of waiting for the user to
        // discover the global shortcut.
        panel.presentWhenReady()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            panel?.presentWhenReady()
        }
        return true
    }
    
    @objc func statusBarItemPressed() {
        self.panel.toggle()
    }

    private var viewController: ViewController? {
        panel?.contentViewController as? ViewController
    }

    private func setupMainMenu() {
        featureMenuItems.removeAll()
        windowBehaviorMenuItems.removeAll()
        sourceLanguageMenuItems.removeAll()
        targetLanguageMenuItems.removeAll()
        sourceLanguageRootItem = nil
        targetLanguageRootItem = nil
        languageSummaryItem = nil

        let mainMenu = NSMenu(title: interfaceText("主菜单", "Main Menu"))

        let appMenuItem = NSMenuItem(title: "translate", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "translate")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let aboutItem = NSMenuItem(
            title: interfaceText("关于 translate", "About translate"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: interfaceText("隐藏 translate", "Hide translate"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.keyEquivalentModifierMask = [.command]
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: interfaceText("退出 translate", "Quit translate"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let translationTitle = interfaceText("翻译", "Translation")
        let translationMenuItem = NSMenuItem(
            title: translationTitle,
            action: nil,
            keyEquivalent: ""
        )
        let translationMenu = NSMenu(title: translationTitle)
        translationMenuItem.submenu = translationMenu
        mainMenu.addItem(translationMenuItem)

        let toggleItem = NSMenuItem(
            title: interfaceText("显示或隐藏窗口", "Show or Hide Window"),
            action: #selector(togglePanelFromMenu),
            keyEquivalent: "\\"
        )
        toggleItem.keyEquivalentModifierMask = [.command]
        toggleItem.target = self
        translationMenu.addItem(toggleItem)
        translationMenu.addItem(.separator())

        let copySourceItem = NSMenuItem(
            title: interfaceText("复制全部原文", "Copy All Source Text"),
            action: #selector(copyAllSourceFromMenu),
            keyEquivalent: ""
        )
        copySourceItem.target = self
        translationMenu.addItem(copySourceItem)

        let copyTranslationItem = NSMenuItem(
            title: interfaceText("复制全部译文", "Copy All Translation"),
            action: #selector(copyAllTranslationFromMenu),
            keyEquivalent: ""
        )
        copyTranslationItem.target = self
        translationMenu.addItem(copyTranslationItem)

        let swapItem = NSMenuItem(
            title: interfaceText("交换语言", "Swap Languages"),
            action: #selector(swapLanguagesFromMenu),
            keyEquivalent: "s"
        )
        swapItem.keyEquivalentModifierMask = [.command]
        swapItem.target = self
        translationMenu.addItem(swapItem)

        addLanguageMenu(to: mainMenu)
        addInterfaceLanguageMenu(to: mainMenu)

        let displayTitle = interfaceText("显示", "Display")
        let displayMenuItem = NSMenuItem(
            title: displayTitle,
            action: nil,
            keyEquivalent: ""
        )
        let displayMenu = NSMenu(title: displayTitle)
        displayMenuItem.submenu = displayMenu
        mainMenu.addItem(displayMenuItem)

        TranslateFeature.allCases.forEach { feature in
            let item = NSMenuItem(
                title: feature.title,
                action: #selector(toggleFeatureFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = feature.rawValue
            item.state = TranslateFeaturePreferences.isEnabled(feature) ? .on : .off
            featureMenuItems[feature] = item
            displayMenu.addItem(item)
        }

        displayMenu.addItem(.separator())
        let restoreItem = NSMenuItem(
            title: interfaceText(
                "恢复推荐显示设置",
                "Restore Recommended Display Settings"
            ),
            action: #selector(restoreRecommendedFeatures),
            keyEquivalent: ""
        )
        restoreItem.target = self
        displayMenu.addItem(restoreItem)

        addWindowMenu(to: mainMenu)
        addShortcutMenu(to: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    private func addWindowMenu(to mainMenu: NSMenu) {
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
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command]
        closeItem.target = self
        windowMenu.addItem(closeItem)
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

    private func addShortcutMenu(to mainMenu: NSMenu) {
        let shortcutTitle = interfaceText("快捷键", "Shortcuts")
        let shortcutMenuItem = NSMenuItem(
            title: shortcutTitle,
            action: nil,
            keyEquivalent: ""
        )
        let shortcutMenu = NSMenu(title: shortcutTitle)
        shortcutMenu.autoenablesItems = false
        shortcutMenuItem.submenu = shortcutMenu
        mainMenu.addItem(shortcutMenuItem)

        [
            interfaceText("显示或隐藏窗口 — ⌘\\", "Show or Hide Window — ⌘\\"),
            interfaceText("关闭窗口 — ⌘W", "Close Window — ⌘W"),
            interfaceText("隐藏应用 — ⌘H", "Hide Application — ⌘H"),
            interfaceText("退出应用 — ⌘Q", "Quit Application — ⌘Q")
        ].forEach { addShortcutReference($0, to: shortcutMenu) }

        shortcutMenu.addItem(.separator())
        [
            interfaceText("选中全部原文 — ⌘A", "Select All Source Text — ⌘A"),
            interfaceText("朗读原文 — ⌘L", "Listen to Source Text — ⌘L"),
            interfaceText("交换语言 — ⌘S", "Swap Languages — ⌘S"),
            interfaceText(
                "应用 Google 拼写修正 — ⌘↩",
                "Apply Google Spelling Correction — ⌘↩"
            ),
            interfaceText(
                "将焦点移出翻译窗口 — ⇥",
                "Move Focus out of Translation Window — ⇥"
            )
        ].forEach { addShortcutReference($0, to: shortcutMenu) }

        shortcutMenu.addItem(.separator())
        [
            interfaceText("撤销 — ⌘Z", "Undo — ⌘Z"),
            interfaceText("重做 — ⌘R", "Redo — ⌘R"),
            interfaceText("剪切 — ⌘X", "Cut — ⌘X"),
            interfaceText("复制所选文字 — ⌘C", "Copy Selected Text — ⌘C"),
            interfaceText("粘贴 — ⌘V", "Paste — ⌘V")
        ].forEach { addShortcutReference($0, to: shortcutMenu) }
    }

    private func addInterfaceLanguageMenu(to mainMenu: NSMenu) {
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

    private func addShortcutReference(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        menu.addItem(item)
    }

    private func addLanguageMenu(to mainMenu: NSMenu) {
        let languageTitle = interfaceText("语言", "Languages")
        let languageMenuItem = NSMenuItem(
            title: languageTitle,
            action: nil,
            keyEquivalent: ""
        )
        let languageMenu = NSMenu(title: languageTitle)
        languageMenu.autoenablesItems = false
        languageMenuItem.submenu = languageMenu
        mainMenu.addItem(languageMenuItem)

        let sourceTitle = interfaceText("默认源语言", "Default Source Language")
        let sourceRootItem = NSMenuItem(
            title: sourceTitle,
            action: nil,
            keyEquivalent: ""
        )
        let sourceMenu = NSMenu(title: sourceTitle)
        sourceMenu.autoenablesItems = false
        sourceRootItem.submenu = sourceMenu
        sourceLanguageRootItem = sourceRootItem
        languageMenu.addItem(sourceRootItem)

        TranslateLanguage.allCases.forEach { language in
            let item = NSMenuItem(
                title: language.title,
                action: #selector(setDefaultSourceLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            sourceLanguageMenuItems[language] = item
            sourceMenu.addItem(item)
        }

        let targetTitle = interfaceText("默认目标语言", "Default Target Language")
        let targetRootItem = NSMenuItem(
            title: targetTitle,
            action: nil,
            keyEquivalent: ""
        )
        let targetMenu = NSMenu(title: targetTitle)
        targetMenu.autoenablesItems = false
        targetRootItem.submenu = targetMenu
        targetLanguageRootItem = targetRootItem
        languageMenu.addItem(targetRootItem)

        TranslateLanguage.allCases.filter(\.canBeTarget).forEach { language in
            let item = NSMenuItem(
                title: language.title,
                action: #selector(setDefaultTargetLanguageFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            targetLanguageMenuItems[language] = item
            targetMenu.addItem(item)
        }

        languageMenu.addItem(.separator())
        let summaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        languageSummaryItem = summaryItem
        languageMenu.addItem(summaryItem)

        let applyItem = NSMenuItem(
            title: interfaceText("应用默认语言", "Apply Default Languages"),
            action: #selector(applyDefaultLanguagesFromMenu),
            keyEquivalent: ""
        )
        applyItem.target = self
        languageMenu.addItem(applyItem)

        let restoreItem = NSMenuItem(
            title: interfaceText(
                "恢复为英语 → 中文（简体）",
                "Restore English → Chinese (Simplified)"
            ),
            action: #selector(restoreInitialLanguagesFromMenu),
            keyEquivalent: ""
        )
        restoreItem.target = self
        languageMenu.addItem(restoreItem)

        updateLanguageMenuStates()
    }

    private func updateLanguageMenuStates() {
        let source = TranslateLanguagePreferences.source
        let target = TranslateLanguagePreferences.target

        sourceLanguageMenuItems.forEach { language, item in
            item.state = language == source ? .on : .off
        }
        targetLanguageMenuItems.forEach { language, item in
            item.state = language == target ? .on : .off
        }

        sourceLanguageRootItem?.title = interfaceText(
            "默认源语言：\(source.title)",
            "Default Source Language: \(source.title)"
        )
        targetLanguageRootItem?.title = interfaceText(
            "默认目标语言：\(target.title)",
            "Default Target Language: \(target.title)"
        )
        languageSummaryItem?.title = interfaceText(
            "当前默认：\(source.title) → \(target.title)",
            "Current Default: \(source.title) → \(target.title)"
        )
    }

    @objc private func setInterfaceLanguageFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppInterfaceLanguage(rawValue: rawValue),
              language != AppInterfaceLanguagePreferences.current else {
            return
        }

        AppInterfaceLanguagePreferences.set(language)

        // Replace the menu after AppKit finishes dispatching the action from
        // the currently open menu, then reload only the page locale while
        // preserving the source text and the current language pair.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setupMainMenu()
            self.viewController?.applyInterfaceLanguagePreservingSource()
        }
    }

    @objc private func togglePanelFromMenu() {
        panel.toggle()
    }

    @objc private func closeWindowFromMenu(_ sender: Any?) {
        if let keyWindow = NSApp.keyWindow {
            keyWindow.performClose(sender)
        } else {
            panel?.close()
        }
    }

    @objc private func toggleWindowBehaviorFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let behavior = TranslateWindowBehavior(rawValue: rawValue) else {
            return
        }

        let enabled = !TranslateWindowPreferences.isEnabled(behavior)
        TranslateWindowPreferences.set(behavior, enabled: enabled)
        sender.state = enabled ? .on : .off

        // Registering canJoinAllApplications while temporarily accessory is
        // what lets this already-created panel join another app's full-screen
        // Space. Restore the regular policy immediately so menus and Dock
        // behavior remain unchanged for the user.
        let restoreRegularPolicy = behavior == .showOnAllSpaces &&
            enabled && NSApp.activationPolicy() == .regular
        if restoreRegularPolicy {
            NSApp.setActivationPolicy(.accessory)
        }
        panel?.applyWindowBehaviorPreferences()
        if restoreRegularPolicy {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func restoreDefaultWindowBehaviors() {
        TranslateWindowPreferences.restoreDefaults()
        TranslateWindowBehavior.allCases.forEach { behavior in
            windowBehaviorMenuItems[behavior]?.state = .off
        }
        panel?.applyWindowBehaviorPreferences()
    }

    @objc private func copyAllSourceFromMenu() {
        viewController?.copyAllSource()
    }

    @objc private func copyAllTranslationFromMenu() {
        viewController?.copyAllTranslation()
    }

    @objc private func swapLanguagesFromMenu() {
        viewController?.swapLanguages()
    }

    @objc private func setDefaultSourceLanguageFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let newSource = TranslateLanguage(rawValue: rawValue) else {
            return
        }

        let oldSource = TranslateLanguagePreferences.source
        let oldTarget = TranslateLanguagePreferences.target
        guard newSource != oldSource else { return }

        var newTarget = oldTarget
        if newSource != .automatic && newSource == oldTarget {
            if oldSource.canBeTarget && oldSource != newSource {
                newTarget = oldSource
            } else {
                newTarget = newSource == .simplifiedChinese ? .english : .simplifiedChinese
            }
        }

        TranslateLanguagePreferences.set(source: newSource, target: newTarget)
        updateLanguageMenuStates()
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc private func setDefaultTargetLanguageFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let newTarget = TranslateLanguage(rawValue: rawValue),
              newTarget.canBeTarget else {
            return
        }

        let oldSource = TranslateLanguagePreferences.source
        let oldTarget = TranslateLanguagePreferences.target
        guard newTarget != oldTarget else { return }

        var newSource = oldSource
        if oldSource != .automatic && newTarget == oldSource {
            newSource = oldTarget != newTarget ? oldTarget : .automatic
        }

        TranslateLanguagePreferences.set(source: newSource, target: newTarget)
        updateLanguageMenuStates()
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc private func applyDefaultLanguagesFromMenu() {
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc private func restoreInitialLanguagesFromMenu() {
        TranslateLanguagePreferences.restoreInitialPair()
        updateLanguageMenuStates()
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc private func toggleFeatureFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let feature = TranslateFeature(rawValue: rawValue) else {
            return
        }

        let enabled = !TranslateFeaturePreferences.isEnabled(feature)
        TranslateFeaturePreferences.set(feature, enabled: enabled)
        sender.state = enabled ? .on : .off
        viewController?.reloadWithCurrentPreferences()
    }

    @objc private func restoreRecommendedFeatures() {
        TranslateFeaturePreferences.restoreRecommendedSettings()
        TranslateFeature.allCases.forEach { feature in
            featureMenuItems[feature]?.state = .on
        }
        viewController?.reloadWithCurrentPreferences()
    }
}
