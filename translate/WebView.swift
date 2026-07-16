//
//  WebView.swift
//  translate
//
//  Created by Minan on 18.01.2023.
//

import Cocoa
import WebKit

final class WindowDragHandleView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

class WebView: WKWebView {
    // The view controller performs page-specific actions such as selecting
    // source text or pressing Google's listen button. Keeping the mapping in
    // native code makes the user-configurable shortcuts work independently of
    // Google Translate's own keyboard-event implementation.
    var shortcutHandler: ((ShortcutAction) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let action = ShortcutPreferences.action(matching: event),
           shortcutHandler?(action) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let action = ShortcutPreferences.action(matching: event),
           shortcutHandler?(action) == true {
            return
        }
        super.keyDown(with: event)
    }

    // Do not show the native contextual menu/callout when text is selected.
    // Command+C still works through performKeyEquivalent above.
    override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    // Suppress the system selection menu before it is created.  Clearing an
    // already-open NSMenu leaves an empty popover on newer macOS versions.
    @available(macOS 15.0, *)
    override func showContextMenuForSelection(_ sender: Any?) {
        // Intentionally empty. Command+C remains available above.
    }

    // Do not fall through to AppKit's dictionary/Quick Look presentation.
    override func quickLook(with event: NSEvent) {
        // Intentionally empty.
    }

    override func quickLookPreviewItems(_ sender: Any?) {
        // Intentionally empty.
    }
}
