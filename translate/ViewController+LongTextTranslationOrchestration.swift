//
//  ViewController+LongTextTranslationOrchestration.swift
//  translate
//

import Cocoa
import QuartzCore
import WebKit

struct ParallelWebTranslationChunk {
    let index: Int
    let source: String
    let separatorAfter: String
    var candidateTranslation: String?
    var candidateUpdatedAt: Date?
    var completedTranslation: String?
    var didLogBlockedBaseline = false
}

struct ParallelWebTranslationBatch {
    let session: Int
    let deadline: Date
    var chunks: [Int: ParallelWebTranslationChunk]
    var inFlightChunkIndexes: Set<Int> = []
    var scheduledPoll: DispatchWorkItem?
}

struct ParallelWebTranslationCache {
    var documentSource = ""
    var sourceLanguage = ""
    var targetLanguage = ""
    var translationsBySource: [String: String] = [:]
}

extension ViewController {
    func translateNextLongTextChunk(session: Int) {
        guard session == translationCoordinator.session else { return }
        guard translationCoordinator.chunkIndex < translationCoordinator.chunks.count else {
            translationCoordinator.scheduledPoll?.cancel()
            translationCoordinator.scheduledPoll = nil
            translationCoordinator.pollInFlightSession = nil
            translationCoordinator.webDeadline = nil
            activeTranslationWebView?.evaluateJavaScript(
                "window.__macTranslateResultObserver?.disconnect();",
                completionHandler: nil
            )
            // The native result view is what the user actually sees. Capture
            // that exact, settled value as the only swappable snapshot rather
            // than trusting a potentially older in-memory assembly buffer.
            // This is important for multi-part results: a delayed old chunk
            // must never make a later language swap lose the final sections.
            let visibleCompletedTranslation = longTextTranslationView?.string
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let completedTranslation = visibleCompletedTranslation.isEmpty
                ? longTextTranslation
                : visibleCompletedTranslation
            if let source = longTextSource, !completedTranslation.isEmpty {
                translationCoordinator.completedSource = source
                translationCoordinator.completedTranslation = completedTranslation
                translationCoordinator.completedSourceLanguage = longTextSourceLanguage
                translationCoordinator.completedTargetLanguage = longTextTargetLanguage
                translationPipelineLogger.info(
                    "Completed translation snapshot: sourceChars=\(source.count, privacy: .public), translationChars=\(completedTranslation.count, privacy: .public), chunks=\(self.translationCoordinator.chunks.count, privacy: .public)"
                )
            }
            let status = setLongTextStatus(.completed)
            if let requestID = translationTimingRequest?.id {
                TranslationPerformanceDiagnostics.shared.finish(
                    requestID: requestID,
                    stage: "request-completed",
                    status: "completed"
                )
            }
            translationCoordinator.formattingOnlyRefresh = false
            updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
            updateLongTextLabels()
            return
        }

        if translationCoordinator.usesConcurrentAPIBatch {
            startConcurrentLongTextAPIBatchIfNeeded(session: session)
            return
        }

        if startParallelWebTranslationIfReady(session: session) {
            return
        }

        let chunk = translationCoordinator.chunks[translationCoordinator.chunkIndex].text
        if chunk.isEmpty {
            longTextTranslation.append(translationCoordinator.chunks[translationCoordinator.chunkIndex].separatorAfter)
            longTextTranslationView?.string = longTextTranslation
            translationCoordinator.chunkIndex += 1
            translateNextLongTextChunk(session: session)
            return
        }
        translationCoordinator.prepareNextChunk(
            webResultDeadline: longTextWebResultDeadline
        )
        // A Return-only edit should behave like Google Translate Web: retain
        // the completed result and controls while the paragraph boundaries
        // are refreshed, instead of flashing a new translation cycle.
        let status = setLongTextStatus(
            translationCoordinator.formattingOnlyRefresh ? .completed : .translating
        )
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)

