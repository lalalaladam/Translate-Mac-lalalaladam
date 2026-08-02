//
//  ViewController+TextInput.swift
//  translate
//

import Cocoa

extension ViewController {
    /// Starts a new source document after an explicit app-level replacement.
    /// User edits deliberately keep AppKit's normal undo history, but a clear
    /// action or language swap must never let Command-Z resurrect a previous
    /// translation's source text.
    func beginNewSourceUndoSession() {
        (longTextSourceView as? TranslationSourceTextView)?.beginNewUndoSession()
        clearParallelWebTranslationCache()
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard textView === longTextSourceView,
              !isUpdatingNativeWorkspace,
              let sourceView = textView as? TranslationSourceTextView else {
            return true
        }
        invalidateAlignmentPresentation()
        sourceView.prepareUndoGrouping(
            affectedRange: affectedCharRange,
            replacementString: replacementString
        )
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingNativeWorkspace else {
            logTranslationCoordinator("native-text-change-ignored-workspace-update")
            return
        }
        guard let sourceView = longTextSourceView,
              let changedView = notification.object as? NSTextView,
              changedView === sourceView else {
            logTranslationCoordinator("native-text-change-ignored-unexpected-view")
            return
        }
        let typedSourceView = sourceView as? TranslationSourceTextView
        let beganNewUndoSession = typedSourceView?
            .completeUndoGroupingAfterTextChange() == true
        if beganNewUndoSession {
            clearParallelWebTranslationCache()
            logTranslationCoordinator(
                "native-full-replacement-started-new-undo-session",
                source: sourceView.string
            )
        }
        logTranslationCoordinator("native-text-change-received", source: sourceView.string)
        if sourceView.hasMarkedText() {
            let isBeginningIMEComposition = imeCompositionEndCheck == nil
            logInputMethodTiming("text-did-change-marked-text")
            logTranslationCoordinator("ime-composition-started", source: sourceView.string)
            logTranslationStateTransition(
                from: "active",
                to: "ime-composing",
                reason: "marked-text-changed",
                markedText: true
            )
            cancelPendingTranslationDebounce(source: sourceView.string)
            translationInputGeneration += 1
            // Cancelling the active translation once is sufficient for the
            // whole marked-text session. Repeating three WebView JavaScript
            // calls for every pinyin keystroke makes the editor visibly
            // stutter while the input method is composing.
            if isBeginningIMEComposition {
                invalidateActiveTranslationWork(source: sourceView.string)
            }
            scheduleIMECompositionEndCheck()
            return
        }
        cancelIMECompositionEndCheck()
        handleCommittedNativeTextChange(sourceView)
    }

