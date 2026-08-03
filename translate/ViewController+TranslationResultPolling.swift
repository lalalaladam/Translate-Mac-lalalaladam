//
//  ViewController+TranslationResultPolling.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
    func pollLongTextTranslation(session: Int) {
        guard session == translationCoordinator.session else { return }
        guard translationCoordinator.chunks.indices.contains(translationCoordinator.chunkIndex) else { return }
        guard translationCoordinator.pollInFlightSession == nil else { return }
        let pollingChunkIndex = translationCoordinator.chunkIndex
        translationCoordinator.scheduledPoll?.cancel()
        translationCoordinator.scheduledPoll = nil
        translationCoordinator.pollAttempts += 1
        guard translationCoordinator.webDeadline.map({ Date() <= $0 }) ?? false else {
            let chunk = translationCoordinator.chunks[translationCoordinator.chunkIndex].text
            finalizeWithAPIFallbackIfNeeded(chunk, session: session)
            return
        }

        let webElapsed = translationCoordinator.webStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if webElapsed >= webStallRecoveryDelay,
           translationCoordinator.candidateTranslation == nil {
            let chunk = translationCoordinator.chunks[translationCoordinator.chunkIndex].text
            previewProvisionalAPITranslationIfReady(session: session)
            if !translationCoordinator.webRetryTriggered,
               retryStalledTranslationOnParallelWebView(chunk, session: session) {
                translationCoordinator.webRetryTriggered = true
                return
            }
            // Do not clear and reinsert the Google textarea here. That retry
            // restarts work already in progress and was the source of the
            // post-paste slowdown seen in the 20260802.174704 logs.
            if !translationCoordinator.provisionalFallbackStarted {
                translationCoordinator.provisionalFallbackStarted = true
                translateLongTextChunkUsingAPI(
                    chunk,
                    session: session,
                    provisional: true
                )
            }
        }

        translationCoordinator.pollInFlightSession = session
        guard let serviceWebView = activeTranslationWebView else {
            translationCoordinator.pollInFlightSession = nil
            translateLongTextChunkUsingAPI(
                translationCoordinator.chunks[translationCoordinator.chunkIndex].text,
                session: session
            )
            return
        }
        let serviceGeneration = translationCoordinator.activeWebViewGeneration
        let extractionStartedAt = CACurrentMediaTime()
        if translationTimingRequest?.didLogExtractionStart == false {
            translationTimingRequest?.didLogExtractionStart = true
            logTranslationTiming("swift-result-extraction-started")
        }
        serviceWebView.evaluateJavaScript(#"""
            (() => {
                const selectors = [
                    ".QcsUad .ryNqvb",
                    ".QcsUad .HwtZe",
                    ".QcsUad .jCAhz",
                    ".QcsUad .lRu31",
                    ".QcsUad [jsname=\"W297wb\"]"
                ].join(",");
                const extractable = (element) => {
                    const style = getComputedStyle(element);
                    const rect = element.getBoundingClientRect();
                    // The app-owned long-text workspace hides Google's
                    // result host via inherited visibility.  That must not
                    // suppress extraction from the background service DOM.
                    return style.display !== "none" &&
                        rect.width > 0 && rect.height > 0;
                };
                const resultRoot = document.querySelector(".QcsUad.sMVRZe") ||
                    document.querySelector(".QcsUad:not(.FkMbO)") ||
                    document.querySelector(".QcsUad");
                const resultGroups = [
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
                const candidates = nodes
                    .filter((element) => extractable(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c"));
                const candidateTextGroups = [];
                const groupIndexByHost = new Map();
                for (const element of candidates) {
                    const text = (element.innerText || element.textContent || "").trim();
                    if (!text) continue;
                    const duplicatesDescendant = candidates.some((other) =>
                        other !== element && element.contains(other) &&
                        (other.innerText || other.textContent || "").trim() === text
                    );
                    if (duplicatesDescendant) continue;
                    const host = element.closest(".HwtZe") || element.parentElement;
                    let groupIndex = groupIndexByHost.get(host);
                    if (groupIndex === undefined) {
                        groupIndex = candidateTextGroups.length;
                        groupIndexByHost.set(host, groupIndex);
                        candidateTextGroups.push([]);
                    }
                    if (!candidateTextGroups[groupIndex].includes(text)) {
                        candidateTextGroups[groupIndex].push(text);
                    }
                }
                const candidateTexts = candidateTextGroups
                    .map((group, index) => {
                        const host = Array.from(groupIndexByHost.keys())
                            .find((candidate) => groupIndexByHost.get(candidate) === index);
                        const hostText = host?.matches?.(".HwtZe")
                            ? (host.innerText || "").trim()
                            : "";
                        return hostText || group.join(" ").trim();
                    })
                    .filter((text, index, all) => Boolean(text) && all.indexOf(text) === index);
                const source = document.querySelector("textarea")?.value || "";
                const trimmedSource = source.trim();
                // Keep this deliberately compatible with older WebKit
                // JavaScript engines. A CJK range check is used instead of
                // Unicode property escapes because the latter are not
                // available in every macOS runtime supported by the app.
                const looksLikeLatinStyleWord = /^[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’\-][A-Za-zÀ-ÖØ-öø-ÿ]+)*$/
                    .test(trimmedSource);
                // Chinese, Japanese, and Korean text normally has no spaces,
                // so a full sentence must never be reduced to one token.
                const containsCJKScript = /[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]/
                    .test(trimmedSource);
                // Only one CJK character is unambiguously atomic here. Two or
                // more characters may already form a complete short phrase.
                const isSingleCJKCharacter = containsCJKScript &&
                    Array.from(trimmedSource).length === 1;
                const isSingleWord =
                    (looksLikeLatinStyleWord && !containsCJKScript) ||
                    isSingleCJKCharacter;
                const translation = isSingleWord
                    ? (candidateTexts[0] || "").split(/\s+/).filter(Boolean)[0] || ""
                    : candidateTexts.join("\n");
                if (window.__macTranslateWaitForDifferentResult &&
                    translation === window.__macTranslateBlockedTranslation) {
                    return [source, ""];
                }
                if (translation) {
                    window.__macTranslateWaitForDifferentResult = false;
                }
                return [source, translation];
            })();
        """#) { [weak self] result, _ in
            guard let self else { return }
            if self.translationCoordinator.pollInFlightSession == session {
                self.translationCoordinator.pollInFlightSession = nil
            }
            guard session == self.translationCoordinator.session,
                  self.translationCoordinator.activeWebViewGeneration == serviceGeneration,
                  self.activeTranslationWebView === serviceWebView else { return }
            guard pollingChunkIndex == self.translationCoordinator.chunkIndex else { return }
            guard self.translationCoordinator.chunks.indices.contains(self.translationCoordinator.chunkIndex) else {
                return
            }
            let payload = result as? [Any]
            let observedSource = (payload?.first as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedSource = self.translationCoordinator.chunks[self.translationCoordinator.chunkIndex].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let extractedTranslation = (payload?.dropFirst().first as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logTextPipelineSnapshot("google-dom-result-before-normalization", extractedTranslation)
            let translation = TranslationServiceTextNormalizer.normalize(
                extractedTranslation,
                forSource: expectedSource
            )

            // Do not accept a result until Google's textarea contains the
            // exact chunk currently being translated. This prevents a
            // previous chunk's DOM result from being appended to the next.
            guard observedSource == expectedSource else {
                self.scheduleLongTextPoll(session: session)
                return
            }
            let isLoading = translation.isEmpty ||
                translation.range(
                    of: "正在翻译|translating|loading",
                    options: .regularExpression.union(.caseInsensitive)
                ) != nil

            if isLoading {
                self.scheduleLongTextPoll(session: session)
                return
            }

            if self.translationCoordinator.noteValidGoogleWebCandidate() {
                self.logTranslationTiming("api-provisional-cancelled-web-won")
            }

            if self.translationTimingRequest?.didLogFirstValidExtraction == false {
                self.translationTimingRequest?.didLogFirstValidExtraction = true
                self.logTranslationTiming(
                    "swift-valid-result-extracted",
                    details: String(format: "extraction_ms=%.3f", (CACurrentMediaTime() - extractionStartedAt) * 1_000)
                )
            }

            // A cleared Google input can retain the preceding translation for
            // a moment. Do not append that stale result.  Google also writes
            // sentence translations in stages (for example, it can expose
            // "Test it again." before later appending a second clause), so
            // wait until the candidate has been unchanged for a real quiet
            // interval rather than accepting two adjacent short polls.
            if translation == self.translationCoordinator.lastWebTranslation && self.translationCoordinator.pollAttempts < 10 {
                self.scheduleLongTextPoll(session: session)
                return
            }
            self.translationCoordinator.recordCandidate(translation)
            self.previewSingleChunkTranslationIfSafe(
                translation,
                session: session,
                chunkIndex: pollingChunkIndex
            )
            guard let candidateUpdatedAt = self.translationCoordinator.candidateUpdatedAt else {
                self.scheduleLongTextPoll(session: session)
                return
            }
            let settlingInterval = self.translationCoordinator.resultSettlingInterval(
                default: self.longTextResultSettlingInterval
            )
            let remainingQuietTime = settlingInterval -
                Date().timeIntervalSince(candidateUpdatedAt)
            guard remainingQuietTime <= 0 else {
                self.scheduleLongTextPoll(
                    session: session,
                    delay: max(0.05, remainingQuietTime)
                )
                return
            }

            self.translationCoordinator.lastWebTranslation = translation
            if self.translationTimingRequest?.didLogStableResult == false {
                self.translationTimingRequest?.didLogStableResult = true
                self.logTranslationTiming(
                    "result-declared-stable",
                    details: String(format: "quiet_ms=%.0f", settlingInterval * 1_000)
                )
            }
            self.appendLongTextTranslation(
                translation,
                session: session,
                source: "Google Web",
                provider: .web
            )
        }
    }

    func finalizeWithAPIFallbackIfNeeded(_ chunk: String, session: Int) {
        guard isCurrentTranslationWork(session: session) else { return }

        // The candidate has already been checked against the current source.
        // At the deadline, commit the value already visible instead of
        // replacing it with a late fallback result.
        if translationCoordinator.webHasValidCandidate,
           let candidate = translationCoordinator.candidateTranslation {
            translationCoordinator.lastWebTranslation = candidate
            logTranslationTiming("result-declared-stable")
            appendLongTextTranslation(
                candidate,
                session: session,
                source: "Google Web at deadline",
                provider: .web
            )
            return
        }

        translationCoordinator.fallbackShouldFinalize = true
        if let provisional = translationCoordinator.provisionalFallbackTranslation {
            logTranslationTiming("api-provisional-promoted-to-final")
            appendLongTextTranslation(
                provisional,
                session: session,
                source: "provisional API fallback at Web deadline",
                provider: .api
            )
            return
        }
        // A provisional request already in flight will observe
        // translationCoordinator.fallbackShouldFinalize and append its response as final.
        guard translationCoordinator.fallbackTask == nil else { return }
        translateLongTextChunkUsingAPI(chunk, session: session)
    }

    func retriggerStalledGoogleWebTranslation(_ chunk: String, session: Int) {
        guard session == translationCoordinator.session,
              let serviceWebView = activeTranslationWebView else { return }
        let serviceGeneration = translationCoordinator.activeWebViewGeneration
        let encoded = Data(chunk.utf8).base64EncodedString()
        logTranslationTiming("web-stall-light-retry-started")
        serviceWebView.evaluateJavaScript(#"""
            (() => {
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;
                const value = new TextDecoder().decode(
                    Uint8Array.from(atob("\#(encoded)"), (character) =>
                        character.charCodeAt(0))
                );
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
                setTimeout(() => {
                    setter.call(textarea, value);
                    textarea.dispatchEvent(new Event("input", { bubbles: true }));
                }, 45);
                return true;
            })();
        """#) { [weak self] result, _ in
            guard let self,
                  session == self.translationCoordinator.session,
                  serviceGeneration == self.translationCoordinator.activeWebViewGeneration,
                  (result as? Bool) == true else { return }
            self.logTranslationTiming("web-stall-light-retry-dispatched")
        }
    }

    /// Match Google Translate's perceived speed without weakening completion
    /// validation. Google paints an updated DOM result immediately and may
    /// refine it over the next few mutations. For a one-chunk request we can
    /// mirror that verified candidate in the native result pane at once while
    /// keeping the 750 ms quiet-period check before committing the swappable
    /// translation snapshot. Multi-chunk requests deliberately skip previews
    /// because a partial chunk cannot safely replace the assembled document.
    func previewSingleChunkTranslationIfSafe(
        _ translation: String,
        session: Int,
        chunkIndex: Int
    ) {
        guard session == translationCoordinator.session,
              chunkIndex == 0,
              translationCoordinator.chunks.count == 1,
              translationCoordinator.chunks.indices.contains(chunkIndex),
              let currentSource = longTextSource,
              longTextSourceView?.string == currentSource,
              !translation.isEmpty else { return }

        longTextTranslationView?.string = translation
        logFirstVisibleTranslationIfNeeded(provider: .web)
        if translationTimingRequest?.didLogFirstVerifiedDisplay == false {
            translationTimingRequest?.didLogFirstVerifiedDisplay = true
            logTranslationTiming(
                "first-valid-result-displayed",
                diagnosticFields: ["provider": "web"]
            )
        }
        updateInlineLongText(
            source: nil,
            translation: translation,
            status: longTextStatusLabel?.stringValue ?? ""
        )
        workspaceTranslationCountLabel?.stringValue =
            textCountDescription(translation)
        longTextTranslationLabel?.stringValue =
            textCountDescription(translation)
    }

    func scheduleLongTextPoll(
        session: Int,
        delay: TimeInterval? = nil
    ) {
        guard session == translationCoordinator.session else { return }
        translationCoordinator.scheduledPoll?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollLongTextTranslation(session: session)
        }
        translationCoordinator.scheduledPoll = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? longTextPollInterval),
            execute: workItem
        )
    }
}
