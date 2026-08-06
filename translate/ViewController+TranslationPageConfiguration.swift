//
//  ViewController+TranslationPageConfiguration.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    private static let primaryWebWarmupProbe = "connection warmup"

    @discardableResult
    func startPrimaryWebWarmupIfPossible() -> Bool {
        let visibleSource = longTextSourceView?.string ?? ""
        guard primaryWebWarmupState == .idle,
              isReady,
              activeTranslationWebView === webView,
              translationPageMatches(
                  source: currentSourceLanguage,
                  target: currentTargetLanguage,
                  in: webView
              ),
              visibleSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        primaryWebWarmupGeneration += 1
        let generation = primaryWebWarmupGeneration
        primaryWebWarmupState = .running
        let encodedProbe = Data(Self.primaryWebWarmupProbe.utf8).base64EncodedString()
        // DOM readiness alone does not prove that Google's translation
        // request path is warm. Keep the native connection cover visible
        // until the probe completes so "ready" has one consistent meaning.
        showConnectionOverlay(waitingForNetwork: true)
        logTranslationCoordinator("primary-web-warmup-started", source: "")

        webView.evaluateJavaScript(#"""
            (() => {
                const token = \#(generation);
                const probe = new TextDecoder().decode(Uint8Array.from(
                    atob("\#(encodedProbe)"), (character) => character.charCodeAt(0)));
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;

                let privacyStyle = document.getElementById(
                    "mac-translate-warmup-result-privacy"
                );
                if (!privacyStyle) {
                    privacyStyle = document.createElement("style");
                    privacyStyle.id = "mac-translate-warmup-result-privacy";
                    privacyStyle.textContent = ".QcsUad { opacity: 0 !important; }";
                    (document.head || document.documentElement).appendChild(privacyStyle);
                }
                window.__macTranslateWarmupObserver?.disconnect();
                clearTimeout(window.__macTranslateWarmupTimer);
                window.__macTranslateWarmupGeneration = token;
                window.__macTranslateWarmupProbe = probe;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                const readResult = () => {
                    const root = document.querySelector(".QcsUad.sMVRZe") ||
                        document.querySelector(".QcsUad:not(.FkMbO), .QcsUad");
                    if (!root) return "";
                    const selectors = [
                        "[jsname=\"W297wb\"]",
                        ".ryNqvb",
                        ".jCAhz",
                        ".lRu31"
                    ];
                    for (const selector of selectors) {
                        const text = Array.from(root.querySelectorAll(selector))
                            .map((element) => (element.innerText ||
                                element.textContent || "").trim())
                            .filter(Boolean)
                            .join(" ")
                            .trim();
                        if (text) return text;
                    }
                    return "";
                };
                const baseline = readResult();
                const startedAt = performance.now();
                const finish = (status) => {
                    if (window.__macTranslateWarmupGeneration !== token) return;
                    window.__macTranslateWarmupObserver?.disconnect();
                    clearTimeout(window.__macTranslateWarmupTimer);
                    if (textarea.value === probe) {
                        setter.call(textarea, "");
                        textarea.dispatchEvent(new Event("input", { bubbles: true }));
                    }
                    const resetStartedAt = performance.now();
                    const notifyWhenSettled = () => {
                        if (window.__macTranslateWarmupGeneration !== token) return;
                        if (readResult() && performance.now() - resetStartedAt < 420) {
                            setTimeout(notifyWhenSettled, 40);
                            return;
                        }
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translationServiceWarmupFinished",
                            generation: token,
                            status,
                            elapsedMS: performance.now() - startedAt
                        });
                    };
                    setTimeout(notifyWhenSettled, 40);
                };
                const check = () => {
                    if (window.__macTranslateWarmupGeneration !== token ||
                        textarea.value !== probe) return;
                    const result = readResult();
                    if (result && result !== baseline) finish("ready");
                };
                window.__macTranslateWarmupObserver = new MutationObserver(check);
                window.__macTranslateWarmupObserver.observe(document.documentElement,
                    { childList: true, subtree: true, characterData: true });
                setter.call(textarea, probe);
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
                window.__macTranslateWarmupTimer = setTimeout(
                    () => finish("timeout"),
                    3200
                );
                setTimeout(check, 0);
                return true;
            })();
        """#) { [weak self] result, error in
            guard let self,
                  self.primaryWebWarmupGeneration == generation,
                  self.primaryWebWarmupState == .running else { return }
            guard result as? Bool == true, error == nil else {
                self.finishPrimaryWebWarmup(
                    generation: generation,
                    status: "injection-failed"
                )
                return
            }
        }

        primaryWebWarmupTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishPrimaryWebWarmup(generation: generation, status: "swift-timeout")
        }
        primaryWebWarmupTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: timeout)
        return true
    }

    func finishPrimaryWebWarmup(generation: Int, status: String) {
        guard primaryWebWarmupGeneration == generation,
              primaryWebWarmupState == .running else { return }
        primaryWebWarmupTimeoutWorkItem?.cancel()
        primaryWebWarmupTimeoutWorkItem = nil
        primaryWebWarmupState = .finished
        logTranslationCoordinator("primary-web-warmup-\(status)", source: "")
        hideConnectionOverlay()
        // The primary request path is now proven healthy. Start only the one
        // secondary page most likely to be needed next; parallel same-direction
        // capacity remains deferred until a real translation has completed.
        scheduleIdleSecondaryWebViewWarmups(after: 0)
    }

    func cancelPrimaryWebWarmupForUserRequest() {
        guard primaryWebWarmupState == .running else { return }
        let cancelledGeneration = primaryWebWarmupGeneration
        primaryWebWarmupTimeoutWorkItem?.cancel()
        primaryWebWarmupTimeoutWorkItem = nil
        primaryWebWarmupGeneration += 1
        primaryWebWarmupState = .finished
        webView.evaluateJavaScript(#"""
            if (window.__macTranslateWarmupGeneration === \#(cancelledGeneration)) {
                window.__macTranslateWarmupGeneration = -1;
                window.__macTranslateWarmupObserver?.disconnect();
                clearTimeout(window.__macTranslateWarmupTimer);
                const textarea = document.querySelector("textarea");
                if (textarea?.value === window.__macTranslateWarmupProbe) {
                    Object.getOwnPropertyDescriptor(
                        HTMLTextAreaElement.prototype,
                        "value"
                    ).set.call(textarea, "");
                }
            }
        """#, completionHandler: nil)
        logTranslationCoordinator("primary-web-warmup-cancelled-user-request", source: "")
        hideConnectionOverlay()
    }

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
            markTranslationWebServiceReady(webView)
            installTranslationTimingRuntime(in: webView)
            logStartupTiming("Parallel translation service ready")
            resumeTranslationWaitingForParallelIfCurrent()
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
            markTranslationWebServiceReady(webView)
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
            markTranslationWebServiceReady(webView)
            translationCoordinator.markWebServiceActive()
            installTranslationTimingRuntime(in: webView)
            logStartupTiming("Standby translation service ready")
            scheduleAutomaticWarmupAfterStandbyIfIdle()
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
