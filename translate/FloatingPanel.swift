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
    
    required init() {
        let styleMask: StyleMask = [.resizable, .titled, .closable, .fullSizeContentView]
        
        super.init(contentRect: .zero, styleMask: styleMask, backing: .buffered, defer: false)
        
        // This is a normal window.  It is raised explicitly by toggle() and
        // therefore never remains permanently above other applications.
        level = .normal
        isFloatingPanel = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        contentViewController = ViewController()
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
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
    
    public func toggle() {
        let controller = contentViewController as! ViewController
        
        if !controller.isReady {
            return
        }
        
        // If the window is both visible and frontmost, the shortcut hides it.
        // If another application is frontmost, the same shortcut brings this
        // window forward instead of doing nothing.
        let shouldHide = isVisible && isKeyWindow && NSApp.isActive
        if shouldHide {
            isPresented = false
            orderOut(nil)
            return
        }

        isPresented = true
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        controller.focusAndSelectField()
    }
    
    override func close() {
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
