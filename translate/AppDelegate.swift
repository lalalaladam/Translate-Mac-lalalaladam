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
    private var sourceLanguageMenuItems: [TranslateLanguage: NSMenuItem] = [:]
    private var targetLanguageMenuItems: [TranslateLanguage: NSMenuItem] = [:]
    private var sourceLanguageRootItem: NSMenuItem?
    private var targetLanguageRootItem: NSMenuItem?
    private var languageSummaryItem: NSMenuItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        TranslateFeaturePreferences.registerDefaults()
        TranslateLanguagePreferences.registerDefaults()
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
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    @objc func statusBarItemPressed() {
        self.panel.toggle()
    }

    private var viewController: ViewController? {
        panel?.contentViewController as? ViewController
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem(title: "translate", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "translate")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let aboutItem = NSMenuItem(
            title: "关于 translate",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏 translate",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.keyEquivalentModifierMask = [.command]
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 translate",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let translationMenuItem = NSMenuItem(title: "翻译", action: nil, keyEquivalent: "")
        let translationMenu = NSMenu(title: "翻译")
        translationMenuItem.submenu = translationMenu
        mainMenu.addItem(translationMenuItem)

        let toggleItem = NSMenuItem(
            title: "显示或隐藏窗口",
            action: #selector(togglePanelFromMenu),
            keyEquivalent: "\\"
        )
        toggleItem.keyEquivalentModifierMask = [.command]
        toggleItem.target = self
        translationMenu.addItem(toggleItem)
        translationMenu.addItem(.separator())

        let copySourceItem = NSMenuItem(
            title: "复制全部原文",
            action: #selector(copyAllSourceFromMenu),
            keyEquivalent: ""
        )
        copySourceItem.target = self
        translationMenu.addItem(copySourceItem)

        let copyTranslationItem = NSMenuItem(
            title: "复制全部译文",
            action: #selector(copyAllTranslationFromMenu),
            keyEquivalent: ""
        )
        copyTranslationItem.target = self
        translationMenu.addItem(copyTranslationItem)

        let swapItem = NSMenuItem(
            title: "交换语言",
            action: #selector(swapLanguagesFromMenu),
            keyEquivalent: "s"
        )
        swapItem.keyEquivalentModifierMask = [.command]
        swapItem.target = self
        translationMenu.addItem(swapItem)

        addLanguageMenu(to: mainMenu)

        let displayMenuItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu(title: "显示")
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
            title: "恢复推荐显示设置",
            action: #selector(restoreRecommendedFeatures),
            keyEquivalent: ""
        )
        restoreItem.target = self
        displayMenu.addItem(restoreItem)

        NSApp.mainMenu = mainMenu
    }

    private func addLanguageMenu(to mainMenu: NSMenu) {
        let languageMenuItem = NSMenuItem(title: "语言", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: "语言")
        languageMenu.autoenablesItems = false
        languageMenuItem.submenu = languageMenu
        mainMenu.addItem(languageMenuItem)

        let sourceRootItem = NSMenuItem(title: "默认源语言", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu(title: "默认源语言")
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

        let targetRootItem = NSMenuItem(title: "默认目标语言", action: nil, keyEquivalent: "")
        let targetMenu = NSMenu(title: "默认目标语言")
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
            title: "应用默认语言",
            action: #selector(applyDefaultLanguagesFromMenu),
            keyEquivalent: ""
        )
        applyItem.target = self
        languageMenu.addItem(applyItem)

        let restoreItem = NSMenuItem(
            title: "恢复为英语 → 中文（简体）",
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

        sourceLanguageRootItem?.title = "默认源语言：\(source.title)"
        targetLanguageRootItem?.title = "默认目标语言：\(target.title)"
        languageSummaryItem?.title = "当前默认：\(source.title) → \(target.title)"
    }

    @objc private func togglePanelFromMenu() {
        panel.toggle()
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
