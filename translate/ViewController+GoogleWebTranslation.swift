//
//  ViewController+GoogleWebTranslation.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func translateLongTextChunkUsingGoogleWeb(
        _ chunk: String,
        session: Int
    ) {
        guard session == translationCoordinator.session else { return }
        logTextPipelineSnapshot("3-before-webview-submission", chunk)
        guard let serviceWebView = activeTranslationWebView else {
            translateLongTextChunkUsingAPI(chunk, session: session)
            return
        }
        let encodingStartedAt = CACurrentMediaTime()
        let encoded = Data(chunk.utf8).base64EncodedString()
        logTranslationTiming(
            "text-encoding-completed",
            details: String(format: "duration_ms=%.3f", (CACurrentMediaTime() - encodingStartedAt) * 1_000)
        )
        let serviceGeneration = translationCoordinator.activeWebViewGeneration
        let timingRequestID = translationTimingRequest?.id ?? 0
        let evaluationStartedAt = CACurrentMediaTime()
        logTranslationTiming("evaluate-javascript-started")

        serviceWebView.evaluateJavaScript(#"""
            (() => {
                const jsStartedAt = performance.now();
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;
                window.__macTranslateActiveTiming = {
                    requestID: \#(timingRequestID),
                    session: \#(session),
                    jsStartedAt,
                    firstResultMutationAt: null
                };
                const value = new TextDecoder().decode(
                    Uint8Array.from(atob("\#(encoded)"), (character) =>
                        character.charCodeAt(0))
                );
                const inputAlreadyCurrent = textarea.value === value;
                window.__macTranslateReadCurrentResult = () => {
                    const extractable = (element) => {
                        const style = getComputedStyle(element);
                        const rect = element.getBoundingClientRect();
                        // The native long-text workspace intentionally hides
                        // Google's result host with `visibility: hidden`.
                        // Visibility is inherited, so treating it as a
                        // readability requirement made every long WebView
                        // result look empty and forced the API deadline path.
                        // A node with layout and without display:none is still
                        // safe to extract; explicitly removed UI is filtered
                        // below by its known non-result containers.
                        return style.display !== "none" &&
                            rect.width > 0 && rect.height > 0;
                    };
                    // Google reuses .ryNqvb for dictionary alternatives.
                    // Prefer the main translation wrappers first and only
                    // fall back to the generic word nodes when no wrapper is
                    // present. This prevents synonyms from being concatenated
                    // into an ordinary translation.
                    // Google renders dictionary alternatives in additional
                    // .QcsUad cards. Restrict extraction to the main result
                    // card so entries such as “不是” do not become
                    // “no blame”. Keep all text nodes inside that one card so
                    // multi-segment sentence and long-text results stay whole.
                    const resultRoot = document.querySelector(".QcsUad.sMVRZe") ||
                        document.querySelector(".QcsUad:not(.FkMbO)") ||
                        document.querySelector(".QcsUad");
                    const resultGroups = [
                        // W297wb/ryNqvb are Google's actual translated text
                        // nodes. HwtZe is an outer responsive container and
                        // can also contain a duplicate rendering layer plus
                        // dictionary details for longer input.
                        "[jsname=\"W297wb\"]",
                        ".ryNqvb",
                        ".jCAhz",
                        ".lRu31",
                        ".HwtZe"
                    ];
                    let nodes = [];
                    for (const selector of resultGroups) {
                        nodes = resultRoot
                            ? Array.from(resultRoot.querySelectorAll(selector)).filter(extractable)
                            : [];
                        if (nodes.length) break;
                    }
                    const candidates = nodes.filter((element) =>
                        extractable(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c")
                    );
                    const textGroups = [];
                    const groupIndexByHost = new Map();
                    for (const element of candidates) {
                        const text = (element.innerText || element.textContent || "").trim();
                        if (!text) continue;
                        // Ignore an outer accessibility/responsive wrapper
                        // when a descendant exposes the same translated text.
                        const duplicatesDescendant = candidates.some((other) =>
                            other !== element && element.contains(other) &&
                            (other.innerText || other.textContent || "").trim() === text
                        );
                        if (duplicatesDescendant) continue;
                        // Google places all translated sentence nodes for one
                        // source paragraph in the same HwtZe result block.
                        // Preserve that block boundary instead of flattening
                        // every node with a space (which erased a single
                        // Return), while still joining sentence fragments
                        // inside the same paragraph naturally.
                        const host = element.closest(".HwtZe") || element.parentElement;
                        let groupIndex = groupIndexByHost.get(host);
                        if (groupIndex === undefined) {
                            groupIndex = textGroups.length;
                            groupIndexByHost.set(host, groupIndex);
                            textGroups.push([]);
                        }
                        if (!textGroups[groupIndex].includes(text)) {
                            textGroups[groupIndex].push(text);
                        }
                    }
                    const texts = textGroups
                        .map((group, index) => {
                            const host = Array.from(groupIndexByHost.keys())
                                .find((candidate) => groupIndexByHost.get(candidate) === index);
                            // innerText on the concrete translation block is
                            // the only Google value that retains explicit
                            // source Returns. This is safe here because `host`
                            // comes from an already accepted W297wb/ryNqvb
                            // translation node, not from a global HwtZe scan.
                            const hostText = host?.matches?.(".HwtZe")
                                ? (host.innerText || "").trim()
                                : "";
                            return hostText || group.join(" ").trim();
                        })
                        .filter((text, index, all) => Boolean(text) && all.indexOf(text) === index);
                    const source = document.querySelector("textarea")?.value || "";
                    const trimmedSource = source.trim();
                    const latinWord = /^[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’\-][A-Za-zÀ-ÖØ-öø-ÿ]+)*$/
                        .test(trimmedSource);
                    const containsCJK = /[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]/
                        .test(trimmedSource);
                    // A single CJK character can safely use Google's primary
                    // dictionary meaning. Never extend this heuristic to two
                    // or more characters: short phrases such as “是这样吗”
                    // and “貌似还行” must retain their complete translation.
                    const singleCJKCharacter = containsCJK &&
                        Array.from(trimmedSource).length === 1;
                    const translation = (latinWord && !containsCJK) ||
                        singleCJKCharacter
                        ? (texts[0] || "").split(/\s+/).filter(Boolean)[0] || ""
                        : texts.join("\n");
                    if (window.__macTranslateWaitForDifferentResult &&
                        translation === window.__macTranslateBlockedTranslation) {
                        return [source, ""];
                    }
                    if (translation) {
                        window.__macTranslateWaitForDifferentResult = false;
                    }
                    return [source, translation];
                };
                // Snapshot the old result with the exact same parser used for
                // the eventual result.  The earlier implementation collected
                // every matching selector here but used only the first
                // preferred result group later. Those two strings could
                // differ, allowing the still-visible old translation through.
                if (!inputAlreadyCurrent) {
                    window.__macTranslateWaitForDifferentResult = false;
                    const previousPayload = window.__macTranslateReadCurrentResult();
                    window.__macTranslateBlockedTranslation = previousPayload?.[1] || "";
                    window.__macTranslateWaitForDifferentResult =
                        Boolean(window.__macTranslateBlockedTranslation);
                }
                window.__macTranslateResultObserver?.disconnect();
                clearTimeout(window.__macTranslateResultNotificationTimer);
                const notifyResultChanged = (records) => {
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
                    clearTimeout(window.__macTranslateResultNotificationTimer);
                    window.__macTranslateResultNotificationTimer = setTimeout(() => {
                        // Mutations inside Google's translation card are not
                        // proof that the result belongs to the new source: the
                        // input replacement itself also mutates this subtree.
                        // Keep blocking the baseline until the parsed result
                        // really changes. If the correct new translation is
                        // legitimately identical, the current request's API
                        // fallback will resolve it without exposing stale DOM.
                        const payload = window.__macTranslateReadCurrentResult?.();
                        if (!payload || !payload[1]) return;
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translationDOMResult",
                            session: \#(session),
                            chunkIndex: \#(translationCoordinator.chunkIndex),
                            serviceGeneration: \#(serviceGeneration),
                            source: payload[0],
                            translation: payload[1],
                            jsElapsedMS: performance.now() - jsStartedAt,
                            firstMutationMS: window.__macTranslateActiveTiming?.firstResultMutationAt == null
                                ? -1
                                : window.__macTranslateActiveTiming.firstResultMutationAt - jsStartedAt
                        });
                    }, 45);
                };
                window.__macTranslateResultObserver = new MutationObserver(
                    notifyResultChanged
                );
                window.__macTranslateResultObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                const observerReadyAt = performance.now();
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;

                if (!inputAlreadyCurrent) {
                    // Behave like direct typing in the original Google-DOM
                    // version. Replacing the value once is sufficient;
                    // clearing it first starts a second Google translation
                    // cycle and materially delays short translations.
                    setter.call(textarea, value);
                    const textareaWrittenAt = performance.now();
                    textarea.dispatchEvent(new Event("input", { bubbles: true }));
                    const inputDispatchedAt = performance.now();
                    window.webkit.messageHandlers.callbackHandler.postMessage({
                        action: "translationTimingJS",
                        requestID: \#(timingRequestID),
                        session: \#(session),
                        milestone: "injection-completed",
                        observerReadyMS: observerReadyAt - jsStartedAt,
                        textareaWrittenMS: textareaWrittenAt - jsStartedAt,
                        inputDispatchedMS: inputDispatchedAt - jsStartedAt
                    });
                } else {
                    // The result may have completed before this observer was
                    // installed. Deliver it immediately instead of waiting
                    // for another mutation or polling interval.
                    setTimeout(() => {
                        const payload = window.__macTranslateReadCurrentResult?.();
                        if (!payload || !payload[1]) return;
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translationDOMResult",
                            session: \#(session),
                            chunkIndex: \#(translationCoordinator.chunkIndex),
                            serviceGeneration: \#(serviceGeneration),
                            source: payload[0],
                            translation: payload[1],
                            jsElapsedMS: performance.now() - jsStartedAt,
                            firstMutationMS: window.__macTranslateActiveTiming?.firstResultMutationAt == null
                                ? -1
                                : window.__macTranslateActiveTiming.firstResultMutationAt - jsStartedAt
                        });
                    }, 0);
                }
                return [textarea.value, {
                    jsStartedMS: jsStartedAt,
                    completionMS: performance.now() - jsStartedAt
                }];
            })();
        """#) { [weak self] result, _ in
            guard let self,
                  session == self.translationCoordinator.session,
                  self.translationCoordinator.activeWebViewGeneration == serviceGeneration,
                  self.activeTranslationWebView === serviceWebView else { return }
            self.logTranslationTiming(
                "evaluate-javascript-completion",
                details: String(format: "swift_duration_ms=%.3f", (CACurrentMediaTime() - evaluationStartedAt) * 1_000)
            )
            let resultPayload = result as? [Any]
            let returnedSource = resultPayload?.first as? String
            logTextPipelineSnapshot("4-google-textarea-after-write", returnedSource)
            if !self.didLogFirstTextInjection,
               let injectedSource = returnedSource,
               injectedSource == chunk {
                self.didLogFirstTextInjection = true
                self.logStartupTiming("First text injection completed")
            }
            // The synchronous JavaScript result is merely an acknowledgement
            // of the textarea write. WebKit can occasionally return nil or
            // normalize the value while Google has already accepted the
            // input and begun updating its result DOM. Falling back here
            // discarded those valid WebView translations within a few
            // milliseconds, especially for long pasted text. Let the normal
            // source-verified poll decide instead; it still falls back at the
            // existing Web deadline when the input genuinely did not land.
            guard returnedSource == chunk else {
                self.logTranslationTiming("web-submission-awaiting-poll")
                self.scheduleLongTextPoll(session: session)
                return
            }
            self.translationCoordinator.pollAttempts = 0
            self.translationCoordinator.candidateTranslation = nil
            self.translationCoordinator.candidateUpdatedAt = nil
            self.pollLongTextTranslation(session: session)
        }
    }
}
