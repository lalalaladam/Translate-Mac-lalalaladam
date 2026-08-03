//
//  ViewController+TranslationPageConfiguration.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func configureTranslationPageAfterDOMReady(_ webView: WKWebView) {
        if webView === parallelTranslationWebView {
            guard translationPageMatches(
                source: parallelTranslationSource,
                target: parallelTranslationTarget,
                in: parallelTranslationWebView
            ) else {
                return
            }
            parallelTranslationWebViewLoading = false
            parallelTranslationWebViewReady = true
            installTranslationTimingRuntime(in: webView)
            logStartupTiming("Parallel translation service ready")
            return
        }
        logStartupTiming(webView === automaticTranslationWebView
            ? "Automatic DOM ready"
            : "Primary DOM ready")
        installTranslationTimingRuntime(in: webView)
        logInputMethodTiming(
            webView === automaticTranslationWebView
                ? "automatic-webview-dom-ready"
                : "primary-webview-dom-ready",
            webFocus: false
        )
        if webView === automaticTranslationWebView {
            guard translationPageMatches(
                source: .automatic,
                target: automaticTranslationTarget,
                in: automaticTranslationWebView
            ), automaticTranslationTarget == currentTargetLanguage else {
                return
            }
            automaticTranslationWebViewLoading = false
            automaticTranslationWebViewReady = true
            translationCoordinator.markWebServiceActive()
            if let source = pendingAutomaticTranslationSource,
               pendingAutomaticTranslationSession == translationCoordinator.session,
               longTextSource == source,
               longTextSourceView?.string == source {
                pendingAutomaticTranslationSource = nil
                pendingAutomaticTranslationSession = nil
                beginLongTextTranslation(source)
            } else if pendingAutomaticTranslationSource != nil {
                translationPipelineLogger.info(
                    "Discarded stale automatic-language request after page load"
                )
                pendingAutomaticTranslationSource = nil
                pendingAutomaticTranslationSession = nil
            }
            return
        }
        if webView === standbyTranslationWebView {
            guard translationPageMatches(
                source: standbyTranslationSource,
                target: standbyTranslationTarget,
                in: standbyTranslationWebView
            ) else {
                return
            }
            standbyTranslationWebViewLoading = false
            standbyTranslationWebViewReady = true
            translationCoordinator.markWebServiceActive()
            installTranslationTimingRuntime(in: webView)
            logStartupTiming("Standby translation service ready")
            if let pendingSource = pendingPrimaryTranslationSource,
               pendingPrimaryTranslationSession == translationCoordinator.session {
                let effectiveSource = translationCoordinator.effectiveSourceLanguage(
                    for: pendingSource,
                    selectedLanguage: currentSourceLanguage
                )
                if promoteStandbyTranslationServiceIfReady(
                    source: effectiveSource,
                    target: currentTargetLanguage
                ) {
                    submitPendingPrimaryTranslationIfCurrent()
                }
            }
            return
        }
        updateCurrentLanguages(from: webView.url)
        activatePrimaryTranslationServiceAfterDOMReady()
        let hidePinyin = TranslateFeaturePreferences.hidePinyin ? "true" : "false"
        let hideGoogleSelectionToolbar = TranslateFeaturePreferences.hideGoogleSelectionToolbar
            ? "true"
            : "false"
        let simplifyActionButtons = TranslateFeaturePreferences.simplifyActionButtons
            ? "true"
            : "false"
        let highlightSelectedLanguage = TranslateFeaturePreferences.highlightSelectedLanguage
            ? "true"
            : "false"
        let sourceCopyLabel = interfaceText("复制原文", "Copy Source Text")
        let sourceClearLabel = interfaceText("清除", "Clear")
        let swapLanguagesLabel = interfaceText("交换源语言和目标语言", "Swap source and target languages")
        let wordCountLabel = interfaceText("单词", "Words")
        let chineseCharacterCountLabel = interfaceText("汉字", "Chinese characters")

        // Google changes its generated class names frequently.  This script
        // uses stable accessibility markers where possible and also performs
        // a conservative visual/text check for the pinyin line that is shown
        // next to Chinese results.
        let pageConfigurationScript = TranslationPageConfigurationScript.make(
            hidePinyin: hidePinyin,
            hideGoogleSelectionToolbar: hideGoogleSelectionToolbar,
            simplifyActionButtons: simplifyActionButtons,
            highlightSelectedLanguage: highlightSelectedLanguage,
            sourceCopyLabel: sourceCopyLabel,
            sourceClearLabel: sourceClearLabel,
            swapLanguagesLabel: swapLanguagesLabel,
            wordCountLabel: wordCountLabel,
            chineseCharacterCountLabel: chineseCharacterCountLabel
        )
        self.webView.evaluateJavaScript(pageConfigurationScript) { [weak self] _, _ in
            guard let self else { return }
            self.setTheme { [weak self] in
                guard let self else { return }
                self.restorePendingSourceTextIfNeeded()
                // Translation service readiness was published as soon as its
                // textarea existed. These legacy Google-page decorations are
                // now background-only and must never resubmit the same source
                // or delay a cold-start/language-swap request.
                self.logStartupTiming("Primary background decoration ready")
                self.logInputMethodTiming("primary-css-scripts-ready", webFocus: false)
            }
        }
    }

}
