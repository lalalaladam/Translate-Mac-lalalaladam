//
//  ViewController+TranslationWebService.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func showConnectionOverlay(waitingForNetwork: Bool) {
        connectionOverlay?.isHidden = false
        connectionRetryButton?.title = interfaceText("立即重试", "Retry Now")

        if waitingForNetwork {
            connectionTitleLabel?.stringValue = interfaceText(
                "正在连接翻译服务…",
                "Connecting to the translation service…"
            )
            connectionDetailLabel?.stringValue = interfaceText(
                "如果网络或 VPN 正在启动，连接恢复后会自动继续。",
                "If your network or VPN is starting, the app will continue automatically when it is available."
            )
            connectionSpinner?.isHidden = false
            connectionSpinner?.startAnimation(nil)
        } else {
            connectionTitleLabel?.stringValue = interfaceText(
                "暂时无法连接 Google Translate",
                "Google Translate is currently unavailable"
            )
            connectionDetailLabel?.stringValue = interfaceText(
                "请检查网络或开启可访问 Google Translate 的 VPN。软件会自动重试，也可以立即重试。",
                "Check your network or connect a VPN that can reach Google Translate. The app will retry automatically, or you can retry now."
            )
            connectionSpinner?.isHidden = true
            connectionSpinner?.stopAnimation(nil)
        }
    }

    func hideConnectionOverlay() {
        delayedConnectionOverlayWorkItem?.cancel()
        delayedConnectionOverlayWorkItem = nil
        connectionOverlay?.isHidden = true
        connectionSpinner?.stopAnimation(nil)
    }

    func scheduleConnectionOverlayIfStillLoading(attempt: Int) {
        delayedConnectionOverlayWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.translationLoadAttempt == attempt,
                  !self.isReady else { return }
            self.showConnectionOverlay(waitingForNetwork: true)
        }
        delayedConnectionOverlayWorkItem = workItem
        // Avoid flashing a connection screen during an ordinary cold launch.
        // It remains available for genuinely slow or unavailable networks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: workItem)
    }

    func loadTranslationService() {
        automaticRetryWorkItem?.cancel()
        loadTimeoutWorkItem?.cancel()
        translationLoadAttempt += 1
        let attempt = translationLoadAttempt

        // Google is a background translation service only. Keep it mounted so
        // its dynamic result DOM continues updating, but make it fully
        // transparent so its responsive UI can never flash on screen.
        webView.isHidden = false
        webView.alphaValue = backgroundTranslationWebViewAlpha
        isReady = false
        hideConnectionOverlay()
        scheduleConnectionOverlayIfStillLoading(attempt: attempt)
        logStartupTiming("Primary page load started")
        webView.load(
            URLRequest(
                url: defaultTranslationURL(),
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
        )

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.translationLoadAttempt == attempt,
                  !self.isReady else {
                return
            }
            self.handleTranslationLoadFailure()
        }
        loadTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: timeout)
    }

    @objc func retryTranslationService() {
        loadTranslationService()
    }

    func handleTranslationLoadFailure() {
        guard !isReady else { return }
        delayedConnectionOverlayWorkItem?.cancel()
        delayedConnectionOverlayWorkItem = nil
        loadTimeoutWorkItem?.cancel()
        showConnectionOverlay(waitingForNetwork: false)
        scheduleAutomaticRetry()
    }

    func scheduleAutomaticRetry() {
        automaticRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            self.loadTranslationService()
        }
        automaticRetryWorkItem = retry
        // VPN connection changes are not exposed as a reliable AppKit event.
        // A gentle retry loop lets a newly connected VPN recover without an
        // app restart and avoids polling while the page is already ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: retry)
    }

    override func keyDown(with event: NSEvent) {
        // Keyboard shortcuts inside the page are handled by the injected JS.
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // The compact app has no usable secondary/detail page.  In
        // particular, Google's selection UI links to /details, which appears
        // blank after our compact-page CSS is applied.
        let isTranslateHome = url.scheme == "https" &&
            url.host == "translate.google.com" &&
            (url.path.isEmpty || url.path == "/")
        decisionHandler(isTranslateHome ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if webView === standbyTranslationWebView {
            standbyTranslationWebViewReady = false
            standbyTranslationWebViewLoading = false
            return
        }
        guard webView !== automaticTranslationWebView else {
            automaticTranslationWebViewReady = false
            automaticTranslationWebViewLoading = false
            return
        }
        handleTranslationLoadFailure()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if webView === standbyTranslationWebView {
            standbyTranslationWebViewReady = false
            standbyTranslationWebViewLoading = false
            return
        }
        guard webView !== automaticTranslationWebView else {
            automaticTranslationWebViewReady = false
            automaticTranslationWebViewLoading = false
            return
        }
        handleTranslationLoadFailure()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let label = webView === automaticTranslationWebView
            ? "Automatic"
            : (webView === standbyTranslationWebView ? "Standby" : "Primary")
        logStartupTiming("\(label) navigation finished")
        waitForTranslationDOM(in: webView)
    }

    func waitForTranslationDOM(in webView: WKWebView) {
        let service = webView === automaticTranslationWebView
            ? "automatic"
            : (webView === standbyTranslationWebView ? "standby" : "primary")
        webView.evaluateJavaScript(#"""
            (() => {
                const notify = () => {
                    if (!document.querySelector("textarea")) return false;
                    window.webkit.messageHandlers.callbackHandler.postMessage({
                        action: "translationServiceDOMReady",
                        service: "\#(service)"
                    });
                    return true;
                };
                if (notify()) return true;
                window.__macTranslateDOMReadyObserver?.disconnect();
                window.__macTranslateDOMReadyObserver = new MutationObserver(() => {
                    if (notify()) window.__macTranslateDOMReadyObserver?.disconnect();
                });
                window.__macTranslateDOMReadyObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
                return false;
            })();
        """#, completionHandler: nil)
    }

    func activatePrimaryTranslationServiceAfterDOMReady() {
        // The app-owned workspace is already visible. Once Google's textarea
        // exists, translation injection is safe; CSS/theme work on the hidden
        // page can finish independently and must not be on the request path.
        webView.isHidden = false
        webView.alphaValue = backgroundTranslationWebViewAlpha

        let hadPendingPrimaryRequest = pendingPrimaryTranslationSource != nil
        markReady()
        logStartupTiming("Primary translation service ready")
        logTranslationTiming("primary-translation-service-ready")
        logInputMethodTiming("primary-translation-service-ready", webFocus: false)

        if languageSwapInProgress {
            completeLanguageSwapIfReady()
        } else if hadPendingPrimaryRequest {
            submitPendingPrimaryTranslationIfCurrent()
        } else if let source = longTextSourceView?.string,
                  !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A source-triggered language-page reload reaches this path with
            // no explicit pending slot. Continue the existing request exactly
            // once, using the native editor as the source of truth.
            beginLongTextTranslation(source)
        }

        restoreSourceFocusAfterLanguageSwapIfNeeded()
        loadTimeoutWorkItem?.cancel()
        automaticRetryWorkItem?.cancel()
        hideConnectionOverlay()

        // Do not let reverse-page warming compete with the first translation.
        // By the time this fires, an immediate cold-start request has normally
        // produced its first result; the standby remains ready for a later swap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.warmStandbyTranslationServiceForReverseDirection()
        }
    }

    func installTranslationTimingRuntime(in webView: WKWebView) {
        webView.evaluateJavaScript(#"""
            (() => {
                if (window.__macTranslateTimingRuntimeReady) return true;
                window.__macTranslateTimingRuntimeReady = true;
                window.__macTranslateActiveTiming = null;
                window.__macTranslateTimingObserver = new MutationObserver((records) => {
                    const timing = window.__macTranslateActiveTiming;
                    if (!timing || timing.firstResultMutationAt != null) return;
                    const touchesResult = records.some((record) => {
                        const target = record.target?.nodeType === Node.ELEMENT_NODE
                            ? record.target
                            : record.target?.parentElement;
                        if (target?.closest?.(".QcsUad")) return true;
                        return Array.from(record.addedNodes || []).some((node) => {
                            const element = node.nodeType === Node.ELEMENT_NODE
                                ? node
                                : node.parentElement;
                            return element?.matches?.(".QcsUad") ||
                                element?.closest?.(".QcsUad") ||
                                element?.querySelector?.(".QcsUad");
                        });
                    });
                    if (!touchesResult) return;
                    timing.firstResultMutationAt = performance.now();
                    window.webkit.messageHandlers.callbackHandler.postMessage({
                        action: "translationTimingJS",
                        requestID: timing.requestID,
                        session: timing.session,
                        milestone: "first-result-dom-mutation",
                        jsElapsedMS: timing.firstResultMutationAt - timing.jsStartedAt
                    });
                });
                window.__macTranslateTimingObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                return true;
            })();
        """#) { [weak self] result, error in
            guard let self, result as? Bool == true, error == nil else { return }
            self.logStartupTiming(webView === self.automaticTranslationWebView
                ? "Automatic timing observer ready"
                : "Primary timing observer ready")
        }
    }

    public func reloadWithCurrentPreferences() {
        reloadPreservingSource(for: .currentPage)
    }

    public func applyDefaultLanguagesPreservingSource() {
        currentSourceLanguage = TranslateLanguagePreferences.source
        currentTargetLanguage = TranslateLanguagePreferences.target
        reloadPreservingSource(for: .defaultLanguages)
    }

    func applyCurrentLanguagesPreservingSource() {
        loadAutomaticTranslationService(target: currentTargetLanguage)
        if promoteStandbyTranslationServiceIfReady(
            source: currentSourceLanguage,
            target: currentTargetLanguage
        ) {
            completeLanguageSwapIfReady()
            restoreSourceFocusAfterLanguageSwapIfNeeded()
            return
        }
        reloadPreservingSource(
            for: .translationURL(
                translationURL(
                    source: currentSourceLanguage,
                    target: currentTargetLanguage
                )
            )
        )
    }

    func loadAutomaticTranslationService(target: TranslateLanguage) {
        if automaticTranslationTarget == target,
           automaticTranslationWebViewReady || automaticTranslationWebViewLoading {
            return
        }
        automaticTranslationWebViewReady = false
        automaticTranslationWebViewLoading = true
        automaticTranslationTarget = target
        logStartupTiming("Automatic page load started")
        automaticTranslationWebView.load(
            URLRequest(
                url: translationURL(source: .automatic, target: target),
                cachePolicy: .useProtocolCachePolicy,
                timeoutInterval: 15
            )
        )
    }

    func warmStandbyTranslationServiceForReverseDirection() {
        let reverseSource = currentTargetLanguage
        let reverseTarget = currentSourceLanguage
        guard reverseSource != .automatic,
              reverseTarget.canBeTarget,
              reverseSource != reverseTarget else {
            standbyTranslationWebViewReady = false
            standbyTranslationWebViewLoading = false
            return
        }
        if translationPageMatches(
            source: reverseSource,
            target: reverseTarget,
            in: standbyTranslationWebView
        ), standbyTranslationWebViewReady || standbyTranslationWebViewLoading {
            return
        }

        standbyTranslationWebViewReady = false
        standbyTranslationWebViewLoading = true
        logStartupTiming("Standby reverse page load started")
        standbyTranslationWebView.load(
            URLRequest(
                url: translationURL(source: reverseSource, target: reverseTarget),
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
        )
    }

    func promoteStandbyTranslationServiceIfReady(
        source: TranslateLanguage,
        target: TranslateLanguage
    ) -> Bool {
        guard standbyTranslationWebViewReady,
              translationPageMatches(
                source: source,
                target: target,
                in: standbyTranslationWebView
              ) else {
            return false
        }

        let previousPrimary = webView!
        webView = standbyTranslationWebView
        standbyTranslationWebView = previousPrimary
        // The former primary page is already the reverse of the newly active
        // pair, so it remains a ready standby without another navigation.
        standbyTranslationWebViewReady = true
        standbyTranslationWebViewLoading = false
        activeTranslationWebView = webView
        isReady = true
        logStartupTiming("Warm standby promoted to primary")
        logTranslationTiming("warm-standby-promoted")
        return true
    }

    public func applyInterfaceLanguagePreservingSource() {
        // The visible translator is native. Reloading the hidden Google page
        // would read its empty textarea and recreate the workspace, erasing
        // the user's active source/result pair. Refresh native labels only.
        updateLongTextLabels()
        setTheme()
    }

    func reloadPreservingSource(for destination: ReloadDestination) {
        reloadRequestGeneration += 1
        let generation = reloadRequestGeneration

        let startReload: (String) -> Void = { [weak self] source in
            guard let self else { return }
            DispatchQueue.main.async {
                guard generation == self.reloadRequestGeneration else { return }
                // The visible editor is app-owned. Prefer it over the
                // transparent Google textarea, which can still contain the
                // previous text after the user clears the editor.
                self.pendingSourceTextForReload = source
                self.pendingSourceRestoreAttempts = 0
                self.installUserScripts(on: self.webView.configuration.userContentController)
                // Never expose the Google document during a reload. The
                // native workspace remains visible while the new language
                // pair is applied in the background.
                self.webView.isHidden = false
                self.webView.alphaValue = self.backgroundTranslationWebViewAlpha
                self.isReady = false

                switch destination {
                case .currentPage:
                    self.webView.reload()
                case .defaultLanguages:
                    self.webView.load(URLRequest(url: self.defaultTranslationURL()))
                case .interfaceLanguage:
                    self.webView.load(
                        URLRequest(
                            url: self.interfaceLocalizedURL(from: self.webView.url)
                        )
                    )
                case .translationURL(let url):
                    self.webView.load(URLRequest(url: url))
                }
            }
        }

        if let sourceView = longTextSourceView {
            startReload(sourceView.string)
        } else {
            webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
                result, _ in
                startReload(result as? String ?? "")
            }
        }
    }

}
