//
//  TranslationServiceCoordinator.swift
//  translate
//

import Foundation
import os

let translationServiceLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "TranslationPipeline"
)

/// Owns the mutable state for the long-text translation pipeline.
///
/// ViewController still drives the existing pipeline while this first
/// extraction keeps request ordering, retries, polling, and UI behavior
/// unchanged. Later extractions can move operations behind this boundary
/// without spreading pipeline state across the view controller.
final class TranslationServiceCoordinator {
    let googleWebChunkUTF16Limit = 4_500

    struct Invalidation {
        let session: Int
        let hadPipelineWork: Bool
        let cancelledScheduledPoll: Bool
        let cancelledFallbackTask: Bool
    }

    struct OrderedConcurrentResult {
        let translation: String
        let separator: String
        let replacesVisibleTranslation: Bool
        let usedAPI: Bool
    }

    var completedSource = ""
    var completedTranslation = ""
    var completedSourceLanguage = ""
    var completedTargetLanguage = ""
    var replacesVisibleTranslation = false
    var formattingOnlyRefresh = false

    var chunks: [TranslationChunk] = []
    var chunkIndex = 0
    var chunkRetryCount = 0

    var usesConcurrentAPIBatch = false
    var concurrentAPITasks: [Int: URLSessionDataTask] = [:]
    var concurrentAPIResults: [Int: String] = [:]
    var concurrentAPIRetryCounts: [Int: Int] = [:]
    var concurrentAPIWebResultIndexes: Set<Int> = []
    var concurrentAPIBatchStarted = false

    var session = 0
    var pollAttempts = 0
    var lastWebTranslation: String?
    var candidateTranslation: String?
    var candidateUpdatedAt: Date?
    var activeWebViewGeneration = 0
    var pollInFlightSession: Int?
    var scheduledPoll: DispatchWorkItem?
    var webDeadline: Date?
    var webStartedAt: Date?
    var webRetryTriggered = false
    var webHasValidCandidate = false
    var provisionalFallbackStarted = false
    var provisionalFallbackTranslation: String?
    var provisionalFallbackPreviewDisplayed = false
    var fallbackShouldFinalize = false
    var lastWebActivityAt: Date?
    var coldResumeHedgeActive = false
    private var webResultRejectionCounts: [String: Int] = [:]

    var debounceWorkItem: DispatchWorkItem?
    var fallbackTask: URLSessionDataTask?
    var lastRecoveredResultDisplaySession: Int?

    @discardableResult
    func beginSession(
        chunks newChunks: [TranslationChunk],
        keepsVisibleResult: Bool,
        formattingOnly: Bool,
        concurrentAPIChunkThreshold: Int
    ) -> Int {
        activeWebViewGeneration += 1
        session += 1
        replacesVisibleTranslation = keepsVisibleResult
        formattingOnlyRefresh = formattingOnly
        chunks = newChunks
        chunkIndex = 0
        usesConcurrentAPIBatch = newChunks.count >= concurrentAPIChunkThreshold
        concurrentAPIResults.removeAll(keepingCapacity: true)
        concurrentAPIRetryCounts.removeAll(keepingCapacity: true)
        concurrentAPIWebResultIndexes.removeAll(keepingCapacity: true)
        concurrentAPIBatchStarted = false
        pollAttempts = 0
        lastWebTranslation = nil
        candidateTranslation = nil
        candidateUpdatedAt = nil
        webResultRejectionCounts.removeAll(keepingCapacity: true)
        scheduledPoll?.cancel()
        scheduledPoll = nil
        pollInFlightSession = nil
        return session
    }

    func invalidate() -> Invalidation {
        let invalidatedSession = session
        let cancelledScheduledPoll = scheduledPoll != nil
        let cancelledFallbackTask = fallbackTask != nil
        let hadPipelineWork = cancelledScheduledPoll ||
            cancelledFallbackTask ||
            !concurrentAPITasks.isEmpty ||
            !chunks.isEmpty

        session += 1
        activeWebViewGeneration += 1
        pollInFlightSession = nil
        webDeadline = nil
        webStartedAt = nil
        webRetryTriggered = false
        webHasValidCandidate = false
        provisionalFallbackStarted = false
        provisionalFallbackTranslation = nil
        provisionalFallbackPreviewDisplayed = false
        fallbackShouldFinalize = false
        coldResumeHedgeActive = false
        candidateTranslation = nil
        candidateUpdatedAt = nil
        webResultRejectionCounts.removeAll(keepingCapacity: true)
        chunks.removeAll(keepingCapacity: true)
        chunkIndex = 0
        usesConcurrentAPIBatch = false
        concurrentAPIResults.removeAll(keepingCapacity: true)
        concurrentAPIRetryCounts.removeAll(keepingCapacity: true)
        concurrentAPIWebResultIndexes.removeAll(keepingCapacity: true)
        concurrentAPIBatchStarted = false

        scheduledPoll?.cancel()
        scheduledPoll = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        concurrentAPITasks.values.forEach { $0.cancel() }
        concurrentAPITasks.removeAll(keepingCapacity: true)

        return Invalidation(
            session: invalidatedSession,
            hadPipelineWork: hadPipelineWork,
            cancelledScheduledPoll: cancelledScheduledPoll,
            cancelledFallbackTask: cancelledFallbackTask
        )
    }

