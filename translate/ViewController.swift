//
//  ViewController.swift
//  translate
//

import Cocoa
import WebKit

private final class AppearanceObservingView: NSView {
    var effectiveAppearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearanceDidChange?()
    }
}

class ViewController: NSViewController, WKNavigationDelegate {
    private static let windowBehaviorBarHeight: CGFloat = 34

    private enum ReloadDestination {
        case currentPage
        case defaultLanguages
        case interfaceLanguage
    }

    public var isReady = false
    private var readyHandlers: [() -> Void] = []

    var webView: WebView!
    var visualEffect: NSVisualEffectView!
    private var keepOnTopButton: NSButton!
    private var showOnAllSpacesButton: NSButton!
    private var windowBehaviorBar: WindowBehaviorBarView?
    private var windowBehaviorSettingsGroup: NSView?
    private var windowBehaviorDivider: NSView?
    private var pendingSourceTextForReload: String?
    private var pendingSourceRestoreAttempts = 0
    private var reloadRequestGeneration = 0
    private var applicationAppearanceObservation: NSKeyValueObservation?
    private var connectionOverlay: NSVisualEffectView?
    private var connectionTitleLabel: NSTextField?
    private var connectionDetailLabel: NSTextField?
    private var connectionSpinner: NSProgressIndicator?
    private var connectionRetryButton: NSButton?
    private var loadTimeoutWorkItem: DispatchWorkItem?
    private var automaticRetryWorkItem: DispatchWorkItem?
    private var translationLoadAttempt = 0

