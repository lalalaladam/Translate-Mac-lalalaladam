//
//  AppDelegate.swift
//  translate
//
//  Created by Minan on 15.01.2023.
//

import Cocoa
import Carbon.HIToolbox
import os

private let appLifecycleLogger = Logger(subsystem: "com.lalalaladam.translate", category: "StartupTiming")

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
    var featureMenuItems: [TranslateFeature: NSMenuItem] = [:]
    var windowBehaviorMenuItems: [TranslateWindowBehavior: NSMenuItem] = [:]
    var sourceLanguageMenuItems: [TranslateLanguage: NSMenuItem] = [:]
    var targetLanguageMenuItems: [TranslateLanguage: NSMenuItem] = [:]
    var sourceLanguageRootItem: NSMenuItem?
    var targetLanguageRootItem: NSMenuItem?
    var languageSummaryItem: NSMenuItem?
    var shortcutSettingsController: ShortcutSettingsWindowController?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
#if DEBUG
        appLifecycleLogger.info("Application did finish launching")
#endif
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

        // A cold launch must not depend on Google Translate loading. Network
        // and VPN services are often still starting just after login; waiting
        // for WebKit navigation here could leave the app running without any
        // visible main window. Present the native window on the next AppKit
        // turn, then let the web content finish loading inside it.
        DispatchQueue.main.async { [weak self] in
            self?.panel.presentWhenReady()
        }
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

    var viewController: ViewController? {
        panel?.contentViewController as? ViewController
    }
}
