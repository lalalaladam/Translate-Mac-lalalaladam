//
//  TranslationServiceCoordinator.swift
//  translate
//

import Foundation
import os

private let translationServiceLogger = Logger(
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
    var fallbackShouldFinalize = false

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
        pollAttempts = 0
        lastWebTranslation = nil
        candidateTranslation = nil
        candidateUpdatedAt = nil
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
        fallbackShouldFinalize = false
        candidateTranslation = nil
        candidateUpdatedAt = nil
        chunks.removeAll(keepingCapacity: true)
        chunkIndex = 0
        usesConcurrentAPIBatch = false
        concurrentAPIResults.removeAll(keepingCapacity: true)
        concurrentAPIRetryCounts.removeAll(keepingCapacity: true)

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

    func prepareNextChunk(webResultDeadline: TimeInterval) {
        pollAttempts = 0
        chunkRetryCount = 0
        webDeadline = Date().addingTimeInterval(webResultDeadline)
        webStartedAt = Date()
        webRetryTriggered = false
        webHasValidCandidate = false
        provisionalFallbackStarted = false
        provisionalFallbackTranslation = nil
        fallbackShouldFinalize = false
        candidateTranslation = nil
        candidateUpdatedAt = nil
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

    func clearAfterEmptyInput() {
        clearCompletedSnapshot()
        clearTranslationBuffers()
        usesConcurrentAPIBatch = false
        concurrentAPITasks.values.forEach { $0.cancel() }
        concurrentAPITasks.removeAll(keepingCapacity: true)
        concurrentAPIResults.removeAll(keepingCapacity: true)
        concurrentAPIRetryCounts.removeAll(keepingCapacity: true)
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

    func textRemovingLineBreaks(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined()
    }

    func splitLongText(_ text: String) -> [TranslationChunk] {
        var chunks: [TranslationChunk] = []
        var start = text.startIndex

        while start < text.endIndex {
            var maximumEnd = start
            var utf16Count = 0
            while maximumEnd < text.endIndex {
                let next = text.index(after: maximumEnd)
                let characterUTF16Count = text[maximumEnd..<next].utf16.count
                guard utf16Count + characterUTF16Count <= googleWebChunkUTF16Limit else {
                    break
                }
                utf16Count += characterUTF16Count
                maximumEnd = next
            }
            if maximumEnd == text.endIndex {
                chunks.append(TranslationChunk(
                    text: String(text[start..<text.endIndex]),
                    separatorAfter: ""
                ))
                break
            }

            let candidate = text[start..<maximumEnd]
            let minimumBreakOffset = Int(Double(candidate.count) * 0.55)
            let minimumBreak = candidate.index(
                candidate.startIndex,
                offsetBy: minimumBreakOffset,
                limitedBy: candidate.endIndex
            ) ?? candidate.startIndex
            let sentenceBreakCharacters = CharacterSet(charactersIn: ".!?。！？")
            let whitespaceBreakCharacters = CharacterSet.whitespacesAndNewlines
            let isBreak = { (index: String.Index, characters: CharacterSet) in
                guard index >= minimumBreak else { return false }
                return candidate[index].unicodeScalars.allSatisfy {
                    characters.contains($0)
                }
            }
            let preferredBreak = candidate.indices.reversed().first {
                isBreak($0, sentenceBreakCharacters)
            } ?? candidate.indices.reversed().first {
                isBreak($0, whitespaceBreakCharacters)
            }

            if let preferredBreak {
                let next = text.index(after: preferredBreak)
                let boundary = text[preferredBreak..<next]
                let isWhitespace = boundary.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }
                var separatorStart = preferredBreak
                if isWhitespace {
                    while separatorStart > start {
                        let previous = text.index(before: separatorStart)
                        guard text[previous].unicodeScalars.allSatisfy({
                            CharacterSet.whitespacesAndNewlines.contains($0)
                        }) else { break }
                        separatorStart = previous
                    }
                }
                chunks.append(TranslationChunk(
                    text: String(text[start..<(isWhitespace ? separatorStart : next)]),
                    separatorAfter: isWhitespace
                        ? String(text[separatorStart..<next])
                        : ""
                ))
                start = next
            } else {
                chunks.append(TranslationChunk(
                    text: String(text[start..<maximumEnd]),
                    separatorAfter: ""
                ))
                start = maximumEnd
            }
        }

        return chunks.filter { !$0.text.isEmpty || !$0.separatorAfter.isEmpty }
    }

    func effectiveSourceLanguage(
        for text: String,
        selectedLanguage: TranslateLanguage
    ) -> TranslateLanguage {
        guard selectedLanguage != .automatic else { return .automatic }
        return inputMatchesLanguage(text, selectedLanguage)
            ? selectedLanguage
            : .automatic
    }

    private func inputMatchesLanguage(
        _ text: String,
        _ language: TranslateLanguage
    ) -> Bool {
        let scalars = text.unicodeScalars
        let hasHan = scalars.contains {
            (0x3400...0x4DBF).contains($0.value) ||
                (0x4E00...0x9FFF).contains($0.value) ||
                (0xF900...0xFAFF).contains($0.value)
        }
        let hasKana = scalars.contains { (0x3040...0x30FF).contains($0.value) }
        let hasHangul = scalars.contains { (0xAC00...0xD7AF).contains($0.value) }
        let hasCyrillic = scalars.contains { (0x0400...0x052F).contains($0.value) }
        let hasArabic = scalars.contains { (0x0600...0x06FF).contains($0.value) }
        let hasHebrew = scalars.contains { (0x0590...0x05FF).contains($0.value) }
        let hasGreek = scalars.contains { (0x0370...0x03FF).contains($0.value) }
        let hasLatin = scalars.contains {
            ($0.value >= 0x0041 && $0.value <= 0x005A) ||
                ($0.value >= 0x0061 && $0.value <= 0x007A) ||
                (0x00C0...0x024F).contains($0.value)
        }

        switch language {
        case .simplifiedChinese, .traditionalChinese:
            return hasHan && !hasKana && !hasHangul
        case .japanese:
            return hasKana
        case .korean:
            return hasHangul
        case .russian, .ukrainian, .bulgarian, .serbian, .belarusian:
            return hasCyrillic
        case .arabic, .persian, .urdu, .pashto:
            return hasArabic
        case .hebrew:
            return hasHebrew
        case .greek:
            return hasGreek
        case .english, .afrikaans, .albanian, .basque, .catalan, .croatian,
             .czech, .danish, .dutch, .estonian, .filipino, .finnish,
             .french, .german, .hungarian, .indonesian, .italian, .latin,
             .malay, .norwegian, .polish, .portuguese, .romanian, .slovak,
             .slovenian, .spanish, .swedish, .swahili, .turkish, .vietnamese:
            return hasLatin && !hasHan && !hasKana && !hasHangul &&
                !hasCyrillic && !hasArabic && !hasHebrew && !hasGreek
        default:
            return true
        }
    }

    static func googleTranslationRequest(
        for text: String,
        sourceLanguage: String,
        targetLanguage: String
    ) -> URLRequest? {
        var components = URLComponents(
            string: "https://translate.googleapis.com/translate_a/single"
        )
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sourceLanguage),
            URLQueryItem(name: "tl", value: targetLanguage),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Translate/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func translationText(from data: Data) -> String? {
        let rawResponse = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
        translationServiceLogger.info(
            "Google raw response: \(rawResponse, privacy: .public)"
        )
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = response.first as? [[Any]] else {
            translationServiceLogger.error("Google response JSON parsing failed")
            return nil
        }
        let translation = segments.compactMap { $0.first as? String }.joined()
        translationServiceLogger.info(
            "Google parsed translation: chars=\(translation.count, privacy: .public)"
        )
        return translation.isEmpty ? nil : translation
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
              concurrentAPITasks.isEmpty,
              concurrentAPIResults.isEmpty else {
            return false
        }

        onStarted()
        for (index, chunk) in chunks.enumerated() {
            if chunk.text.isEmpty {
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
                replacesVisibleTranslation: replacesResult
            ))
            chunkIndex += 1
        }

        guard !orderedResults.isEmpty else { return }
        onOrderedResults(orderedResults, chunkIndex == chunks.count)
    }
}
