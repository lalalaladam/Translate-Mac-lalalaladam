//
//  AppDelegate+LanguageMenus.swift
//  translate
//

import Cocoa

extension AppDelegate {
    func addLanguageMenu(to mainMenu: NSMenu) {
        let languageTitle = interfaceText("默认语言", "Default Languages")
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

    func updateLanguageMenuStates() {
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

    @objc func setInterfaceLanguageFromMenu(_ sender: NSMenuItem) {
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
            self.viewController?.syncWindowBehaviorControls()
            self.viewController?.applyInterfaceLanguagePreservingSource()
        }
    }

}
