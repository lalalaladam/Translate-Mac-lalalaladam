//
//  ViewController+TranslationSubmission.swift
//  translate
//

import Cocoa
import QuartzCore
import WebKit

extension ViewController {
    func beginLongTextTranslation(_ source: String) {
        // Do not write into the editor while an IME has marked (uncommitted)
        // text, otherwise Chinese/Japanese composition is committed or lost.
        guard longTextSourceView?.hasMarkedText() != true else { return }
        // The native editor is authoritative. Navigation and automatic-
        // detection callbacks are asynchronous and can arrive after a swap or
        // a later edit. Never let such a stale callback replace the complete
        // text that is currently visible in the source pane.
        if let visibleSource = longTextSourceView?.string,
           visibleSource != source {
            translationPipelineLogger.info(
                "Discarded stale translation request: visibleChars=\(visibleSource.count, privacy: .public), requestChars=\(source.count, privacy: .public)"
            )
            return
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }
        startTranslationTimingRequest(source: source, session: translationCoordinator.session)
        logTranslationTiming("swift-begin-translation")
        if !didLogFirstTranslationCommand {
            didLogFirstTranslationCommand = true
            logStartupTiming("First translation command received")
        }

        let effectiveSourceLanguage = translationCoordinator.effectiveSourceLanguage(
            for: source,
            selectedLanguage: currentSourceLanguage
        )
        let targetLanguage = currentTargetLanguage
        if effectiveSourceLanguage == .automatic {
            pendingPrimaryTranslationSource = nil
            pendingPrimaryTranslationSession = nil
            activeTranslationWebView = automaticTranslationWebView
            guard automaticTranslationWebViewReady,
                  translationPageMatches(
                      source: .automatic,
                      target: targetLanguage,
                      in: automaticTranslationWebView
                  ) else {
                pendingAutomaticTranslationSource = source
                pendingAutomaticTranslationSession = translationCoordinator.session
                loadAutomaticTranslationService(target: targetLanguage)
                return
            }
            pendingAutomaticTranslationSource = nil
            pendingAutomaticTranslationSession = nil
        } else {
            guard isReady else {
                pendingPrimaryTranslationSource = source
                pendingPrimaryTranslationSession = translationCoordinator.session
                return
            }
            pendingPrimaryTranslationSource = nil
            pendingPrimaryTranslationSession = nil
            pendingAutomaticTranslationSource = nil
            pendingAutomaticTranslationSession = nil
            activeTranslationWebView = webView
            if !translationPageMatches(
                source: effectiveSourceLanguage,
                target: targetLanguage
            ) {
                if promoteStandbyTranslationServiceIfReady(
                    source: effectiveSourceLanguage,
                    target: targetLanguage
                ) {
                    activeTranslationWebView = webView
                } else if standbyTranslationWebViewLoading,
                          standbyTranslationSource == effectiveSourceLanguage,
                          standbyTranslationTarget == targetLanguage {
                    // An empty-pane swap may have started warming the exact
                    // reverse page only moments before the first keystroke.
                    // Wait for that isolated standby load instead of starting
                    // a competing primary navigation for the same language
                    // pair.
                    pendingPrimaryTranslationSource = source
                    pendingPrimaryTranslationSession = translationCoordinator.session
                    logTranslationTiming("standby-warmup-awaited")
                    return
                } else {
                    logTranslationTiming(
                        "standby-promotion-missed",
                        diagnosticFields: [
                            "standby_ready": standbyTranslationWebViewReady,
                            "standby_loading": standbyTranslationWebViewLoading,
                            "standby_pair_matches": standbyTranslationSource == effectiveSourceLanguage &&
                                standbyTranslationTarget == targetLanguage
                        ]
                    )
                    reloadPreservingSource(
                        for: .translationURL(
                            translationURL(
                                source: effectiveSourceLanguage,
                                target: targetLanguage
                            )
                        )
                    )
                    return
                }
            }
        }

        // Google Translate evaluates the complete source text on every edit;
        // it does not translate a newly typed suffix and concatenate it to the
        // old result. Keep the old native result visible only until the first
        // stable result for this full source arrives.
        let keepsCompatibleVisibleResult = !translationCoordinator.completedTranslation.isEmpty &&
            translationCoordinator.completedTargetLanguage == targetLanguage.rawValue
        let formattingOnlyRefresh = keepsCompatibleVisibleResult &&
            translationCoordinator.completedSourceLanguage == effectiveSourceLanguage.rawValue &&
            !translationCoordinator.completedSource.isEmpty &&
            translationCoordinator.completedSource != source &&
            translationCoordinator.textRemovingLineBreaks(
                translationCoordinator.completedSource
            ) == translationCoordinator.textRemovingLineBreaks(source)
        let chunks = translationCoordinator.splitLongText(source)
        if effectiveSourceLanguage != .automatic,
           chunks.count == 1,
           prefersParallelTranslationWebView,
           parallelTranslationWebViewReady,
           translationPageMatches(
               source: effectiveSourceLanguage,
               target: targetLanguage,
               in: parallelTranslationWebView
           ) {
            activeTranslationWebView = parallelTranslationWebView
            logTranslationTiming("healthy-parallel-webview-reused")
        }
        translationResultProviders.removeAll()
        // Each completed start owns one WebView channel.  A delayed DOM
        // callback from the other preloaded Google page must never complete
        // this request, even if its text happens to match the current chunk.
        let session = translationCoordinator.beginSession(
            chunks: chunks,
            keepsVisibleResult: keepsCompatibleVisibleResult,
            formattingOnly: formattingOnlyRefresh,
            concurrentAPIChunkThreshold: concurrentAPIChunkThreshold
        )
        if !formattingOnlyRefresh {
            (longTextTranslationView?.enclosingScrollView as? TranslationResultScrollView)?
                .beginTailFollowingSession(session)
        }
        updateTranslationTimingSession(session)
        longTextSource = source
        longTextTranslation = keepsCompatibleVisibleResult ? translationCoordinator.completedTranslation : ""
        longTextSourceLanguage = effectiveSourceLanguage.rawValue
        longTextTargetLanguage = targetLanguage.rawValue
        longTextOverlay?.isHidden = false
        if longTextSourceView?.string != source {
            logInputMethodTiming("native-source-rewrite-before-translation")
            isUpdatingNativeWorkspace = true
            longTextSourceView?.string = source
            isUpdatingNativeWorkspace = false
        }
        longTextTranslationView?.string = longTextTranslation
        guard !chunks.isEmpty else {
            setLongTextStatus(.idle)
            updateLongTextLabels()
            return
        }
        updateLongTextLabels()
        translateNextLongTextChunk(session: session)
    }

