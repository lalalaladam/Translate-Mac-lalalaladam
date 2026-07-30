//
//  AppDelegate+PreferencesWindows.swift
//  translate
//

import Cocoa

extension AppDelegate {
    @objc func showShortcutSettings() {
        if shortcutSettingsController == nil {
            shortcutSettingsController = ShortcutSettingsWindowController(
                referenceWindow: panel,
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

    @objc func showAboutPanel() {
        let debugMetadata = AppBuildMetadata.isDebugBuild
            ? "\n\n\(AppBuildMetadata.debugAboutDescription)"
            : ""
        let credits = NSAttributedString(
            string: interfaceText(
                "\(debugMetadata)\n\nGitHub：lalalaladam\n\n致谢原作者：m-inan\n原始项目：github.com/m-inan/mac-translate\n\n本项目是独立重构和扩展版本，未获得原作者官方认可。",
                "\(debugMetadata)\n\nGitHub: lalalaladam\n\nOriginal author: m-inan\nOriginal project: github.com/m-inan/mac-translate\n\nThis is an independent redesign and extension and is not officially endorsed by the original author."
            ),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

}
