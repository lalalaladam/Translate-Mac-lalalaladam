//
//  TranslationPerformanceDiagnostics.swift
//  translate
//

import Foundation
import QuartzCore
import os

enum AppBuildMetadata {
    private static let bundle = Bundle.main

    static let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    static let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    static let gitCommit = bundle.object(forInfoDictionaryKey: "TranslateGitCommit") as? String ?? "unknown"
    static let gitWorkingTreeStatus = bundle.object(forInfoDictionaryKey: "TranslateGitWorkingTreeStatus") as? String ?? "unknown"
    static let buildTimestamp = bundle.object(forInfoDictionaryKey: "TranslateBuildTimestamp") as? String ?? "unknown"
    static let debugIdentifier = bundle.object(forInfoDictionaryKey: "TranslateDebugBuildIdentifier") as? String ?? "unknown"

    static var isDebugBuild: Bool {
        debugIdentifier != "unknown" && !debugIdentifier.isEmpty
    }

    static var logFields: [String: Any] {
        [
            "marketing_version": marketingVersion,
            "build_number": buildNumber,
            "git_commit": gitCommit,
            "git_working_tree_status": gitWorkingTreeStatus,
            "build_timestamp": buildTimestamp,
            "debug_build": debugIdentifier
        ]
    }

    static var debugAboutDescription: String {
        "Version: v\(marketingVersion)\nBuild: \(buildNumber)\nCommit: \(gitCommit)\nStatus: \(gitWorkingTreeStatus)\nBuild Time: \(buildTimestamp)"
    }
}

final class TranslationPerformanceDiagnostics {
    static let shared = TranslationPerformanceDiagnostics()

    static let logPath: String = {
        // App Sandbox does not grant write access to the shared
        // ~/Library/Logs directory. Application Support resolves inside the
        // app container, so the diagnostics can be recorded by signed
        // release builds as well as local builds.
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("Translate/Logs", isDirectory: true)
            .appendingPathComponent("translation-performance.jsonl")
            .path
    }()

    private static let logger = Logger(
        subsystem: "com.lalalaladam.translate",
        category: "PerformanceDiagnostics"
    )

    private struct RequestContext {
        let startedAt: CFTimeInterval
        var lastEventAt: CFTimeInterval
        let characterCount: Int
        let utf16Count: Int
        let direction: String
        var firstResultAt: CFTimeInterval?
        var firstVisibleResultAt: CFTimeInterval?
        var firstVisibleResultProvider: String?
        var idleBeforeRequestMilliseconds: Double?
        var coldResumeHedgeStarted = false
        var observerRegisteredCount = 0
        var observerDisconnectedCount = 0
        var timerScheduledCount = 0
        var timerFiredCount = 0
        var timerCancelledCount = 0
        var stateTransitionCount = 0
        var isTerminal = false
    }

    private let queue = DispatchQueue(
        label: "com.lalalaladam.translate.performance-diagnostics",
        qos: .utility
    )
    private let runID = UUID().uuidString
    private let logURL: URL
    private var requests: [Int: RequestContext] = [:]
    private var didReportWriteFailure = false
    // Keep the diagnostics useful for recent performance analysis without
    // allowing an always-on production log to grow without bound. Retaining
    // complete JSONL lines keeps the file directly consumable by jq.
    private let maximumLogBytes = 5 * 1_024 * 1_024
    private let retainedLogBytes = 2_500 * 1_024

