//
//  ViewController+TranslationAPI.swift
//  translate
//

import Cocoa
import QuartzCore
import WebKit

extension ViewController {
    func translateLongTextChunkUsingAPI(
        _ chunk: String,
        session: Int,
        provisional: Bool = false
    ) {
        let timingRequestID = translationTimingRequest.flatMap {
            $0.session == session ? $0.id : nil
        } ?? 0
        guard isCurrentTranslationWork(session: session),
              let request = TranslationServiceCoordinator.googleTranslationRequest(
                  for: chunk,
                  sourceLanguage: longTextSourceLanguage,
                  targetLanguage: longTextTargetLanguage
              ) else {
            logTranslationCoordinator(
                "fallback-cancelled-as-stale",
                source: longTextSource,
                requestID: timingRequestID,
                session: session
            )
            return
        }
        logTranslationTiming(provisional ? "api-provisional-started" : "api-fallback-started")

        guard session == translationCoordinator.session else {
            finishLongTextTranslationWithError(session: session)
            return
        }

        translationPipelineLogger.info(
            "Starting API \(provisional ? "provisional safety net" : "fallback", privacy: .public): chunkChars=\(chunk.count, privacy: .public)"
        )
        let requestedChunkIndex = translationCoordinator.chunkIndex
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let translation = data.flatMap(
                TranslationServiceCoordinator.translationText(from:)
            )
            let succeeded = error == nil &&
                (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true &&
                !(translation?.isEmpty ?? true)

            DispatchQueue.main.async {
                guard let self,
                      self.isCurrentTranslationWork(session: session),
                      requestedChunkIndex == self.translationCoordinator.chunkIndex else {
                    self?.logTranslationCoordinator(
                        "fallback-cancelled-as-stale",
                        source: self?.longTextSource,
                        requestID: timingRequestID,
                        session: session
                    )
                    return
                }
                self.translationCoordinator.fallbackTask = nil
                if provisional && self.translationCoordinator.webHasValidCandidate {
                    self.logTranslationTiming("api-provisional-discarded-web-won")
                    return
                }
                guard succeeded, let translation else {
                    if self.translationCoordinator.chunkRetryCount == 0 {
                        self.translationCoordinator.chunkRetryCount = 1
                        translationPipelineLogger.error(
                            "Translation chunk failed; performing the single permitted retry: chunkIndex=\(self.translationCoordinator.chunkIndex, privacy: .public), error=\(String(describing: error), privacy: .public)"
                        )
                        self.translateLongTextChunkUsingAPI(
                            chunk,
                            session: session,
                            provisional: provisional
                        )
                        return
                    }
                    translationPipelineLogger.error(
                        "Translation chunk failed after retry: chunkIndex=\(self.translationCoordinator.chunkIndex, privacy: .public), status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public), error=\(String(describing: error), privacy: .public)"
                    )
                    if provisional {
                        self.logTranslationTiming("api-provisional-failed-web-continues")
                        return
                    }
                    self.finishLongTextTranslationWithError(session: session)
                    return
                }
                if provisional && !self.translationCoordinator.fallbackShouldFinalize {
                    let normalized = TranslationServiceTextNormalizer.normalize(
                        translation,
                        forSource: chunk
                    )
                    // Keep the lower-quality API result hidden while Google
                    // Web still has time to finish. It is promoted only at
                    // the Web deadline when no source-verified Web candidate
                    // exists, so the first visible result never flashes from
                    // API to Web.
                    self.translationCoordinator.provisionalFallbackTranslation = normalized
                    if !self.previewProvisionalAPITranslationIfReady(session: session) {
                        self.logTranslationTiming("api-provisional-ready-hidden")
                    }
                } else {
                    self.appendLongTextTranslation(
                        translation,
                        session: session,
                        source: "direct API fallback",
                        provider: .api
                    )
                }
            }
        }
        translationCoordinator.fallbackTask?.cancel()
        translationCoordinator.fallbackTask = task
        task.resume()
    }

    func isCurrentTranslationWork(session: Int) -> Bool {
        guard session == translationCoordinator.session,
              !languageSwapInProgress,
              translationCoordinator.debounceWorkItem == nil,
              languageSwapPendingText == nil,
              let source = longTextSource,
              longTextSourceView?.string == source,
              longTextTargetLanguage == currentTargetLanguage.rawValue else {
            return false
        }
        return longTextSourceLanguage == translationCoordinator.effectiveSourceLanguage(
            for: source,
            selectedLanguage: currentSourceLanguage
        ).rawValue
    }

    func logFirstVisibleTranslationIfNeeded(provider: TranslationResultProvider) {
        guard translationTimingRequest?.didLogFirstDisplay == false else { return }
        translationTimingRequest?.didLogFirstDisplay = true
        logTranslationTiming(
            "first-visible-result-displayed",
            diagnosticFields: [
                "provider": provider == .web ? "web" : "api"
            ]
        )
    }

    @discardableResult
    func previewProvisionalAPITranslationIfReady(session: Int) -> Bool {
        guard session == translationCoordinator.session,
              translationCoordinator.coldResumeHedgeActive,
              !translationCoordinator.provisionalFallbackPreviewDisplayed,
              !translationCoordinator.webHasValidCandidate,
              translationCoordinator.webStartedAt.map({
                  Date().timeIntervalSince($0) >= webStallRecoveryDelay
              }) == true,
              translationCoordinator.chunkIndex == 0,
              translationCoordinator.chunks.count == 1,
              let translation = translationCoordinator.provisionalFallbackTranslation,
              !translation.isEmpty,
              let currentSource = longTextSource,
              longTextSourceView?.string == currentSource else {
            return false
        }

        translationCoordinator.provisionalFallbackPreviewDisplayed = true
        longTextTranslationView?.string = translation
        logFirstVisibleTranslationIfNeeded(provider: .api)
        logTranslationTiming("api-provisional-preview-displayed")
        updateInlineLongText(
            source: nil,
            translation: translation,
            status: longTextStatusLabel?.stringValue ?? ""
        )
        workspaceTranslationCountLabel?.stringValue = textCountDescription(translation)
        longTextTranslationLabel?.stringValue = textCountDescription(translation)
        return true
    }

