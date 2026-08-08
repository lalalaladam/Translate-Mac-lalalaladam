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

    @objc func showTranslateCustomAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.rebuildContent()
        aboutWindowController?.present()
    }

}

final class AboutWindowController: NSWindowController {
    private static let contentWidth: CGFloat = AppBuildMetadata.isDebugBuild ? 600 : 540
    private static let contentHeight: CGFloat = AppBuildMetadata.isDebugBuild ? 528 : 428

    init() {
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.contentWidth,
                height: Self.contentHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func rebuildContent() {
        guard let window else { return }
        window.title = interfaceText("关于 Translate", "About Translate")

        let size = NSSize(width: Self.contentWidth, height: Self.contentHeight)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        var top = size.height - 42

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.frame = NSRect(
            x: (size.width - 96) / 2,
            y: top - 96,
            width: 96,
            height: 96
        )
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)
        top -= 108

        let name = label("Translate", size: 24, weight: .semibold)
        name.alignment = .center
        place(name, in: content, top: &top, height: 30, gap: 6)

        let standardVersion = label(
            interfaceText(
                "版本 \(AppBuildMetadata.marketingVersion)（构建 \(AppBuildMetadata.buildNumber)）",
                "Version \(AppBuildMetadata.marketingVersion) (Build \(AppBuildMetadata.buildNumber))"
            ),
            color: .secondaryLabelColor
        )
        standardVersion.alignment = .center
        place(standardVersion, in: content, top: &top, height: 18, gap: 18)

        if AppBuildMetadata.isDebugBuild {
            let metadata = label(
                AppBuildMetadata.debugAboutDescription,
                size: 12,
                color: .secondaryLabelColor
            )
            metadata.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            metadata.alignment = .center
            place(metadata, in: content, top: &top, height: 82, width: 310, gap: 18)
        }

        let separator = NSBox(frame: NSRect(x: 32, y: top - 1, width: size.width - 64, height: 1))
        separator.boxType = .separator
        content.addSubview(separator)
        top -= 19

        let credits = label(
            interfaceText(
                "署名与致谢\n\nGitHub：github.com/lalalaladam/Translate-Mac-lalalaladam\n\n致谢原作者：m-inan\n原始项目：github.com/m-inan/mac-translate\n\n图标由 Lefika 设计（VectorStock 图片 #45239855）\n依据 VectorStock Free License 使用并保留署名。\n\n本项目是独立重构和扩展版本，未获得原作者官方认可。",
                "Attribution & Credits\n\nGitHub: github.com/lalalaladam/Translate-Mac-lalalaladam\n\nOriginal author: m-inan\nOriginal project: github.com/m-inan/mac-translate\n\nIcon designed by Lefika (VectorStock Image #45239855)\nUsed under the VectorStock Free License with attribution.\n\nThis is an independent redesign and extension and is not officially endorsed by the original author."
            ),
            size: 12,
            color: .secondaryLabelColor
        )
        credits.alignment = .center
        credits.maximumNumberOfLines = 0
        credits.lineBreakMode = .byWordWrapping
        credits.preferredMaxLayoutWidth = Self.contentWidth - 64
        place(credits, in: content, top: &top, height: 190, width: size.width - 64)

        window.contentView = content
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.center()
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func label(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = true
        return field
    }

    private func place(
        _ field: NSTextField,
        in content: NSView,
        top: inout CGFloat,
        height: CGFloat,
        width: CGFloat? = nil,
        gap: CGFloat = 0
    ) {
        let fieldWidth = width ?? content.frame.width - 64
        field.frame = NSRect(
            x: (content.frame.width - fieldWidth) / 2,
            y: top - height,
            width: fieldWidth,
            height: height
        )
        content.addSubview(field)
        top -= height + gap
    }
}
