//
//  ViewController+LongTextTranslationOrchestration.swift
//  translate
//

import Cocoa
import QuartzCore
import WebKit

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
}
