//
//  ViewController+WindowBehaviorBar.swift
//  translate
//

import Cocoa

extension ViewController {
    func installWindowBehaviorBar() {
        let barHeight = Self.windowBehaviorBarHeight
        let bar = WindowBehaviorBarView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: view.bounds.width,
                height: barHeight
            )
        )
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor.separatorColor.cgColor

        keepOnTopButton = makeWindowBehaviorButton(
            title: interfaceText("当前 Space 置顶", "Keep on Top"),
            behavior: .keepOnTop
        )
        showOnAllSpacesButton = makeWindowBehaviorButton(
            title: interfaceText("所有 Space 显示", "Show on All Spaces"),
            behavior: .showOnAllSpaces
        )

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16)
        ])

        let stack = NSStackView(
            views: [keepOnTopButton, divider, showOnAllSpacesButton]
        )
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Visually separate the interactive settings from the draggable blank
        // area on either side of the bottom bar.
        let settingsGroup = NSView()
        settingsGroup.translatesAutoresizingMaskIntoConstraints = false
        settingsGroup.wantsLayer = true
        settingsGroup.layer?.cornerRadius = 9
        settingsGroup.layer?.borderWidth = 0.75
        settingsGroup.addSubview(stack)
        bar.addSubview(settingsGroup)
        NSLayoutConstraint.activate([
            settingsGroup.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            settingsGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: settingsGroup.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: settingsGroup.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: settingsGroup.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: settingsGroup.bottomAnchor, constant: -3)
        ])

        view.addSubview(bar)
        windowBehaviorBar = bar
        windowBehaviorSettingsGroup = settingsGroup
        windowBehaviorDivider = divider
        updateWindowBehaviorBarAppearance()
        syncWindowBehaviorControls()
    }

    func makeWindowBehaviorButton(
        title: String,
        behavior: TranslateWindowBehavior
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(windowBehaviorButtonChanged(_:)))
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.tag = behavior == .keepOnTop ? 0 : 1
        button.state = TranslateWindowPreferences.isEnabled(behavior) ? .on : .off
        return button
    }

    @objc func windowBehaviorButtonChanged(_ sender: NSButton) {
        let behavior: TranslateWindowBehavior = sender.tag == 0
            ? .keepOnTop
            : .showOnAllSpaces
        (NSApp.delegate as? AppDelegate)?.setWindowBehavior(
            behavior,
            enabled: sender.state == .on
        )
    }

    func syncWindowBehaviorControls() {
        keepOnTopButton?.title = interfaceText(
            "当前 Space 置顶",
            "Keep on Top"
        )
        showOnAllSpacesButton?.title = interfaceText(
            "所有 Space 显示",
            "Show on All Spaces"
        )
        keepOnTopButton?.state = TranslateWindowPreferences.keepOnTop ? .on : .off
        showOnAllSpacesButton?.state = TranslateWindowPreferences.showOnAllSpaces ? .on : .off
    }

}
