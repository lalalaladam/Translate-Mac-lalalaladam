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
}

struct ParallelWebTranslationBatch {
    let session: Int
    let deadline: Date
    var chunks: [Int: ParallelWebTranslationChunk]
    var inFlightChunkIndexes: Set<Int> = []
    var scheduledPoll: DispatchWorkItem?
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

        let chunks = translationCoordinator.chunks.enumerated().reduce(
            into: [Int: ParallelWebTranslationChunk]()
        ) { result, item in
            result[item.offset] = ParallelWebTranslationChunk(
                index: item.offset,
                source: item.element.text,
                separatorAfter: item.element.separatorAfter
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
        submitParallelWebChunk(
            chunks[0]!,
            in: primaryWebView,
            session: session
        )
        submitParallelWebChunk(
            chunks[1]!,
            in: parallelTranslationWebView,
            session: session
        )
        scheduleParallelWebPoll(session: session, delay: longTextPollInterval)
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
                const source = document.querySelector("textarea")?.value || "";
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
                        : [];
                    if (nodes.length) break;
                }
                const texts = nodes.map((element) =>
                    (element.textContent || "").trim()
                ).filter((text, index, values) => Boolean(text) && values.indexOf(text) === index);
                return [source, texts.join(" ")];
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
            logTranslationTiming("parallel-web-chunk-stable")
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
        parallelWebTranslationBatch = nil
        let assembledTranslation = (0..<translationCoordinator.chunks.count).compactMap {
            batch.chunks[$0].flatMap { chunk in
                chunk.completedTranslation.map { $0 + chunk.separatorAfter }
            }
        }.joined()
        guard !assembledTranslation.isEmpty else {
            fallBackFromParallelWebTranslation(session: session)
            return
        }
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
}
