//
//  WebView.swift
//  translate
//
//  Created by Minan on 18.01.2023.
//

import Cocoa
import WebKit

class WebView: WKWebView {
    private let commandKey = NSEvent.ModifierFlags.command.rawValue
    private var shouldDragWindow = false
        
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == NSEvent.EventType.keyDown {
            if (event.modifierFlags.rawValue & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue) == commandKey {
                switch event.charactersIgnoringModifiers! {
                case "z":
                    if NSApp.sendAction(Selector(("undo:")), to: nil, from: self) { return true }
                case "r":
                    if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
                case "x":
                    if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
                case "c":
                    if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
                case "v":
                    if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
                default:
                break
                }
            }
        }
        
        return super.performKeyEquivalent(with: event)
    }
    
    override func mouseDown(with event: NSEvent) {
        // Both the source textarea (upper-left) and the result pane (right)
        // must keep native WebKit text selection.  Other parts of the page
        // remain window-drag surfaces.
        let point = convert(event.locationInWindow, from: nil)
        let isResultTextArea = point.x >= bounds.midX
        let isSourceTextArea = point.x < bounds.midX && point.y < bounds.height * 0.62
        shouldDragWindow = !(isResultTextArea || isSourceTextArea)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if shouldDragWindow {
            self.window?.performDrag(with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if shouldDragWindow {
            super.mouseUp(with: event)
            self.window?.mouseUp(with: event)
        } else {
            super.mouseUp(with: event)
        }
        shouldDragWindow = false
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
