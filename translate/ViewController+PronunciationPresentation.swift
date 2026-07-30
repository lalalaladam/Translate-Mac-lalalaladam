//
//  ViewController+PronunciationPresentation.swift
//  translate
//

import Cocoa

extension ViewController {
    func updatePronunciationLabels(source: String, translation: String) {
        updatePronunciationLabel(
            text: source,
            language: currentSourceLanguage,
            row: sourcePronunciationRow,
            label: sourcePronunciationLabel,
            pane: .source
        )
        updatePronunciationLabel(
            text: translation,
            language: currentTargetLanguage,
            row: translationPronunciationRow,
            label: translationPronunciationLabel,
            pane: .translation
        )
    }

    func updatePronunciationLabel(
        text: String,
        language: TranslateLanguage,
        row: NSView?,
        label: NSTextField?,
        pane: PronunciationPane
    ) {
        let word = singleWordForPronunciation(text)
        let key = word.map { "\(language.rawValue)|\($0.lowercased())" }
        let cachedKey = pane == .source
            ? sourcePronunciationKey
            : translationPronunciationKey
        guard key != cachedKey else {
            refreshPronunciationDisplayLabel(for: pane)
            return
        }

        if pane == .source {
            sourcePronunciationKey = key
            sourcePronunciationValue = nil
            sourcePronunciationSource = .standard
            sourcePronunciationGeneration += 1
        } else {
            translationPronunciationKey = key
            translationPronunciationValue = nil
            translationPronunciationSource = .standard
            translationPronunciationGeneration += 1
        }
        let requestGeneration = pane == .source
            ? sourcePronunciationGeneration
            : translationPronunciationGeneration
        row?.isHidden = true
        label?.stringValue = ""

        guard let word else { return }
        PronunciationService.fetch(word: word, language: language) { [weak self] pronunciation in
            guard let self,
                  (pane == .source
                      ? self.sourcePronunciationGeneration == requestGeneration
                      : self.translationPronunciationGeneration == requestGeneration),
                  (pane == .source
                      ? self.sourcePronunciationKey == key
                      : self.translationPronunciationKey == key),
                  let pronunciation,
                  !pronunciation.ipa.isEmpty else { return }
            if pane == .source {
                self.sourcePronunciationValue = pronunciation.ipa
                self.sourcePronunciationSource = pronunciation.source
            } else {
                self.translationPronunciationValue = pronunciation.ipa
                self.translationPronunciationSource = pronunciation.source
            }
            self.refreshPronunciationDisplayLabel(for: pane)
            row?.isHidden = false
        }
    }

    func refreshPronunciationDisplayLabels() {
        refreshPronunciationDisplayLabel(for: .source)
        refreshPronunciationDisplayLabel(for: .translation)
    }

    func refreshPronunciationDisplayLabel(for pane: PronunciationPane) {
        let value: String?
        let source: PronunciationSource
        let label: NSTextField?
        switch pane {
        case .source:
            value = sourcePronunciationValue
            source = sourcePronunciationSource
            label = sourcePronunciationLabel
        case .translation:
            value = translationPronunciationValue
            source = translationPronunciationSource
            label = translationPronunciationLabel
        }
        guard let value else {
            label?.stringValue = ""
            return
        }
        switch source {
        case .standard:
            label?.stringValue = interfaceText("音标  \(value)", "IPA  \(value)")
        case .ai:
            label?.stringValue = interfaceText("AI 返回  \(value)", "AI result  \(value)")
        case .estimated:
            label?.stringValue = interfaceText("推测  \(value)", "Estimated  \(value)")
        }
    }

    func singleWordForPronunciation(_ text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        let pattern = #"^[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              expression.firstMatch(
                  in: candidate,
                  range: NSRange(candidate.startIndex..., in: candidate)
              ) != nil else {
            return nil
        }
        return candidate
    }
}
