//
//  TranslationPerformanceDiagnostics.swift
//  translate
//

import Foundation
import QuartzCore

#if DEBUG
final class TranslationPerformanceDiagnostics {
    static let shared = TranslationPerformanceDiagnostics()

    static let logPath: String = {
        let library = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!
        return library
            .appendingPathComponent("Logs/Translate", isDirectory: true)
            .appendingPathComponent("translation-performance.jsonl")
            .path
    }()

    private struct RequestContext {
        let startedAt: CFTimeInterval
        var lastEventAt: CFTimeInterval
        let characterCount: Int
        let utf16Count: Int
        let direction: String
        var isTerminal = false
    }

    private let queue = DispatchQueue(
        label: "com.lalalaladam.translate.performance-diagnostics",
        qos: .utility
    )
    private let runID = UUID().uuidString
    private let logURL: URL
    private var requests: [Int: RequestContext] = [:]

    private init() {
        logURL = URL(fileURLWithPath: Self.logPath)
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                appendRecord([
                    "timestamp": Self.timestamp(),
                    "run_id": runID,
                    "request_id": 0,
                    "stage": "diagnostics-started",
                    "elapsed_ms": 0.0,
                    "stage_ms": 0.0,
                    "text_chars": 0,
                    "text_utf16": 0,
                    "direction": "none",
                    "status": "ready"
                ])
            } catch {
                // Diagnostics must never interfere with translation behavior.
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

    func finish(requestID: Int, stage: String, status: String) {
        guard requestID > 0 else { return }
        let now = CACurrentMediaTime()
        queue.async { [self] in
            guard requests[requestID]?.isTerminal == false else { return }
            write(requestID: requestID, stage: stage, status: status, at: now)
            requests[requestID]?.isTerminal = true
        }
    }

    private func write(
        requestID: Int,
        stage: String,
        status: String,
        at now: CFTimeInterval
    ) {
        guard var context = requests[requestID] else { return }
        let elapsed = max(0, (now - context.startedAt) * 1_000)
        let stageDuration = max(0, (now - context.lastEventAt) * 1_000)
        context.lastEventAt = now
        requests[requestID] = context
        appendRecord([
            "timestamp": Self.timestamp(),
            "run_id": runID,
            "request_id": requestID,
            "stage": stage,
            "elapsed_ms": Self.roundedMilliseconds(elapsed),
            "stage_ms": Self.roundedMilliseconds(stageDuration),
            "text_chars": context.characterCount,
            "text_utf16": context.utf16Count,
            "direction": context.direction,
            "status": status
        ])
    }

    private func appendRecord(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              var data = try? JSONSerialization.data(withJSONObject: record) else {
            return
        }
        data.append(0x0A)
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // A logging failure must remain invisible to the translation path.
        }
    }

    private static func roundedMilliseconds(_ value: Double) -> Double {
        (value * 1_000).rounded() / 1_000
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
#endif
