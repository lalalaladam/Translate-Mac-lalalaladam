import Cocoa

import QuartzCore

import WebKit

extension ViewController {
    func alignmentSelection(in view: NSTextView) -> AlignmentSelection? {
        let selectedRange = view.selectedRange()
        guard selectedRange.length > 0 else { return nil }
        let text = view.string
        let nsText = text as NSString
        let units = alignmentUnitRanges(in: text)
        guard let firstIndex = units.firstIndex(where: {
            NSIntersectionRange($0, selectedRange).length > 0
        }), let lastIndex = units.lastIndex(where: {
            NSIntersectionRange($0, selectedRange).length > 0
        }) else { return nil }

        var lowerIndex = firstIndex
        var upperIndex = lastIndex
        func expandedSelection() -> (range: NSRange, text: String) {
            let start = units[lowerIndex].location
            let last = units[upperIndex]
            let range = NSRange(location: start, length: last.location + last.length - start)
            return (
                range,
                nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        var expanded = expandedSelection()
        while !isValidAlignmentText(expanded.text) {
            // Add whole units on both sides until even a selected word has
            // enough context to produce a dependable alignment request.
            if lowerIndex > units.startIndex {
                lowerIndex -= 1
                expanded = expandedSelection()
                if expanded.text.utf16.count > 4_000 { return nil }
                if isValidAlignmentText(expanded.text) { break }
            }
            if upperIndex < units.index(before: units.endIndex) {
                upperIndex += 1
                expanded = expandedSelection()
                if expanded.text.utf16.count > 4_000 { return nil }
            } else if lowerIndex == units.startIndex {
                return nil
            }
        }
        // Keep a little margin below Google's 4,500 UTF-16 chunk boundary.
        // This supports several paragraphs without making a single lookup
        // compete with the app's normal long-text translation path.
        guard !expanded.text.isEmpty, expanded.text.utf16.count <= 4_000,
              isValidAlignmentText(expanded.text) else { return nil }
        return AlignmentSelection(
            range: expanded.range,
            text: expanded.text,
            sentenceCount: upperIndex - lowerIndex + 1
        )
    }

    private func alignmentUnitRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let lineExpression = try? NSRegularExpression(pattern: #"(?m)^.*(?:\n|$)"#)
        let lines = (lineExpression?.matches(in: text, range: fullRange).map(\.range) ?? [])
            .filter { nsText.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        var units: [NSRange] = []
        for line in lines {
            let lineText = nsText.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if isCitationLikeAlignmentText(lineText) {
                units.append(line)
                continue
            }
            let sentenceExpression = try? NSRegularExpression(pattern: #"(?s)[^.!?。！？\n]+[.!?。！？]?"#)
            let sentences = sentenceExpression?.matches(in: text, range: line).map(\.range) ?? []
            units.append(contentsOf: sentences.isEmpty ? [line] : sentences)
        }
        return units
    }

    private func isCitationLikeAlignmentText(_ text: String) -> Bool {
        text.range(of: "doi:", options: .caseInsensitive) != nil ||
            text.range(of: #"^\s*\d+[.、]"#, options: .regularExpression) != nil
    }

    private func isValidAlignmentText(_ text: String) -> Bool {
        let hanCount = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }.count
        let wordCount = text.split { !$0.isLetter && !$0.isNumber }.count
        return hanCount >= 8 || (wordCount >= 4 && text.count >= 20)
    }

    func findCorrespondingText(from view: NSTextView, isSource: Bool) {
        let lookupStartedAt = CACurrentMediaTime()
        alignmentRequestCount += 1
        let diagnosticRequestID = 1_000_000 + alignmentRequestCount
        let sourceLanguage = isSource ? currentSourceLanguage.rawValue : currentTargetLanguage.rawValue
        let targetLanguage = isSource ? currentTargetLanguage.rawValue : currentSourceLanguage.rawValue
        let direction = "\(sourceLanguage)->\(targetLanguage)"
        let rawSelection = view.selectedRange()
        let rawSelectionText = rawSelection.length > 0
            ? (view.string as NSString).substring(with: rawSelection)
            : ""
        TranslationPerformanceDiagnostics.shared.begin(
            requestID: diagnosticRequestID,
            characterCount: rawSelectionText.count,
            utf16Count: rawSelectionText.utf16.count,
            direction: direction
        )

        guard longTextOverlay?.isHidden == false,
              let selection = alignmentSelection(in: view) else {
            TranslationPerformanceDiagnostics.shared.recordDetailed(
                requestID: diagnosticRequestID,
                stage: "alignment-selection-rejected",
                status: "rejected",
                extra: [
                    "raw_selection_utf16": rawSelectionText.utf16.count,
                    "selection_prepare_ms": (CACurrentMediaTime() - lookupStartedAt) * 1_000
                ]
            )
            TranslationPerformanceDiagnostics.shared.finish(
                requestID: diagnosticRequestID,
                stage: "alignment-finished",
                status: "rejected"
            )
            showAlignmentNotice(interfaceText("选区不符合要求", "Invalid selection"))
            return
        }
        guard let oppositeView = isSource ? longTextTranslationView : longTextSourceView,
              !oppositeView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            TranslationPerformanceDiagnostics.shared.finish(
                requestID: diagnosticRequestID,
                stage: "alignment-finished",
                status: "missing-opposite-text"
            )
            showAlignmentNotice(interfaceText("另一侧没有文本", "No text to search"))
            return
        }

        TranslationPerformanceDiagnostics.shared.recordDetailed(
            requestID: diagnosticRequestID,
            stage: "alignment-selection-ready",
            extra: [
                "raw_selection_utf16": rawSelectionText.utf16.count,
                "expanded_selection_chars": selection.text.count,
                "expanded_selection_utf16": selection.text.utf16.count,
                "expanded_unit_count": selection.sentenceCount,
                "opposite_text_utf16": oppositeView.string.utf16.count,
                "selection_prepare_ms": (CACurrentMediaTime() - lookupStartedAt) * 1_000
            ]
        )

        alignmentRequestGeneration += 1
        let generation = alignmentRequestGeneration
        let selectedTextSnapshot = view.string
        let oppositeTextSnapshot = oppositeView.string
        alignmentTask?.cancel()
        clearAlignmentHighlights(in: view)
        clearAlignmentHighlights(in: oppositeView)
        highlightAlignment(in: view, range: selection.range, color: .systemYellow)
        showAlignmentNotice(interfaceText("正在定位对应句…", "Finding corresponding text…"))

        guard let request = TranslationServiceCoordinator.googleTranslationRequest(
            for: selection.text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ) else { return }
        let requestSubmittedAt = CACurrentMediaTime()
        TranslationPerformanceDiagnostics.shared.recordDetailed(
            requestID: diagnosticRequestID,
            stage: "alignment-request-submitted",
            extra: ["request_prepare_ms": (requestSubmittedAt - lookupStartedAt) * 1_000]
        )
        alignmentTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let responseReceivedAt = CACurrentMediaTime()
            let parsingStartedAt = responseReceivedAt
            let translated = data.flatMap(
                TranslationServiceCoordinator.translationText(from:)
            )
            let parsingCompletedAt = CACurrentMediaTime()
            let succeeded = error == nil &&
                (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true &&
                !(translated?.isEmpty ?? true)
            DispatchQueue.main.async {
                guard let self,
                      generation == self.alignmentRequestGeneration,
                      view.string == selectedTextSnapshot,
                      oppositeView.string == oppositeTextSnapshot else {
                    TranslationPerformanceDiagnostics.shared.finish(
                        requestID: diagnosticRequestID,
                        stage: "alignment-finished",
                        status: "discarded-stale"
                    )
                    return
                }
                self.alignmentTask = nil
                guard succeeded, let translated else {
                    TranslationPerformanceDiagnostics.shared.recordDetailed(
                        requestID: diagnosticRequestID,
                        stage: "alignment-request-failed",
                        status: "failed",
                        extra: [
                            "http_status": (response as? HTTPURLResponse)?.statusCode ?? -1,
                            "network_ms": (responseReceivedAt - requestSubmittedAt) * 1_000,
                            "parse_ms": (parsingCompletedAt - parsingStartedAt) * 1_000,
                            "main_queue_ms": (CACurrentMediaTime() - parsingCompletedAt) * 1_000
                        ]
                    )
                    TranslationPerformanceDiagnostics.shared.finish(
                        requestID: diagnosticRequestID,
                        stage: "alignment-finished",
                        status: "failed"
                    )
                    self.showAlignmentNotice(interfaceText("定位失败", "Lookup failed"))
                    return
                }
                guard let candidate = self.bestAlignmentCandidate(
                    translated: translated,
                    selectedRange: selection.range,
                    selectedView: view,
                    oppositeView: oppositeView
                ) else {
                    TranslationPerformanceDiagnostics.shared.finish(
                        requestID: diagnosticRequestID,
                        stage: "alignment-finished",
                        status: "no-candidate"
                    )
                    self.showAlignmentNotice(interfaceText("未找到候选", "No candidate found"))
                    return
                }
                let displayStartedAt = CACurrentMediaTime()
                self.highlightAlignment(in: oppositeView, range: candidate.range, color: .systemGreen)
                oppositeView.scrollRangeToVisible(candidate.range)
                let confidence = candidate.score >= 0.62
                    ? interfaceText("已定位对应句", "Corresponding text located")
                    : interfaceText("已定位最接近的候选句", "Closest candidate located")
                self.showAlignmentNotice(confidence)
                TranslationPerformanceDiagnostics.shared.recordDetailed(
                    requestID: diagnosticRequestID,
                    stage: "alignment-result-displayed",
                    status: confidence == interfaceText("已定位对应句", "Corresponding text located") ? "matched" : "closest-candidate",
                    extra: [
                        "http_status": (response as? HTTPURLResponse)?.statusCode ?? -1,
                        "network_ms": (responseReceivedAt - requestSubmittedAt) * 1_000,
                        "parse_ms": (parsingCompletedAt - parsingStartedAt) * 1_000,
                        "main_queue_ms": (displayStartedAt - parsingCompletedAt) * 1_000,
                        "candidate_scoring_ms": candidate.scoringMilliseconds,
                        "candidate_evaluated_count": candidate.evaluatedCount,
                        "candidate_unit_count": candidate.unitCount,
                        "candidate_utf16": candidate.text.utf16.count,
                        "translated_utf16": translated.utf16.count,
                        "candidate_similarity": candidate.similarity,
                        "candidate_position_score": candidate.positionalScore,
                        "candidate_coverage_score": candidate.coverageScore,
                        "candidate_total_score": candidate.score,
                        "display_ms": (CACurrentMediaTime() - displayStartedAt) * 1_000,
                        "total_ms": (CACurrentMediaTime() - lookupStartedAt) * 1_000
                    ]
                )
                TranslationPerformanceDiagnostics.shared.finish(
                    requestID: diagnosticRequestID,
                    stage: "alignment-finished",
                    status: "completed"
                )
            }
        }
        alignmentTask?.resume()
    }

    private func bestAlignmentCandidate(
        translated: String,
        selectedRange: NSRange,
        selectedView: NSTextView,
        oppositeView: NSTextView
    ) -> AlignmentCandidate? {
        let text = oppositeView.string
        let nsText = text as NSString
        let units = alignmentUnitRanges(in: text)
        guard !units.isEmpty else { return nil }
        let expectedPosition = Double(selectedRange.location + selectedRange.length / 2) /
            Double(max(1, (selectedView.string as NSString).length))
        // `translated` is the expected text on the opposite side.  Its
        // UTF-16 length is therefore a much better coverage target than the
        // source selection's character count across languages.
        let expectedLength = max(1, translated.utf16.count)
        let maximumCandidateLength = max(160, Int(Double(expectedLength) * 1.85))
        var best: AlignmentCandidate?
        var evaluatedCount = 0
        let scoringStartedAt = CACurrentMediaTime()
        for start in units.indices {
            // A long selected passage may legitimately cover many short
            // sentences or table rows. Search enough complete units to cover
            // it, but bound work and avoid sweeping in a whole document.
            for count in 1...160 where start + count <= units.count {
                let first = units[start]
                let last = units[start + count - 1]
                let range = NSRange(location: first.location, length: last.location + last.length - first.location)
                let candidateText = nsText.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                let candidateLength = candidateText.utf16.count
                if candidateLength > maximumCandidateLength, count > 1 { break }
                evaluatedCount += 1
                let similarity = alignmentTextSimilarity(translated, candidateText)
                let position = Double(range.location + range.length / 2) / Double(max(1, nsText.length))
                let positionalScore = max(0, 1 - abs(expectedPosition - position) * 1.5)
                let coverageScore = Double(min(expectedLength, candidateLength)) /
                    Double(max(max(expectedLength, candidateLength), 1))
                let score = similarity * 0.52 + positionalScore * 0.13 + coverageScore * 0.35
                if best == nil || score > best!.score {
                    best = AlignmentCandidate(
                        range: range,
                        text: candidateText,
                        score: score,
                        unitCount: count,
                        evaluatedCount: 0,
                        similarity: similarity,
                        positionalScore: positionalScore,
                        coverageScore: coverageScore,
                        scoringMilliseconds: 0
                    )
                }
            }
        }
        guard let best else { return nil }
        return AlignmentCandidate(
            range: best.range,
            text: best.text,
            score: best.score,
            unitCount: best.unitCount,
            evaluatedCount: evaluatedCount,
            similarity: best.similarity,
            positionalScore: best.positionalScore,
            coverageScore: best.coverageScore,
            scoringMilliseconds: (CACurrentMediaTime() - scoringStartedAt) * 1_000
        )
    }

    private func alignmentTextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func tokens(_ text: String) -> Set<String> {
            let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let han = Array(text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.map(String.init))
            let bigrams = zip(han, han.dropFirst()).map { $0 + $1 }
            return Set(words + bigrams)
        }
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    private func clearAlignmentHighlights(in view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(alignmentHighlightMarker, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(self.alignmentHighlightMarker, range: range)
        }
    }

    private func highlightAlignment(in view: NSTextView, range: NSRange, color: NSColor) {
        view.textStorage?.addAttributes([
            .backgroundColor: color.withAlphaComponent(0.34),
            alignmentHighlightMarker: true
        ], range: range)
        view.scrollRangeToVisible(range)
    }

    private func showAlignmentNotice(_ text: String) {
        longTextStatusLabel?.stringValue = text
    }

}
