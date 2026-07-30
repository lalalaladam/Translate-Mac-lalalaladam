//
//  ViewController+LanguageSelection.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func longTextLanguageCodes() -> (source: String, target: String) {
        (currentSourceLanguage.rawValue, currentTargetLanguage.rawValue)
    }

    func translationPageMatches(
        source: TranslateLanguage,
        target: TranslateLanguage,
        in page: WKWebView? = nil
    ) -> Bool {
        guard let url = (page ?? webView).url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let pageSource = items.first(where: { $0.name == "sl" })?.value,
              let pageTarget = items.first(where: { $0.name == "tl" })?.value else {
            return false
        }
        return pageSource == source.rawValue && pageTarget == target.rawValue
    }

    func presentNativeLanguagePicker(
        side: NativeLanguagePickerSide,
        webPointX: CGFloat,
        webPointY: CGFloat
    ) {
        languagePickerPopover?.performClose(nil)
        let selectedLanguage = side == .source
            ? currentSourceLanguage
            : currentTargetLanguage
        let picker = NativeLanguagePickerController(
            side: side,
            selectedLanguage: selectedLanguage
        ) { [weak self] language in
            self?.selectNativeLanguage(language, for: side)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        languagePickerPopover = popover

        let anchor = NSRect(
            x: max(0, webPointX - 8),
            y: max(0, webView.isFlipped
                ? webPointY - 8
                : webView.bounds.height - webPointY - 8),
            width: 16,
            height: 16
        )
        popover.show(relativeTo: anchor, of: webView, preferredEdge: .maxY)
    }

    func presentNativeLanguagePicker(
        side: NativeLanguagePickerSide,
        relativeTo button: NSButton
    ) {
        languagePickerPopover?.performClose(nil)
        let selectedLanguage = side == .source
            ? currentSourceLanguage
            : currentTargetLanguage
        let picker = NativeLanguagePickerController(
            side: side,
            selectedLanguage: selectedLanguage
        ) { [weak self] language in
            self?.selectNativeLanguage(language, for: side)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        languagePickerPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    func selectNativeLanguage(
        _ language: TranslateLanguage,
        for side: NativeLanguagePickerSide
    ) {
        let oldSource = currentSourceLanguage
        let oldTarget = currentTargetLanguage
        var source = oldSource
        var target = oldTarget

        switch side {
        case .source:
            source = language
            if source != .automatic && source == target {
                target = oldSource.canBeTarget && oldSource != source
                    ? oldSource
                    : (source == .simplifiedChinese ? .english : .simplifiedChinese)
            }
        case .target:
            guard language.canBeTarget else { return }
            target = language
            if source != .automatic && source == target {
                source = oldTarget != target ? oldTarget : .automatic
            }
        }

        guard source != oldSource || target != oldTarget else { return }
        currentSourceLanguage = source
        currentTargetLanguage = target
        languagePickerPopover?.performClose(nil)

        if let longTextSource {
            updateLongTextLabels()
            queueLongTextTranslation(longTextSource)
        } else {
            applyCurrentLanguagesPreservingSource()
        }
    }

    func swapCurrentTranslationLanguages() {
        guard longTextSourceView?.hasMarkedText() != true else {
            logTranslationCoordinator("language-swap-skipped-marked-text")
            logInputMethodTiming("language-swap-skipped-marked-text")
            return
        }
        // Google cannot meaningfully swap an automatically detected source.
        // For all explicit pairs, exchange only the active session languages;
        // the persistent defaults in the menu remain untouched.
        guard currentSourceLanguage != .automatic else {
            logTranslationCoordinator("language-swap-skipped-automatic-source")
            return
        }

        // A multi-part translation is only safe to swap after every part has
        // completed. Prefer the current native result pane, which is the
        // complete text the user can see; the assembly cache is only a
        // fallback in case the view is temporarily unavailable.
        let completedTranslation: String?
        if longTextSource != nil {
            let visibleTranslation = longTextTranslationView?.string
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let translationToSwap = visibleTranslation.isEmpty
                ? translationCoordinator.completedTranslation
                : visibleTranslation
            guard longTextStatusState == .completed,
                  !translationToSwap.isEmpty else {
                logTranslationCoordinator("language-swap-skipped-incomplete-result")
                return
            }
            completedTranslation = translationToSwap
            translationPipelineLogger.info(
                "Swapping completed translation snapshot: sourceChars=\(self.longTextSource?.count ?? 0, privacy: .public), translationChars=\(translationToSwap.count, privacy: .public), cachedTranslationChars=\(self.translationCoordinator.completedTranslation.count, privacy: .public)"
            )
        } else {
            completedTranslation = nil
        }

        logTranslationCoordinator(
            "language-swap-start",
            source: completedTranslation ?? longTextSourceView?.string
        )
        cancelPendingTranslationDebounce(source: longTextSourceView?.string)
        translationInputGeneration += 1
        languageSwapInProgress = true
        languageSwapPendingText = completedTranslation ?? longTextSourceView?.string
        languageSwapSnapshotText = completedTranslation
        invalidateActiveTranslationWork(source: languageSwapPendingText)

        let source = currentSourceLanguage
        currentSourceLanguage = currentTargetLanguage
        currentTargetLanguage = source

        // With two empty panes there is no text snapshot to preserve. Treat
        // the language pair as native editor state only. In particular, do
        // not navigate either hidden Google page and do not touch the first
        // responder here: an asynchronous WebKit navigation can finish while
        // a Chinese/Japanese input method owns marked text and truncate that
        // composition. The first committed source edit will prepare the
        // matching background translation page without disturbing AppKit's
        // editor lifecycle.
        let panesAreEmpty = longTextSourceView?.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            longTextTranslationView?.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        if panesAreEmpty {
            languageSwapInProgress = false
            languageSwapPendingText = nil
            languageSwapSnapshotText = nil
            refreshWorkspaceLanguageTitles()
            logTranslationCoordinator("language-swap-ready", source: "")
            return
        }

        if let swappedSource = completedTranslation {
            // Cancel every old result callback before loading the reversed
            // language pair. The hidden Google textarea contains only its
            // latest chunk, so it must never be used as the swap source.
            longTextSource = swappedSource
            longTextTranslation = ""
            translationCoordinator.clearCompletedSnapshot()
            translationCoordinator.clearTranslationBuffers()
            isUpdatingNativeWorkspace = true
            longTextSourceView?.string = swappedSource
            longTextTranslationView?.string = ""
            isUpdatingNativeWorkspace = false
            longTextSourceView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
            longTextTranslationView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
            let status = setLongTextStatus(.preparing)
            updateInlineLongText(source: swappedSource, translation: "", status: status)
            updateLongTextLabels()
            // Reload the hidden Google page so it uses the new language pair.
            restoreSourceFocusAfterLanguageSwap = true
            applyCurrentLanguagesPreservingSource()
            // NSTextView can preserve its previous clip-view offset when its
            // content is replaced. Scroll again on the next layout pass so
            // the user always sees the beginning of the complete swapped text.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.longTextSource == swappedSource else { return }
                self.longTextSourceView?.scrollRangeToVisible(
                    NSRange(location: 0, length: 0)
                )
            }
        } else {
            restoreSourceFocusAfterLanguageSwap = true
            applyCurrentLanguagesPreservingSource()
        }
    }

}
