//
//  ViewController+TranslationDiagnostics.swift
//  translate
//

import Cocoa
import os
import WebKit

extension ViewController {
    func logStartupTiming(_ event: String) {
#if DEBUG
        let elapsed = ProcessInfo.processInfo.systemUptime - startupTimingOrigin
        startupTimingLogger.info("\(event, privacy: .public) +\(elapsed, format: .fixed(precision: 3))s")
#endif
    }

    func startTranslationTimingRequest(source: String, session: Int) {
        if translationTimingRequest?.source == source,
           translationTimingRequest?.didLogFinalDisplay == false { return }
        translationTimingRequestCount += 1
        let label: String
        switch translationTimingRequestCount {
        case 1: label = "cold-first"
        case 2: label = "warm-second"
        default: label = "request-\(translationTimingRequestCount)"
        }
        translationTimingRequest = TranslationTimingRequest(
            id: translationTimingRequestCount,
            label: label,
            source: source,
            session: session,
            startedAt: CACurrentMediaTime()
        )
        TranslationPerformanceDiagnostics.shared.begin(
            requestID: translationTimingRequestCount,
            characterCount: source.count,
            utf16Count: source.utf16.count,
            direction: "\(currentSourceLanguage.rawValue)->\(currentTargetLanguage.rawValue)"
        )
        logTranslationStateTransition(
            from: "idle",
            to: "request-started",
            reason: "user-trigger"
        )
        logTranslationTiming("user-trigger", details: "chars=\(source.count) utf16=\(source.utf16.count)")
    }

    func updateTranslationTimingSession(_ session: Int) {
        translationTimingRequest?.session = session
    }

    func markTranslationWebServiceReady(_ webView: WKWebView) {
        translationWebViewLastActivityAt[ObjectIdentifier(webView)] = Date()
    }

    func logTranslationWebServiceActivity(
        in webView: WKWebView,
        stage: String = "web-service-activity-measured"
    ) {
        let now = Date()
        let key = ObjectIdentifier(webView)
        let previousActivity = translationWebViewLastActivityAt[key]
        translationWebViewLastActivityAt[key] = now

        let role = translationWebViewRole(webView)
        var fields: [String: Any] = [
            "webview_role": role,
            "service_activity_known": previousActivity != nil
        ]
        if let previousActivity {
            fields["service_idle_before_request_ms"] = max(
                0,
                now.timeIntervalSince(previousActivity) * 1_000
            )
        }
        logTranslationTiming(stage, diagnosticFields: fields)
    }

    func translationWebViewRole(_ webView: WKWebView) -> String {
        if webView === automaticTranslationWebView {
            return "automatic"
        } else if webView === parallelTranslationWebView {
            return "parallel"
        } else if webView === standbyTranslationWebView {
            return "standby"
        } else if webView === self.webView {
            return "primary"
        }
        return "unknown"
    }

    func logWebResultRejection(
        in webView: WKWebView,
        reason: String,
        observedSourceMatches: Bool,
        blockedByPreviousResult: Bool,
        extractedUTF16: Int,
        mutationCount: Int,
        webTimingFields: [String: Any]
    ) {
        let role = translationWebViewRole(webView)
        let rejection = translationCoordinator.recordWebResultRejection(
            role: role,
            reason: reason
        )
        guard rejection.isFirst else { return }
        var fields: [String: Any] = [
            "webview_role": role,
            "rejection_reason": reason,
            "rejection_count": rejection.count,
            "observed_source_matches": observedSourceMatches,
            "blocked_by_previous_result": blockedByPreviousResult,
            "extracted_result_utf16": extractedUTF16,
            "result_mutation_count": mutationCount
        ]
        webTimingFields.forEach { fields[$0.key] = $0.value }
        logTranslationTiming("web-result-rejected", diagnosticFields: fields)
    }

    func logTranslationTiming(
        _ milestone: String,
        details: String = "",
        diagnosticFields: [String: Any] = [:]
    ) {
        guard let request = translationTimingRequest else { return }
        let elapsed = (CACurrentMediaTime() - request.startedAt) * 1_000
        translationPipelineLogger.info(
            "[TranslationTiming][\(request.label, privacy: .public)][request=\(request.id, privacy: .public)][session=\(request.session, privacy: .public)] milestone=\(milestone, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 3)) \(details, privacy: .public)"
        )
        if diagnosticFields.isEmpty {
            TranslationPerformanceDiagnostics.shared.record(
                requestID: request.id,
                stage: milestone
            )
        } else {
            TranslationPerformanceDiagnostics.shared.recordDetailed(
                requestID: request.id,
                stage: milestone,
                extra: diagnosticFields
            )
        }
    }

    func logTranslationStateTransition(
        from: String,
        to: String,
        reason: String,
        markedText: Bool? = nil,
        requestID: Int? = nil
    ) {
        let resolvedRequestID = requestID ?? translationTimingRequest?.id ?? 0
        guard resolvedRequestID > 0 else { return }
        TranslationPerformanceDiagnostics.shared.recordStateTransition(
            requestID: resolvedRequestID,
            from: from,
            to: to,
            reason: reason,
            markedText: markedText
        )
    }

    func logTranslationCoordinator(
        _ milestone: String,
        source: String? = nil,
        requestID: Int? = nil,
        session: Int? = nil
    ) {
        let resolvedRequestID = requestID ?? translationTimingRequest?.id ?? 0
        let resolvedSession = session ?? translationCoordinator.session
        let characterCount = source?.count ?? longTextSourceView?.string.count ?? 0
        let direction = "\(currentSourceLanguage.rawValue)->\(currentTargetLanguage.rawValue)"
        translationPipelineLogger.info(
            "[TranslationTiming][coordinator][request=\(resolvedRequestID, privacy: .public)][session=\(resolvedSession, privacy: .public)] milestone=\(milestone, privacy: .public) chars=\(characterCount, privacy: .public) direction=\(direction, privacy: .public)"
        )
        guard resolvedRequestID > 0 else {
            let diagnosticSource = source ?? longTextSourceView?.string ?? ""
            TranslationPerformanceDiagnostics.shared.recordEvent(
                stage: milestone,
                characterCount: diagnosticSource.count,
                utf16Count: diagnosticSource.utf16.count,
                direction: direction
            )
            return
        }
        let terminalStatus: String?
        switch milestone {
        case "request-invalidated-by-new-input":
            terminalStatus = "cancelled"
        case "fallback-cancelled-as-stale":
            terminalStatus = "cancelled-stale"
        default:
            terminalStatus = nil
        }
        if let terminalStatus {
            TranslationPerformanceDiagnostics.shared.finish(
                requestID: resolvedRequestID,
                stage: milestone,
                status: terminalStatus
            )
        } else {
            TranslationPerformanceDiagnostics.shared.record(
                requestID: resolvedRequestID,
                stage: milestone
            )
        }
    }
}
