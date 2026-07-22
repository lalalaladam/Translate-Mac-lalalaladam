//
//  FloatingPanel.swift
//  translate
//
//  Created by Minan on 19.01.2023.
//

import AppKit
import os

private let inputMethodResponderLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "InputMethodTiming"
)

class FloatingPanel: NSPanel {
    public var isPresented = false
    public var isDragged = false
    private var hasPendingPresentation = false
    
    required init() {
        // Keep the main panel as a normal, activatable macOS window. Space
        // membership is controlled with collectionBehavior below; changing
        // the app activation policy during launch can cause macOS to move a
        // newly created panel to another desktop or a full-screen Space.
        var styleMask: StyleMask = [
            .resizable,
            .titled,
            .closable,
            .fullSizeContentView
        ]
        if TranslateWindowPreferences.showOnAllSpaces {
            styleMask.insert(.nonactivatingPanel)
        }
        
        super.init(contentRect: .zero, styleMask: styleMask, backing: .buffered, defer: false)

        // The customized two-pane interface needs enough room for language
        // controls, selectable text, and the native bottom bar. Do not allow
        // AppKit to compress it into a narrow strip.
        let minimumContentSize = NSSize(
            width: CGFloat(Constants.WIDTH),
            height: CGFloat(Constants.HEIGHT)
        )
        minSize = minimumContentSize
        contentMinSize = minimumContentSize
        
        // Keep an activatable normal panel; the optional always-on-top
        // behavior is controlled only through the native Window menu.
        isFloatingPanel = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        contentViewController = ViewController()
        applyWindowBehaviorPreferences()
        
        isOpaque = false
        backgroundColor = .clear
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = 16
        
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        
        center()

    }

    public func applyWindowBehaviorPreferences() {
        level = TranslateWindowPreferences.keepOnTop ? .floating : .normal

        // When shown across Spaces the panel can accept input without
        // activating the owning application. In normal mode presentNow()
        // explicitly activates the application before making the panel key.
        becomesKeyOnlyIfNeeded = TranslateWindowPreferences.showOnAllSpaces

        var behavior: CollectionBehavior = [.participatesInCycle]
        if TranslateWindowPreferences.showOnAllSpaces {
            behavior.insert(.canJoinAllSpaces)
            if #available(macOS 13.0, *) {
                // Unlike canJoinAllSpaces, this explicitly allows the panel
                // to join another application's full-screen Space.
                behavior.insert(.canJoinAllApplications)
            } else {
                // macOS 12 has no cross-application equivalent; this is the
                // closest available full-screen compatibility behavior.
                behavior.insert(.fullScreenAuxiliary)
            }
        } else {
            behavior.insert(.managed)
        }
        collectionBehavior = behavior
    }

    public func presentWhenReady() {
        let controller = contentViewController as! ViewController

        // Showing a native window must never wait for a remote website. At
        // cold login the network (or a VPN) can take a while to become ready;
        // WebKit will continue loading after the window is already visible.
        presentNow()

        guard !controller.isReady, !hasPendingPresentation else { return }
        hasPendingPresentation = true
        controller.whenReady { [weak self] in
            guard let self else { return }
            self.hasPendingPresentation = false
            // The native editor already owns keyboard input when the panel is
            // shown. Never restore focus from a WebView-ready callback: if an
            // input method owns marked text, moving the responder away and
            // back has already destroyed that composition.
        }
    }

    private func presentNow() {
        hasPendingPresentation = false
        let controller = contentViewController as! ViewController

        applyWindowBehaviorPreferences()
        isPresented = true
        if TranslateWindowPreferences.showOnAllSpaces {
            // Activating a regular application from another application's
            // full-screen Space can make macOS switch to the application's
            // previously assigned desktop. Keep this panel in the current
            // Space and only change its front order.
            orderFrontRegardless()
            makeKey()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        if controller.isReady {
            controller.focusAndSelectField()
        }
    }

    public func toggle() {
        // If the window is both visible and frontmost, the shortcut hides it.
        // If another application is frontmost, the same shortcut brings this
        // window forward instead of doing nothing.
        let shouldHide = isVisible && isKeyWindow && NSApp.isActive
        if shouldHide {
            isPresented = false
            orderOut(nil)
            return
        }

        presentWhenReady()
    }
    
    override func close() {
        hasPendingPresentation = false
        isPresented = false
        orderOut(nil)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
#if DEBUG
        let previousType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let requestedType = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let textView = (responder as? NSTextView) ?? (firstResponder as? NSTextView)
        let marked = textView?.hasMarkedText() ?? false
        let markedRange = textView?.markedRange() ?? NSRange(location: NSNotFound, length: 0)
#endif
        if responder is BackgroundTranslationWebView {
#if DEBUG
            inputMethodResponderLogger.info(
                "[InputMethodTiming] event=blocked-background-webview-first-responder previous=\(previousType, privacy: .public) requested=\(requestedType, privacy: .public) current=\(previousType, privacy: .public) accepted=false marked=\(marked, privacy: .public) markedRange={\(markedRange.location, privacy: .public),\(markedRange.length, privacy: .public)}"
            )
#endif
            return false
        }
        let accepted = super.makeFirstResponder(responder)
#if DEBUG
        let currentType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        inputMethodResponderLogger.info(
            "[InputMethodTiming] event=first-responder-change previous=\(previousType, privacy: .public) requested=\(requestedType, privacy: .public) current=\(currentType, privacy: .public) accepted=\(accepted, privacy: .public) marked=\(marked, privacy: .public) markedRange={\(markedRange.location, privacy: .public),\(markedRange.length, privacy: .public)}"
        )
#endif
        return accepted
    }
    
    override func performDrag(with event: NSEvent) {
        super.performDrag(with: event)
        isDragged = true
    }
    
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        
        if (isDragged) {
            let controller = contentViewController as! ViewController
            controller.focusAndSelectField()
            isDragged = false
        }
    }

    // Native text views now own the visible workspace, so route configured
    // command shortcuts at the window level instead of relying on the hidden
    // WKWebView to be the first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let action = ShortcutPreferences.action(matching: event),
           let controller = contentViewController as? ViewController,
           controller.performShortcut(action) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
