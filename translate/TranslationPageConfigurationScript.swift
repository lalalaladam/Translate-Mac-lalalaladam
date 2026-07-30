//
//  TranslationPageConfigurationScript.swift
//  translate
//

import Foundation

/// Builds the CSS and JavaScript used to adapt the Google Translate page to the native app UI.
enum TranslationPageConfigurationScript {
    static func make(
        hidePinyin: String,
        hideGoogleSelectionToolbar: String,
        simplifyActionButtons: String,
        highlightSelectedLanguage: String,
        sourceCopyLabel: String,
        sourceClearLabel: String,
        swapLanguagesLabel: String,
        wordCountLabel: String,
        chineseCharacterCountLabel: String
    ) -> String {
        return #"""
            (() => {
                const preferences = {
                    hidePinyin: \#(hidePinyin),
                    hideGoogleSelectionToolbar: \#(hideGoogleSelectionToolbar),
                    simplifyActionButtons: \#(simplifyActionButtons),
                    highlightSelectedLanguage: \#(highlightSelectedLanguage)
                };
                const styleId = "mac-translate-style";
                const styleText = \#(TranslationPageStyles.javaScriptTemplateLiteral);

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

                // Google keeps an accessibility hint for its history sidebar
                // in the document. With the compact page layout it can be
                // positioned over the source textarea after a long input.
                // This exact hint is not translation content, so hide only
                // the node whose complete text matches it.
                const isSidebarTranslationHint = (text) =>
                    /^(使用箭头按钮可查看完整译文|use (?:the )?arrow buttons? to view (?:the )?full translation)\.?$/i
                        .test(text.trim());

                const isLongTextLimitNotice = (text) =>
                    /(如需翻译超过\s*5[,，]?000\s*个字符.*复制.*粘贴原文|translate more than\s*5,?000\s*characters.*copy.*paste)/i
                        .test(text.replace(/\s+/g, " "));

                const isLanguageSwapHint = (text) =>
                    /(交换源语言和目标语言|swap source and target languages?)/i
                        .test(text.replace(/\s+/g, " "));

                const copyActionPattern = /(copy translation|copy|content_copy|复制译文|复制翻译|复制)/i;

                const controlLabel = (element) => [
                    element.getAttribute("aria-label") || "",
                    element.getAttribute("data-tooltip") || "",
                    element.getAttribute("title") || "",
                    element.getAttribute("jsname") || "",
                    textOf(element)
                ].join(" ").replace(/\s+/g, " ").trim();

                const countLabels = {
                    words: "\#(wordCountLabel)",
                    chineseCharacters: "\#(chineseCharacterCountLabel)"
                };

                const visible = (element) => {
                    const style = getComputedStyle(element);
                    const rect = element.getBoundingClientRect();
                    return style.display !== "none" && style.visibility !== "hidden" &&
                        rect.width > 0 && rect.height > 0;
                };

                const textCount = (text) => {
                    const hanCharacters = (text.match(/[\u3400-\u9fff\uf900-\ufaff]/g) || []).length;
                    // Unicode class \p{L} includes Han characters. Remove
                    // them before counting word-like runs so Chinese text is
                    // reported as 汉字, not as a misleading series of words.
                    const nonHanText = text.replace(/[\u3400-\u9fff\uf900-\ufaff]/g, " ");
                    const words = (nonHanText.match(
                        /[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*/gu
                    ) || []).length;
                    return { words, hanCharacters };
                };

                const countText = (text) => {
                    const { words, hanCharacters } = textCount(text);
                    const parts = [];
                    if (words > 0) parts.push(`${countLabels.words} ${words}`);
                    if (hanCharacters > 0) {
                        parts.push(`${countLabels.chineseCharacters} ${hanCharacters}`);
                    }
                    return parts.join(" · ");
                };

                const countNode = (host, side, toolbar) => {
                    if (!host) return null;
                    host.style.setProperty("position", "relative", "important");
                    const id = `mac-translate-text-count-${side}`;
                    let node = document.getElementById(id);
                    if (!node) {
                        node = document.createElement("span");
                        node.id = id;
                        node.className = "mac-translate-text-count";
                        node.setAttribute("data-mac-translate-count-side", side);
                        node.setAttribute("aria-live", "polite");
                    }
                    const placement = toolbar || host;
                    if (node.parentElement !== placement) placement.appendChild(node);
                    node.setAttribute(
                        "data-mac-translate-count-placement",
                        toolbar ? "toolbar" : "fallback"
                    );
                    return node;
                };

                const hideNativeSourceCharacterCount = (sourceHost) => {
                    if (!sourceHost) return;
                    // Google places its character quota beside, rather than
                    // inside, the textarea in some layouts. Check the local
                    // input container and a few ancestors, without touching
                    // any unrelated numeric controls elsewhere on the page.
                    let container = sourceHost;
                    for (let level = 0; container && level < 4; level += 1) {
                        Array.from(container.querySelectorAll("*")).forEach((element) => {
                            if (element.classList.contains("mac-translate-text-count") ||
                                element.children.length > 0) {
                                return;
                            }
                            const text = textOf(element);
                            const label = [
                                element.getAttribute("aria-label") || "",
                                element.getAttribute("data-tooltip") || ""
                            ].join(" ");
                            const isCharacterQuota =
                                /^\d[\d,]*\s*\/\s*\d[\d,]*$/.test(text) ||
                                /(目前为.*个字符.*上限|上限为.*字符|characters?.*(limit|maximum|out of))/i
                                    .test(label);
                            if (isCharacterQuota) {
                                element.style.setProperty("display", "none", "important");
                            }
                        });
                        container = container.parentElement;
                    }
                };

                const updateTextCounts = () => {
                    const textarea = document.querySelector("textarea.er8xn, textarea");
                    if (textarea) {
                        const sourceHost = textarea.closest(".QFw9Te") || textarea.parentElement;
                        const sourceToolbar = document.querySelector(".xMmqsf");
                        const node = countNode(sourceHost, "source", sourceToolbar);
                        if (node) node.textContent = countText(textarea.value);
                        hideNativeSourceCharacterCount(sourceHost);
                    }

                    const results = Array.from(document.querySelectorAll(resultTextSelector))
                        .filter(visible)
                        // Google marks several nested wrappers as result text.
                        // Prefer the innermost wrapper so its text is counted
                        // once instead of once per nested element.
                        .filter((element, _, all) => !all.some((other) =>
                            other !== element && element.contains(other) &&
                            textOf(other) === textOf(element)
                        ));
                    const result = results.find((element) => textOf(element)) || results[0];
                    if (!result) return;
                    const resultHost = result.closest(".QcsUad") || result.parentElement;
                    const resultToolbar = resultHost.querySelector(".VO9ucd");
                    const node = countNode(resultHost, "result", resultToolbar);
                    if (node) node.textContent = countText(textOf(result));
                };

                const ensureSourceToolbarButtons = () => {
                    const toolbar = document.querySelector(".xMmqsf");
                    const resultToolbar = document.querySelector(".QcsUad .VO9ucd");
                    if (!toolbar || !resultToolbar) return;

                    const resultCopyButton = Array.from(
                        resultToolbar.querySelectorAll("button")
                    ).find((button) => copyActionPattern.test(controlLabel(button)));
                    if (!resultCopyButton) return;

                    let slot = document.getElementById("mac-translate-source-copy-slot");
                    const existingButton = document.getElementById("mac-translate-source-copy");
                    const existingClear = document.getElementById("mac-translate-source-clear");
                    if (slot && slot.parentElement === toolbar && existingButton && existingClear) return;
                    if (slot) slot.remove();
                    document.getElementById("mac-translate-source-clear-slot")?.remove();

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

                    const clearSlot = document.createElement("div");
                    clearSlot.id = "mac-translate-source-clear-slot";
                    clearSlot.style.setProperty("height", "48px", "important");
                    clearSlot.style.setProperty("flex", "0 0 auto", "important");
                    clearSlot.style.setProperty("display", "flex", "important");
                    clearSlot.style.setProperty("align-items", "center", "important");
                    const clearButton = button.cloneNode(false);
                    clearButton.id = "mac-translate-source-clear";
                    clearButton.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22"
                        aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"
                        stroke-linecap="round" stroke-linejoin="round">
                        <path d="M3 6h18"></path><path d="M8 6V4h8v2"></path>
                        <path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path>
                        <path d="M14 10v6"></path></svg>`;
                    clearButton.setAttribute("aria-label", "\#(sourceClearLabel)");
                    clearButton.setAttribute("title", "\#(sourceClearLabel)");
                    clearButton.style.setProperty("width", "48px", "important");
                    clearButton.style.setProperty("min-width", "48px", "important");
                    clearButton.style.setProperty("padding", "0", "important");
                    clearSlot.appendChild(clearButton);
                    toolbar.prepend(clearSlot, slot);
                };

                const swapControlPattern = /^(?:交换源语言和目标语言|swap source and target languages?)/i;

                const ensureCustomSwapButton = () => {
                    const original = Array.from(document.querySelectorAll(
                        'button[aria-label], [role="button"][aria-label]'
                    )).find((element) =>
                        element.id !== "mac-translate-custom-swap" &&
                        swapControlPattern.test(controlLabel(element))
                    );
                    if (!original) return;

                    const rect = original.getBoundingClientRect();
                    if (!rect.width || !rect.height) return;
                    original.style.setProperty("visibility", "hidden", "important");

                    let button = document.getElementById("mac-translate-custom-swap");
                    if (!button) {
                        button = document.createElement("button");
                        button.id = "mac-translate-custom-swap";
                        button.type = "button";
                        button.textContent = "⇄";
                        button.setAttribute("aria-label", "\#(swapLanguagesLabel)");
                        button.setAttribute("title", "\#(swapLanguagesLabel)");
                        button.style.cssText = [
                            "position:fixed", "z-index:10002", "display:flex",
                            "align-items:center", "justify-content:center",
                            "border:0", "border-radius:8px", "padding:0",
                            "background:transparent", "color:inherit", "cursor:pointer",
                            "font:600 31px/1 -apple-system, BlinkMacSystemFont, sans-serif"
                        ].join(" !important;") + " !important;";
                        document.body.appendChild(button);
                    }
                    button.style.setProperty("left", `${rect.left}px`, "important");
                    button.style.setProperty("top", `${rect.top}px`, "important");
                    button.style.setProperty("width", `${rect.width}px`, "important");
                    button.style.setProperty("height", `${rect.height}px`, "important");
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
                        if (child !== actionGroup && !child.contains(copyControl) &&
                            !child.classList.contains("mac-translate-text-count")) {
                            hide(child);
                        }
                    });
                    toolbar.style.setProperty("justify-content", "flex-end", "important");
                    toolbar.setAttribute("data-mac-translate-actions-ready", "1");
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
                        // This is Google's floating hover hint for the swap
                        // button. Recent layouts duplicate its text in nested
                        // absolutely positioned nodes, so hiding only a
                        // standard role=tooltip is not sufficient.
                        if (isLanguageSwapHint(text) && element.tagName !== "BUTTON") {
                            const style = getComputedStyle(element);
                            if (element.getAttribute("role") === "tooltip" ||
                                style.position === "absolute" || style.position === "fixed" ||
                                element.children.length <= 2) {
                                hide(element);
                                return;
                            }
                        }
                        if ((isSidebarTranslationHint(text) || isLongTextLimitNotice(text)) &&
                            (element.children.length <= 3 ||
                             element.matches('[role="alert"], [role="dialog"]'))) {
                            hide(element.closest('[role="alert"], [role="dialog"]') || element);
                            return;
                        }
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
                        ensureSourceToolbarButtons();
                        keepOnlyResultCopyButton();
                    }

                    ensureCustomSwapButton();

                    updateTextCounts();

                };

                var cleanupScheduled = false;
                var cleanupTimer = null;
                const scheduleCleanup = (delay = 160) => {
                    if (cleanupTimer) clearTimeout(cleanupTimer);
                    cleanupScheduled = true;
                    cleanupTimer = setTimeout(() => {
                        cleanupTimer = null;
                        cleanupScheduled = false;
                        cleanup();
                    }, delay);
                };
                window.__macTranslateScheduleCleanup = scheduleCleanup;

                if (!window.__macTranslateInstalled) {
                    window.__macTranslateInstalled = true;
                    // Google changes many DOM nodes for every individual
                    // keystroke.  Watching style/class changes made this
                    // custom cleanup scan the entire page repeatedly while
                    // typing. New UI (results, pinyin and selection bars)
                    // still arrives as child nodes, so observe only those
                    // and coalesce the work after the page settles.
                    const observer = new MutationObserver((records) => {
                        let resultToolbarChanged = false;
                        for (const record of records) {
                            for (const node of record.addedNodes) {
                                const element = node.nodeType === Node.ELEMENT_NODE
                                    ? node
                                    : node.parentElement;
                                const toolbar = element && (
                                    element.matches?.(".QcsUad .VO9ucd")
                                        ? element
                                        : element.closest?.(".QcsUad .VO9ucd")
                                );
                                if (toolbar) {
                                    // This synchronous, local operation runs
                                    // before a frame is painted. It prevents
                                    // Google's G action from flashing while
                                    // avoiding the expensive full-page scan.
                                    toolbar.setAttribute("data-mac-translate-actions-ready", "0");
                                    resultToolbarChanged = true;
                                }
                            }
                        }
                        scheduleCleanup(resultToolbarChanged ? 50 : 240);
                    });
                    observer.observe(document.documentElement, {
                        childList: true,
                        subtree: true
                    });

                    // Google attaches a click action to .ryNqvb/.jCAhz that
                    // opens the overlapping word-by-word panel.  Block only
                    // that action; native mouse dragging and text selection
                    // remain untouched because mousedown is not cancelled.
                    const blockResultClick = (event) => {
                        const target = event.target;
                        const element = target && target.closest ? target : null;
                        if (!element) return;

                        // Result toolbars can be nested inside the result text
                        // container. Let their native actions receive the
                        // click instead of treating the button as a text
                        // click that opens Google's word-by-word panel.
                        if (element.closest(
                            'button, a, [role="button"], input, select, textarea'
                        )) return;

                        const detail = element.closest(detailSelector);
                        const result = element.closest(resultTextSelector);
                        if (detail || result) {
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            scheduleCleanup(40);
                        }
                    };

                    document.addEventListener("click", blockResultClick, true);
                    document.addEventListener("dblclick", blockResultClick, true);
                    document.addEventListener("selectionchange", () => scheduleCleanup(40), true);
                    // Do not scan Google's complete page on every typed
                    // character. Pasting remains immediate because its DOM
                    // update is handled by the child-node observer above.
                    document.addEventListener("input", (event) => {
                        const target = event.target;
                        if (target instanceof HTMLTextAreaElement) {
                            updateTextCounts();
                        }
                        scheduleCleanup(320);
                    }, true);

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
        """#
    }
}
