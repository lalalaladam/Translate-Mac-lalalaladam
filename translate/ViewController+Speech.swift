import AVFoundation

import Cocoa

import WebKit

extension ViewController {
    func speakSource() {
        if longTextOverlay?.isHidden == false {
            let source = selectedText(in: longTextSourceView) ??
                longTextSourceView?.string ?? longTextSource ?? ""
            speak(source, language: currentSourceLanguage, pane: .source)
            return
        }
        webView.evaluateJavaScript(#"""
            (() => window.getSelection()?.toString().trim() ||
                document.querySelector("textarea")?.value || "")();
        """#) { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            DispatchQueue.main.async {
                self.speak(text, language: self.currentSourceLanguage, pane: .source)
            }
        }
    }

    func speakTranslation() {
        if longTextOverlay?.isHidden == false {
            let translation = selectedText(in: longTextTranslationView) ??
                longTextTranslationView?.string ?? longTextTranslation
            speak(translation, language: currentTargetLanguage, pane: .translation)
            return
        }
        webView.evaluateJavaScript(#"""
            (() => {
                const selected = window.getSelection()?.toString().trim();
                if (selected) return selected;
                const selectors = [
                    ".QcsUad .ryNqvb",
                    ".QcsUad .HwtZe",
                    ".QcsUad .jCAhz",
                    ".QcsUad .lRu31"
                ];
                for (const selector of selectors) {
                    const text = document.querySelector(selector)?.innerText?.trim();
                    if (text) return text;
                }
                return "";
            })();
        """#) { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            DispatchQueue.main.async {
                self.speak(text, language: self.currentTargetLanguage, pane: .translation)
            }
        }
    }

    private func selectedText(in view: NSTextView?) -> String? {
        guard let view, view.selectedRange().length > 0 else { return nil }
        let range = view.selectedRange()
        return (view.string as NSString).substring(with: range)
    }

    // MARK: - On-demand text alignment

    /// Expand both ends of the user's selection to semantic units.  Reference
    /// entries contain DOI values, dates and initials whose periods are not
    /// sentence boundaries, so an entire citation line is one unit.
    private func speak(_ text: String, language: TranslateLanguage, pane: SpeechPane) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // The same control toggles an active utterance off. Starting the
        // opposite pane always interrupts the previous one immediately.
        if speechSynthesizer.isSpeaking, activeSpeechPane == pane {
            stopSpeaking()
            return
        }
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if language != .automatic {
            utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        }
        speechSynthesizer.speak(utterance)
        activeSpeechPane = pane
    }

    func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        activeSpeechPane = nil
    }

    @objc func workspaceSourceLanguageClicked(_ sender: NSButton) {
        presentNativeLanguagePicker(side: .source, relativeTo: sender)
    }

    @objc func workspaceTargetLanguageClicked(_ sender: NSButton) {
        presentNativeLanguagePicker(side: .target, relativeTo: sender)
    }

    @objc func workspaceSwapLanguages() {
        swapCurrentTranslationLanguages()
    }

}
