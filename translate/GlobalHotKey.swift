//
//  GlobalHotKey.swift
//  translate
//
//  A small self-contained global shortcut wrapper.  The original project
//  used the remote HotKey Swift package; keeping the registration here makes
//  the modified project buildable without downloading a package at runtime.
//

import Cocoa
import Carbon.HIToolbox

final class GlobalHotKey {
    private static let signature: OSType = 0x4D435452 // "MCTR"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var keyDownHandler: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32) {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData = userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>
                .fromOpaque(userData)
                .takeUnretainedValue()
            return hotKey.handle(event)
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }

    private func handle(_ event: EventRef?) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == Self.signature else {
            return status
        }

        DispatchQueue.main.async { [weak self] in
            self?.keyDownHandler?()
        }
        return noErr
    }
}
