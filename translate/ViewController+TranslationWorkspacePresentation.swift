//
//  ViewController+TranslationWorkspacePresentation.swift
//  translate
//

import Cocoa

extension ViewController {
    func activateInlineLongText(source: String) {
        let encodedSource = Data(source.utf8).base64EncodedString()
        let sourceClearLabel = interfaceText("清除", "Clear")
        let sourceLanguageTitle = currentSourceLanguage.title
        let targetLanguageTitle = currentTargetLanguage.title
        let swapLanguagesLabel = interfaceText("交换语言", "Swap languages")
        webView.evaluateJavaScript(#"""
            (() => {
                const decode = (encoded) => new TextDecoder().decode(
                    Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0))
                );
                const source = decode("\#(encodedSource)");
                const id = "mac-translate-inline-long-text";
                const styleId = "mac-translate-inline-long-text-style";
                let state = window.__macTranslateInlineLongText;

                if (!state) {
                    const textarea = document.querySelector("textarea.er8xn, textarea");
                    const sourceHost = textarea?.closest(".QFw9Te") || textarea?.parentElement;
                    // Google's result host class changes across compact and
                    // wide layouts. The app-owned workspace no longer needs
                    // that host; only an editable source is required.
                    const resultHost = document.querySelector(".QcsUad");
                    if (!textarea) return false;

                    let style = document.getElementById(styleId);
                    if (!style) {
                        style = document.createElement("style");
                        style.id = styleId;
                        style.textContent = `
                            #${id} {
                                position: fixed; inset: 0; z-index: 10000; display: grid;
                                grid-template-rows: 58px minmax(0, 1fr);
                                overflow: hidden; pointer-events: auto;
                                background: rgba(246,246,246,.88) !important;
                                backdrop-filter: blur(22px);
                            }
                            #${id} .mac-inline-header {
                                display: grid; grid-template-columns: minmax(0,1fr) 54px minmax(0,1fr);
                                align-items: center; padding: 0 14px; border-bottom: 1px solid rgba(0,0,0,.08);
                            }
                            #${id} .mac-inline-language, #${id} .mac-inline-swap {
                                appearance: none; border: 0; background: transparent !important;
                                color: inherit; cursor: pointer; font: 600 17px/24px -apple-system, BlinkMacSystemFont, sans-serif;
                                padding: 7px 10px; border-radius: 8px;
                            }
                            #${id} .mac-inline-language:first-child { justify-self: start; }
                            #${id} .mac-inline-language:last-child { justify-self: end; }
                            #${id} .mac-inline-swap { font-size: 25px; justify-self: center; }
                            #${id} .mac-inline-panes { display: flex; min-height: 0; gap: 1px; }
                            #${id} .mac-inline-pane {
                                display: flex; flex: 1 1 0; height: 100%;
                                min-width: 0; min-height: 0;
                                flex-direction: column; pointer-events: auto;
                                background: transparent !important;
                            }
                            #${id} .mac-inline-editor, #${id} .mac-inline-result {
                                flex: 1; min-height: 0; overflow: auto; padding: 16px 18px;
                                font: 18px/28px -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif;
                                color: var(--translate-text-color, #000); white-space: pre-wrap;
                                overflow-wrap: anywhere; outline: none;
                            }
                            #${id} .mac-inline-editor { cursor: text; }
                            #${id} .mac-inline-footer {
                                display: flex; flex: 0 0 34px; align-items: center;
                                margin-top: auto; gap: 8px; padding: 0 10px 2px;
                                color: rgba(60,64,67,.75);
                                font: 12px/16px -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif;
                                font-variant-numeric: tabular-nums;
                            }
                            #${id} .mac-inline-count { margin-left: auto; text-align: right; }
                            #${id} .mac-inline-copy, #${id} .mac-inline-clear {
                                appearance: none; border: 0; border-radius: 7px; padding: 4px 7px;
                                color: inherit; background: transparent !important; cursor: pointer;
                                font: inherit;
                            }
                            @media (prefers-color-scheme: dark) {
                                #${id} { background: rgba(30,30,30,.88) !important; }
                                #${id} .mac-inline-header { border-color: rgba(255,255,255,.12); }
                                #${id} .mac-inline-footer { color: rgba(255,255,255,.68); }
                            }
                        `;
                        (document.head || document.documentElement).appendChild(style);
                    }

                    const root = document.createElement("div");
                    root.id = id;
                    const header = document.createElement("div");
                    header.className = "mac-inline-header";
                    const sourceLanguage = document.createElement("button");
                    sourceLanguage.className = "mac-inline-language";
                    sourceLanguage.type = "button";
                    sourceLanguage.textContent = "\#(sourceLanguageTitle)";
                    const swap = document.createElement("button");
                    swap.className = "mac-inline-swap";
                    swap.type = "button";
                    swap.textContent = "⇄";
                    swap.setAttribute("aria-label", "\#(swapLanguagesLabel)");
                    const targetLanguage = document.createElement("button");
                    targetLanguage.className = "mac-inline-language";
                    targetLanguage.type = "button";
                    targetLanguage.textContent = "\#(targetLanguageTitle)";
                    const showPicker = (side, button) => {
                        const rect = button.getBoundingClientRect();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "showLanguagePicker", side,
                            x: rect.left + rect.width / 2, y: rect.bottom
                        });
                    };
                    sourceLanguage.addEventListener("click", () => showPicker("source", sourceLanguage));
                    targetLanguage.addEventListener("click", () => showPicker("target", targetLanguage));
                    swap.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({ action: "swapLanguages" });
                    });
                    header.append(sourceLanguage, swap, targetLanguage);
                    const makePane = (editable) => {
                        const pane = document.createElement("section");
                        pane.className = "mac-inline-pane";
                        const text = document.createElement("div");
                        text.className = editable ? "mac-inline-editor" : "mac-inline-result";
                        text.contentEditable = editable ? "true" : "false";
                        text.tabIndex = 0;
                        text.spellcheck = editable;
                        const footer = document.createElement("div");
                        footer.className = "mac-inline-footer";
                        const status = document.createElement("span");
                        const copy = document.createElement("button");
                        copy.className = "mac-inline-copy";
                        copy.type = "button";
                        copy.textContent = "复制";
                        const clear = document.createElement("button");
                        clear.className = "mac-inline-clear";
                        clear.type = "button";
                        clear.innerHTML = `<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"
                            fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                            <path d="M3 6h18"></path><path d="M8 6V4h8v2"></path><path d="M6 6l1 14h10l1-14"></path>
                            <path d="M10 10v6"></path><path d="M14 10v6"></path></svg>`;
                        clear.setAttribute("aria-label", "\#(sourceClearLabel)");
                        clear.setAttribute("title", "\#(sourceClearLabel)");
                        const count = document.createElement("span");
                        count.className = "mac-inline-count";
                        if (editable) {
                            footer.append(status, clear, copy, count);
                        } else {
                            footer.append(status, copy, count);
                        }
                        pane.append(text, footer);
                        return { pane, text, status, copy, clear, count };
                    };
                    const left = makePane(true);
                    const right = makePane(false);
                    left.status.textContent = "原文";
                    right.status.textContent = "译文";
                    left.copy.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "copySource", text: left.text.innerText
                        });
                    });
                    left.clear.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "clearSource"
                        });
                    });
                    right.copy.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "copyTranslation", text: right.text.innerText
                        });
                    });
                    let typingTimer;
                    left.text.addEventListener("input", () => {
                        const text = left.text.innerText.replace(/\n$/, "");
                        clearTimeout(typingTimer);
                        typingTimer = setTimeout(() => {
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "updateLongText", text
                            });
                        }, 160);
                    });
                    const panes = document.createElement("div");
                    panes.className = "mac-inline-panes";
                    panes.append(left.pane, right.pane);
                    root.append(header, panes);
                    document.body.appendChild(root);
                    sourceHost?.style.setProperty("visibility", "hidden", "important");
                    resultHost?.style.setProperty("visibility", "hidden", "important");

                    const isHan = (character) => /[\u3400-\u9fff\uf900-\ufaff]/.test(character);
                    const describe = (text) => {
                        const han = (text.match(/[\u3400-\u9fff\uf900-\ufaff]/g) || []).length;
                        const nonHan = text.replace(/[\u3400-\u9fff\uf900-\ufaff]/g, " ");
                        const words = (nonHan.match(/[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*/gu) || []).length;
                        const values = [];
                        if (words) values.push(`单词 ${words}`);
                        if (han) values.push(`汉字 ${han}`);
                        return values.join(" · ") || "单词 0";
                    };
                    state = window.__macTranslateInlineLongText = {
                        root, left, right, sourceLanguage, targetLanguage, describe,
                        close: () => {
                            root.remove();
                            sourceHost?.style.removeProperty("visibility");
                            resultHost?.style.removeProperty("visibility");
                            window.__macTranslateInlineLongText = null;
                        }
                    };
                }

                state.sourceLanguage.textContent = "\#(sourceLanguageTitle)";
                state.targetLanguage.textContent = "\#(targetLanguageTitle)";
                state.left.text.innerText = source;
                state.left.count.textContent = state.describe(source);
                state.right.text.innerText = "";
                state.right.count.textContent = "单词 0";
                state.right.status.textContent = "正在准备翻译…";
                return true;
            })();
        """#) { _, _ in }
    }

    func updateInlineLongText(source: String?, translation: String, status: String) {
        translationPipelineLogger.info(
            "Final displayed translation (inline workspace): chars=\(translation.count, privacy: .public)"
        )
        let encodedSource = source.map { Data($0.utf8).base64EncodedString() } ?? ""
        let encodedTranslation = Data(translation.utf8).base64EncodedString()
        let encodedStatus = Data(status.utf8).base64EncodedString()
        let hasSource = source == nil ? "false" : "true"
        webView.evaluateJavaScript(#"""
            (() => {
                const state = window.__macTranslateInlineLongText;
                if (!state) return;
                const decode = (encoded) => new TextDecoder().decode(
                    Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0))
                );
                if (\#(hasSource)) {
                    state.left.text.innerText = decode("\#(encodedSource)");
                    state.left.count.textContent = state.describe(state.left.text.innerText);
                }
                state.right.text.innerText = decode("\#(encodedTranslation)");
                state.right.count.textContent = state.describe(state.right.text.innerText);
                state.right.status.textContent = decode("\#(encodedStatus)");
            })();
        """#, completionHandler: nil)
    }

    func returnToNormalTranslation(_ source: String) {
        translationCoordinator.debounceWorkItem?.cancel()
        translationCoordinator.session += 1
        longTextSource = nil
        longTextTranslation = ""
        translationResultProviders.removeAll()
        completedTranslationResultProviders.removeAll()
        translationCoordinator.chunks = []
        translationCoordinator.chunkIndex = 0
        let encoded = Data(source.utf8).base64EncodedString()
        webView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateInlineLongText?.close();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const value = new TextDecoder().decode(Uint8Array.from(
                    atob("\#(encoded)"), (character) => character.charCodeAt(0)
                ));
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype, "value"
                ).set;
                setter.call(textarea, value);
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)
    }

    @objc func closeLongTextMode() {
        stopSpeaking()
        invalidateAlignmentPresentation()
        translationCoordinator.debounceWorkItem?.cancel()
        translationCoordinator.session += 1
        longTextOverlay?.isHidden = true
        longTextSource = nil
        longTextTranslation = ""
        translationResultProviders.removeAll()
        completedTranslationResultProviders.removeAll()
        translationCoordinator.clearCompletedSnapshot()
        translationCoordinator.clearTranslationBuffers()
        setLongTextStatus(.idle)
        webView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateInlineLongText?.close();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype, "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)
        focusAndSelectField()
    }

    func updateLongTextLabels() {
        guard let source = longTextSource else {
            longTextStatusLabel?.stringValue = ""
            let emptyCount = textCountDescription("")
            workspaceSourceCountLabel?.stringValue = emptyCount
            workspaceTranslationCountLabel?.stringValue = emptyCount
            longTextSourceLabel?.stringValue = emptyCount
            longTextTranslationLabel?.stringValue = emptyCount
            updatePronunciationLabels(source: "", translation: "")
            refreshWorkspaceLanguageTitles()
            return
        }
        refreshWorkspaceLanguageTitles()
        longTextStatusLabel?.stringValue = longTextStatusText()
        let sourceCount = textCountDescription(source)
        let translationCount = textCountDescription(longTextTranslation)
        workspaceSourceCountLabel?.stringValue = sourceCount
        workspaceTranslationCountLabel?.stringValue = translationCount
        longTextSourceLabel?.stringValue = sourceCount
        longTextTranslationLabel?.stringValue = translationCount
        updatePronunciationLabels(source: source, translation: longTextTranslation)
    }

    @discardableResult
    func setLongTextStatus(_ state: LongTextStatusState) -> String {
        longTextStatusState = state
        // Never offer a long-text swap while its Google result is still
        // being assembled. The completed snapshot is the only valid source
        // for a reverse translation.
        workspaceSwapButton?.isEnabled = currentSourceLanguage != .automatic &&
            (longTextSource == nil ||
                (state == .completed && !translationCoordinator.completedTranslation.isEmpty))
        let text = longTextStatusText()
        longTextStatusLabel?.stringValue = text
        return text
    }

    func longTextStatusText() -> String {
        switch longTextStatusState {
        case .idle:
            return ""
        case .preparing:
            return interfaceText("正在准备翻译…", "Preparing translation…")
        case .translating:
            guard translationCoordinator.chunks.count > 1 else {
                return interfaceText("正在翻译…", "Translating…")
            }
            return interfaceText(
                "正在翻译第 \(translationCoordinator.chunkIndex + 1) / \(translationCoordinator.chunks.count) 段…",
                "Translating part \(translationCoordinator.chunkIndex + 1) of \(translationCoordinator.chunks.count)…"
            )
        case .completed:
            let completion = translationCoordinator.chunks.count > 1
                ? interfaceText("长文本翻译完成", "Long-text translation complete")
                : interfaceText("翻译完成", "Translation complete")
            guard let provider = translationProviderStatusText() else {
                return completion
            }
            return "\(completion) · \(provider)"
        case .failed:
            return interfaceText(
                "部分内容未能完成翻译；请重试。",
                "Some content could not be translated. Please try again."
            )
        }
    }

    func translationProviderStatusText() -> String? {
        let usedWeb = translationResultProviders.contains(.web)
        let usedAPI = translationResultProviders.contains(.api)
        switch (usedWeb, usedAPI) {
        case (true, true):
            return interfaceText("Web + API 翻译", "Web + API translation")
        case (true, false):
            return interfaceText("Web 翻译", "Web translation")
        case (false, true):
            return interfaceText("API 翻译", "API translation")
        case (false, false):
            return nil
        }
    }

    func refreshWorkspaceLanguageTitles() {
        setWorkspaceLanguageTitle(workspaceSourceLanguageButton, language: currentSourceLanguage)
        setWorkspaceLanguageTitle(workspaceTargetLanguageButton, language: currentTargetLanguage)
        let color = isDarkMode ? NSColor.white : NSColor.labelColor
        workspaceSwapButton?.attributedTitle = NSAttributedString(
            string: "⇄",
            attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: color
            ]
        )
    }

    func setWorkspaceLanguageTitle(_ button: NSButton?, language: TranslateLanguage) {
        button?.attributedTitle = NSAttributedString(
            string: language.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: isDarkMode ? NSColor.white : NSColor.labelColor
            ]
        )
    }

}