        // Keep the WebView hidden, but prefer the same Google Translate Web
        // result that the pre-1.0 versions displayed.  The Web and
        // translate_a/single endpoints do not always produce the same
        // translation for medical phrases such as "gravida 4 para 3".
        translateLongTextChunkUsingGoogleWeb(
            chunk,
            session: session
        )
    }

    /// Google Translate's web UI owns one textarea, so it can only process
    /// oversized chunks serially. For documents with three or more chunks,
    /// request the API chunks concurrently and reveal them strictly in source
    /// order as their predecessors become available.
    func startConcurrentLongTextAPIBatchIfNeeded(session: Int) {
        translationCoordinator.startConcurrentAPIBatch(
            session: session,
            sourceLanguage: longTextSourceLanguage,
            targetLanguage: longTextTargetLanguage,
            onStarted: { [weak self] in
                self?.logTranslationTiming("parallel-api-batch-started")
            },
            onChunkReady: { [weak self] in
                self?.logTranslationTiming("parallel-api-chunk-ready")
            },
            onOrderedResults: { [weak self] results, completed in
                guard let self else { return }
                for result in results {
                    if result.replacesVisibleTranslation {
                        self.longTextTranslation =
                            result.translation + result.separator
                    } else {
                        self.longTextTranslation.append(result.translation)
                        self.longTextTranslation.append(result.separator)
                    }
                }
                self.longTextTranslationView?.string = self.longTextTranslation
                self.updateInlineLongText(
                    source: nil,
                    translation: self.longTextTranslation,
                    status: self.longTextStatusLabel?.stringValue ?? ""
                )
                self.updateLongTextLabels()
                if completed {
                    self.translateNextLongTextChunk(session: session)
                }
            },
            onFailure: { [weak self] in
                self?.finishLongTextTranslationWithError(session: session)
            }
        )
    }

    @discardableResult
    func startParallelWebTranslationIfReady(session: Int) -> Bool {
        guard session == translationCoordinator.session,
              translationCoordinator.chunkIndex == 0,
              translationCoordinator.chunks.count == 2,
              parallelTranslationWebViewReady,
              let primaryWebView = activeTranslationWebView,
              primaryWebView !== parallelTranslationWebView,
              translationPageMatches(
                  source: TranslateLanguage(rawValue: longTextSourceLanguage) ?? .automatic,
                  target: TranslateLanguage(rawValue: longTextTargetLanguage) ?? .simplifiedChinese,
                  in: parallelTranslationWebView
              ) else {
            return false
        }

        let canReusePreviousChunks =
            parallelWebTranslationCache.documentSource == translationCoordinator.completedSource &&
            parallelWebTranslationCache.sourceLanguage == longTextSourceLanguage &&
            parallelWebTranslationCache.targetLanguage == longTextTargetLanguage
        let chunks = translationCoordinator.chunks.enumerated().reduce(
            into: [Int: ParallelWebTranslationChunk]()
        ) { result, item in
            result[item.offset] = ParallelWebTranslationChunk(
                index: item.offset,
                source: item.element.text,
                separatorAfter: item.element.separatorAfter,
                completedTranslation: canReusePreviousChunks
                    ? parallelWebTranslationCache.translationsBySource[item.element.text]
                    : nil
            )
        }
        parallelWebTranslationBatch = ParallelWebTranslationBatch(
            session: session,
            deadline: Date().addingTimeInterval(longTextWebResultDeadline),
            chunks: chunks
        )
        let status = setLongTextStatus(.translating)
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
        logTranslationTiming("parallel-web-batch-started")
        for index in 0..<translationCoordinator.chunks.count {
            guard let chunk = chunks[index] else { continue }
            if chunk.completedTranslation != nil {
                logTranslationTiming(
                    "parallel-web-chunk-reused",
                    details: "chunk=\(index)",
                    diagnosticFields: [
                        "chunk_index": index,
                        "chunk_source_utf16": chunk.source.utf16.count
                    ]
                )
                continue
            }
            submitParallelWebChunk(
                chunk,
                in: index == 0 ? primaryWebView : parallelTranslationWebView,
                session: session
            )
        }
        finishParallelWebTranslationIfComplete(session: session)
        if parallelWebTranslationBatch?.session == session {
            scheduleParallelWebPoll(session: session, delay: longTextPollInterval)
        }
        return true
    }

    func submitParallelWebChunk(
        _ chunk: ParallelWebTranslationChunk,
        in serviceWebView: WKWebView,
        session: Int
    ) {
        let encoded = Data(chunk.source.utf8).base64EncodedString()
        serviceWebView.evaluateJavaScript(#"""
            (() => {
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;
                const value = new TextDecoder().decode(
                    Uint8Array.from(atob("\#(encoded)"), (character) =>
                        character.charCodeAt(0))
                );
                // Swift validates sources after trimming their outer
                // whitespace. Use the same equivalence here so adding a
                // trailing space can reuse an already correct translation
                // instead of waiting for an identical-result API fallback.
                const inputAlreadyCurrent = textarea.value.trim() === value.trim();
                window.__macTranslateReadParallelResult = () => {
                    const source = document.querySelector("textarea")?.value || "";
                    const extractable = (element) => {
                        const style = getComputedStyle(element);
                        const rect = element.getBoundingClientRect();
                        return style.display !== "none" &&
                            rect.width > 0 && rect.height > 0;
                    };
                    const resultRoot = document.querySelector(".QcsUad.sMVRZe") ||
                        document.querySelector(".QcsUad:not(.FkMbO)") ||
                        document.querySelector(".QcsUad");
                    const resultGroups = [
                        "[jsname=\"W297wb\"]", ".ryNqvb", ".jCAhz", ".lRu31", ".HwtZe"
                    ];
                    var nodes = [];
                    for (const selector of resultGroups) {
                        nodes = resultRoot
                            ? Array.from(resultRoot.querySelectorAll(selector))
                                .filter(extractable)
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
                        const duplicatesDescendant = candidates.some((other) =>
                            other !== element && element.contains(other) &&
                            (other.innerText || other.textContent || "").trim() === text
                        );
                        if (duplicatesDescendant) continue;
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
                    const texts = textGroups.map((group, index) => {
                        const host = Array.from(groupIndexByHost.keys())
                            .find((candidate) => groupIndexByHost.get(candidate) === index);
                        const hostText = host?.matches?.(".HwtZe")
                            ? (host.innerText || "").trim()
                            : "";
                        return hostText || group.join(" ").trim();
                    }).filter((text, index, values) =>
                        Boolean(text) && values.indexOf(text) === index
                    );
                    // Result blocks represent Google's translated paragraphs.
                    // Joining them with spaces erased an inserted Return and
                    // made the stale-result guard behave inconsistently.
                    const translation = texts.join("\n");
                    if (window.__macTranslateParallelWaitForDifferentResult &&
                        translation === window.__macTranslateParallelBlockedTranslation) {
                        return [source, "", true];
                    }
                    if (translation) {
                        window.__macTranslateParallelWaitForDifferentResult = false;
                    }
                    return [source, translation, false];
                };
                if (!inputAlreadyCurrent) {
                    window.__macTranslateParallelWaitForDifferentResult = false;
                    const previousPayload = window.__macTranslateReadParallelResult();
                    window.__macTranslateParallelBlockedTranslation =
                        previousPayload?.[1] || "";
                    window.__macTranslateParallelWaitForDifferentResult = Boolean(
                        window.__macTranslateParallelBlockedTranslation
                    );
                } else {
                    window.__macTranslateParallelWaitForDifferentResult = false;
                }
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                setter.call(textarea, value);
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
                return textarea.value === value;
            })();
        """#) { [weak self] _, _ in
            guard let self,
                  self.parallelWebTranslationBatch?.session == session else { return }
            self.logTranslationTiming("parallel-web-chunk-submitted")
        }
    }

    func pollParallelWebTranslation(session: Int) {
        guard var batch = parallelWebTranslationBatch,
              batch.session == session,
              session == translationCoordinator.session else {
            return
        }
        batch.scheduledPoll = nil
        guard Date() <= batch.deadline else {
            parallelWebTranslationBatch = batch
            fallBackFromParallelWebTranslation(session: session)
            return
        }

        let pending = batch.chunks.values.filter {
            $0.completedTranslation == nil && !batch.inFlightChunkIndexes.contains($0.index)
        }
        guard !pending.isEmpty else {
            parallelWebTranslationBatch = batch
            finishParallelWebTranslationIfComplete(session: session)
            return
        }
        guard let primaryWebView = activeTranslationWebView else {
            parallelWebTranslationBatch = batch
            fallBackFromParallelWebTranslation(session: session)
            return
        }
        pending.forEach { chunk in
            batch.inFlightChunkIndexes.insert(chunk.index)
        }
        parallelWebTranslationBatch = batch

        for chunk in pending {
            let serviceWebView: WKWebView = chunk.index == 0
                ? primaryWebView
                : parallelTranslationWebView
            evaluateParallelWebResult(
                for: chunk,
                in: serviceWebView,
                session: session
            )
        }
    }

    func evaluateParallelWebResult(
        for chunk: ParallelWebTranslationChunk,
        in serviceWebView: WKWebView,
        session: Int
    ) {
        serviceWebView.evaluateJavaScript(#"""
            (() => {
                if (typeof window.__macTranslateReadParallelResult === "function") {
                    return window.__macTranslateReadParallelResult();
                }
                // A configured result reader is installed by submission with
                // the exact parser used for the old-result baseline. Do not
                // fall back to a second, whitespace-flattening parser while
                // that setup is temporarily unavailable.
                const source = document.querySelector("textarea")?.value || "";
                return [source, "", false];
            })();
        """#) { [weak self] result, _ in
            self?.handleParallelWebResult(
                result,
                forChunkIndex: chunk.index,
                session: session
            )
        }
    }

    func handleParallelWebResult(
        _ result: Any?,
        forChunkIndex chunkIndex: Int,
        session: Int
    ) {
        guard var batch = parallelWebTranslationBatch,
              batch.session == session,
              session == translationCoordinator.session,
              var chunk = batch.chunks[chunkIndex] else {
            return
        }
        batch.inFlightChunkIndexes.remove(chunkIndex)
        let payload = result as? [Any]
        let observedSource = (payload?.first as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let extractedTranslation = (payload?.dropFirst().first as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let blockedByPreviousResult = payload?.dropFirst(2).first as? Bool ?? false
        let expectedSource = chunk.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = TranslationServiceTextNormalizer.normalize(
            extractedTranslation,
            forSource: expectedSource
        )
        let isLoading = translation.isEmpty ||
            translation.range(
                of: "正在翻译|translating|loading",
                options: .regularExpression.union(.caseInsensitive)
            ) != nil

        guard observedSource == expectedSource, !isLoading else {
            if blockedByPreviousResult, !chunk.didLogBlockedBaseline {
                chunk.didLogBlockedBaseline = true
                batch.chunks[chunkIndex] = chunk
                logTranslationTiming(
                    "parallel-web-stale-result-blocked",
                    details: "chunk=\(chunkIndex)",
                    diagnosticFields: [
                        "chunk_index": chunkIndex,
                        "chunk_source_utf16": chunk.source.utf16.count
                    ]
                )
            }
            parallelWebTranslationBatch = batch
            scheduleParallelWebPoll(session: session)
            return
        }

        if translation != chunk.candidateTranslation {
            chunk.candidateTranslation = translation
            chunk.candidateUpdatedAt = Date()
        } else if let candidateUpdatedAt = chunk.candidateUpdatedAt,
                  Date().timeIntervalSince(candidateUpdatedAt) >=
                    translationCoordinator.resultSettlingInterval(
                        default: longTextResultSettlingInterval
                    ) {
            chunk.completedTranslation = translation
            logTranslationTiming(
                "parallel-web-chunk-stable",
                details: "chunk=\(chunkIndex) source_utf16=\(chunk.source.utf16.count) translation_chars=\(translation.count)",
                diagnosticFields: [
                    "chunk_index": chunkIndex,
                    "chunk_source_utf16": chunk.source.utf16.count,
                    "chunk_translation_chars": translation.count
                ]
            )
        }
        batch.chunks[chunkIndex] = chunk
        parallelWebTranslationBatch = batch
        finishParallelWebTranslationIfComplete(session: session)
        scheduleParallelWebPoll(session: session)
    }

    func scheduleParallelWebPoll(
        session: Int,
        delay: TimeInterval? = nil
    ) {
        guard var batch = parallelWebTranslationBatch,
              batch.session == session,
              session == translationCoordinator.session,
              batch.scheduledPoll == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollParallelWebTranslation(session: session)
        }
        batch.scheduledPoll = workItem
        parallelWebTranslationBatch = batch
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? longTextPollInterval),
            execute: workItem
        )
    }

    func finishParallelWebTranslationIfComplete(session: Int) {
        guard let batch = parallelWebTranslationBatch,
              batch.session == session,
              session == translationCoordinator.session,
              batch.chunks.count == translationCoordinator.chunks.count,
              batch.chunks.values.allSatisfy({ $0.completedTranslation != nil }) else {
            return
        }
        batch.scheduledPoll?.cancel()
        let assembledTranslation = (0..<translationCoordinator.chunks.count).compactMap {
            batch.chunks[$0].flatMap { chunk in
                chunk.completedTranslation.map { $0 + chunk.separatorAfter }
            }
        }.joined()
        guard !assembledTranslation.isEmpty else {
            fallBackFromParallelWebTranslation(session: session)
            return
        }
        parallelWebTranslationCache = ParallelWebTranslationCache(
            documentSource: longTextSource ?? "",
            sourceLanguage: longTextSourceLanguage,
            targetLanguage: longTextTargetLanguage,
            translationsBySource: batch.chunks.values.reduce(into: [:]) { result, chunk in
                if let translation = chunk.completedTranslation {
                    result[chunk.source] = translation
                }
            }
        )
        parallelWebTranslationBatch = nil
        if translationCoordinator.replacesVisibleTranslation {
            longTextTranslation = assembledTranslation
            translationCoordinator.replacesVisibleTranslation = false
        } else {
            longTextTranslation.append(assembledTranslation)
        }
        longTextTranslationView?.string = longTextTranslation
        translationCoordinator.chunkIndex = translationCoordinator.chunks.count
        logTranslationTiming("parallel-web-batch-completed")
        translateNextLongTextChunk(session: session)
    }

    func fallBackFromParallelWebTranslation(session: Int) {
        guard let batch = parallelWebTranslationBatch,
              batch.session == session,
              session == translationCoordinator.session else {
            return
        }
        batch.scheduledPoll?.cancel()
        parallelWebTranslationBatch = nil
        activeTranslationWebView?.evaluateJavaScript(
            "window.__macTranslateResultObserver?.disconnect();",
            completionHandler: nil
        )
        parallelTranslationWebView.evaluateJavaScript(
            "window.__macTranslateResultObserver?.disconnect();",
            completionHandler: nil
        )
        translationCoordinator.enableConcurrentAPIFallback()
        logTranslationTiming("parallel-web-batch-api-fallback")
        startConcurrentLongTextAPIBatchIfNeeded(session: session)
    }

    func cancelParallelWebTranslationBatch() {
        parallelWebTranslationBatch?.scheduledPoll?.cancel()
        parallelWebTranslationBatch = nil
    }

    func clearParallelWebTranslationCache() {
        parallelWebTranslationCache = ParallelWebTranslationCache()
    }
}