    @discardableResult
    func prepareNextChunk(
        webResultDeadline: TimeInterval,
        coldResumeIdleThreshold: TimeInterval
    ) -> TimeInterval? {
        let now = Date()
        let idleDuration = lastWebActivityAt.map { now.timeIntervalSince($0) }
        lastWebActivityAt = now
        pollAttempts = 0
        chunkRetryCount = 0
        webDeadline = now.addingTimeInterval(webResultDeadline)
        webStartedAt = now
        webRetryTriggered = false
        webHasValidCandidate = false
        provisionalFallbackStarted = false
        provisionalFallbackTranslation = nil
        provisionalFallbackPreviewDisplayed = false
        fallbackShouldFinalize = false
        coldResumeHedgeActive = idleDuration.map {
            $0 >= coldResumeIdleThreshold
        } ?? false
        candidateTranslation = nil
        candidateUpdatedAt = nil
        webResultRejectionCounts.removeAll(keepingCapacity: true)
        return idleDuration
    }

    func markWebServiceActive() {
        lastWebActivityAt = Date()
    }

    func clearCompletedSnapshot() {
        completedSource = ""
        completedTranslation = ""
        completedSourceLanguage = ""
        completedTargetLanguage = ""
        replacesVisibleTranslation = false
        formattingOnlyRefresh = false
    }

    func clearTranslationBuffers() {
        chunks.removeAll(keepingCapacity: true)
        chunkIndex = 0
        candidateTranslation = nil
        candidateUpdatedAt = nil
    }

    func enableConcurrentAPIFallback(
        reusingWebResults: [Int: String] = [:]
    ) {
        usesConcurrentAPIBatch = true
        concurrentAPITasks.values.forEach { $0.cancel() }
        concurrentAPITasks.removeAll(keepingCapacity: true)
        concurrentAPIResults = reusingWebResults
        concurrentAPIRetryCounts.removeAll(keepingCapacity: true)
        concurrentAPIWebResultIndexes = Set(reusingWebResults.keys)
        concurrentAPIBatchStarted = false
    }

    func clearAfterEmptyInput() {
        clearCompletedSnapshot()
        clearTranslationBuffers()
        usesConcurrentAPIBatch = false
        concurrentAPITasks.values.forEach { $0.cancel() }
        concurrentAPITasks.removeAll(keepingCapacity: true)
        concurrentAPIResults.removeAll(keepingCapacity: true)
        concurrentAPIRetryCounts.removeAll(keepingCapacity: true)
        concurrentAPIWebResultIndexes.removeAll(keepingCapacity: true)
        concurrentAPIBatchStarted = false
        pollAttempts = 0
        lastWebTranslation = nil
        scheduledPoll?.cancel()
        scheduledPoll = nil
        pollInFlightSession = nil
    }

    func resultSettlingInterval(default defaultInterval: TimeInterval) -> TimeInterval {
        guard chunks.count == 1, let chunk = chunks.first else {
            return defaultInterval
        }
        switch chunk.text.utf16.count {
        case ...600:
            return 0.55
        case ...2_000:
            return 0.6
        default:
            return 0.65
        }
    }

    @discardableResult
    func noteValidGoogleWebCandidate() -> Bool {
        guard !webHasValidCandidate else { return false }
        webHasValidCandidate = true
        guard fallbackTask != nil else { return false }
        fallbackTask?.cancel()
        fallbackTask = nil
        return true
    }

    @discardableResult
    func recordCandidate(_ translation: String) -> Bool {
        guard translation != candidateTranslation else { return false }
        candidateTranslation = translation
        candidateUpdatedAt = Date()
        return true
    }

    func recordWebResultRejection(role: String, reason: String) -> (count: Int, isFirst: Bool) {
        let key = "\(role)_\(reason)"
        let count = webResultRejectionCounts[key, default: 0] + 1
        webResultRejectionCounts[key] = count
        return (count, count == 1)
    }

