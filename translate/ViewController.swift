//
//  ViewController.swift
//  translate
//

import Cocoa
import WebKit

class ViewController: NSViewController, WKNavigationDelegate {
    public var isReady = false

    var webView: WKWebView!
    var visualEffect: NSVisualEffectView!
    private var pendingSourceTextForReload: String?
    private var pendingSourceRestoreAttempts = 0

    var isDarkMode: Bool {
        let mode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return mode == "Dark"
    }

    private func installUserScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()
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

    override func loadView() {
        let width = Constants.WIDTH
        let height = Constants.HEIGHT
        let source = Constants.SOURCE_LANGUAGE
        let translation = Constants.TRANSLATION_LANGUAGE

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "callbackHandler")
        installUserScripts(on: config.userContentController)

        webView = WebView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            configuration: config
        )
        webView.navigationDelegate = self

        let url = URL(string: "https://translate.google.com/?sl=\(source)&tl=\(translation)")!
        webView.load(URLRequest(url: url))

        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")

        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] _ in
            self?.setTheme()
        }

        visualEffect = NSVisualEffectView(frame: self.view.bounds)
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.autoresizingMask = [.width, .height]

        self.view.addSubview(visualEffect, positioned: .below, relativeTo: nil)
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
                    return (element.getAttribute("aria-label") || "").trim() === "发送反馈" ||
                        textOf(element) === "发送反馈";
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
                    button.setAttribute("aria-label", "复制原文");
                    button.setAttribute("title", "复制原文");
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
                        if (preferences.simplifyActionButtons && element.tagName === "BUTTON" &&
                            /^(语音翻译|听取原文|Voice input|Listen to source text)$/i.test(ariaLabel)) {
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

                    // Do not let Google install a page-level context menu or
                    // selection callout.  Native text selection and Cmd+C
                    // continue to work; the AppKit WebView subclass also
                    // removes any native menu that WebKit tries to present.
                    document.addEventListener("contextmenu", (event) => {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                    }, true);

                    document.addEventListener("keydown", (event) => {
                        const keyCode = event.keyCode;
                        const metaKey = event.metaKey;

                        if (metaKey && keyCode === 65) {
                            event.preventDefault();
                            const textarea = document.getElementsByTagName("textarea")[0];
                            if (textarea) {
                                textarea.focus();
                                textarea.select();
                            }
                        }

                        if (keyCode === 9) {
                            event.preventDefault();
                            window.webkit.messageHandlers.callbackHandler.postMessage(keyCode);
                        }

                        if (metaKey && keyCode === 76) {
                            const listenButton = document.querySelector(
                                ".m0Qfkd .VfPpkd-Bz112c-kBDsod:not(.VfPpkd-Bz112c-kBDsod-OWXEXe-IT5dJd)"
                            );
                            if (listenButton) listenButton.click();
                            setTimeout(() => {
                                const textarea = document.getElementsByTagName("textarea")[0];
                                if (textarea) {
                                    textarea.focus();
                                    textarea.select();
                                }
                            }, 800);
                        }

                        if (metaKey && keyCode === 83) {
                            const swap = Array.from(document.querySelectorAll("i"))
                                .find((element) => element.innerText === "swap_horiz");
                            if (swap) swap.click();
                        }

                        if (metaKey && keyCode === 13) {
                            const label = document.querySelector(".mvqA2c");
                            if (label) label.click();
                        }
                    });
                }

                cleanup();
            })();
        """#, completionHandler: nil)

        self.setTheme()
        restorePendingSourceTextIfNeeded()
        isReady = true
    }

    func setTheme() {
        visualEffect.material = isDarkMode ? .dark : .light
        let color = isDarkMode ? "white" : "black"
        let selectedLanguageColor = isDarkMode ? "#A8C7FA" : "#0B57D0"
        let selectedLanguageBackground = isDarkMode
            ? "rgba(168, 199, 250, 0.20)"
            : "rgba(11, 87, 208, 0.14)"
        let selectedLanguageStyle = TranslateFeaturePreferences.highlightSelectedLanguage
            ? #"""
                [role="tab"][data-language-code][aria-selected="true"] {
                    background: \#(selectedLanguageBackground) !important;
                    color: \#(selectedLanguageColor) !important;
                    border-radius: 10px !important;
                    box-shadow: inset 0 -3px 0 \#(selectedLanguageColor) !important;
                    font-weight: 900 !important;
                }

                [role="tab"][data-language-code][aria-selected="true"] * {
                    color: \#(selectedLanguageColor) !important;
                    font-weight: 900 !important;
                }
            """#
            : ""

        self.webView.evaluateJavaScript(#"""
            const theme = document.getElementById("mac-translate-theme-style");
            if (theme) theme.textContent = `
                *, *:before, *:after {
                    background: transparent !important;
                    color: \#(color) !important;
                    box-shadow: none !important;
                    border-color: \#(color) !important;
                    border: none !important;
                    border-top: none !important;
                }

                \#(selectedLanguageStyle)

                .zXU7Rb, .ccvoYb.EjH7wc {
                    border: none !important;
                }
            `;
        """#, completionHandler: nil)
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
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let self else { return }
            self.pendingSourceTextForReload = result as? String ?? ""
            self.pendingSourceRestoreAttempts = 0
            self.installUserScripts(on: self.webView.configuration.userContentController)
            self.isReady = false
            self.webView.reload()
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