    @discardableResult
    func appendLongTextTranslation(
        _ translation: String,
        session: Int,
        source: String,
        provider: TranslationResultProvider
    ) -> Bool {
        guard session == translationCoordinator.session else { return false }
        guard let currentSource = longTextSource else {
            recoverFromRejectedResultDisplay(
                session: session,
                reason: "missing-request-source"
            )
            return false
        }
        guard longTextSourceView?.string == currentSource else {
            recoverFromRejectedResultDisplay(
                session: session,
                reason: "native-source-mismatch"
            )
            return false
        }
        guard translationCoordinator.chunks.indices.contains(translationCoordinator.chunkIndex) else {
            recoverFromRejectedResultDisplay(
                session: session,
                reason: "missing-current-chunk"
            )
            return false
        }
        let translation = TranslationServiceTextNormalizer.normalize(
            translation,
            forSource: translationCoordinator.chunks[translationCoordinator.chunkIndex].text
        )
        let separator = translationCoordinator.chunks[translationCoordinator.chunkIndex].separatorAfter
        if translationCoordinator.replacesVisibleTranslation && translationCoordinator.chunkIndex == 0 {
            longTextTranslation = translation + separator
            translationCoordinator.replacesVisibleTranslation = false
        } else {
            longTextTranslation.append(translation)
            longTextTranslation.append(separator)
        }
        translationCoordinator.webDeadline = nil
        translationResultProviders.insert(provider)
        longTextTranslationView?.string = longTextTranslation
        logFirstVisibleTranslationIfNeeded(provider: provider)
        if translationTimingRequest?.didLogFinalDisplay == false {
            translationTimingRequest?.didLogFinalDisplay = true
            logTranslationTiming("final-result-displayed", details: "source=\(source)")
        }
        translationPipelineLogger.info(
            "Final displayed translation (\(source)): chars=\(self.longTextTranslation.count, privacy: .public)"
        )
        updateInlineLongText(
            source: nil,
            translation: longTextTranslation,
            status: longTextStatusLabel?.stringValue ?? ""
        )
        translationCoordinator.chunkIndex += 1
        updateLongTextLabels()
        translateNextLongTextChunk(session: session)
        return true
    }

    func recoverFromRejectedResultDisplay(
        session: Int,
        reason: String
    ) {
        guard session == translationCoordinator.session else { return }
        logTranslationTiming("result-display-rejected-\(reason)")

        guard translationCoordinator.lastRecoveredResultDisplaySession != session else { return }
        translationCoordinator.lastRecoveredResultDisplaySession = session
        guard let sourceView = longTextSourceView else {
            finishLongTextTranslationWithError(session: session)
            return
        }
        // Never rewrite or submit marked text owned by an input method. Its
        // normal commit notification will enqueue the authoritative source.
        guard !sourceView.hasMarkedText() else {
            translationPipelineLogger.info(
                "Stable translation deferred for active input method: reason=\(reason, privacy: .public), session=\(session, privacy: .public)"
            )
            logTranslationTiming("result-display-recovery-waiting-for-ime")
            logTranslationStateTransition(
                from: "result-display-rejected",
                to: "waiting-for-ime",
                reason: reason,
                markedText: true
            )
            // A few input methods finish composition without delivering a
            // follow-up textDidChange notification. Keep the normal commit
            // path, but also arm its existing bounded reconciliation check.
            scheduleIMECompositionEndCheck()
            return
        }

        translationPipelineLogger.error(
            "Stable translation could not be displayed: reason=\(reason, privacy: .public), session=\(session, privacy: .public)"
        )

        let latestSource = sourceView.string
        guard !latestSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }
        logTranslationTiming("result-display-recovery-resubmitted")
        logTranslationStateTransition(
            from: "result-display-rejected",
            to: "resubmitting",
            reason: reason,
            markedText: false
        )
        // Defer until the current extraction callback has unwound. The normal
        // queue path invalidates every observer, timer and fallback belonging
        // to this rejected request before submitting the latest native text.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  session == self.translationCoordinator.session,
                  self.longTextSourceView?.string == latestSource else { return }
            self.queueLongTextTranslation(latestSource, mode: .immediate)
        }
    }

    func finishLongTextTranslationWithError(session: Int) {
        guard session == translationCoordinator.session else { return }
        if translationCoordinator.formattingOnlyRefresh && !translationCoordinator.completedTranslation.isEmpty {
            translationCoordinator.formattingOnlyRefresh = false
            longTextTranslation = translationCoordinator.completedTranslation
            translationResultProviders = completedTranslationResultProviders
            let status = setLongTextStatus(.completed)
            updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
            updateLongTextLabels()
            if let requestID = translationTimingRequest?.id {
                TranslationPerformanceDiagnostics.shared.finish(
                    requestID: requestID,
                    stage: "formatting-refresh-completed",
                    status: "completed"
                )
            }
            return
        }
        let status = setLongTextStatus(.failed)
        if let requestID = translationTimingRequest?.id {
            TranslationPerformanceDiagnostics.shared.finish(
                requestID: requestID,
                stage: "request-failed",
                status: "failed"
            )
        }
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
        updateLongTextLabels()
    }
}
