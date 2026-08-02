//
//  TranslationServiceCoordinator+TextProcessing.swift
//  translate
//

import Foundation
import os

extension TranslationServiceCoordinator {
    func textRemovingLineBreaks(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined()
    }

    func splitLongText(_ text: String) -> [TranslationChunk] {
        if let balancedPair = balancedParallelWebChunks(text) {
            return balancedPair
        }
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

    /// Two warm WebViews are useful only when their work is comparable. The
    /// generic chunker fills the first chunk toward 4,500 UTF-16 units, which
    /// produced the observed 4,330 + 265 split and left the second DOM mostly
    /// idle. Documents that fit exactly two Web chunks instead split near the
    /// midpoint, while still preferring paragraph and sentence boundaries.
    private func balancedParallelWebChunks(_ text: String) -> [TranslationChunk]? {
        let totalUTF16 = text.utf16.count
        guard totalUTF16 > googleWebChunkUTF16Limit,
              totalUTF16 <= googleWebChunkUTF16Limit * 2 else {
            return nil
        }

        typealias Candidate = (
            leftEnd: String.Index,
            rightStart: String.Index,
            separator: String,
            score: Int
        )
        let midpoint = totalUTF16 / 2
        let sentenceBreaks = CharacterSet(charactersIn: ".!?。！？")
        let whitespace = CharacterSet.whitespacesAndNewlines
        var best: Candidate?

        func consider(
            leftEnd: String.Index,
            rightStart: String.Index,
            leftUTF16: Int,
            rightStartUTF16: Int,
            separator: String,
            penalty: Int
        ) {
            guard leftUTF16 > 0,
                  totalUTF16 - rightStartUTF16 > 0,
                  leftUTF16 <= googleWebChunkUTF16Limit,
                  totalUTF16 - rightStartUTF16 <= googleWebChunkUTF16Limit else {
                return
            }
            let boundaryCenter = (leftUTF16 + rightStartUTF16) / 2
            let candidate = Candidate(
                leftEnd,
                rightStart,
                separator,
                abs(boundaryCenter - midpoint) + penalty
            )
            if best == nil || candidate.score < best!.score {
                best = candidate
            }
        }

        var index = text.startIndex
        var utf16Offset = 0
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index..<next]
            let characterUTF16 = character.utf16.count
            let afterOffset = utf16Offset + characterUTF16
            let isWhitespace = character.unicodeScalars.allSatisfy(whitespace.contains)

            if isWhitespace {
                let runStart = index
                let runStartOffset = utf16Offset
                var runEnd = next
                var runEndOffset = afterOffset
                while runEnd < text.endIndex {
                    let runNext = text.index(after: runEnd)
                    let runCharacter = text[runEnd..<runNext]
                    guard runCharacter.unicodeScalars.allSatisfy(whitespace.contains) else {
                        break
                    }
                    runEndOffset += runCharacter.utf16.count
                    runEnd = runNext
                }
                let separator = String(text[runStart..<runEnd])
                let containsLineBreak = separator.unicodeScalars.contains {
                    CharacterSet.newlines.contains($0)
                }
                consider(
                    leftEnd: runStart,
                    rightStart: runEnd,
                    leftUTF16: runStartOffset,
                    rightStartUTF16: runEndOffset,
                    separator: separator,
                    penalty: containsLineBreak ? 0 : totalUTF16 / 16
                )
                index = runEnd
                utf16Offset = runEndOffset
                continue
            }

            // A sentence boundary may move slightly away from the exact
            // midpoint to keep complete thoughts together. A hard character
            // boundary remains the last resort for text without separators.
            let isSentenceBreak = character.unicodeScalars.allSatisfy {
                sentenceBreaks.contains($0)
            }
            consider(
                leftEnd: next,
                rightStart: next,
                leftUTF16: afterOffset,
                rightStartUTF16: afterOffset,
                separator: "",
                penalty: isSentenceBreak ? totalUTF16 / 50 : totalUTF16 / 8
            )
            index = next
            utf16Offset = afterOffset
        }

        guard let best else { return nil }
        return [
            TranslationChunk(
                text: String(text[..<best.leftEnd]),
                separatorAfter: best.separator
            ),
            TranslationChunk(
                text: String(text[best.rightStart...]),
                separatorAfter: ""
            )
        ]
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
}