    private init() {
        logURL = URL(fileURLWithPath: Self.logPath)
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
                        reportWriteFailure("Unable to create performance diagnostics log file.")
                        return
                    }
                }
                var startupRecord: [String: Any] = [
                    "timestamp": Self.timestamp(),
                    "run_id": runID,
                    "request_id": 0,
                    "level": 1,
                    "stage": "diagnostics-started",
                    "elapsed_ms": 0.0,
                    "stage_ms": 0.0,
                    "text_chars": 0,
                    "text_utf16": 0,
                    "direction": "none",
                    "status": "ready"
                ]
                startupRecord.merge(AppBuildMetadata.logFields) { _, new in new }
                appendRecord(startupRecord)
            } catch {
                reportWriteFailure("Unable to initialize performance diagnostics: \(error.localizedDescription)")
            }
        }
    }

    func begin(
        requestID: Int,
        characterCount: Int,
        utf16Count: Int,
        direction: String
    ) {
        let now = CACurrentMediaTime()
        queue.async { [self] in
            requests[requestID] = RequestContext(
                startedAt: now,
                lastEventAt: now,
                characterCount: characterCount,
                utf16Count: utf16Count,
                direction: direction
            )
            write(
                requestID: requestID,
                stage: "request-started",
                status: "running",
                at: now
            )
        }
    }

    func record(requestID: Int, stage: String, status: String = "running") {
        guard requestID > 0 else { return }
        let now = CACurrentMediaTime()
        queue.async { [self] in
            guard requests[requestID]?.isTerminal == false else { return }
            write(requestID: requestID, stage: stage, status: status, at: now)
        }
    }

    /// Records a privacy-safe diagnostic event with numeric or categorical
    /// fields. Callers must never place source or translated text in `extra`.
    func recordDetailed(
        requestID: Int,
        stage: String,
        status: String = "running",
        extra: [String: Any]
    ) {
        guard requestID > 0 else { return }
        let now = CACurrentMediaTime()
        queue.async { [self] in
            guard requests[requestID]?.isTerminal == false else { return }
            write(
                requestID: requestID,
                stage: stage,
                status: status,
                at: now,
                extra: extra
            )
        }
    }

    /// Level 2 state transition record. The optional flags describe runtime
    /// state only; source and translated text are intentionally never logged.
    func recordStateTransition(
        requestID: Int,
        from: String,
        to: String,
        reason: String,
        markedText: Bool? = nil
    ) {
        guard requestID > 0 else { return }
        let now = CACurrentMediaTime()
        var extra: [String: Any] = [
            "from_state": from,
            "to_state": to,
            "reason": reason
        ]
        if let markedText { extra["marked_text"] = markedText }
        queue.async { [self] in
            guard requests[requestID]?.isTerminal == false else { return }
            write(
                requestID: requestID,
                stage: "state-transition",
                status: "running",
                at: now,
                extra: extra
            )
        }
    }

    /// Records UI and coordination events that occur before a translation
    /// request exists (or after its request context has been retired).
    /// These records intentionally contain only counts, never source text.
    func recordEvent(
        stage: String,
        status: String = "info",
        characterCount: Int,
        utf16Count: Int,
        direction: String
    ) {
        queue.async { [self] in
            appendRecord([
                "timestamp": Self.timestamp(),
                "run_id": runID,
                "request_id": 0,
                "level": Self.level(for: stage),
                "stage": stage,
                "elapsed_ms": 0.0,
                "stage_ms": 0.0,
                "text_chars": characterCount,
                "text_utf16": utf16Count,
                "direction": direction,
                "status": status
            ])
        }
    }

    /// Debug-only, privacy-safe snapshots for diagnosing result-pane tail
    /// following. Text content is never recorded; only lengths and geometry.
    func recordTailFollowingEvent(
        stage: String,
        status: String,
        sequence: Int,
        trigger: String,
        followsTail: Bool?,
        resultUTF16: Int,
        documentHeight: Double? = nil,
        viewportHeight: Double? = nil,
        visibleMaxY: Double? = nil,
        distanceFromBottom: Double? = nil,
        reason: String? = nil
    ) {
        guard AppBuildMetadata.isDebugBuild else { return }
        queue.async { [self] in
            var record: [String: Any] = [
                "timestamp": Self.timestamp(),
                "run_id": runID,
                "request_id": 0,
                "level": 2,
                "stage": stage,
                "elapsed_ms": 0.0,
                "stage_ms": 0.0,
                "text_chars": 0,
                "text_utf16": resultUTF16,
                "direction": "result-tail",
                "status": status,
                "sequence": sequence,
                "trigger": trigger
            ]
            if let followsTail { record["follows_tail"] = followsTail }
            if let documentHeight { record["document_height"] = documentHeight }
            if let viewportHeight { record["viewport_height"] = viewportHeight }
            if let visibleMaxY { record["visible_max_y"] = visibleMaxY }
            if let distanceFromBottom {
                record["distance_from_bottom"] = distanceFromBottom
            }
            if let reason { record["reason"] = reason }
            record.merge(AppBuildMetadata.logFields) { _, new in new }
            appendRecord(record)
        }
    }

    func finish(requestID: Int, stage: String, status: String) {
        guard requestID > 0 else { return }
        let now = CACurrentMediaTime()
        queue.async { [self] in
            guard requests[requestID]?.isTerminal == false else { return }
            write(requestID: requestID, stage: stage, status: status, at: now)
            writeSummary(requestID: requestID, terminalStage: stage, terminalStatus: status, at: now)
            requests[requestID]?.isTerminal = true
        }
    }

    private func write(
        requestID: Int,
        stage: String,
        status: String,
        at now: CFTimeInterval,
        extra: [String: Any] = [:]
    ) {
        guard var context = requests[requestID] else { return }
        let elapsed = max(0, (now - context.startedAt) * 1_000)
        let stageDuration = max(0, (now - context.lastEventAt) * 1_000)
        context.lastEventAt = now
        updateCounters(for: stage, extra: extra, context: &context, at: now)
        requests[requestID] = context
        var record: [String: Any] = [
            "timestamp": Self.timestamp(),
            "run_id": runID,
            "request_id": requestID,
            "level": Self.level(for: stage),
            "stage": stage,
            "elapsed_ms": Self.roundedMilliseconds(elapsed),
            "stage_ms": Self.roundedMilliseconds(stageDuration),
            "text_chars": context.characterCount,
            "text_utf16": context.utf16Count,
            "direction": context.direction,
            "status": status
        ]
        extra.forEach { key, value in record[key] = value }
        appendRecord(record)
    }

    private func updateCounters(
        for stage: String,
        extra: [String: Any],
        context: inout RequestContext,
        at now: CFTimeInterval
    ) {
        if stage == "first-valid-result-displayed", context.firstResultAt == nil {
            context.firstResultAt = now
        }
        if stage == "first-visible-result-displayed",
           context.firstVisibleResultAt == nil {
            context.firstVisibleResultAt = now
            context.firstVisibleResultProvider = extra["provider"] as? String
        }
        if stage == "translation-idle-measured" {
            context.idleBeforeRequestMilliseconds =
                (extra["idle_before_request_ms"] as? NSNumber)?.doubleValue
        }
        if stage == "cold-resume-hedge-started" {
            context.coldResumeHedgeStarted = true
        }
        if stage.contains("observer-registered") || stage == "js-observer-ready" {
            context.observerRegisteredCount += 1
        }
        if stage.contains("observer-disconnected") { context.observerDisconnectedCount += 1 }
        if stage.contains("timer-scheduled") || stage.contains("debounce-scheduled") {
            context.timerScheduledCount += 1
        }
        if stage.contains("timer-fired") || stage.contains("debounce-fired") {
            context.timerFiredCount += 1
        }
        if stage.contains("timer-cancelled") || stage.contains("debounce-cancelled") {
            context.timerCancelledCount += 1
        }
        if stage == "state-transition" { context.stateTransitionCount += 1 }
    }

    private func writeSummary(
        requestID: Int,
        terminalStage: String,
        terminalStatus: String,
        at now: CFTimeInterval
    ) {
        guard let context = requests[requestID] else { return }
        let totalElapsed = max(0, (now - context.startedAt) * 1_000)
        let firstResultElapsed = context.firstResultAt.map {
            Self.roundedMilliseconds(max(0, ($0 - context.startedAt) * 1_000))
        }
        let firstVisibleResultElapsed = context.firstVisibleResultAt.map {
            Self.roundedMilliseconds(max(0, ($0 - context.startedAt) * 1_000))
        }
        var summary: [String: Any] = [
            "timestamp": Self.timestamp(),
            "run_id": runID,
            "request_id": requestID,
            "level": 3,
            "stage": "request-summary",
            "status": terminalStatus,
            "terminal_stage": terminalStage,
            "total_elapsed_ms": Self.roundedMilliseconds(totalElapsed),
            "text_chars": context.characterCount,
            "text_utf16": context.utf16Count,
            "direction": context.direction,
            "observer_registered_count": context.observerRegisteredCount,
            "observer_disconnected_count": context.observerDisconnectedCount,
            "timer_scheduled_count": context.timerScheduledCount,
            "timer_fired_count": context.timerFiredCount,
            "timer_cancelled_count": context.timerCancelledCount,
            "state_transition_count": context.stateTransitionCount,
            "cold_resume_hedge_started": context.coldResumeHedgeStarted
        ]
        if let firstResultElapsed { summary["first_result_elapsed_ms"] = firstResultElapsed }
        if let firstVisibleResultElapsed {
            summary["first_visible_result_elapsed_ms"] = firstVisibleResultElapsed
        }
        if let provider = context.firstVisibleResultProvider {
            summary["first_visible_result_provider"] = provider
        }
        if let idleMilliseconds = context.idleBeforeRequestMilliseconds {
            summary["idle_before_request_ms"] = idleMilliseconds
        }
        summary.merge(AppBuildMetadata.logFields) { _, new in new }
        appendRecord(summary)
    }

    private static func level(for stage: String) -> Int {
        if stage == "state-transition" ||
            stage.contains("timer") ||
            stage.contains("observer") ||
            stage.contains("ime") {
            return 2
        }
        return 1
    }

    private func appendRecord(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record) else {
            return
        }
        data.append(0x0A)
        do {
            trimLogIfNeeded(forAppending: data.count)
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            reportWriteFailure("Unable to write performance diagnostics: \(error.localizedDescription)")
        }
    }

    private func reportWriteFailure(_ message: String) {
        guard !didReportWriteFailure else { return }
        didReportWriteFailure = true
        Self.logger.error("\(message, privacy: .public)")
    }

    private func trimLogIfNeeded(forAppending byteCount: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let currentSize = attributes[.size] as? NSNumber,
              currentSize.intValue + byteCount > maximumLogBytes,
              let existingData = try? Data(contentsOf: logURL) else {
            return
        }

        let retainedStartOffset = max(0, existingData.count - retainedLogBytes)
        guard retainedStartOffset > 0 else { return }
        let candidateStart = existingData.index(
            existingData.startIndex,
            offsetBy: retainedStartOffset
        )
        guard let lineBreak = existingData[candidateStart...].firstIndex(of: 0x0A) else {
            return
        }
        let retainedData = Data(existingData[existingData.index(after: lineBreak)...])
        try? retainedData.write(to: logURL, options: .atomic)
    }

    private static func roundedMilliseconds(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
