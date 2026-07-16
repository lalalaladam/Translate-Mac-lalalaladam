//
//  AppDelegate.swift
//  translate
//
//  Created by Minan on 15.01.2023.
//

import Cocoa
import Carbon.HIToolbox

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
    private var shortcutSettingsController: ShortcutSettingsWindowController?

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
        ShortcutPreferences.registerDefaults()
        setupMainMenu()
        panel = FloatingPanel()
        
        statusBar = NSStatusBar()
        statusBarItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusBarItem.button {
            button.image = NSImage(named: "icon")
            button.action = #selector(statusBarItemPressed)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        registerGlobalShortcut()

        // A cold launch should behave like a normal app: show its window once
        // the customized page is ready instead of waiting for the user to
        // discover the global shortcut.
        panel.presentWhenReady()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // No persistent resources need explicit cleanup.
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusBarMenu()
        } else {
            panel.toggle()
        }
    }

    private func showStatusBarMenu() {
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

    private var viewController: ViewController? {
        panel?.contentViewController as? ViewController
    }

    private func registerGlobalShortcut() {
        // Releasing the previous wrapper unregisters its Carbon hotkey before
        // the user-selected global show/hide binding is installed.
        hotKey = nil
        let binding = ShortcutPreferences.binding(for: .showHideWindow)
        hotKey = GlobalHotKey(
            keyCode: UInt32(binding.keyCode),
            modifiers: binding.carbonModifiers
        )
    }

    private func applyShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
        let binding = ShortcutPreferences.binding(for: action)
        item.keyEquivalent = binding.keyEquivalent
        item.keyEquivalentModifierMask = binding.modifierFlags
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

        let appMenuItem = NSMenuItem(title: "Translate", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Translate")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let aboutItem = NSMenuItem(
            title: interfaceText("关于 Translate", "About Translate"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
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
            keyEquivalent: ""
        )
        applyShortcut(.closeWindow, to: closeItem)
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
            self.viewController?.syncWindowBehaviorControls()
            self.viewController?.applyInterfaceLanguagePreservingSource()
        }
    }

    @objc private func showShortcutSettings() {
        if shortcutSettingsController == nil {
            shortcutSettingsController = ShortcutSettingsWindowController(
                didChangeShortcuts: { [weak self] in
                    guard let self else { return }
                    self.registerGlobalShortcut()
                    self.setupMainMenu()
                }
            )
        }
        shortcutSettingsController?.showWindow(nil)
        shortcutSettingsController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        setWindowBehavior(behavior, enabled: enabled)
        sender.state = enabled ? .on : .off
    }

    func setWindowBehavior(
        _ behavior: TranslateWindowBehavior,
        enabled: Bool
    ) {
        TranslateWindowPreferences.set(behavior, enabled: enabled)
        windowBehaviorMenuItems[behavior]?.state = enabled ? .on : .off
        viewController?.syncWindowBehaviorControls()

        // The panel was created while the app used accessory policy, so it is
        // already eligible for full-screen Spaces. Changing the application's
        // activation policy here can make macOS move the window—or the user—to
        // another desktop.
        if behavior == .showOnAllSpaces {
            recreatePanelForSpaceModeChange()
        } else {
            panel?.applyWindowBehaviorPreferences()
        }
    }

    private func recreatePanelForSpaceModeChange() {
        guard let oldPanel = panel else { return }

        let frame = oldPanel.frame
        let wasVisible = oldPanel.isVisible
        let wasPresented = oldPanel.isPresented
        let controller = oldPanel.contentViewController

        oldPanel.orderOut(nil)

        let replacement = FloatingPanel()
        replacement.contentViewController = controller
        replacement.setFrame(frame, display: false)
        replacement.isPresented = wasPresented
        panel = replacement

        if wasVisible {
            replacement.presentWhenReady()
        }
    }

    @objc private func restoreDefaultWindowBehaviors() {
        TranslateWindowPreferences.restoreDefaults()
        TranslateWindowBehavior.allCases.forEach { behavior in
            windowBehaviorMenuItems[behavior]?.state = .off
        }
        panel?.applyWindowBehaviorPreferences()
        viewController?.syncWindowBehaviorControls()
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

private final class ShortcutSettingsWindowController: NSWindowController {
    private let didChangeShortcuts: () -> Void

    init(didChangeShortcuts: @escaping () -> Void) {
        self.didChangeShortcuts = didChangeShortcuts
        let panel = ShortcutSettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 610),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        rebuildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        rebuildContent()
        super.showWindow(sender)
    }

    private func rebuildContent() {
        guard let panel = window else { return }
        panel.title = interfaceText("快捷键设置", "Shortcut Settings")

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 610))
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        let heading = NSTextField(labelWithString: interfaceText("快捷键设置", "Shortcut Settings"))
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        root.addArrangedSubview(heading)

        let hint = NSTextField(wrappingLabelWithString: interfaceText(
            "点击右侧按键，再按下新的组合键。重复的组合键不会被保存；可随时恢复默认设置。",
            "Click a shortcut, then press a new key combination. Duplicate shortcuts are not saved; defaults can be restored at any time."
        ))
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(hint)

        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)

        ShortcutAction.allCases.forEach { action in
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false

            let title = NSTextField(labelWithString: action.title)
            title.lineBreakMode = .byTruncatingTail
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let recorder = ShortcutRecorderButton(
                binding: ShortcutPreferences.binding(for: action)
            )
            recorder.onRecord = { [weak self, weak recorder] binding in
                guard let self, let recorder else { return }
                guard ShortcutPreferences.set(binding, for: action) else {
                    recorder.cancelRecording()
                    self.showDuplicateShortcutAlert()
                    return
                }
                recorder.binding = binding
                self.didChangeShortcuts()
            }

            row.addArrangedSubview(title)
            row.addArrangedSubview(recorder)
            title.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
            recorder.widthAnchor.constraint(equalToConstant: 160).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
            root.addArrangedSubview(row)
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.distribution = .gravityAreas

        let restoreButton = NSButton(
            title: interfaceText("恢复默认快捷键", "Restore Default Shortcuts"),
            target: self,
            action: #selector(restoreDefaultShortcuts)
        )
        footer.addArrangedSubview(restoreButton)

        let closeButton = NSButton(
            title: interfaceText("完成", "Done"),
            target: self,
            action: #selector(closeSettings)
        )
        closeButton.keyEquivalent = "\r"
        footer.addArrangedSubview(closeButton)
        root.addArrangedSubview(footer)

        panel.contentView = content
    }

    @objc private func restoreDefaultShortcuts() {
        ShortcutPreferences.restoreDefaults()
        didChangeShortcuts()
        rebuildContent()
    }

    @objc private func closeSettings() {
        window?.close()
    }

    private func showDuplicateShortcutAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = interfaceText("快捷键已被使用", "Shortcut Already in Use")
        alert.informativeText = interfaceText(
            "每项功能必须使用不同的快捷键。请改用其他组合键。",
            "Each feature must use a different shortcut. Please choose another combination."
        )
        alert.addButton(withTitle: interfaceText("好", "OK"))
        alert.beginSheetModal(for: window!)
    }
}