    func scheduleIMECompositionEndCheck() {
        imeCompositionEndCheck?.cancel()
        imeCompositionGeneration += 1
        let generation = imeCompositionGeneration

        let check = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.imeCompositionGeneration,
                  let sourceView = self.longTextSourceView else { return }

            if sourceView.hasMarkedText() {
                self.scheduleIMECompositionEndCheck(generation: generation)
                return
            }

            // AppKit can clear marked text after its final textDidChange
            // callback has already returned. Give a normal unmarked callback
            // one more run-loop interval to take the authoritative path; if
            // none arrives, submit the committed editor contents ourselves.
            self.scheduleIMECompositionEndCheck(generation: generation, settling: true)
        }
        imeCompositionEndCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: check)
    }

    func scheduleIMECompositionEndCheck(
        generation: Int,
        settling: Bool = false
    ) {
        let check = DispatchWorkItem { [weak self] in
            guard let self,
                  generation == self.imeCompositionGeneration,
                  let sourceView = self.longTextSourceView else { return }

            if sourceView.hasMarkedText() {
                self.scheduleIMECompositionEndCheck(generation: generation)
                return
            }

            if settling {
                self.imeCompositionEndCheck = nil
                (sourceView as? TranslationSourceTextView)?
                    .finishPendingIMEUndoGrouping()
                let source = sourceView.string
                guard self.longTextSource != source else { return }
                self.logInputMethodTiming("ime-composition-ended-auto-submit")
                self.logTranslationCoordinator(
                    "ime-composition-ended-auto-submit",
                    source: source
                )
                self.logTranslationStateTransition(
                    from: "ime-composing",
                    to: "committed",
                    reason: "composition-end-check",
                    markedText: false
                )
                self.handleCommittedNativeTextChange(sourceView)
                return
            }

            self.scheduleIMECompositionEndCheck(generation: generation, settling: true)
        }
        imeCompositionEndCheck = check
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (settling ? 0.04 : 0.04),
            execute: check
        )
    }

    func cancelIMECompositionEndCheck() {
        imeCompositionEndCheck?.cancel()
        imeCompositionEndCheck = nil
        imeCompositionGeneration += 1
    }

    func handleCommittedNativeTextChange(
        _ sourceView: NSTextView,
        isHistoryNavigation explicitHistoryNavigation: Bool = false
    ) {
        let source = sourceView.string
        let typedSourceView = sourceView as? TranslationSourceTextView
        let isPaste = typedSourceView?.consumeImmediatePasteFlag() == true
        let isHistoryNavigation = explicitHistoryNavigation ||
            typedSourceView?.isPerformingHistoryNavigation == true
        logTranslationCoordinator("native-text-committed", source: source)
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stopSpeaking()
        }

        // A line break appended at the end is only formatting. Keep the
        // existing translation until the user enters actual text after it;
        // otherwise every standalone Return would start a new network request.
        let sourceWithoutTrailingLineBreaks = source.trimmingCharacters(in: .newlines)
        let previousWithoutTrailingLineBreaks = longTextSource?.trimmingCharacters(in: .newlines)
        if !sourceWithoutTrailingLineBreaks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sourceWithoutTrailingLineBreaks == previousWithoutTrailingLineBreaks {
            let hadPendingTranslation = translationCoordinator.debounceWorkItem != nil
            longTextSource = source
            updateLongTextLabels()
            logTranslationCoordinator("native-text-change-ignored-formatting-only", source: source)
            // If Return arrived before the preceding debounce fired, that
            // older work item no longer matches the editor and will be
            // discarded. Reschedule the same text with its line break so the
            // final English input cannot remain permanently untranslated.
            if hadPendingTranslation {
                queueLongTextTranslation(source, mode: .debouncedNativeInput)
            }
            return
        }

        logTranslationCoordinator(
            isPaste
                ? "native-paste-submission-queued"
                : (isHistoryNavigation
                    ? "native-history-submission-queued"
                    : "native-text-submission-queued"),
            source: source
        )
        queueLongTextTranslation(
            source,
            mode: isPaste || isHistoryNavigation ? .immediate : .debouncedNativeInput
        )
    }

    @objc func workspaceClearSource() {
        stopSpeaking()
        invalidateAlignmentPresentation()
        isUpdatingNativeWorkspace = true
        longTextSourceView?.string = ""
        isUpdatingNativeWorkspace = false
        beginNewSourceUndoSession()
        queueLongTextTranslation("")
        longTextSourceView?.window?.makeFirstResponder(longTextSourceView)
    }

    @objc func workspaceCopySource() {
        copyToPasteboard(longTextSourceView?.string ?? longTextSource ?? "")
    }

    @objc func workspaceCopyTranslation() {
        copyToPasteboard(longTextTranslationView?.string ?? longTextTranslation)
    }

    @objc func workspaceSpeakSource() {
        speakSource()
    }

    @objc func workspaceSpeakTranslation() {
        speakTranslation()
    }

    func textCountDescription(_ text: String) -> String {
        let hanCharacters = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }.count
        let nonHanText = String(text.unicodeScalars.filter {
            !((0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value))
        }.map(Character.init))
        let pattern = #"[\p{L}\p{M}]+(?:['’-][\p{L}\p{M}]+)*"#
        let wordCount = (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
            in: nonHanText,
            range: NSRange(nonHanText.startIndex..., in: nonHanText)
        ) ?? 0
        var values: [String] = []
        if wordCount > 0 {
            values.append(interfaceText("单词 \(wordCount)", "Words \(wordCount)"))
        }
        if hanCharacters > 0 {
            values.append(interfaceText("汉字 \(hanCharacters)", "Chinese characters \(hanCharacters)"))
        }
        return values.isEmpty ? interfaceText("单词 0", "Words 0") : values.joined(separator: " · ")
    }

}
