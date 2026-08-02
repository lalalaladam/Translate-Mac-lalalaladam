//
//  ViewController+TranslationDiagnostics.swift
//  translate
//

import Cocoa
import os

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