    var webResultRejectionSummaryFields: [String: Any] {
        webResultRejectionCounts.reduce(into: [:]) { fields, item in
            fields["web_rejection_\(item.key)_count"] = item.value
        }
    }

    @discardableResult
    func startConcurrentAPIBatch(
        session expectedSession: Int,
        sourceLanguage: String,
        targetLanguage: String,
        onStarted: () -> Void,
        onChunkReady: @escaping () -> Void,
        onOrderedResults: @escaping ([OrderedConcurrentResult], Bool) -> Void,
        onFailure: @escaping () -> Void
    ) -> Bool {
        guard expectedSession == session,
              usesConcurrentAPIBatch,
              !concurrentAPIBatchStarted else {
            return false
        }

        concurrentAPIBatchStarted = true
        onStarted()
        for (index, chunk) in chunks.enumerated() {
            if concurrentAPIResults[index] != nil {
                continue
            } else if chunk.text.isEmpty {
                concurrentAPIResults[index] = ""
            } else {
                requestConcurrentAPIChunk(
                    chunk.text,
                    chunkIndex: index,
                    session: expectedSession,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    onChunkReady: onChunkReady,
                    onOrderedResults: onOrderedResults,
                    onFailure: onFailure
                )
            }
        }
        flushConcurrentAPIResults(
            session: expectedSession,
            onOrderedResults: onOrderedResults
        )
        return true
    }

    private func requestConcurrentAPIChunk(
        _ chunk: String,
        chunkIndex: Int,
        session expectedSession: Int,
        sourceLanguage: String,
        targetLanguage: String,
        onChunkReady: @escaping () -> Void,
        onOrderedResults: @escaping ([OrderedConcurrentResult], Bool) -> Void,
        onFailure: @escaping () -> Void
    ) {
        guard expectedSession == session,
              usesConcurrentAPIBatch,
              let request = Self.googleTranslationRequest(
                  for: chunk,
                  sourceLanguage: sourceLanguage,
                  targetLanguage: targetLanguage
              ) else {
            onFailure()
            return
        }

        let task = URLSession.shared.dataTask(with: request) {
            [weak self] data, response, error in
            let translation = data.flatMap(Self.translationText(from:))
            let succeeded = error == nil &&
                (response as? HTTPURLResponse).map {
                    200..<300 ~= $0.statusCode
                } == true &&
                !(translation?.isEmpty ?? true)

            DispatchQueue.main.async {
                guard let self,
                      expectedSession == self.session,
                      self.usesConcurrentAPIBatch,
                      self.chunks.indices.contains(chunkIndex) else {
                    return
                }
                self.concurrentAPITasks[chunkIndex] = nil
                guard succeeded, let translation else {
                    let retries = self.concurrentAPIRetryCounts[
                        chunkIndex,
                        default: 0
                    ]
                    guard retries == 0 else {
                        onFailure()
                        return
                    }
                    self.concurrentAPIRetryCounts[chunkIndex] = retries + 1
                    self.requestConcurrentAPIChunk(
                        chunk,
                        chunkIndex: chunkIndex,
                        session: expectedSession,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        onChunkReady: onChunkReady,
                        onOrderedResults: onOrderedResults,
                        onFailure: onFailure
                    )
                    return
                }

                self.concurrentAPIResults[chunkIndex] =
                    TranslationServiceTextNormalizer.normalize(
                        translation,
                        forSource: chunk
                    )
                onChunkReady()
                self.flushConcurrentAPIResults(
                    session: expectedSession,
                    onOrderedResults: onOrderedResults
                )
            }
        }
        concurrentAPITasks[chunkIndex] = task
        task.resume()
    }

    private func flushConcurrentAPIResults(
        session expectedSession: Int,
        onOrderedResults: ([OrderedConcurrentResult], Bool) -> Void
    ) {
        guard expectedSession == session, usesConcurrentAPIBatch else { return }
        var orderedResults: [OrderedConcurrentResult] = []

        while chunks.indices.contains(chunkIndex),
              let translation = concurrentAPIResults.removeValue(
                  forKey: chunkIndex
              ) {
            let separator = chunks[chunkIndex].separatorAfter
            let replacesResult = replacesVisibleTranslation && chunkIndex == 0
            if replacesResult {
                replacesVisibleTranslation = false
            }
            orderedResults.append(OrderedConcurrentResult(
                translation: translation,
                separator: separator,
                replacesVisibleTranslation: replacesResult,
                usedAPI: concurrentAPIWebResultIndexes.remove(chunkIndex) == nil
            ))
            chunkIndex += 1
        }

        guard !orderedResults.isEmpty else { return }
        onOrderedResults(orderedResults, chunkIndex == chunks.count)
    }
}