    func submitPendingPrimaryTranslationIfCurrent() {
        guard let source = pendingPrimaryTranslationSource,
              pendingPrimaryTranslationSession == translationCoordinator.session,
              longTextSource == source,
              longTextSourceView?.string == source else {
            pendingPrimaryTranslationSource = nil
            pendingPrimaryTranslationSession = nil
            return
        }
        pendingPrimaryTranslationSource = nil
        pendingPrimaryTranslationSession = nil
        beginLongTextTranslation(source)
    }

    func activateCustomTranslationWorkspace() {
        // Keep the page mounted and transparent. This preserves Google's
        // proven WebView translation behavior without exposing its UI.
        webView.isHidden = false
        webView.alphaValue = backgroundTranslationWebViewAlpha
        // A language swap owns the pending source until the new page is fully
        // configured. Do not let page activation submit the swapped snapshot
        // in parallel with newer native input.
        if languageSwapInProgress {
            return
        }
        // Once the native workspace exists, its editor is the sole source of
        // truth. Google's hidden textarea can contain only the most recently
        // translated chunk after a long-text session. Reading it here after a
        // language swap would either restart with an incomplete source or be
        // rejected as stale, leaving the UI stuck at "Preparing".
        if let nativeSource = longTextSourceView?.string {
            beginLongTextTranslation(nativeSource)
            restoreSourceFocusAfterLanguageSwapIfNeeded()
            return
        }
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let self else { return }
            let source = self.pendingSourceTextForReload ?? (result as? String ?? "")
            self.beginLongTextTranslation(source)
            self.webView.isHidden = false
            self.webView.alphaValue = self.backgroundTranslationWebViewAlpha
            self.restoreSourceFocusAfterLanguageSwapIfNeeded()
        }
    }

    func completeLanguageSwapIfReady() {
        guard languageSwapInProgress,
              isReady,
              translationPageMatches(
                  source: currentSourceLanguage,
                  target: currentTargetLanguage
              ) else { return }

        let latestSource = languageSwapPendingText ?? longTextSourceView?.string ?? ""
        languageSwapInProgress = false
        languageSwapPendingText = nil
        languageSwapSnapshotText = nil
        logTranslationCoordinator("language-swap-ready", source: latestSource)
        guard !latestSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        logTranslationCoordinator("language-swap-latest-text-submitted", source: latestSource)
        queueLongTextTranslation(latestSource, mode: .immediate)
    }

    func restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: Int = 0) {
        guard restoreSourceFocusAfterLanguageSwap else { return }

        guard let sourceView = longTextSourceView,
              let window = sourceView.window else {
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: attempt + 1)
                }
            } else {
                restoreSourceFocusAfterLanguageSwap = false
            }
            return
        }

        // Reassigning an NSTextView that is already first responder interrupts
        // marked text owned by Chinese/Japanese input methods. An existing
        // responder needs no restoration at all.
        if window.firstResponder === sourceView {
            restoreSourceFocusAfterLanguageSwap = false
            return
        }

        // Never change responders while an IME composition is active.
        if sourceView.hasMarkedText() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: attempt)
            }
            return
        }

        if window.makeFirstResponder(sourceView) {
            restoreSourceFocusAfterLanguageSwap = false
            return
        }

        if attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: attempt + 1)
            }
        } else {
            restoreSourceFocusAfterLanguageSwap = false
        }
    }

    func cancelPendingTranslationDebounce(source: String? = nil) {
        guard translationCoordinator.debounceWorkItem != nil else { return }
        translationCoordinator.debounceWorkItem?.cancel()
        translationCoordinator.debounceWorkItem = nil
        logTranslationCoordinator("translation-debounce-cancelled", source: source)
    }

    func invalidateActiveTranslationWork(source: String?) {
        let invalidatedRequestID = translationTimingRequest?.id
        cancelAutomaticTranslationServiceWarmup()
        cancelParallelWebTranslationBatch()
        let invalidation = translationCoordinator.invalidate()
        let hadActiveRequest = translationTimingRequest != nil || invalidation.hadPipelineWork
        pendingAutomaticTranslationSource = nil
        pendingAutomaticTranslationSession = nil
        pendingPrimaryTranslationSource = nil
        pendingPrimaryTranslationSession = nil

        if invalidation.cancelledScheduledPoll {
            logTranslationCoordinator(
                "stability-timer-cancelled",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidation.session
            )
        }
        if invalidation.cancelledFallbackTask {
            logTranslationCoordinator(
                "fallback-cancelled-as-stale",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidation.session
            )
        }

        for serviceWebView in [webView, automaticTranslationWebView, parallelTranslationWebView] {
            serviceWebView?.evaluateJavaScript(#"""
                window.__macTranslateResultObserver?.disconnect();
                clearTimeout(window.__macTranslateResultNotificationTimer);
            """#, completionHandler: nil)
        }
        if hadActiveRequest {
            logTranslationStateTransition(
                from: "active",
                to: "invalidated",
                reason: "new-input",
                requestID: invalidatedRequestID
            )
            logTranslationCoordinator(
                "observer-disconnected",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidation.session
            )
            logTranslationCoordinator(
                "request-invalidated-by-new-input",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidation.session
            )
        }
        translationTimingRequest = nil
    }

    func queueLongTextTranslation(
        _ source: String,
        mode: TranslationSubmissionMode = .immediate
    ) {
        invalidateAlignmentPresentation()
        cancelPendingTranslationDebounce(source: source)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }

        translationInputGeneration += 1
        let inputGeneration = translationInputGeneration
        invalidateActiveTranslationWork(source: source)

        if languageSwapInProgress {
            languageSwapPendingText = source
            longTextSource = source
            updateLongTextLabels()
            logTranslationCoordinator("language-swap-pending-text-updated", source: source)
            if languageSwapSnapshotText != nil {
                languageSwapSnapshotText = nil
                logTranslationCoordinator("language-swap-snapshot-cancelled", source: source)
            }
            return
        }

        longTextSource = source
        updateLongTextLabels()
        let status = setLongTextStatus(.preparing)
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)

        let scheduledSourceLanguage = currentSourceLanguage
        let scheduledTargetLanguage = currentTargetLanguage
        let delay: TimeInterval
        switch mode {
        case .debouncedNativeInput:
            delay = nativeTextTranslationDebounce
        case .immediate:
            delay = source.utf16.count > translationCoordinator.googleWebChunkUTF16Limit
                ? longTextTranslationDebounce
                : 0
        }

        let submit = { [weak self] in
            guard let self else { return }
            self.translationCoordinator.debounceWorkItem = nil
            let skipReason: String?
            if inputGeneration != self.translationInputGeneration {
                skipReason = "input-generation-changed"
            } else if self.languageSwapInProgress {
                skipReason = "language-swap-in-progress"
            } else if scheduledSourceLanguage != self.currentSourceLanguage ||
                        scheduledTargetLanguage != self.currentTargetLanguage {
                skipReason = "language-changed"
            } else if self.longTextSourceView?.hasMarkedText() == true {
                skipReason = "marked-text-active"
            } else if self.longTextSourceView?.string != source {
                skipReason = "native-source-mismatch"
            } else if self.longTextSource != source {
                skipReason = "tracked-source-mismatch"
            } else {
                skipReason = nil
            }
            if let skipReason {
                self.logTranslationCoordinator(
                    "translation-submission-skipped-\(skipReason)",
                    source: source
                )
                return
            }
            if mode == .debouncedNativeInput {
                self.logTranslationCoordinator("translation-debounce-fired", source: source)
            }
            self.startTranslationTimingRequest(
                source: source,
                session: self.translationCoordinator.session + 1
            )
            self.logTranslationTiming("swift-input-processing-started")
            self.translationCoordinator.session += 1
            self.updateTranslationTimingSession(self.translationCoordinator.session)
            self.logTranslationTiming("native-input-processing-completed")
            self.beginLongTextTranslation(source)
        }

        if delay == 0 {
            submit()
            return
        }
        let workItem = DispatchWorkItem(block: submit)
        translationCoordinator.debounceWorkItem = workItem
        if mode == .debouncedNativeInput {
            logTranslationCoordinator("translation-debounce-scheduled", source: source)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func clearLongTextTranslationForEmptyInput() {
        logTranslationCoordinator("empty-input-clearing", source: "")
        clearParallelWebTranslationCache()
        cancelPendingTranslationDebounce(source: "")
        translationInputGeneration += 1
        invalidateActiveTranslationWork(source: "")
        longTextSource = nil
        longTextTranslation = ""
        translationResultProviders.removeAll()
        completedTranslationResultProviders.removeAll()
        translationCoordinator.clearAfterEmptyInput()
        longTextOverlay?.isHidden = false

        isUpdatingNativeWorkspace = true
        longTextSourceView?.string = ""
        longTextTranslationView?.string = ""
        isUpdatingNativeWorkspace = false

        // Keep the background Google document in the same empty state. This
        // prevents a later language swap or copy action from reviving stale
        // text that is no longer present in the visible editor.
        webView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateResultObserver?.disconnect();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)
        automaticTranslationWebView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateResultObserver?.disconnect();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)

        setLongTextStatus(.idle)
        updateLongTextLabels()
        // Keep the app-owned inline workspace in sync when this path is
        // reached from its editable source, without showing a network error.
        updateInlineLongText(source: "", translation: "", status: "")
        logTranslationCoordinator("empty-input-cleared", source: "")
    }

}
