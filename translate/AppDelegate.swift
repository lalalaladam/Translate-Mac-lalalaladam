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

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        TranslateFeaturePreferences.registerDefaults()
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
