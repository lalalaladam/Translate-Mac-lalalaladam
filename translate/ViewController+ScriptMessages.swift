//
//  ViewController+ScriptMessages.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let payload = message.body as? [String: Any],
           let action = payload["action"] as? String {
            if action == "translationTimingJS",
               let requestID = (payload["requestID"] as? NSNumber)?.intValue,
               let session = (payload["session"] as? NSNumber)?.intValue,
               requestID == translationTimingRequest?.id,
               session == translationTimingRequest?.session,
               let milestone = payload["milestone"] as? String {
                let details = payload
                    .filter { !["action", "requestID", "session", "milestone"].contains($0.key) }
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                logTranslationTiming("js-\(milestone)", details: details)
                return
            }

            if action == "translationServiceDOMReady",
               let service = payload["service"] as? String {
                let serviceWebView: WKWebView
                switch service {
                case "automatic":
                    serviceWebView = automaticTranslationWebView
                case "standby":
                    serviceWebView = standbyTranslationWebView
                case "parallel":
                    serviceWebView = parallelTranslationWebView
                default:
                    serviceWebView = webView
                }
                configureTranslationPageAfterDOMReady(serviceWebView)
                return
            }

            if action == "copySource", let text = payload["text"] as? String {
                copyToPasteboard(longTextSource ?? text)
                return
            }

            if action == "clearSource" {
                DispatchQueue.main.async { [weak self] in
                    self?.queueLongTextTranslation("")
                }
                return
            }

            if action == "swapLanguages" {
                DispatchQueue.main.async { [weak self] in
                    self?.swapCurrentTranslationLanguages()
                }
                return
            }

            if action == "translationDOMResult",
               let observedSession = (payload["session"] as? NSNumber)?.intValue,
               let observedChunkIndex = (payload["chunkIndex"] as? NSNumber)?.intValue,
               let observedServiceGeneration = (payload["serviceGeneration"] as? NSNumber)?.intValue,
               observedSession == translationCoordinator.session,
               observedChunkIndex == translationCoordinator.chunkIndex,
               observedServiceGeneration == translationCoordinator.activeWebViewGeneration,
               translationCoordinator.chunks.indices.contains(observedChunkIndex),
               let observedSource = payload["source"] as? String,
               let observedTranslation = payload["translation"] as? String {
                let expectedSource = translationCoordinator.chunks[observedChunkIndex].text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let source = observedSource
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let extractedTranslation = observedTranslation
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                logTextPipelineSnapshot(
                    "google-dom-observer-result-before-normalization",
                    extractedTranslation
                )
                let translation = TranslationServiceTextNormalizer.normalize(
                    extractedTranslation,
                    forSource: expectedSource
                )
                guard source == expectedSource,
                      !translation.isEmpty,
                      translation.range(
                        of: "正在翻译|translating|loading",
                        options: .regularExpression.union(.caseInsensitive)
                      ) == nil else {
                    return
                }

                if !didLogFirstTranslationResult {
                    didLogFirstTranslationResult = true
                    logStartupTiming("First translation result appeared")
                }

                if translationTimingRequest?.didLogFirstValidJSResult == false {
                    translationTimingRequest?.didLogFirstValidJSResult = true
                    let jsElapsed = (payload["jsElapsedMS"] as? NSNumber)?.doubleValue ?? -1
                    let firstMutation = (payload["firstMutationMS"] as? NSNumber)?.doubleValue ?? -1
                    logTranslationTiming(
                        "js-first-valid-result",
                        details: String(format: "js_elapsed_ms=%.3f first_mutation_ms=%.3f", jsElapsed, firstMutation)
                    )
                }

                // This is only a candidate. Preview a source-verified
                // one-chunk result immediately, but keep the observer alive
                // and require the normal quiet interval before committing it
                // as the final, swappable translation.
                if translationCoordinator.noteValidGoogleWebCandidate() {
                    logTranslationTiming("api-provisional-cancelled-web-won")
                }
                translationCoordinator.recordCandidate(translation)
                previewSingleChunkTranslationIfSafe(
                    translation,
                    session: observedSession,
                    chunkIndex: observedChunkIndex
                )
                let settlingInterval = translationCoordinator.resultSettlingInterval(
                    default: longTextResultSettlingInterval
                )
                let elapsedQuietTime = translationCoordinator.candidateUpdatedAt.map {
                    Date().timeIntervalSince($0)
                } ?? 0
                scheduleLongTextPoll(
                    session: observedSession,
                    delay: max(0.05, settlingInterval - elapsedQuietTime)
                )
                return
            }

            if action == "translateLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.queueLongTextTranslation(text, mode: .immediate)
                }
                return
            }

            if action == "updateLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.queueLongTextTranslation(text)
                }
                return
            }

            if action == "exitLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.returnToNormalTranslation(text)
                }
                return
            }

            if action == "copyTranslation", let text = payload["text"] as? String {
                copyToPasteboard(longTextSource == nil ? text : longTextTranslation)
                return
            }

            if action == "showLanguagePicker",
               let sideValue = payload["side"] as? String,
               let x = (payload["x"] as? NSNumber)?.doubleValue,
               let y = (payload["y"] as? NSNumber)?.doubleValue {
                let side: NativeLanguagePickerSide = sideValue == "target" ? .target : .source
                DispatchQueue.main.async { [weak self] in
                    self?.presentNativeLanguagePicker(
                        side: side,
                        webPointX: CGFloat(x),
                        webPointY: CGFloat(y)
                    )
                }
                return
            }
        }

        let keyCode = message.body as? Int
        if keyCode == 9 {
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            appDelegate.panel.resignKey()
        }
    }
}