    var isDarkMode: Bool {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public func whenReady(_ handler: @escaping () -> Void) {
        if isReady {
            handler()
        } else {
            readyHandlers.append(handler)
        }
    }

    private func markReady() {
        isReady = true
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private func installUserScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()

        // Google measures source text in a hidden 24/32 px layer and later
        // switches visible long text to 18/28 px. Its web font can also swap
        // after the first glyph is painted. Stabilize every visible source
        // layer before first paint while preserving the measurement layer.
        let typographyGuard = WKUserScript(
            source: #"""
                (() => {
                    const styleId = "mac-translate-early-source-typography";
                    const install = () => {
                        if (document.getElementById(styleId)) return true;
                        const root = document.head || document.documentElement;
                        if (!root) return false;

                        const style = document.createElement("style");
                        style.id = styleId;
                        style.textContent = `
                            .QFw9Te .Hapztf,
                            .QFw9Te .cEWAef,
                            .QFw9Te .er8xn,
                            .QFw9Te .fXYY1b,
                            .QFw9Te .sB7Iec {
                                font-family: -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif !important;
                                font-size: 18px !important;
                                line-height: 28px !important;
                                font-weight: 400 !important;
                                letter-spacing: normal !important;
                                transition: none !important;
                            }

                            .QFw9Te .vJwDU {
                                font-family: -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif !important;
                                font-size: 24px !important;
                                line-height: 32px !important;
                                font-weight: 400 !important;
                                letter-spacing: normal !important;
                                transition: none !important;
                            }

                            /* Google uses 24/32 and 18/28 typography for the
                               expanded result at different responsive states.
                               Keep its visible and measurement layers aligned
                               without altering compact result cards. */
                            .QcsUad.sMVRZe .Cbi98e,
                            .QcsUad.sMVRZe .OvtS8d,
                            .QcsUad.sMVRZe .lRu31 {
                                font-size: 18px !important;
                                line-height: 28px !important;
                                transition: none !important;
                            }
                        `;
                        root.appendChild(style);
                        return true;
                    };

                    // Google's textarea auto-height update runs in a later
                    // timer. During a large paste, WebKit therefore scrolls
                    // the still-short textarea to the caret at the end before
                    // Google expands it. Match Google's final height during
                    // the input event, before that intermediate frame paints.
                    document.addEventListener("input", (event) => {
                        const textarea = event.target;
                        if (!(textarea instanceof HTMLTextAreaElement) ||
                            !textarea.matches(
                                ".er8xn, textarea[role=\"combobox\"][aria-controls=\"kvLWu\"]"
                            )) {
                            return;
                        }

                        textarea.style.removeProperty("height");
                        textarea.style.height =
                            `${Math.ceil(textarea.scrollHeight)}px`;
                    }, true);

                    if (!install()) {
                        document.addEventListener("DOMContentLoaded", install, {
                            once: true
                        });
                    }
                })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(typographyGuard)

        let suppressSelectionToolbar = TranslateFeaturePreferences.hideGoogleSelectionToolbar
            ? "true"
            : "false"

        // Install this before Google's scripts. Selection itself is a WebKit
        // default action, so stopping page listeners does not remove native
        // selection or Command+C; it only suppresses Google's optional UI.
        let interactionGuard = WKUserScript(
            source: #"""
                (() => {
                    if (window.__macTranslateEarlyInteractionGuard) return;
                    window.__macTranslateEarlyInteractionGuard = true;
                    const suppressSelectionToolbar = \#(suppressSelectionToolbar);

                    const sourceSelector = "textarea, .er8xn";
                    const resultSelector = [
                        ".QcsUad .ryNqvb",
                        ".QcsUad .HwtZe",
                        ".QcsUad .jCAhz",
                        ".QcsUad .lRu31",
                        ".QcsUad [jsname=\"W297wb\"]"
                    ].join(",");

                    const hit = (event) => {
                        const target = event.target;
                        if (!target || !target.closest) return null;
                        if (target.closest("#mac-translate-source-copy")) return null;
                        return {
                            source: target.closest(sourceSelector),
                            result: target.closest(resultSelector)
                        };
                    };

                    window.addEventListener("click", (event) => {
                        const target = event.target;
                        const button = target && target.closest ?
                            target.closest("#mac-translate-source-copy") : null;
                        if (!button) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        const textarea = document.querySelector("textarea");
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "copySource",
                            text: textarea ? textarea.value : ""
                        });
                    }, true);

                    const stopPageSelectionHandlers = (event) => {
                        if (!suppressSelectionToolbar) return;
                        const match = hit(event);
                        if (!match || (!match.source && !match.result)) return;
                        event.stopImmediatePropagation();
                        window.__macTranslateScheduleCleanup?.();
                    };

                    window.addEventListener("mouseup", stopPageSelectionHandlers, true);
                    window.addEventListener("pointerup", stopPageSelectionHandlers, true);

                    // Result activation always stays blocked because Google's
                    // compact detail page otherwise becomes an empty overlay.
                    const stopResultActivation = (event) => {
                        const match = hit(event);
                        if (!match || (!match.source && !match.result)) return;
                        if (match.result) {
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.__macTranslateScheduleCleanup?.();
                        } else if (suppressSelectionToolbar && match.source) {
                            event.stopImmediatePropagation();
                            window.__macTranslateScheduleCleanup?.();
                        }
                    };

                    window.addEventListener("click", stopResultActivation, true);
                    window.addEventListener("dblclick", stopResultActivation, true);

                    window.addEventListener("selectionchange", (event) => {
                        if (!suppressSelectionToolbar) return;
                        event.stopImmediatePropagation();
                        window.__macTranslateScheduleCleanup?.();
                    }, true);

                    window.addEventListener("contextmenu", (event) => {
                        const match = hit(event);
                        if (!match || (!match.source && !match.result)) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                    }, true);
                })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(interactionGuard)
    }

    private func defaultTranslationURL() -> URL {
        var components = URLComponents(string: "https://translate.google.com/")!
        components.queryItems = [
            URLQueryItem(
                name: "sl",
                value: TranslateLanguagePreferences.source.rawValue
            ),
            URLQueryItem(
                name: "tl",
                value: TranslateLanguagePreferences.target.rawValue
            ),
            URLQueryItem(
                name: "hl",
                value: AppInterfaceLanguagePreferences.current.googleLocale
            ),
            URLQueryItem(name: "op", value: "translate")
        ]
        return components.url!
    }

    private func interfaceLocalizedURL(from currentURL: URL?) -> URL {
        guard let currentURL,
              var components = URLComponents(
                url: currentURL,
                resolvingAgainstBaseURL: false
              ),
              components.host == "translate.google.com" else {
            return defaultTranslationURL()
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "hl" }
        queryItems.append(
            URLQueryItem(
                name: "hl",
                value: AppInterfaceLanguagePreferences.current.googleLocale
            )
        )
        components.queryItems = queryItems
        return components.url ?? defaultTranslationURL()
    }

    override func loadView() {
        let width = CGFloat(Constants.WIDTH)
        let height = CGFloat(Constants.HEIGHT)
        let barHeight = Self.windowBehaviorBarHeight

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "callbackHandler")
        installUserScripts(on: config.userContentController)

        webView = WebView(
            frame: NSRect(
                x: 0,
                y: barHeight,
                width: width,
                height: height - barHeight
            ),
            configuration: config
        )
        webView.autoresizingMask = [.width, .height]
        webView.shortcutHandler = { [weak self] action in
            self?.performShortcut(action) ?? false
        }
        webView.navigationDelegate = self

        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")

        // Give the native settings bar its own layout space. Previously it
        // was overlaid on WKWebView, so long translations could place the
        // Google copy button underneath the bar.
        let rootView = AppearanceObservingView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        rootView.addSubview(webView)
        self.view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] _ in
            // The distributed notification can precede AppKit's appearance
            // propagation. Retry briefly so the final pass always observes
            // the new application-level appearance.
            [0.0, 0.1, 0.35].forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    [weak self] in
                    self?.setTheme()
                }
            }
        }

        visualEffect = NSVisualEffectView(frame: self.view.bounds)
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.autoresizingMask = [.width, .height]

        self.view.addSubview(visualEffect, positioned: .below, relativeTo: nil)

        installWindowBehaviorBar()
        installConnectionOverlay()

        (view as? AppearanceObservingView)?.effectiveAppearanceDidChange = {
            [weak self] in
            self?.setTheme()
        }

        applicationAppearanceObservation = NSApp.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.setTheme()
            }
        }

        // Keep window movement completely outside the web content. These
        // narrow native strips behave like a conventional title bar while
        // source/result text remains exclusively available for selection.
        let edgeInset: CGFloat = 4
        let handleHeight: CGFloat = 14
        let topHandle = WindowDragHandleView(
            frame: NSRect(
                x: 0,
                y: self.view.bounds.height - edgeInset - handleHeight,
                width: self.view.bounds.width,
                height: handleHeight
            )
        )
        topHandle.autoresizingMask = [.width, .minYMargin]
        self.view.addSubview(topHandle)

        let bottomHandle = WindowDragHandleView(
            frame: NSRect(
                x: 0,
                y: Self.windowBehaviorBarHeight + edgeInset,
                width: self.view.bounds.width,
                height: handleHeight
            )
        )
        bottomHandle.autoresizingMask = [.width, .maxYMargin]
        self.view.addSubview(bottomHandle)

        // Do not leave a blank panel while a network service or VPN is still
        // starting. The overlay is replaced by Google Translate as soon as
        // the first successful navigation finishes.
        loadTranslationService()
    }

    deinit {
        loadTimeoutWorkItem?.cancel()
        automaticRetryWorkItem?.cancel()
    }

    private func installWindowBehaviorBar() {
        let barHeight = Self.windowBehaviorBarHeight
        let bar = WindowBehaviorBarView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: view.bounds.width,
                height: barHeight
            )
        )
        bar.blendingMode = .behindWindow
        bar.state = .active
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor.separatorColor.cgColor

        keepOnTopButton = makeWindowBehaviorButton(
            title: interfaceText("当前 Space 置顶", "Keep on Top"),
            behavior: .keepOnTop
        )
        showOnAllSpacesButton = makeWindowBehaviorButton(
            title: interfaceText("所有 Space 显示", "Show on All Spaces"),
            behavior: .showOnAllSpaces
        )

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16)
        ])

        let stack = NSStackView(
            views: [keepOnTopButton, divider, showOnAllSpacesButton]
        )
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Visually separate the interactive settings from the draggable blank
        // area on either side of the bottom bar.
        let settingsGroup = NSView()
        settingsGroup.translatesAutoresizingMaskIntoConstraints = false
        settingsGroup.wantsLayer = true
        settingsGroup.layer?.cornerRadius = 9
        settingsGroup.layer?.borderWidth = 0.75
        settingsGroup.addSubview(stack)
        bar.addSubview(settingsGroup)
        NSLayoutConstraint.activate([
            settingsGroup.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            settingsGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: settingsGroup.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: settingsGroup.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: settingsGroup.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: settingsGroup.bottomAnchor, constant: -3)
        ])

        view.addSubview(bar)
        windowBehaviorBar = bar
        windowBehaviorSettingsGroup = settingsGroup
        windowBehaviorDivider = divider
        updateWindowBehaviorBarAppearance()
        syncWindowBehaviorControls()
    }

    private func makeWindowBehaviorButton(
        title: String,
        behavior: TranslateWindowBehavior
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(windowBehaviorButtonChanged(_:)))
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.tag = behavior == .keepOnTop ? 0 : 1
        button.state = TranslateWindowPreferences.isEnabled(behavior) ? .on : .off
        return button
    }

    @objc private func windowBehaviorButtonChanged(_ sender: NSButton) {
        let behavior: TranslateWindowBehavior = sender.tag == 0
            ? .keepOnTop
            : .showOnAllSpaces
        (NSApp.delegate as? AppDelegate)?.setWindowBehavior(
            behavior,
            enabled: sender.state == .on
        )
    }

    func syncWindowBehaviorControls() {
        keepOnTopButton?.title = interfaceText(
            "当前 Space 置顶",
            "Keep on Top"
        )
        showOnAllSpacesButton?.title = interfaceText(
            "所有 Space 显示",
            "Show on All Spaces"
        )
        keepOnTopButton?.state = TranslateWindowPreferences.keepOnTop ? .on : .off
        showOnAllSpacesButton?.state = TranslateWindowPreferences.showOnAllSpaces ? .on : .off
    }

    private func installConnectionOverlay() {
        let overlay = NSVisualEffectView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.material = .popover
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 2

        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 390

        let retryButton = NSButton(
            title: interfaceText("立即重试", "Retry Now"),
            target: self,
            action: #selector(retryTranslationService)
        )
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [spinner, title, detail, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
        view.addSubview(overlay, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Self.windowBehaviorBarHeight
            ),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24)
        ])

        connectionOverlay = overlay
        connectionTitleLabel = title
        connectionDetailLabel = detail
        connectionSpinner = spinner
        connectionRetryButton = retryButton
        showConnectionOverlay(waitingForNetwork: true)
    }

    private func showConnectionOverlay(waitingForNetwork: Bool) {
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

    private func hideConnectionOverlay() {
        connectionOverlay?.isHidden = true
        connectionSpinner?.stopAnimation(nil)
    }

    private func loadTranslationService() {
        automaticRetryWorkItem?.cancel()
        loadTimeoutWorkItem?.cancel()
        translationLoadAttempt += 1
        let attempt = translationLoadAttempt

        isReady = false
        showConnectionOverlay(waitingForNetwork: true)
        webView.load(
            URLRequest(
                url: defaultTranslationURL(),
                cachePolicy: .reloadIgnoringLocalCacheData,
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

    @objc private func retryTranslationService() {
        loadTranslationService()
    }

    private func handleTranslationLoadFailure() {
        guard !isReady else { return }
        loadTimeoutWorkItem?.cancel()
        showConnectionOverlay(waitingForNetwork: false)
        scheduleAutomaticRetry()
    }

    private func scheduleAutomaticRetry() {
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
        handleTranslationLoadFailure()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleTranslationLoadFailure()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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

        // Google changes its generated class names frequently.  This script
        // uses stable accessibility markers where possible and also performs
        // a conservative visual/text check for the pinyin line that is shown
        // next to Chinese results.
        self.webView.evaluateJavaScript(#"""
            (() => {
                const preferences = {
                    hidePinyin: \#(hidePinyin),
                    hideGoogleSelectionToolbar: \#(hideGoogleSelectionToolbar),
                    simplifyActionButtons: \#(simplifyActionButtons),
                    highlightSelectedLanguage: \#(highlightSelectedLanguage)
                };
                const styleId = "mac-translate-style";
                const styleText = `
                    header,
                    #kvLWu,
                    .VjFXz,
                    .VlPnLc,
                    .gp-footer,
                    .hgbeOc.EjH7wc {
                        display: none !important;
                    }

                    .leDWne {
                        display: none !important;
                    }

                    .QcsUad:not(.FkMbO) .lRu31,
                    .er8xn {
                        min-height: 65px;
                    }

                    /* Keep visible source layers on a local, stable font and
                       preserve Google's hidden 24/32 px line-count layer. */
                    .QFw9Te .Hapztf,
                    .QFw9Te .cEWAef,
                    .QFw9Te .er8xn,
                    .QFw9Te .fXYY1b,
                    .QFw9Te .sB7Iec {
                        font-family: -apple-system, BlinkMacSystemFont,
                            "Helvetica Neue", Arial, sans-serif !important;
                        font-size: 18px !important;
                        line-height: 28px !important;
                        font-weight: 400 !important;
                        letter-spacing: normal !important;
                        transition: none !important;
                    }

                    .QFw9Te .vJwDU {
                        font-family: -apple-system, BlinkMacSystemFont,
                            "Helvetica Neue", Arial, sans-serif !important;
                        font-size: 24px !important;
                        line-height: 32px !important;
                        font-weight: 400 !important;
                        letter-spacing: normal !important;
                        transition: none !important;
                    }

                    /* Keep the expanded result and its two hidden measurement
                       layers aligned across Google's responsive states. */
                    .QcsUad.sMVRZe .Cbi98e,
                    .QcsUad.sMVRZe .OvtS8d,
                    .QcsUad.sMVRZe .lRu31 {
                        font-size: 18px !important;
                        line-height: 28px !important;
                        transition: none !important;
                    }

                    html {
                        overflow: hidden;
                    }

                    .QcsUad .zWhQbb,
                    .QcsUad .mDTU0c {
                        display: none !important;
                    }

                    ${preferences.highlightSelectedLanguage ? `
                        /* Make the selected source and target languages clear. */
                        [role="tab"][data-language-code][aria-selected="true"],
                        [role="tab"][data-language-code][aria-selected="true"] * {
                            font-weight: 900 !important;
                        }
                    ` : ""}

                    /* Keep selecting/copying available while suppressing the
                       WebKit text-selection callout actions. */
                    body,
                    textarea,
                    .er8xn,
                    .QcsUad .ryNqvb,
                    .QcsUad .jCAhz,
                    .QcsUad .HwtZe {
                        -webkit-user-select: text !important;
                        -webkit-touch-callout: none !important;
                    }

                    body::-webkit-scrollbar {
                        width: 0;
                        height: 0;
                        display: none;
                        -webkit-appearance: none;
                    }

                    ${preferences.hidePinyin ? `
                        [aria-label*="transliteration" i],
                        [aria-label*="romanization" i],
                        [aria-label*="pronunciation" i],
                        [data-testid*="transliteration" i],
                        [data-testid*="romanization" i],
                        [class*="transliteration" i],
                        [class*="romanization" i],
                        [class*="phonetic" i],
                        [class*="pinyin" i],
                        .QcsUad .UdTY9,
                        .QcsUad .kO6q6e,
                        .QcsUad [jsname="c3wAjc"] {
                            display: none !important;
                        }
                    ` : ""}

                    ${preferences.hideGoogleSelectionToolbar ? `
                        [aria-label*="dictionary" i],
                        [aria-label*="查字典"],
                        [data-tooltip*="dictionary" i],
                        [data-tooltip*="查字典"],
                        [title*="dictionary" i],
                        [title*="查字典"],
                        [jsname="SDSjce"],
                        [jsname="tD3Ohc"],
                        button[aria-label="朗读所选文字"],
                        button[aria-label="复制文字"],
                        button[aria-label*="selected text" i],
                        .ebT7ne,
                        .F0pQVc,
                        [jscontroller="ZR6Gve"],
                        [jsname="PbDcyb"],
                        [jsaction*="lysa9c"] {
                            display: none !important;
                        }
                    ` : ""}

                    ${preferences.simplifyActionButtons ? `
                        button[aria-label="语音翻译"],
                        button[aria-label="听取原文"],
                        button[aria-label="Voice input"],
                        button[aria-label="Listen to source text"],
                        .xMmqsf button[aria-label*="voice" i],
                        .xMmqsf button[aria-label*="microphone" i],
                        .xMmqsf button[aria-label*="speak" i],
                        .xMmqsf button[aria-label*="listen" i],
                        .xMmqsf button[data-tooltip*="voice" i],
                        .xMmqsf button[data-tooltip*="microphone" i],
                        .QcsUad button[aria-label="保存翻译"],
                        .QcsUad button[aria-label="听取译文"],
                        .QcsUad a[aria-label="使用 Google 搜索"],
                        .QcsUad button[aria-label="请对此翻译评分"],
                        .QcsUad button[aria-label="分享此译文"],
                        .QcsUad button[aria-label="Save translation"],
                        .QcsUad button[aria-label="Listen to translation"],
                        .QcsUad a[aria-label="Search with Google"],
                        .QcsUad button[aria-label="Rate this translation"],
                        .QcsUad button[aria-label="Share translation"],
                        .QcsUad .VO9ucd a,
                        .QcsUad a[aria-label*="Google" i],
                        .QcsUad a[href*="google.com/search" i],
                        [aria-label="发送反馈"],
                        [aria-label="Send feedback"],
                        [jsname="N7Eqid"],
                        .feedback-link {
                            display: none !important;
                        }
                    ` : ""}
                `;

                let style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement("style");
                    style.id = styleId;
                    (document.head || document.body).appendChild(style);
                }
                style.textContent = styleText;

                let theme = document.getElementById("mac-translate-theme-style");
                if (!theme) {
                    theme = document.createElement("style");
                    theme.id = "mac-translate-theme-style";
                    (document.head || document.body).appendChild(theme);
                }

                const roots = [];
                const collectRoots = (root) => {
                    roots.push(root);
                    root.querySelectorAll("*").forEach((element) => {
                        if (element.shadowRoot) {
                            collectRoots(element.shadowRoot);
                        }
                    });
                };

                const forEachElement = (callback) => {
                    roots.length = 0;
                    collectRoots(document);
                    roots.forEach((root) => root.querySelectorAll("*").forEach(callback));
                };

                const textOf = (element) => (element.innerText || element.textContent || "")
                    .replace(/\\s+/g, " ")
                    .trim();

                const isRightPane = (element) => {
                    const rect = element.getBoundingClientRect();
                    if (!rect.width || !rect.height) return false;
                    return rect.left > window.innerWidth * 0.42 ||
                        (rect.left + rect.width > window.innerWidth * 0.55 &&
                         rect.width < window.innerWidth * 0.70);
                };

                const hasChineseSibling = (element) => {
                    let parent = element.parentElement;
                    for (let level = 0; parent && level < 4; level += 1) {
                        const siblings = Array.from(parent.children)
                            .filter((child) => child !== element);
                        if (siblings.some((sibling) => /[\\u3400-\\u9fff]/.test(textOf(sibling)))) {
                            return true;
                        }
                        parent = parent.parentElement;
                    }
                    return false;
                };

                const looksLikePinyin = (text) => {
                    if (text.length < 2 || text.length > 400 || /[\\u3400-\\u9fff]/.test(text)) {
                        return false;
                    }
                    const letters = (text.match(/[A-Za-zÀ-ÖØ-öø-ÿ]/g) || []).length;
                    const toneMarks = /[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]/i.test(text);
                    const apostrophe = /['’]/.test(text);
                    return letters > 3 && /\\s/.test(text) && (toneMarks || apostrophe);
                };

                const detailLabel = (element) => [
                    element.getAttribute("aria-label") || "",
                    element.getAttribute("data-tooltip") || "",
                    textOf(element)
                ].join(" ").trim();

                const isDetailControl = (element) => {
                    const label = detailLabel(element);
                    return /^(展开|收起|expand|collapse|show more|hide details|详细|word[- ]by[- ]word)/i.test(label) ||
                        /\\b(word[- ]by[- ]word|show more|expand details)\\b/i.test(label);
                };

                const hide = (element) => {
                    if (element.getAttribute("data-mac-translate-hidden") === "1") return;
                    element.setAttribute("data-mac-translate-hidden", "1");
                    element.style.setProperty("display", "none", "important");
                };

                const isFeedbackElement = (element) => {
                    const label = (element.getAttribute("aria-label") || "").trim();
                    const text = textOf(element);
                    return /^(发送反馈|Send feedback)$/i.test(label) ||
                        /^(发送反馈|Send feedback)$/i.test(text);
                };

                const copyActionPattern = /(copy translation|copy|content_copy|复制译文|复制翻译|复制)/i;

                const controlLabel = (element) => [
                    element.getAttribute("aria-label") || "",
                    element.getAttribute("data-tooltip") || "",
                    element.getAttribute("title") || "",
                    element.getAttribute("jsname") || "",
                    textOf(element)
                ].join(" ").replace(/\s+/g, " ").trim();

                const ensureSourceCopyButton = () => {
                    const toolbar = document.querySelector(".xMmqsf");
                    const resultToolbar = document.querySelector(".QcsUad .VO9ucd");
                    if (!toolbar || !resultToolbar) return;

                    const resultCopyButton = Array.from(
                        resultToolbar.querySelectorAll("button")
                    ).find((button) => copyActionPattern.test(controlLabel(button)));
                    if (!resultCopyButton) return;

                    let slot = document.getElementById("mac-translate-source-copy-slot");
                    const existingButton = document.getElementById("mac-translate-source-copy");
                    if (slot && slot.parentElement === toolbar && existingButton) return;
                    if (slot) slot.remove();

                    slot = document.createElement("div");
                    slot.id = "mac-translate-source-copy-slot";
                    slot.style.setProperty("width", "48px", "important");
                    slot.style.setProperty("height", "48px", "important");
                    slot.style.setProperty("flex", "0 0 48px", "important");
                    slot.style.setProperty("display", "flex", "important");
                    slot.style.setProperty("align-items", "center", "important");
                    slot.style.setProperty("justify-content", "center", "important");

                    // Clone Google's real result-copy button so the left and
                    // right icons use the exact same DOM, classes and SVG.
                    const button = resultCopyButton.cloneNode(true);
                    button.querySelectorAll("[id]").forEach((element) => {
                        element.removeAttribute("id");
                    });
                    [button, ...button.querySelectorAll("*")].forEach((element) => {
                        element.removeAttribute("jscontroller");
                        element.removeAttribute("jsname");
                        element.removeAttribute("jsaction");
                        element.removeAttribute("data-mac-translate-hidden");
                    });
                    button.id = "mac-translate-source-copy";
                    button.setAttribute("aria-label", "\#(sourceCopyLabel)");
                    button.setAttribute("title", "\#(sourceCopyLabel)");
                    button.removeAttribute("data-tooltip");

                    slot.appendChild(button);
                    toolbar.prepend(slot);
                };

                const keepOnlyResultCopyButton = () => {
                    const toolbar = document.querySelector(".QcsUad .VO9ucd");
                    if (!toolbar) return;
                    const copyControl = Array.from(
                        toolbar.querySelectorAll("button")
                    ).find((button) => copyActionPattern.test(controlLabel(button)));
                    if (!copyControl) return;

                    const actionGroup = copyControl.closest(".YJGJsb");
                    if (actionGroup) {
                        Array.from(actionGroup.children).forEach((child) => {
                            if (!child.contains(copyControl)) hide(child);
                        });
                        actionGroup.style.setProperty("width", "48px", "important");
                        actionGroup.style.setProperty("min-width", "48px", "important");
                        actionGroup.style.setProperty("display", "flex", "important");
                    }

                    Array.from(toolbar.children).forEach((child) => {
                        if (child !== actionGroup && !child.contains(copyControl)) hide(child);
                    });
                    toolbar.style.setProperty("justify-content", "flex-end", "important");
                };

                // “查字典/Lookup” is unique to Google's contextual selection
                // row.  Do not key this rule off Copy/Listen: those controls
                // also exist in the two permanent source/result toolbars.
                const selectionActionPattern = /(查字典|dictionary|look up|lookup|menu_book|definitions?)/i;

                const hideSelectionAction = (element, selectedText) => {
                    if (!selectedText) return false;
                    const role = element.getAttribute("role") || "";
                    const className = typeof element.className === "string" ? element.className : "";
                    const isControl = element.tagName === "BUTTON" || element.tagName === "A" ||
                        role === "button" ||
                        element.hasAttribute("aria-label") ||
                        element.hasAttribute("data-tooltip") ||
                        element.hasAttribute("title") ||
                        /material-icons|google-symbols/i.test(className);
                    if (!isControl) return false;

                    const label = [
                        element.getAttribute("aria-label") || "",
                        element.getAttribute("data-tooltip") || "",
                        element.getAttribute("title") || "",
                        element.getAttribute("jsname") || "",
                        textOf(element)
                    ].join(" ").trim();
                    if (!selectionActionPattern.test(label)) return false;

                    // The current and recent Google layouts put these controls
                    // in a compact floating row.  Walk upward to hide that
                    // row, while avoiding the main result container and its
                    // persistent copy/listen controls when no text is selected.
                    let candidate = element;
                    for (let level = 0; candidate && level < 6; level += 1) {
                        const ownsEditableText = candidate.matches(
                            `textarea, .er8xn, ${resultTextSelector}`
                        ) || candidate.querySelector(
                            `textarea, .er8xn, ${resultTextSelector}`
                        );
                        if (ownsEditableText) break;

                        const rect = candidate.getBoundingClientRect();
                        const style = window.getComputedStyle(candidate);
                        const controls = candidate.querySelectorAll(
                            'button, a, [role="button"], [jsname]'
                        ).length;
                        const compact = rect.width > 0 && rect.height > 0 &&
                            rect.height <= 120 && rect.width <= window.innerWidth * 0.9;
                        const floating = style.position === "absolute" || style.position === "fixed";
                        if (controls >= 2 && compact && (floating || level > 0) &&
                            !candidate.matches(".QcsUad")) {
                            hide(candidate);
                            return true;
                        }
                        candidate = candidate.parentElement;
                    }

                    hide(element);
                    return true;
                };

                const resultTextSelector = [
                    ".QcsUad .ryNqvb",
                    ".QcsUad .HwtZe",
                    ".QcsUad .jCAhz",
                    ".QcsUad .lRu31",
                    ".QcsUad [jsname=\"W297wb\"]"
                ].join(",");

                const detailSelector = [
                    ".QcsUad .zWhQbb",
                    ".QcsUad .mDTU0c",
                    ".QcsUad .UdTY9",
                    ".QcsUad [aria-expanded=\"true\"]"
                ].join(",");

                const cleanup = () => {
                    const selection = window.getSelection();
                    const active = document.activeElement;
                    let selectedText = selection && !selection.isCollapsed ?
                        selection.toString().trim() : "";
                    if (!selectedText && active &&
                        (active.tagName === "TEXTAREA" || active.tagName === "INPUT") &&
                        typeof active.selectionStart === "number" &&
                        active.selectionEnd > active.selectionStart) {
                        selectedText = active.value.slice(active.selectionStart, active.selectionEnd).trim();
                    }

                    forEachElement((element) => {
                        const tag = element.tagName;
                        if (["SCRIPT", "STYLE", "TEXTAREA", "INPUT", "SELECT", "OPTION"].includes(tag)) {
                            return;
                        }

                        const marker = [
                            element.className || "",
                            element.getAttribute("aria-label") || "",
                            element.getAttribute("data-testid") || "",
                            element.getAttribute("data-tooltip") || "",
                            element.getAttribute("title") || "",
                            element.getAttribute("href") || ""
                        ].join(" ");

                        const ariaLabel = (element.getAttribute("aria-label") || "").trim();
                        const sourceControlLabel = [
                            ariaLabel,
                            element.getAttribute("data-tooltip") || "",
                            element.getAttribute("title") || ""
                        ].join(" ").trim();
                        if (preferences.simplifyActionButtons &&
                            element.tagName === "BUTTON" &&
                            element.closest(".xMmqsf") &&
                            /(语音翻译|听取原文|voice|microphone|speak|listen)/i.test(sourceControlLabel)) {
                            hide(element);
                            return;
                        }

                        if (preferences.simplifyActionButtons && element.tagName === "A" && isRightPane(element) &&
                            /google/i.test(marker) && /(search|搜索)/i.test(marker)) {
                            hide(element);
                            return;
                        }

                        // These are the current result/pinyin nodes.  The
                        // pinyin line is deliberately removed as a whole,
                        // including the hidden 展开/收起 controls inside it.
                        if (preferences.hidePinyin && element.matches(".QcsUad .UdTY9, .QcsUad .kO6q6e, .QcsUad [jsname=\"c3wAjc\"]")) {
                            hide(element.closest(".UdTY9") || element);
                            return;
                        }

                        // Current Google input/result text-selection popover.
                        if (preferences.hideGoogleSelectionToolbar && element.matches(
                            "[jsname=\"SDSjce\"], [jsname=\"tD3Ohc\"], " +
                            "button[aria-label=\"朗读所选文字\"], " +
                            "button[aria-label=\"复制文字\"], " +
                            "button[aria-label*=\"selected text\" i]"
                        )) {
                            hide(element.closest("[jsname=\"SDSjce\"]") || element);
                            return;
                        }

                        // Google reuses this row for the selection actions
                        // (speaker, copy, dictionary, etc.).  Remove the
                        // complete row, not only the dictionary link, so no
                        // floating action icons are left behind.
                        if (preferences.hideGoogleSelectionToolbar && element.matches(".ebT7ne, .F0pQVc, [jscontroller=\"ZR6Gve\"], [jsname=\"PbDcyb\"], [jsaction*=\"lysa9c\"]")) {
                            hide(element);
                            return;
                        }

                        if (preferences.hideGoogleSelectionToolbar && hideSelectionAction(element, selectedText)) {
                            return;
                        }

                        if (preferences.simplifyActionButtons && isFeedbackElement(element)) {
                            const feedback = element.closest(".cJ1Ndf") || element;
                            hide(feedback);
                            return;
                        }

                        if (preferences.hidePinyin && /(transliteration|romanization|phonetic|pinyin|pronunciation)/i.test(marker)) {
                            hide(element);
                            return;
                        }

                        const text = textOf(element);
                        const rect = element.getBoundingClientRect();
                        if (preferences.hidePinyin && isRightPane(element) && rect.height < 100 &&
                            element.children.length <= 3 && looksLikePinyin(text) &&
                            hasChineseSibling(element)) {
                            hide(element);
                        }

                        if (element.getAttribute("aria-expanded") === "true" && isDetailControl(element)) {
                            element.setAttribute("aria-expanded", "false");
                        }
                    });

                    if (preferences.simplifyActionButtons) {
                        ensureSourceCopyButton();
                        keepOnlyResultCopyButton();
                    }

                };

                let cleanupScheduled = false;
                const scheduleCleanup = () => {
                    if (cleanupScheduled) return;
                    cleanupScheduled = true;
                    queueMicrotask(() => {
                        cleanupScheduled = false;
                        cleanup();
                    });
                };
                window.__macTranslateScheduleCleanup = scheduleCleanup;

                if (!window.__macTranslateInstalled) {
                    window.__macTranslateInstalled = true;
                    const observer = new MutationObserver(scheduleCleanup);
                    observer.observe(document.documentElement, {
                        childList: true,
                        subtree: true,
                        attributes: true,
                        attributeFilter: ["class", "style", "aria-expanded"]
                    });

                    // Google attaches a click action to .ryNqvb/.jCAhz that
                    // opens the overlapping word-by-word panel.  Block only
                    // that action; native mouse dragging and text selection
                    // remain untouched because mousedown is not cancelled.
                    const blockResultClick = (event) => {
                        const target = event.target;
                        const element = target && target.closest ? target : null;
                        if (!element) return;

                        const detail = element.closest(detailSelector);
                        const result = element.closest(resultTextSelector);
                        if (detail || result) {
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            scheduleCleanup();
                        }
                    };

                    document.addEventListener("click", blockResultClick, true);
                    document.addEventListener("dblclick", blockResultClick, true);
                    document.addEventListener("selectionchange", scheduleCleanup, true);
                    document.addEventListener("input", scheduleCleanup, true);

                    // Do not let Google install a page-level context menu or
                    // selection callout.  Native text selection and Cmd+C
                    // continue to work; the AppKit WebView subclass also
                    // removes any native menu that WebKit tries to present.
                    document.addEventListener("contextmenu", (event) => {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                    }, true);

                }

                cleanup();
            })();
        """#) { [weak self] _, _ in
            guard let self else { return }
            self.setTheme { [weak self] in
                guard let self else { return }
                self.restorePendingSourceTextIfNeeded()
                self.markReady()
                self.loadTimeoutWorkItem?.cancel()
                self.automaticRetryWorkItem?.cancel()
                self.hideConnectionOverlay()
            }
        }
    }

    func setTheme(completion: (() -> Void)? = nil) {
        visualEffect.material = isDarkMode ? .dark : .light
        updateWindowBehaviorBarAppearance()
        let selectedLanguageStyle = TranslateFeaturePreferences.highlightSelectedLanguage
            ? #"""
                [role="tab"][data-language-code][aria-selected="true"] {
                    background: var(--translate-selected-background) !important;
                    color: var(--translate-selected-color) !important;
                    border-radius: 10px !important;
                    box-shadow: inset 0 -3px 0 var(--translate-selected-color) !important;
                    font-weight: 900 !important;
                }

                [role="tab"][data-language-code][aria-selected="true"] * {
                    color: var(--translate-selected-color) !important;
                    font-weight: 900 !important;
                }
            """#
            : ""

        self.webView.evaluateJavaScript(#"""
            let theme = document.getElementById("mac-translate-theme-style");
            if (!theme) {
                theme = document.createElement("style");
                theme.id = "mac-translate-theme-style";
                (document.head || document.documentElement).appendChild(theme);
            }
            theme.textContent = `
                :root {
                    color-scheme: light dark !important;
                    --translate-text-color: black;
                    --translate-selected-color: #0B57D0;
                    --translate-selected-background: rgba(11, 87, 208, 0.14);
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --translate-text-color: white;
                        --translate-selected-color: #A8C7FA;
                        --translate-selected-background: rgba(168, 199, 250, 0.20);
                    }
                }

                *, *:before, *:after {
                    background: transparent !important;
                    color: var(--translate-text-color) !important;
                    box-shadow: none !important;
                    border-color: var(--translate-text-color) !important;
                    border: none !important;
                    border-top: none !important;
                }

                \#(selectedLanguageStyle)

                .zXU7Rb, .ccvoYb.EjH7wc {
                    border: none !important;
                }
            `;
        """#) { _, _ in
            completion?()
        }
    }

    private func updateWindowBehaviorBarAppearance() {
        let dark = isDarkMode
        windowBehaviorBar?.material = dark ? .dark : .light
        windowBehaviorBar?.layer?.borderColor = NSColor.separatorColor.cgColor

        windowBehaviorSettingsGroup?.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(dark ? 0.12 : 0.055).cgColor
        windowBehaviorSettingsGroup?.layer?.borderColor = NSColor.separatorColor.cgColor
        windowBehaviorDivider?.wantsLayer = true
        windowBehaviorDivider?.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    public func focusAndSelectField() {
        self.webView.evaluateJavaScript("""
            setTimeout(function() {
                var textarea = document.getElementsByTagName("textarea")[0];
                if (textarea) {
                    textarea.focus();
                    textarea.select();
                }
            }, 20);
        """, completionHandler: nil)
    }

    public func reloadWithCurrentPreferences() {
        reloadPreservingSource(for: .currentPage)
    }

    public func applyDefaultLanguagesPreservingSource() {
        reloadPreservingSource(for: .defaultLanguages)
    }

    public func applyInterfaceLanguagePreservingSource() {
        reloadPreservingSource(for: .interfaceLanguage)
    }

    private func reloadPreservingSource(for destination: ReloadDestination) {
        reloadRequestGeneration += 1
        let generation = reloadRequestGeneration

        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let self else { return }

            DispatchQueue.main.async {
                guard generation == self.reloadRequestGeneration else { return }
                self.pendingSourceTextForReload = result as? String ?? ""
                self.pendingSourceRestoreAttempts = 0
                self.installUserScripts(on: self.webView.configuration.userContentController)
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
                }
            }
        }
    }

    public func copyAllSource() {
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let text = result as? String else { return }
            self?.copyToPasteboard(text)
        }
    }

    public func copyAllTranslation() {
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
                return nodes
                    .filter((element) => visible(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c"))
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
        webView.evaluateJavaScript(#"""
            (() => {
                const labelled = document.querySelector(
                    'button[aria-label*="Swap" i], button[aria-label*="交换"], button[aria-label*="切换"]'
                );
                if (labelled) {
                    labelled.click();
                    return true;
                }
                const icon = Array.from(document.querySelectorAll("i"))
                    .find((element) => element.innerText.trim() === "swap_horiz");
                const control = icon && (icon.closest("button") || icon);
                if (control) control.click();
                return Boolean(control);
            })();
        """#, completionHandler: nil)
    }

    func performShortcut(_ action: ShortcutAction) -> Bool {
        switch action {
        case .showHideWindow:
            // This action is registered as a Carbon global hotkey. Handling
            // it here too would toggle twice while the app is active.
            return false
        case .closeWindow:
            view.window?.performClose(nil)
        case .hideApplication:
            NSApp.hide(nil)
        case .quitApplication:
            NSApp.terminate(nil)
        case .selectAllSource:
            focusAndSelectField()
        case .listenSource:
            listenToSource()
        case .swapLanguages:
            swapLanguages()
        case .applySpellingCorrection:
            applySpellingCorrection()
        case .moveFocusOut:
            (NSApplication.shared.delegate as? AppDelegate)?.panel.resignKey()
        case .undo:
            return NSApp.sendAction(Selector(("undo:")), to: nil, from: webView)
        case .redo:
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: webView)
        case .cut:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: webView)
        case .copy:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: webView)
        case .paste:
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: webView)
        }
        return true
    }

    private func listenToSource() {
        webView.evaluateJavaScript(#"""
            (() => {
                const button = document.querySelector(
                    ".m0Qfkd .VfPpkd-Bz112c-kBDsod:not(.VfPpkd-Bz112c-kBDsod-OWXEXe-IT5dJd)"
                );
                if (button) button.click();
            })();
        """#, completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.focusAndSelectField()
        }
    }

    private func applySpellingCorrection() {
        webView.evaluateJavaScript(#"""
            document.querySelector(".mvqA2c")?.click();
        """#, completionHandler: nil)
    }

    private func restorePendingSourceTextIfNeeded() {
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

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension ViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let payload = message.body as? [String: Any],
           payload["action"] as? String == "copySource",
           let text = payload["text"] as? String {
            copyToPasteboard(text)
            return
        }

        let keyCode = message.body as? Int
        if keyCode == 9 {
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            appDelegate.panel.resignKey()
        }
    }
}
