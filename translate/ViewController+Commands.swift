//
//  ViewController+Commands.swift
//  translate
//

import Cocoa
import WebKit
import os

extension ViewController {
    func logInputMethodTiming(_ event: String, webFocus: Bool = false) {
#if DEBUG
        let responder = view.window?.firstResponder
        let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let marked = longTextSourceView?.hasMarkedText() ?? false
        let markedRange = longTextSourceView?.markedRange() ?? NSRange(location: NSNotFound, length: 0)
        inputMethodTimingLogger.info(
            "[InputMethodTiming] event=\(event, privacy: .public) firstResponder=\(responderType, privacy: .public) marked=\(marked, privacy: .public) markedRange={\(markedRange.location, privacy: .public),\(markedRange.length, privacy: .public)} webFocus=\(webFocus, privacy: .public)"
        )
#endif
    }

    public func focusAndSelectField(selectContents: Bool = true) {
        if longTextOverlay?.isHidden == false, let sourceView = longTextSourceView {
            logInputMethodTiming("native-focus-request select=\(selectContents)")
            guard !sourceView.hasMarkedText() else {
                logInputMethodTiming("native-focus-skipped-marked-text")
                return
            }
            if sourceView.window?.firstResponder !== sourceView {
                sourceView.window?.makeFirstResponder(sourceView)
            }
            if selectContents {
                sourceView.selectAll(nil)
            }
            logInputMethodTiming("native-focus-completed select=\(selectContents)")
            return
        }
        // Both WKWebViews are background services and intentionally reject
        // first responder. Never focus their hidden textarea as a fallback.
        logInputMethodTiming("web-focus-skipped-no-native-editor", webFocus: false)
    }

    public func copyAllSource() {
        if let longTextSource {
            copyToPasteboard(longTextSource)
            return
        }
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let text = result as? String else { return }
            self?.copyToPasteboard(text)
        }
    }

    public func copyAllTranslation() {
        if longTextSource != nil {
            copyToPasteboard(longTextTranslation)
            return
        }
        webView.evaluateJavaScript(#"""
            (() => {
                const visible = (element) => {
                    const style = getComputedStyle(element);
                    const rect = element.getBoundingClientRect();
                    return style.display !== "none" && style.visibility !== "hidden" &&
                        rect.width > 0 && rect.height > 0;
                };
                const primary = Array.from(document.querySelectorAll(".QcsUad .ryNqvb"));
                const nodes = primary.length ? primary : Array.from(document.querySelectorAll(
                    '.QcsUad [jsname="W297wb"], .QcsUad .HwtZe, .QcsUad .jCAhz'
                ));
                const candidates = nodes
                    .filter((element) => visible(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c"));
                return candidates
                    .filter((element) => !candidates.some((other) =>
                        other !== element && element.contains(other) &&
                        (other.innerText || other.textContent || "").trim() ===
                            (element.innerText || element.textContent || "").trim()
                    ))
                    .map((element) => (element.innerText || element.textContent || "").trim())
                    .filter(Boolean)
                    .join(" ");
            })();
        """#) { [weak self] result, _ in
            guard let text = result as? String else { return }
            self?.copyToPasteboard(text)
        }
    }

    public func swapLanguages() {
        (workspaceSwapButton as? WorkspaceSwapButton)?.flashForKeyboardShortcut()
        swapCurrentTranslationLanguages()
    }

    func performShortcut(_ action: ShortcutAction) -> Bool {
        switch action {
        case .showHideWindow:
            // This action is registered as a Carbon global hotkey. Handling
            // it here too would toggle twice while the app is active.
            return false
        case .closeWindow:
            stopSpeaking()
            view.window?.performClose(nil)
        case .hideApplication:
            stopSpeaking()
            NSApp.hide(nil)
        case .quitApplication:
            stopSpeaking()
            NSApp.terminate(nil)
        case .selectAllSource:
            focusAndSelectField()
        case .listenSource:
            speakSource()
        case .listenTranslation:
            speakTranslation()
        case .stopSpeaking:
            stopSpeaking()
        case .swapLanguages:
            swapLanguages()
        case .undo:
            return NSApp.sendAction(Selector(("undo:")), to: nil, from: longTextSourceView ?? webView)
        case .redo:
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: longTextSourceView ?? webView)
        case .cut:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: longTextSourceView ?? webView)
        case .copy:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: longTextSourceView ?? webView)
        case .paste:
            if let sourceView = longTextSourceView,
               longTextOverlay?.isHidden == false {
                sourceView.window?.makeFirstResponder(sourceView)
                sourceView.paste(nil)
                return true
            }
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: webView)
        }
        return true
    }

    func restorePendingSourceTextIfNeeded() {
        guard let sourceText = pendingSourceTextForReload else { return }
        guard pendingSourceRestoreAttempts < 40 else {
            pendingSourceTextForReload = nil
            pendingSourceRestoreAttempts = 0
            return
        }
        pendingSourceRestoreAttempts += 1
        let encoded = Data(sourceText.utf8).base64EncodedString()

        webView.evaluateJavaScript(#"""
            (() => {
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;
                const bytes = Uint8Array.from(atob("\#(encoded)"), (character) =>
                    character.charCodeAt(0));
                const value = new TextDecoder().decode(bytes);
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype, "value"
                ).set;
                setter.call(textarea, value);
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
                return true;
            })();
        """#) { [weak self] result, _ in
            guard let self,
                  self.pendingSourceTextForReload == sourceText else {
                return
            }

            if result as? Bool == true {
                self.pendingSourceTextForReload = nil
                self.pendingSourceRestoreAttempts = 0
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.restorePendingSourceTextIfNeeded()
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
