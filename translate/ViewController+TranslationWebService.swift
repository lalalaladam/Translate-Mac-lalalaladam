//
//  ViewController+TranslationWebService.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func resetPrimaryWebWarmupForNavigation() {
        primaryWebWarmupTimeoutWorkItem?.cancel()
        primaryWebWarmupTimeoutWorkItem = nil
        secondaryWebViewWarmupWorkItem?.cancel()
        secondaryWebViewWarmupWorkItem = nil
        parallelWebViewWarmupWorkItem?.cancel()
        parallelWebViewWarmupWorkItem = nil
        primaryWebWarmupGeneration += 1
        primaryWebWarmupState = .idle
    }

    private var requiredStartupWebViewRoles: Set<String> {
        var roles: Set<String> = ["primary", "automatic", "parallel"]
        if currentSourceLanguage != .automatic,
           currentSourceLanguage != currentTargetLanguage {
            roles.insert("standby")
        }
        return roles
    }

    func logStartupWebViewEvent(
        _ stage: String,
        role: String,
        extraFields: [String: Any] = [:]
    ) {
        let now = CACurrentMediaTime()
        var fields = extraFields
        fields["webview_role"] = role
        if let barrierStartedAt = startupWebViewBarrierStartedAt {
            fields["startup_elapsed_ms"] = max(0, (now - barrierStartedAt) * 1_000)
        }
        if let loadStartedAt = startupWebViewLoadStartedAt[role] {
            fields["webview_load_elapsed_ms"] = max(0, (now - loadStartedAt) * 1_000)
        }
        logTranslationTiming(stage, diagnosticFields: fields)
    }

    func markStartupWebViewReady(_ webView: WKWebView) {
        guard startupWebViewBarrierActive else { return }
        let role = translationWebViewRole(webView)
        guard requiredStartupWebViewRoles.contains(role),
              startupReadyWebViewRoles.insert(role).inserted else { return }
        logStartupWebViewEvent(
            "startup-webview-ready",
            role: role,
            extraFields: [
                "ready_count": startupReadyWebViewRoles.count,
                "required_ready_count": requiredStartupWebViewRoles.count
            ]
        )
        finishStartupWebViewBarrierIfReady()
    }

    func finishStartupWebViewBarrierIfReady() {
        guard startupWebViewBarrierActive,
              startupReadyWebViewRoles == requiredStartupWebViewRoles else { return }
        startupWebViewBarrierActive = false
        startupWebViewBarrierTimeoutWorkItem?.cancel()
        startupWebViewBarrierTimeoutWorkItem = nil
        logStartupWebViewEvent(
            "startup-all-webviews-ready",
            role: "all",
            extraFields: ["ready_count": startupReadyWebViewRoles.count]
        )
        hideConnectionOverlay()
    }

    func startConcurrentStartupWebViewLoads() {
        let source = currentSourceLanguage
        let target = currentTargetLanguage
        startupWebViewBarrierTimeoutWorkItem?.cancel()
        startupWebViewBarrierStartedAt = CACurrentMediaTime()
        startupWebViewLoadStartedAt.removeAll(keepingCapacity: true)
        startupReadyWebViewRoles.removeAll(keepingCapacity: true)
        startupWebViewBarrierActive = true
        logStartupWebViewEvent(
            "startup-webview-barrier-started",
            role: "all",
            extraFields: ["required_ready_count": requiredStartupWebViewRoles.count]
        )
        startupWebViewLoadStartedAt["primary"] = startupWebViewBarrierStartedAt
        logStartupWebViewEvent("startup-webview-load-started", role: "primary")

        let startLoad = { [weak self] (role: String, action: () -> Void) in
            guard let self else { return }
            self.startupWebViewLoadStartedAt[role] = CACurrentMediaTime()
            self.logStartupWebViewEvent("startup-webview-load-started", role: role)
            action()
        }
        startLoad("automatic") {
            self.loadAutomaticTranslationService(target: target)
        }
        if automaticTranslationWebViewReady,
           translationPageMatches(
               source: .automatic,
               target: target,
               in: automaticTranslationWebView
           ) {
            markStartupWebViewReady(automaticTranslationWebView)
        }
        if requiredStartupWebViewRoles.contains("standby") {
            startLoad("standby") {
                self.warmStandbyTranslationService(source: target, target: source)
            }
            if standbyTranslationWebViewReady,
               translationPageMatches(
                   source: target,
                   target: source,
                   in: standbyTranslationWebView
               ) {
                markStartupWebViewReady(standbyTranslationWebView)
            }
        }
        startLoad("parallel") {
            self.warmParallelTranslationService(source: source, target: target)
        }
        if parallelTranslationWebViewReady,
           translationPageMatches(
               source: source,
               target: target,
               in: parallelTranslationWebView
           ) {
            markStartupWebViewReady(parallelTranslationWebView)
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.startupWebViewBarrierActive else { return }
            let missing = self.requiredStartupWebViewRoles
                .subtracting(self.startupReadyWebViewRoles)
                .sorted()
                .joined(separator: ",")
            self.logStartupWebViewEvent(
                "startup-webview-barrier-timeout",
                role: "all",
                extraFields: [
                    "ready_count": self.startupReadyWebViewRoles.count,
                    "missing_roles": missing
                ]
            )
            self.showConnectionOverlay(waitingForNetwork: false)
        }
        startupWebViewBarrierTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: timeout)
    }

    func scheduleIdleSecondaryWebViewWarmups(after delay: TimeInterval) {
        secondaryWebViewWarmupWorkItem?.cancel()
        let source = currentSourceLanguage
        let target = currentTargetLanguage
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isReady,
                  self.currentSourceLanguage == source,
                  self.currentTargetLanguage == target,
                  self.longTextSourceView?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return
            }
            self.secondaryWebViewWarmupWorkItem = nil
            if source == .automatic {
                self.logTranslationCoordinator(
                    "idle-secondary-warmup-started-automatic",
                    source: ""
                )
                self.loadAutomaticTranslationService(target: target)
            } else {
                self.logTranslationCoordinator(
                    "idle-secondary-warmup-started-standby",
                    source: ""
                )
                self.warmStandbyTranslationServiceForReverseDirection()
            }
        }
        secondaryWebViewWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func schedulePostTranslationWebViewWarmups(after delay: TimeInterval) {
        secondaryWebViewWarmupWorkItem?.cancel()
        parallelWebViewWarmupWorkItem?.cancel()
        parallelWebViewWarmupWorkItem = nil
        let source = currentSourceLanguage
        let target = currentTargetLanguage
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.isReady,
                  self.currentSourceLanguage == source,
                  self.currentTargetLanguage == target,
                  self.longTextStatusState == .completed,
                  self.translationCoordinator.debounceWorkItem == nil,
                  !self.languageSwapInProgress else { return }
            self.secondaryWebViewWarmupWorkItem = nil
            // Automatic owns its separately cancellable immediate warmup.
            // Explicit pairs use this slot for the reverse standby page.
            if source != .automatic {
                self.logTranslationCoordinator(
                    "post-translation-secondary-warmup-started-standby",
                    source: ""
                )
                self.warmStandbyTranslationServiceForReverseDirection()
            }
            self.scheduleParallelWebViewWarmup(
                source: source,
                target: target,
                after: 0.2
            )
        }
        secondaryWebViewWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func scheduleAutomaticWarmupAfterStandbyIfIdle() {
        cancelAutomaticTranslationServiceWarmup()
        let source = currentSourceLanguage
        let target = currentTargetLanguage
        guard source != .automatic else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentSourceLanguage == source,
                  self.currentTargetLanguage == target,
                  self.translationCoordinator.debounceWorkItem == nil,
                  !self.languageSwapInProgress,
                  self.longTextSourceView?.hasMarkedText() != true,
                  self.longTextStatusState == .completed ||
                    self.longTextSourceView?.string
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
                return
            }
            self.automaticTranslationWarmupWorkItem = nil
            self.logTranslationCoordinator(
                "sequential-automatic-warmup-started",
                source: ""
            )
            self.loadAutomaticTranslationService(target: target)
        }
        automaticTranslationWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func scheduleParallelWebViewWarmup(
        source: TranslateLanguage,
        target: TranslateLanguage,
        after delay: TimeInterval
    ) {
        parallelWebViewWarmupWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentSourceLanguage == source,
                  self.currentTargetLanguage == target,
                  self.longTextStatusState == .completed,
                  self.translationCoordinator.debounceWorkItem == nil,
                  !self.languageSwapInProgress else { return }
            self.parallelWebViewWarmupWorkItem = nil
            self.logTranslationCoordinator(
                "post-translation-parallel-warmup-started",
                source: ""
            )
            self.warmParallelTranslationService(source: source, target: target)
        }
        parallelWebViewWarmupWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelCompetingSecondaryWebViewLoads(
        source: TranslateLanguage,
        target: TranslateLanguage
    ) {
        secondaryWebViewWarmupWorkItem?.cancel()
        secondaryWebViewWarmupWorkItem = nil
        parallelWebViewWarmupWorkItem?.cancel()
        parallelWebViewWarmupWorkItem = nil
        var stoppedServices: [String] = []

        if automaticTranslationWebViewLoading, source != .automatic {
            automaticTranslationWebView.stopLoading()
            automaticTranslationWebViewLoading = false
            automaticTranslationWebViewReady = false
            stoppedServices.append("automatic")
        }
        let needsLoadingStandby = standbyTranslationWebViewLoading &&
            standbyTranslationSource == source && standbyTranslationTarget == target
        if standbyTranslationWebViewLoading, !needsLoadingStandby {
            standbyTranslationWebView.stopLoading()
            standbyTranslationWebViewLoading = false
            standbyTranslationWebViewReady = false
            stoppedServices.append("standby")
        }
        let needsLoadingParallel = parallelTranslationWebViewLoading &&
            parallelTranslationSource == source && parallelTranslationTarget == target
        if parallelTranslationWebViewLoading, !needsLoadingParallel {
            parallelTranslationWebView.stopLoading()
            parallelTranslationWebViewLoading = false
            parallelTranslationWebViewReady = false
            stoppedServices.append("parallel")
        }
        if !stoppedServices.isEmpty {
            logTranslationCoordinator(
                "secondary-webview-loads-preempted-\(stoppedServices.joined(separator: "-"))",
                source: ""
            )
        }
    }

    func showConnectionOverlay(waitingForNetwork: Bool) {
        connectionOverlay?.isHidden = false
        longTextSourceView?.isEditable = false
        workspaceSourceLanguageButton?.isEnabled = false
        workspaceTargetLanguageButton?.isEnabled = false
        workspaceSwapButton?.isEnabled = false
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
        longTextSourceView?.isEditable = true
        workspaceSourceLanguageButton?.isEnabled = true
        workspaceTargetLanguageButton?.isEnabled = true
        workspaceSwapButton?.isEnabled = true
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
        resetPrimaryWebWarmupForNavigation()
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
        showConnectionOverlay(waitingForNetwork: true)
        logStartupTiming("Primary page load started")
        webView.load(
            URLRequest(
                url: defaultTranslationURL(),
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
        )
        startConcurrentStartupWebViewLoads()

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
        if startupWebViewBarrierActive {
            logStartupWebViewEvent(
                "startup-webview-load-failed",
                role: translationWebViewRole(webView),
                extraFields: [
                    "failure_phase": "provisional-navigation",
                    "error_domain": (error as NSError).domain,
                    "error_code": (error as NSError).code
                ]
            )
        }
        if webView === parallelTranslationWebView {
            prefersParallelTranslationWebView = false
            parallelTranslationWebViewReady = false
            parallelTranslationWebViewLoading = false
            return
        }
        if webView === standbyTranslationWebView {
            standbyTranslationWebViewReady = false
            standbyTranslationWebViewLoading = false
            reloadPrimaryForPendingStandbyTranslationIfNeeded()
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
        if startupWebViewBarrierActive {
            logStartupWebViewEvent(
                "startup-webview-load-failed",
                role: translationWebViewRole(webView),
                extraFields: [
                    "failure_phase": "navigation",
                    "error_domain": (error as NSError).domain,
                    "error_code": (error as NSError).code
                ]
            )
        }
        if webView === parallelTranslationWebView {
            prefersParallelTranslationWebView = false
            parallelTranslationWebViewReady = false
            parallelTranslationWebViewLoading = false
            return
        }
        if webView === standbyTranslationWebView {
            standbyTranslationWebViewReady = false
            standbyTranslationWebViewLoading = false
            reloadPrimaryForPendingStandbyTranslationIfNeeded()
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
        if startupWebViewBarrierActive {
            logStartupWebViewEvent(
                "startup-webview-navigation-finished",
                role: translationWebViewRole(webView)
            )
        }
        // A navigation replaces the page and its translation DOM. Do not let
        // a snapshot from the preceding language pair become a baseline for
        // the newly loaded service page.
        webTranslationSnapshots.removeValue(forKey: ObjectIdentifier(webView))
        let label = webView === automaticTranslationWebView
            ? "Automatic"
            : (webView === standbyTranslationWebView
                ? "Standby"
                : (webView === parallelTranslationWebView ? "Parallel" : "Primary"))
        logStartupTiming("\(label) navigation finished")
        waitForTranslationDOM(in: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard startupWebViewBarrierActive else { return }
        logStartupWebViewEvent(
            "startup-webview-navigation-committed",
            role: translationWebViewRole(webView)
        )
    }

    func waitForTranslationDOM(in webView: WKWebView) {
        let service = webView === automaticTranslationWebView
            ? "automatic"
            : (webView === standbyTranslationWebView
                ? "standby"
                : (webView === parallelTranslationWebView ? "parallel" : "primary"))
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
        markTranslationWebServiceReady(webView)
        translationCoordinator.markWebServiceActive()
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

        let hasVisibleSource = longTextSourceView?.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if !hadPendingPrimaryRequest,
           !languageSwapInProgress,
           !hasVisibleSource,
           startPrimaryWebWarmupIfPossible() {
            return
        } else if !startupWebViewBarrierActive {
            hideConnectionOverlay()
            // Preserve the existing first-request recovery capacity when the
            // user submits before DOM readiness: the real request owns all
            // WebKit and network capacity until it produces a result.
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
                        jsElapsedMS: timing.firstResultMutationAt - timing.jsStartedAt,
                        pageVisibility: document.visibilityState,
                        pageFocused: document.hasFocus()
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
        if currentSourceLanguage == .automatic {
            loadAutomaticTranslationService(target: currentTargetLanguage)
        }
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

    func cancelAutomaticTranslationServiceWarmup() {
        automaticTranslationWarmupWorkItem?.cancel()
        automaticTranslationWarmupWorkItem = nil
    }

    func scheduleAutomaticTranslationServiceWarmup() {
        cancelAutomaticTranslationServiceWarmup()
        let target = currentTargetLanguage
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.currentSourceLanguage == .automatic,
                  self.currentTargetLanguage == target,
                  self.longTextStatusState == .completed,
                  self.translationCoordinator.debounceWorkItem == nil,
                  !self.languageSwapInProgress,
                  self.longTextSourceView?.hasMarkedText() != true else {
                return
            }
            self.automaticTranslationWarmupWorkItem = nil
            self.loadAutomaticTranslationService(target: target)
        }
        automaticTranslationWarmupWorkItem = workItem
        // The real translation is already complete, so warming the only
        // high-value alternate page now cannot delay its first visible result.
        DispatchQueue.main.async(execute: workItem)
    }

    func warmParallelTranslationService(
        source: TranslateLanguage,
        target: TranslateLanguage
    ) {
        guard target.canBeTarget else {
            return
        }
        if !startupWebViewBarrierActive {
            guard isReady,
                  let activeTranslationWebView,
                  translationPageMatches(
                      source: source,
                      target: target,
                      in: activeTranslationWebView
                  ) else { return }
        }
        if parallelTranslationSource == source,
           parallelTranslationTarget == target,
           parallelTranslationWebViewReady || parallelTranslationWebViewLoading {
            return
        }

        parallelTranslationSource = source
        parallelTranslationTarget = target
        prefersParallelTranslationWebView = false
        parallelTranslationWebViewReady = false
        parallelTranslationWebViewLoading = true
        logStartupTiming("Parallel same-direction page load started")
        parallelTranslationWebView.load(
            URLRequest(
                url: translationURL(source: source, target: target),
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
        )
    }

    func warmStandbyTranslationServiceForReverseDirection() {
        warmStandbyTranslationService(
            source: currentTargetLanguage,
            target: currentSourceLanguage
        )
    }

    func warmStandbyTranslationService(
        source: TranslateLanguage,
        target: TranslateLanguage
    ) {
        guard source != .automatic,
              target.canBeTarget,
              source != target else {
            standbyTranslationWebViewReady = false
            standbyTranslationWebViewLoading = false
            return
        }
        if standbyTranslationSource == source,
           standbyTranslationTarget == target,
           standbyTranslationWebViewReady || standbyTranslationWebViewLoading {
            return
        }

        standbyTranslationSource = source
        standbyTranslationTarget = target
        standbyTranslationWebViewReady = false
        standbyTranslationWebViewLoading = true
        logStartupTiming("Standby reverse page load started")
        standbyTranslationWebView.load(
            URLRequest(
                url: translationURL(source: source, target: target),
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
              standbyTranslationSource == source,
              standbyTranslationTarget == target,
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
        standbyTranslationSource = target
        standbyTranslationTarget = source
        standbyTranslationWebViewReady = true
        standbyTranslationWebViewLoading = false
        activeTranslationWebView = webView
        isReady = true
        logStartupTiming("Warm standby promoted to primary")
        logTranslationTiming("warm-standby-promoted")
        return true
    }

    func reloadPrimaryForPendingStandbyTranslationIfNeeded() {
        guard let source = pendingPrimaryTranslationSource,
              pendingPrimaryTranslationSession == translationCoordinator.session,
              longTextSource == source,
              longTextSourceView?.string == source else {
            return
        }
        logTranslationTiming("standby-load-failed-primary-reload")
        reloadPreservingSource(
            for: .translationURL(
                translationURL(
                    source: translationCoordinator.effectiveSourceLanguage(
                        for: source,
                        selectedLanguage: currentSourceLanguage
                    ),
                    target: currentTargetLanguage
                )
            )
        )
    }

    public func applyInterfaceLanguagePreservingSource() {
        // The visible translator is native. Reloading the hidden Google page
        // would read its empty textarea and recreate the workspace, erasing
        // the user's active source/result pair. Refresh native labels only.
        updateLongTextLabels()
        setTheme()
    }

    func reloadPreservingSource(for destination: ReloadDestination) {
        resetPrimaryWebWarmupForNavigation()
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
