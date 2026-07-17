//
//  FloatingPanel.swift
//  translate
//
//  Created by Minan on 19.01.2023.
//

import AppKit

class FloatingPanel: NSPanel {
    public var isPresented = false
    public var isDragged = false
    private var hasPendingPresentation = false
    
    required init() {
        // nonactivatingPanel must be decided when the underlying NSPanel is
        // created. The app delegate recreates this lightweight panel when the
        // all-Spaces preference changes, while preserving its web controller.
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

        if controller.isReady {
            presentNow()
            return
        }

        guard !hasPendingPresentation else { return }
        hasPendingPresentation = true
        controller.whenReady { [weak self] in
            guard let self, self.hasPendingPresentation else { return }
            self.presentNow()
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
        controller.focusAndSelectField()
    }

    public func toggle() {
        let controller = contentViewController as! ViewController
        
        // If the window is both visible and frontmost, the shortcut hides it.
        // If another application is frontmost, the same shortcut brings this
        // window forward instead of doing nothing.
        let shouldHide = isVisible && isKeyWindow && NSApp.isActive
        if shouldHide {
            isPresented = false
            orderOut(nil)
            return
        }

        if controller.isReady {
            presentNow()
        } else {
            presentWhenReady()
        }
    }
    
    override func close() {
        hasPendingPresentation = false
        isPresented = false
        orderOut(nil)
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
}
