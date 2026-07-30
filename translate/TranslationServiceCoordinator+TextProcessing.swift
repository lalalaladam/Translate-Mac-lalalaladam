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
}
