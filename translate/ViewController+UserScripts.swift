//
//  ViewController+UserScripts.swift
//  translate
//

import WebKit

extension ViewController {
        func installUserScripts(on controller: WKUserContentController) {
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
                        //
                        // A replacement paste can also shrink a previously long
                        // source value. Reset the textarea and scrollable parent
                        // positions in that case; otherwise WebKit keeps the old
                        // bottom offset and the new short text appears at its end.
                        const sourceMetrics = new WeakMap();
                        const resetSourceScroll = (textarea) => {
                            const reset = () => {
                                textarea.scrollTop = 0;
                                let parent = textarea.parentElement;
                                for (let level = 0; parent && level < 6; level += 1) {
                                    const style = getComputedStyle(parent);
                                    const canScroll = /auto|scroll/.test(style.overflowY) &&
                                        parent.scrollHeight > parent.clientHeight;
                                    if (canScroll) parent.scrollTop = 0;
                                    parent = parent.parentElement;
                                }
                            };
                            reset();
                            requestAnimationFrame(reset);
                            setTimeout(reset, 0);
                        };

                        document.addEventListener("input", (event) => {
                            const textarea = event.target;
                            if (!(textarea instanceof HTMLTextAreaElement) ||
                                !textarea.matches(
                                    ".er8xn, textarea[role=\"combobox\"][aria-controls=\"kvLWu\"]"
                                )) {
                                return;
                            }

                            const previous = sourceMetrics.get(textarea);
                            textarea.style.removeProperty("height");
                            const scrollHeight = Math.ceil(textarea.scrollHeight);
                            textarea.style.height = `${scrollHeight}px`;

                            if (previous && textarea.value.length < previous.length &&
                                scrollHeight < previous.scrollHeight) {
                                resetSourceScroll(textarea);
                            }
                            sourceMetrics.set(textarea, {
                                length: textarea.value.length,
                                scrollHeight
                            });
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
                            if (target.closest(
                                "#mac-translate-source-copy, #mac-translate-source-clear"
                            )) return null;
                            return {
                                source: target.closest(sourceSelector),
                                result: target.closest(resultSelector)
                            };
                        };

                        document.addEventListener("click", (event) => {
                            const target = event.target;
                            const button = target && target.closest ?
                                target.closest("#mac-translate-custom-swap") : null;
                            if (!button) return;
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "swapLanguages"
                            });
                        }, true);

                        // Replace Google's responsive language wall with the
                        // native searchable picker. The native control avoids
                        // Google’s overlapping labels and hover overlays.
                        const languageControl = (target) => {
                            const control = target && target.closest ? target.closest(
                                'button[aria-label], [role="button"][aria-label]'
                            ) : null;
                            if (!control) return null;
                            const label = (control.getAttribute("aria-label") || "").trim();
                            // Do not match Google's swap control: its label also
                            // contains both “source language” and “target
                            // language”. Only actual language buttons begin with
                            // one of the labels below.
                            return /^(?:源语言|目标语言)(?:[：:\\s]|$)|^(?:Source|Target)\\s+language(?:[：:\\s]|$)/i
                                .test(label) ? control : null;
                        };

                        // Google may begin opening its language wall on press,
                        // before the click handler below runs. Suppress that
                        // early action, while letting the click show the native
                        // picker instead.
                        ["pointerdown", "mousedown"].forEach((type) => {
                            document.addEventListener(type, (event) => {
                                if (!languageControl(event.target)) return;
                                event.preventDefault();
                                event.stopImmediatePropagation();
                            }, true);
                        });

                        document.addEventListener("click", (event) => {
                            const target = event.target;
                            const control = languageControl(target);
                            if (!control) return;
                            const label = control.getAttribute("aria-label") || "";
                            const side = /目标语言|Target language/i.test(label) ? "target" : "source";
                            const rect = control.getBoundingClientRect();
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "showLanguagePicker", side,
                                x: rect.left + rect.width / 2,
                                y: rect.top + rect.height
                            });
                        }, true);

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

                        window.addEventListener("click", (event) => {
                            const target = event.target;
                            const button = target && target.closest ?
                                target.closest("#mac-translate-source-clear") : null;
                            if (!button) return;
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "clearSource"
                            });
                        }, true);

                        // Google Translate truncates its editable field at 5,000
                        // characters. Route a larger paste to native code before
                        // Google's handler sees it; native code translates the
                        // text in safe chunks and presents the complete result.
                        document.addEventListener("paste", (event) => {
                            const target = event.target;
                            const textarea = target && target.closest ?
                                target.closest(sourceSelector) : null;
                            const text = event.clipboardData?.getData("text/plain") || "";
                            if (!textarea || text.length <= 5000) return;
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "translateLongText",
                                text
                            });
                        }, true);

                        // The same handoff must work for normal typing, not only
                        // for a large paste. Intercept the keystroke that would
                        // cross Google's 5,000-character field limit and move
                        // the complete editable value into the inline workspace.
                        document.addEventListener("beforeinput", (event) => {
                            const target = event.target;
                            const textarea = target && target.closest ?
                                target.closest(sourceSelector) : null;
                            if (!textarea || event.inputType === "insertFromPaste") return;
                            const inserted = event.data ??
                                (event.inputType === "insertLineBreak" ? "\n" : "");
                            if (!inserted) return;
                            const start = typeof textarea.selectionStart === "number" ?
                                textarea.selectionStart : textarea.value.length;
                            const end = typeof textarea.selectionEnd === "number" ?
                                textarea.selectionEnd : start;
                            const next = textarea.value.slice(0, start) + inserted +
                                textarea.value.slice(end);
                            if (next.length <= 5000) return;
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "translateLongText",
                                text: next
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
}
