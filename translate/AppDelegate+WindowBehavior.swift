//
//  AppDelegate+WindowBehavior.swift
//  translate
//

import Cocoa

extension AppDelegate {
    @objc func togglePanelFromMenu() {
        panel.toggle()
    }

    @objc func closeWindowFromMenu(_ sender: Any?) {
        if let keyWindow = NSApp.keyWindow {
            keyWindow.performClose(sender)
        } else {
            panel?.close()
        }
    }

    @objc func toggleWindowBehaviorFromMenu(_ sender: NSMenuItem) {
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

    func recreatePanelForSpaceModeChange() {
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

    @objc func restoreDefaultWindowBehaviors() {
        TranslateWindowPreferences.restoreDefaults()
        TranslateWindowBehavior.allCases.forEach { behavior in
            windowBehaviorMenuItems[behavior]?.state = .off
        }
        panel?.applyWindowBehaviorPreferences()
        viewController?.syncWindowBehaviorControls()
    }

}
