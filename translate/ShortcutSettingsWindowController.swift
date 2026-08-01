import Cocoa

import Carbon.HIToolbox

final class ShortcutSettingsWindowController: NSWindowController {
    private let didChangeShortcuts: () -> Void
    private weak var referenceWindow: NSWindow?

    init(
        referenceWindow: NSWindow?,
        didChangeShortcuts: @escaping () -> Void
    ) {
        self.didChangeShortcuts = didChangeShortcuts
        self.referenceWindow = referenceWindow
        let panel = ShortcutSettingsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .normal
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        super.init(window: panel)
        rebuildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        rebuildContent()
        super.showWindow(sender)
        positionRelativeToTranslator()
    }

    private func positionRelativeToTranslator() {
        guard let panel = window else { return }
        guard let referenceWindow else {
            panel.center()
            return
        }

        let referenceFrame = referenceWindow.frame
        var origin = NSPoint(
            x: referenceFrame.midX - panel.frame.width / 2,
            y: referenceFrame.midY - panel.frame.height / 2
        )

        // Keep the settings window wholly reachable even when the translator
        // itself is parked close to a screen edge or on another display.
        if let visibleFrame = referenceWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - panel.frame.width)
            origin.y = min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }

    private func rebuildContent() {
        guard let panel = window else { return }
        panel.title = interfaceText("快捷键设置", "Shortcut Settings")

        let content = ShortcutSettingsBackgroundView(
            frame: NSRect(x: 0, y: 0, width: 560, height: 590)
        )
        // Match the main translator window: a real vibrancy surface rather
        // than an opaque white utility sheet.
        content.material = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .dark
            : .light
        content.blendingMode = .behindWindow
        content.state = .active
        let root = ShortcutSettingsDragStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            // Leave enough room for the traffic lights without creating a
            // detached second title strip below them.
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
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

// This is intentionally a regular window, not an NSPanel: configuration
// should follow ordinary window ordering and never remain above other apps.
private final class ShortcutSettingsPanel: NSWindow {
    weak var activeRecorder: ShortcutRecorderButton?
    private var closeShortcutMonitor: Any?

    override func makeKeyAndOrderFront(_ sender: Any?) {
        installCloseShortcutMonitorIfNeeded()
        super.makeKeyAndOrderFront(sender)
    }

    deinit {
        if let closeShortcutMonitor {
            NSEvent.removeMonitor(closeShortcutMonitor)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if !(activeRecorder?.isRecording ?? false), isCloseShortcut(event) {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = activeRecorder, recorder.isRecording {
            recorder.record(event)
            return true
        }

        if isCloseShortcut(event) {
            performClose(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private func isCloseShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == .command && event.charactersIgnoringModifiers?.lowercased() == "w"
    }

    private func installCloseShortcutMonitorIfNeeded() {
        guard closeShortcutMonitor == nil else { return }
        closeShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self,
                  self.isKeyWindow,
                  !(self.activeRecorder?.isRecording ?? false),
                  self.isCloseShortcut(event) else {
                return event
            }
            self.performClose(nil)
            return nil
        }
    }
}

// The normal title bar remains draggable, and these two background views add
// the same behavior to empty content space.  Controls keep their own event
// handling, so recording or pressing a shortcut button never starts a drag.
private final class ShortcutSettingsBackgroundView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private final class ShortcutSettingsDragStackView: NSStackView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
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
