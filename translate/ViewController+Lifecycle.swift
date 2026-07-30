//
//  ViewController+Lifecycle.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func translationURL(
        source: TranslateLanguage,
        target: TranslateLanguage
    ) -> URL {
        var components = URLComponents(string: "https://translate.google.com/")!
        components.queryItems = [
            URLQueryItem(
                name: "sl",
                value: source.rawValue
            ),
            URLQueryItem(
                name: "tl",
                value: target.rawValue
            ),
            URLQueryItem(
                name: "hl",
                value: AppInterfaceLanguagePreferences.current.googleLocale
            ),
            URLQueryItem(name: "op", value: "translate")
        ]
        return components.url!
    }

    func defaultTranslationURL() -> URL {
        translationURL(
            source: TranslateLanguagePreferences.source,
            target: TranslateLanguagePreferences.target
        )
    }

    func updateCurrentLanguages(from url: URL?) {
        let items = URLComponents(url: url ?? defaultTranslationURL(),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let rawSource = items.first(where: { $0.name == "sl" })?.value,
           let source = TranslateLanguage(rawValue: rawSource),
           source != .automatic {
            currentSourceLanguage = source
        }
        if let rawTarget = items.first(where: { $0.name == "tl" })?.value,
           let target = TranslateLanguage(rawValue: rawTarget), target.canBeTarget {
            currentTargetLanguage = target
        }
    }

    func interfaceLocalizedURL(from currentURL: URL?) -> URL {
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
        logStartupTiming("WebViews creating")
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
        // Keep Google Translate mounted and running in the background. A
        // hidden WKWebView can stop updating its dynamic result DOM, while a
        // fully transparent one continues to behave like the old visible
        // WebView without ever flashing its page through the native workspace.
        webView.alphaValue = backgroundTranslationWebViewAlpha

        // Keep a second Google Translate document permanently warmed with
        // source=auto. A single WebView had to reload the whole Google app
        // whenever the entered script did not match the selected source
        // language, adding several seconds before any result could appear.
        let automaticConfig = WKWebViewConfiguration()
        automaticConfig.userContentController.add(self, name: "callbackHandler")
        automaticTranslationWebView = BackgroundTranslationWebView(
            frame: webView.frame,
            configuration: automaticConfig
        )
        automaticTranslationWebView.autoresizingMask = [.width, .height]
        automaticTranslationWebView.navigationDelegate = self
        automaticTranslationWebView.wantsLayer = true
        automaticTranslationWebView.layer?.backgroundColor = .clear
        automaticTranslationWebView.underPageBackgroundColor = .clear
        automaticTranslationWebView.setValue(false, forKey: "drawsBackground")
        automaticTranslationWebView.alphaValue = backgroundTranslationWebViewAlpha

        // A third background document holds the reverse of the explicit
        // language pair. It is loaded only after the primary page is ready,
        // so cold startup keeps priority while a later swap can avoid a full
        // Google navigation.
        let standbyConfig = WKWebViewConfiguration()
        standbyConfig.userContentController.add(self, name: "callbackHandler")
        installUserScripts(on: standbyConfig.userContentController)
        standbyTranslationWebView = WebView(
            frame: webView.frame,
            configuration: standbyConfig
        )
        standbyTranslationWebView.autoresizingMask = [.width, .height]
        standbyTranslationWebView.shortcutHandler = { [weak self] action in
            self?.performShortcut(action) ?? false
        }
        standbyTranslationWebView.navigationDelegate = self
        standbyTranslationWebView.wantsLayer = true
        standbyTranslationWebView.layer?.backgroundColor = .clear
        standbyTranslationWebView.underPageBackgroundColor = .clear
        standbyTranslationWebView.setValue(false, forKey: "drawsBackground")
        standbyTranslationWebView.alphaValue = backgroundTranslationWebViewAlpha
        activeTranslationWebView = webView
        logStartupTiming("WebViews created")

        // Give the native settings bar its own layout space. Previously it
        // was overlaid on WKWebView, so long translations could place the
        // Google copy button underneath the bar.
        let rootView = AppearanceObservingView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        rootView.addSubview(automaticTranslationWebView)
        rootView.addSubview(standbyTranslationWebView)
        rootView.addSubview(webView)
        self.view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        _ = TranslationPerformanceDiagnostics.shared

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

        // Google Translate stays mounted at a very low alpha so WebKit keeps
        // its dynamic result DOM active. Put a dedicated behind-window glass
        // surface above both service WebViews: it samples only content behind
        // the app window, never the lower sibling WebViews inside the window.
        // This preserves translucency without allowing Google's page through.
        let workspaceBackground = NSVisualEffectView(frame: self.view.bounds)
        workspaceBackground.autoresizingMask = [.width, .height]
        workspaceBackground.material = isDarkMode ? .dark : .light
        workspaceBackground.blendingMode = .behindWindow
        workspaceBackground.state = .active
        workspaceBackground.isEmphasized = false
        self.view.addSubview(workspaceBackground, positioned: .above, relativeTo: webView)
        workspaceBackgroundView = workspaceBackground

        installWindowBehaviorBar()
        installConnectionOverlay()
        installLongTextOverlay()
        // Present the app-owned empty editor immediately. A cold WebKit load
        // continues in the background and should not make a healthy launch
        // look like a multi-second network check.
        longTextOverlay?.isHidden = false
        refreshWorkspaceLanguageTitles()

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

        // Keep window movement completely outside the web content. The top
        // strip behaves like a conventional title bar; the native behavior
        // bar below handles dragging in its own empty areas, so no full-width
        // overlay can cover the result actions.
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

        // Prioritize the explicitly selected direction. It is the normal path
        // for cold-launch typing and must not wait behind the second, automatic-
        // detection Google document competing for the same WebKit resources.
        loadTranslationService()
        // Keep automatic detection warm as well, but enqueue it only after the
        // primary navigation has been started. Both loads remain asynchronous.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.loadAutomaticTranslationService(target: self.currentTargetLanguage)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWorkspaceLayoutIfNeeded()
    }
}