private final class ShortcutSettingsPanel: NSPanel {
    weak var activeRecorder: ShortcutRecorderButton?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let recorder = activeRecorder, recorder.isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        recorder.record(event)
        return true
    }
}

private final class ShortcutRecorderButton: NSButton {
    var binding: ShortcutBinding {
        didSet { updateTitle() }
    }
    var onRecord: ((ShortcutBinding) -> Void)?
    fileprivate private(set) var isRecording = false

    init(binding: ShortcutBinding) {
        self.binding = binding
        super.init(frame: .zero)
        bezelStyle = .rounded
        alignment = .center
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        target = self
        action = #selector(beginRecording)
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = interfaceText("按下快捷键…", "Press Shortcut…")
        (window as? ShortcutSettingsPanel)?.activeRecorder = self
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    fileprivate func record(_ event: NSEvent) {
        if event.keyCode == kVK_Escape {
            cancelRecording()
            return
        }
        let binding = ShortcutBinding(event: event)
        isRecording = false
        (window as? ShortcutSettingsPanel)?.activeRecorder = nil
        onRecord?(binding)
    }

    fileprivate func cancelRecording() {
        isRecording = false
        (window as? ShortcutSettingsPanel)?.activeRecorder = nil
        updateTitle()
    }

    private func updateTitle() {
        title = binding.displayText
    }
}
