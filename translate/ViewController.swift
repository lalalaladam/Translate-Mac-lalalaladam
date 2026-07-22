//
//  ViewController.swift
//  translate
//

import Cocoa
import AVFoundation
import WebKit
import os

private let translationPipelineLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "TranslationPipeline"
)

private let startupTimingLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "StartupTiming"
)

private let inputMethodTimingLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "InputMethodTiming"
)

/// A deliberately plain-text editor for the app-owned source pane.  It does
/// not depend on WebKit's 5,000-character field, and inserting the pasteboard
/// string directly keeps very large pastes on the standard NSTextView path.
private final class TranslationSourceTextView: NSTextView {
    private var hasPendingImmediatePaste = false

    func consumeImmediatePasteFlag() -> Bool {
        let pending = hasPendingImmediatePaste
        hasPendingImmediatePaste = false
        return pending
    }

    override func paste(_ sender: Any?) {
        hasPendingImmediatePaste = true
        if let text = PlainTextPasteboardReader.read(from: .general) {
            insertText(text, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }
}

private enum PlainTextPasteboardReader {
    static func read(from pasteboard: NSPasteboard) -> String? {
        // Word, Pages and browsers normally publish a faithful public.utf8-plain-text
        // representation. Prefer it so HTML/RTF styling and embedded objects never
        // reach Google Translate.
        if let plain = pasteboard.string(forType: .string) {
            return minimallySanitized(plain)
        }

        // Some producers expose only attributed data. AppKit converts that data to
        // visible text while preserving paragraph breaks and tabs.
        for type in [NSPasteboard.PasteboardType.rtf, .rtfd, .html] {
            guard let data = pasteboard.data(forType: type),
                  let attributed = try? NSAttributedString(
                    data: data,
                    options: [:],
                    documentAttributes: nil
                  ) else { continue }
            return minimallySanitized(attributed.string)
        }
        return nil
    }

    private static func minimallySanitized(_ text: String) -> String {
        // U+FFFC represents an attachment rather than visible text. NUL cannot be
        // displayed by NSTextView/HTMLTextAreaElement. Preserve every whitespace,
        // line separator, tab and all other Unicode content byte-for-byte.
        text.unicodeScalars.reduce(into: "") { result, scalar in
            if scalar.value != 0 && scalar.value != 0xFFFC {
                result.unicodeScalars.append(scalar)
            }
        }
    }
}

private struct TranslationChunk {
    let text: String
    let separatorAfter: String
}

private enum TranslationSubmissionMode {
    case debouncedNativeInput
    case immediate
}

private enum PronunciationSource {
    case standard
    case ai
    case estimated
}

/// Fetches standard IPA for English words without loading a web page into the
/// visible translation workspace. Other languages intentionally return no
/// pronunciation until a reliable language-specific dictionary is available.
private struct PronunciationResult {
    let ipa: String
    let source: PronunciationSource
}

private enum PronunciationService {
    private static let dictionaryAPIBaseURL = "https://api.dictionaryapi.dev/api/v2/entries/en/"
    private static let oxfordDictionaryBaseURL = "https://www.oxfordlearnersdictionaries.com/definition/english/"
    private static let wiktionaryAPIBaseURL = "https://en.wiktionary.org/w/api.php"

    static func fetch(
        word: String,
        language: TranslateLanguage,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        guard language == .english else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let candidates = pronunciationLookupCandidates(for: word)
        fetchStandardCandidate(
            candidates,
            index: 0,
            originalWord: word,
            completion: completion
        )
    }

    private static func fetchStandardCandidate(
        _ candidates: [String],
        index: Int,
        originalWord: String,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        guard candidates.indices.contains(index) else {
            // Use the entered word for web/AI fallback. Derived candidates are
            // only for locating a standard dictionary headword.
            fetchFromGoogleSearch(word: originalWord, completion: completion)
            return
        }

        fetchStandardPronunciation(for: candidates[index]) { result in
            if let result {
                completion(result)
                return
            }
            fetchStandardCandidate(
                candidates,
                index: index + 1,
                originalWord: originalWord,
                completion: completion
            )
        }
    }

    private static func fetchStandardPronunciation(
        for word: String,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        guard let encodedWord = word.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
        let url = URL(string: "\(dictionaryAPIBaseURL)\(encodedWord)") else {
            fetchFromOxford(word: word, completion: completion)
            return
        }

        URLSession.shared.dataTask(with: URLRequest(url: url)) { data, response, _ in
            if let data,
               (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
               let pronunciation = pronunciation(from: data) {
                DispatchQueue.main.async {
                    completion(PronunciationResult(ipa: pronunciation, source: .standard))
                }
                return
            }

            fetchFromOxford(word: word, completion: completion)
        }.resume()
    }

    private static func pronunciation(from data: Data) -> String? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for entry in entries {
            if let phonetic = entry["phonetic"] as? String,
               !phonetic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return phonetic
            }

            guard let phonetics = entry["phonetics"] as? [[String: Any]] else { continue }
            for item in phonetics {
                if let text = item["text"] as? String,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func fetchFromOxford(
        word: String,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        guard let encodedWord = word.lowercased().addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
        let url = URL(string: "\(oxfordDictionaryBaseURL)\(encodedWord)") else {
            fetchFromWiktionary(word: word, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Translate/1.0 (macOS pronunciation lookup)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
                  let html = String(data: data, encoding: .utf8),
                  let pronunciation = pronunciationFromOxfordHTML(html) else {
                fetchFromWiktionary(word: word, completion: completion)
                return
            }
            DispatchQueue.main.async {
                completion(PronunciationResult(ipa: pronunciation, source: .standard))
            }
        }.resume()
    }

    private static func pronunciationFromOxfordHTML(_ html: String) -> String? {
        let pattern = #"(?is)<span\s+class=[\"']phon[\"'][^>]*>\s*([^<]+?)\s*</span>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let matches = expression.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        )
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[range])
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func fetchFromWiktionary(
        word: String,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        var components = URLComponents(string: wiktionaryAPIBaseURL)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: word),
            URLQueryItem(name: "prop", value: "wikitext"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "origin", value: "*")
        ]

        guard let url = components?.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        URLSession.shared.dataTask(with: URLRequest(url: url)) { data, response, _ in
            guard let data,
                  (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
                  let wikitext = wikitext(from: data),
                  let pronunciation = pronunciationFromEnglishWikitext(wikitext) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async {
                completion(PronunciationResult(ipa: pronunciation, source: .standard))
            }
        }.resume()
    }

    /// Returns the entered word first, followed by conservative English word
    /// forms that commonly point to the same dictionary headword. This keeps
    /// standard IPA available for inflections such as "running", "studies",
    /// "walked", and ordinary plurals before the app falls back to an estimate.
    private static func pronunciationLookupCandidates(for word: String) -> [String] {
        let normalized = word
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count >= 3,
              normalized.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value)
              }) else {
            return [normalized]
        }

        var candidates = [normalized]
        func add(_ candidate: String) {
            guard candidate.count >= 2,
                  candidate != normalized,
                  candidate.unicodeScalars.allSatisfy({
                      (97...122).contains($0.value)
                  }),
                  !candidates.contains(candidate) else {
                return
            }
            candidates.append(candidate)
        }

        if normalized.hasSuffix("'s") {
            add(String(normalized.dropLast(2)))
        } else if normalized.hasSuffix("s'") {
            add(String(normalized.dropLast()))
        }

        if normalized.hasSuffix("ies"), normalized.count > 4 {
            add(String(normalized.dropLast(3)) + "y")
        }
        if normalized.hasSuffix("ves"), normalized.count > 4 {
            let stem = String(normalized.dropLast(3))
            add(stem + "f")
            add(stem + "fe")
        }
        if normalized.hasSuffix("es"), normalized.count > 4 {
            add(String(normalized.dropLast(2)))
            add(String(normalized.dropLast()))
        }
        if normalized.hasSuffix("s"), normalized.count > 3 {
            add(String(normalized.dropLast()))
        }

        if normalized.hasSuffix("ied"), normalized.count > 4 {
            add(String(normalized.dropLast(3)) + "y")
        }
        if normalized.hasSuffix("ed"), normalized.count > 4 {
            let stem = String(normalized.dropLast(2))
            add(stem)
            add(stem + "e")
            add(removeDoubledFinalConsonant(from: stem))
        } else if normalized.hasSuffix("d"), normalized.count > 3 {
            add(String(normalized.dropLast()))
        }

        if normalized.hasSuffix("ing"), normalized.count > 5 {
            let stem = String(normalized.dropLast(3))
            add(stem)
            add(stem + "e")
            add(removeDoubledFinalConsonant(from: stem))
        }

        if normalized.hasSuffix("est"), normalized.count > 5 {
            let stem = String(normalized.dropLast(3))
            add(stem)
            add(stem + "e")
        } else if normalized.hasSuffix("er"), normalized.count > 4 {
            let stem = String(normalized.dropLast(2))
            add(stem)
            add(stem + "e")
        }

        return candidates
    }

    private static func removeDoubledFinalConsonant(from word: String) -> String {
        let characters = Array(word)
        guard characters.count >= 2,
              characters[characters.count - 1] == characters[characters.count - 2],
              !"aeiou".contains(characters[characters.count - 1]) else {
            return word
        }
        return String(characters.dropLast())
    }

    private static func wikitext(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parse = object["parse"] as? [String: Any] else {
            return nil
        }

        if let wikitext = parse["wikitext"] as? String {
            return wikitext
        }
        if let wikitextObject = parse["wikitext"] as? [String: Any] {
            return wikitextObject["*"] as? String
        }
        return nil
    }

    private static func pronunciationFromEnglishWikitext(_ wikitext: String) -> String? {
        // Limit matching to the English language section so a page containing
        // several languages cannot return another language's pronunciation.
        let englishSectionPattern = #"(?ms)^==\s*English\s*==\s*(.*?)(?=^==[^=].*==\s*$|\z)"#
        guard let sectionExpression = try? NSRegularExpression(pattern: englishSectionPattern),
              let sectionMatch = sectionExpression.firstMatch(
                  in: wikitext,
                  range: NSRange(wikitext.startIndex..., in: wikitext)
              ),
              let sectionRange = Range(sectionMatch.range(at: 1), in: wikitext) else {
            return nil
        }

        let englishSection = String(wikitext[sectionRange])
        let templatePattern = #"\{\{\s*IPA(?:char)?\s*\|([^{}]*)\}\}"#
        guard let templateExpression = try? NSRegularExpression(pattern: templatePattern) else {
            return nil
        }

        let matches = templateExpression.matches(
            in: englishSection,
            range: NSRange(englishSection.startIndex..., in: englishSection)
        )
        for match in matches {
            guard let contentRange = Range(match.range(at: 1), in: englishSection) else {
                continue
            }
            let parameters = englishSection[contentRange]
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            for parameter in parameters {
                let value = parameter
                    .replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      value != "en",
                      !value.contains("="),
                      value.range(of: #"[\[\]/ˈˌəɪʊɔɑæɛɜɒθðʃʒŋː]"#, options: .regularExpression) != nil else {
                    continue
                }
                return value
            }
        }
        return nil
    }

    private static func fetchFromGoogleSearch(
        word: String,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        // WebKit website data stores must be created and used from the main
        // thread. This fallback is reached from URLSession callbacks, which
        // otherwise causes WebKit to raise an EXC_BREAKPOINT and terminate
        // the app for words missing from the dictionary sources.
        DispatchQueue.main.async {
            // Show a conservative estimate immediately when one is available.
            // The hidden Google lookup continues in the background and can
            // replace it later with an AI or standard result.
            if let ipa = estimatedPronunciation(for: word) {
                completion(PronunciationResult(ipa: ipa, source: .estimated))
            }

            BackgroundGooglePronunciationLookup.shared.fetch(
                word: word,
                completion: { result in
                    if let result {
                        completion(result)
                    } else if estimatedPronunciation(for: word) == nil {
                        completion(nil)
                    }
                }
            )
        }
    }

    /// Conservative fallback pronunciations for common coined, slang, and
    /// compound words that may not yet have a dictionary entry. These values
    /// are deliberately marked as estimated in the interface and are never
    /// presented as authoritative dictionary IPA.
    private static func estimatedPronunciation(for word: String) -> String? {
        let estimates: [String: String] = [
            "infollution": "/ˌɪn.fəˈluː.ʃən/",
            "interstellar": "/ˌɪn.təˈstel.ər/",
            "rizz": "/rɪz/",
            "delulu": "/dəˈluː.luː/",
            "cheugy": "/ˈtʃuː.ɡi/",
            "boujee": "/ˈbuː.dʒi/",
            "skibidi": "/ˈskɪ.bɪ.di/",
            "finfluencer": "/ˈfɪn.flu.ən.sər/",
            "situationship": "/ˌsɪtʃ.uˈeɪ.ʃən.ʃɪp/",
            "nomophobia": "/ˌnoʊ.məˈfoʊ.bi.ə/",
            "quinoa": "/ˈkiːn.wɑː/",
            "goat": "/ɡoʊt/",
            "grwm": "/ˈɡɜːr.wəm/"
        ]
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let estimate = estimates[normalizedWord] {
            return estimate
        }
        return generatedEstimate(for: normalizedWord)
    }

    /// Generates a deliberately approximate pronunciation for an English word
    /// that has no dictionary or web result. This is a fallback of last resort:
    /// it uses common spelling patterns, does not claim a dialect, and is
    /// always displayed with the "Estimated"/"推测" label.
    private static func generatedEstimate(for word: String) -> String? {
        guard word.count >= 2,
              word.unicodeScalars.allSatisfy({
                  (97...122).contains($0.value)
              }) else {
            return nil
        }

        var spelling = word
        if spelling.hasSuffix("e"), spelling.count > 3 {
            spelling.removeLast()
        }

        let spellingPatterns: [(String, String)] = [
            ("eigh", "eɪ"),
            ("ough", "ɔː"),
            ("tion", "ʃən"),
            ("sion", "ʒən"),
            ("cian", "ʃən"),
            ("ture", "tʃər"),
            ("dge", "dʒ"),
            ("igh", "aɪ"),
            ("ph", "f"),
            ("ch", "tʃ"),
            ("sh", "ʃ"),
            ("th", "θ"),
            ("wh", "w"),
            ("qu", "kw"),
            ("ck", "k"),
            ("ng", "ŋ"),
            ("ee", "iː"),
            ("ea", "iː"),
            ("oo", "uː"),
            ("ou", "aʊ"),
            ("ow", "aʊ"),
            ("oi", "ɔɪ"),
            ("oy", "ɔɪ"),
            ("ai", "eɪ"),
            ("ay", "eɪ"),
            ("oa", "oʊ")
        ]
        for (pattern, replacement) in spellingPatterns {
            spelling = spelling.replacingOccurrences(of: pattern, with: replacement)
        }

        let characters = Array(spelling)
        var pronunciation = ""
        for index in characters.indices {
            let character = characters[index]
            if "ɑɐɒæəɛɜɪɨʊɔːˈˌθðʃʒŋɡʔ".contains(character) {
                pronunciation.append(character)
                continue
            }

            let nextCharacter = characters.indices.contains(index + 1)
                ? characters[index + 1]
                : nil
            let nextCharacterSoftensConsonant = nextCharacter.map {
                "eiy".contains($0)
            } ?? false
            switch character {
            case "a":
                pronunciation += "æ"
            case "e":
                pronunciation += "ɛ"
            case "i":
                pronunciation += "ɪ"
            case "o":
                pronunciation += "ɒ"
            case "u":
                pronunciation += "ʌ"
            case "y":
                pronunciation += "i"
            case "c":
                pronunciation += nextCharacterSoftensConsonant ? "s" : "k"
            case "g":
                pronunciation += nextCharacterSoftensConsonant ? "dʒ" : "ɡ"
            case "j":
                pronunciation += "dʒ"
            case "q":
                pronunciation += "k"
            case "x":
                pronunciation += "ks"
            case "r":
                pronunciation += "r"
            case "b", "d", "f", "h", "k", "l", "m", "n", "p", "s", "t", "v", "w", "z":
                pronunciation.append(character)
            default:
                pronunciation.append(character)
            }
        }

        guard pronunciation.range(
            of: #"[æəɛɪʊɔɑʌiːeɪoʊaɪɔɪ]"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return "/\(pronunciation)/"
    }
}

/// Last-resort, no-key lookup. This WebView is never attached to the app's
/// visible view hierarchy; it only reads a public Google Search result after
/// the dictionary sources have failed. Search and AI results can change or be
/// unavailable, so callers must treat this result as non-authoritative.
private final class BackgroundGooglePronunciationLookup: NSObject, WKNavigationDelegate {
    static let shared = BackgroundGooglePronunciationLookup()

    private let webView: WKWebView
    private var pendingCompletion: ((PronunciationResult?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var queryCandidates: [String] = []
    private var queryIndex = 0

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.isHidden = true
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
    }

    func fetch(
        word: String,
        completion: @escaping (PronunciationResult?) -> Void
    ) {
        finish(nil)
        pendingCompletion = completion
        queryCandidates = [
            "\"\(word)\" pronunciation IPA",
            "\"\(word)\" phonetic pronunciation",
            "how to pronounce \"\(word)\"",
            "What is the IPA pronunciation of \"\(word)\"?"
        ]
        queryIndex = 0
        loadCurrentQuery()
    }

    private func loadCurrentQuery() {
        guard pendingCompletion != nil,
              queryCandidates.indices.contains(queryIndex) else {
            finish(nil)
            return
        }

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(
                name: "q",
                value: queryCandidates[queryIndex]
            ),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "num", value: "10")
        ]
        guard let url = components?.url else {
            finish(nil)
            return
        }

        timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        if let timeoutWorkItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeoutWorkItem)
        }
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        inspectPage(attempt: 0)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        loadNextQuery()
    }

    private func inspectPage(attempt: Int) {
        guard pendingCompletion != nil else { return }
        webView.evaluateJavaScript(
            "document.body ? document.body.innerText : ''"
        ) { [weak self] result, _ in
            guard let self else { return }
            let text = result as? String ?? ""
            if let result = self.result(from: text) {
                self.finish(result)
                return
            }
            guard attempt < 20 else {
                self.loadNextQuery()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.inspectPage(attempt: attempt + 1)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loadNextQuery()
    }

    private func loadNextQuery() {
        guard pendingCompletion != nil else { return }
        queryIndex += 1
        loadCurrentQuery()
    }

    private func result(from text: String) -> PronunciationResult? {
        let aiResponse = text.range(
            of: #"(?i)AI\s*(Overview|Mode)|AI\s*(概览|模式)"#,
            options: .regularExpression
        ) != nil

        let patterns = [
            #"(?i)(?:IPA|pronunciation|pronounced|phonetic)[^/\n]{0,40}/(?:(?!/|\n).){2,80}/"#,
            #"/(?:(?!/|\n).){2,80}/"#,
            #"(?i)(?:IPA|pronunciation|pronounced|phonetic)[^\[\n]{0,40}\[(?:(?!\]|\n).){2,80}\]"#,
            #"\[(?:(?!\]|\n).){2,80}\]"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let matches = expression.matches(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            )
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                var value = String(text[range])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let slashStart = value.firstIndex(of: "/"),
                   let slashEnd = value.lastIndex(of: "/"),
                   slashStart < slashEnd {
                    value = String(value[slashStart...slashEnd])
                } else if let bracketStart = value.firstIndex(of: "["),
                          let bracketEnd = value.lastIndex(of: "]"),
                          bracketStart < bracketEnd {
                    value = String(value[bracketStart...bracketEnd])
                }
                guard value.range(
                    of: #"[ɑɐɒæəɛɜɪɨʊɔːˈˌθðʃʒŋɡʔ]"#,
                    options: .regularExpression
                ) != nil else {
                    continue
                }
                return PronunciationResult(
                    ipa: value,
                    source: aiResponse ? .ai : .standard
                )
            }
        }
        return nil
    }

    private func finish(_ result: PronunciationResult?) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let completion = pendingCompletion
        pendingCompletion = nil
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(result)
        }
    }
}

/// Borderless AppKit button with a small press response.  This avoids the
/// textured button's dashed focus ring and accent-blue template tint while
/// retaining clear click feedback.
private final class WorkspaceIconButton: NSButton {
    init(image: NSImage, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 0.48
        }
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }
}

/// Text swap control with the same mouse-down feedback as the footer icon
/// buttons. Keeping the feedback inside mouseDown makes it visible before the
/// language reload starts, instead of being hidden by the action that follows.
private final class WorkspaceSwapButton: NSButton {
    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            animator().alphaValue = 0.48
        }
        super.mouseDown(with: event)
        restoreNormalAppearance()
    }

    func flashForKeyboardShortcut() {
        alphaValue = 0.48
        restoreNormalAppearance()
    }

    private func restoreNormalAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().alphaValue = 1
        }
    }
}

/// Text-only language control.  NSButton's inline style grows a rounded
/// system background around titles on newer macOS releases, so use a truly
/// borderless bezel and draw only the language name.
private final class WorkspaceLanguageButton: NSButton {
    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .shadowlessSquare
        isBordered = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        alignment = .center
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

}

private final class AppearanceObservingView: NSView {
    var effectiveAppearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearanceDidChange?()
    }
}

private enum NativeLanguagePickerSide {
    case source
    case target
}

private final class NativeLanguagePickerController: NSViewController,
    NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let side: NativeLanguagePickerSide
    private let selectedLanguage: TranslateLanguage
    private let didSelect: (TranslateLanguage) -> Void
    private var languages: [TranslateLanguage] = []
    private var filteredLanguages: [TranslateLanguage] = []
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private var isApplyingSelection = false

    init(
        side: NativeLanguagePickerSide,
        selectedLanguage: TranslateLanguage,
        didSelect: @escaping (TranslateLanguage) -> Void
    ) {
        self.side = side
        self.selectedLanguage = selectedLanguage
        self.didSelect = didSelect
        super.init(nibName: nil, bundle: nil)
        languages = TranslateLanguage.allCases
            .filter { side == .source || $0.canBeTarget }
            .sorted { lhs, rhs in
                if lhs == .automatic { return true }
                if rhs == .automatic { return false }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        filteredLanguages = languages
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let background = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 390)
        )
        // Use the same behind-window glass treatment as the main translator
        // surface. The popover material is intentionally avoided because it
        // produces a denser grey sheet than the app's transparent window.
        background.material = isDark ? .dark : .light
        background.blendingMode = .behindWindow
        background.state = .active
        view = background

        searchField.placeholderString = interfaceText("搜索语言", "Search languages")
        searchField.delegate = self
        // NSSearchField renders an additional internal icon/well inside a
        // vibrancy popover on recent macOS versions. A plain text field plus
        // one explicit icon prevents the doubled, overlapping placeholder.
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 15)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView(
            image: (NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))) ?? NSImage()
        )
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        let searchSurface = NSVisualEffectView()
        searchSurface.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.material = isDark ? .dark : .light
        searchSurface.blendingMode = .withinWindow
        searchSurface.state = .active
        searchSurface.wantsLayer = true
        searchSurface.layer?.cornerRadius = 11
        searchSurface.layer?.masksToBounds = true
        searchSurface.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(isDark ? 0.08 : 0.045).cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        column.width = 276
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = self
        tableView.dataSource = self
        scrollView.documentView = tableView

        view.addSubview(searchSurface)
        view.addSubview(searchIcon)
        view.addSubview(searchField)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchSurface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            searchSurface.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            searchSurface.heightAnchor.constraint(equalToConstant: 36),
            searchIcon.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 10),
            searchIcon.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 16),
            searchIcon.heightAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let row = filteredLanguages.firstIndex(of: selectedLanguage) ?? -1
        if row >= 0 {
            isApplyingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            isApplyingSelection = false
        }
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isApplyingSelection = true
        tableView.deselectAll(nil)
        if query.isEmpty {
            filteredLanguages = languages
        } else {
            filteredLanguages = languages.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                    $0.rawValue.localizedCaseInsensitiveContains(query)
            }
        }
        tableView.reloadData()
        isApplyingSelection = false
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (searchField.currentEditor() as? NSTextView)?.insertionPointColor = .labelColor
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredLanguages.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("language-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier

        let label: NSTextField
        if let existing = cell.textField {
            label = existing
        } else {
            label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let language = filteredLanguages[row]
        label.stringValue = language == selectedLanguage ? "✓  \(language.title)" : language.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection,
              tableView.selectedRow >= 0,
              tableView.selectedRow < filteredLanguages.count else {
            return
        }
        didSelect(filteredLanguages[tableView.selectedRow])
    }
}

class ViewController: NSViewController, WKNavigationDelegate, NSTextViewDelegate {
    private static let windowBehaviorBarHeight: CGFloat = 34

    private enum ReloadDestination {
        case currentPage
        case defaultLanguages
        case interfaceLanguage
        case translationURL(URL)
    }

    private enum LongTextStatusState {
        case idle
        case preparing
        case translating
        case completed
        case failed
    }

    private enum SpeechPane {
        case source
        case translation
    }

    private enum PronunciationPane: Equatable {
        case source
        case translation
    }

    public var isReady = false
    private var readyHandlers: [() -> Void] = []

    var webView: WebView!
    private var automaticTranslationWebView: BackgroundTranslationWebView!
    private weak var activeTranslationWebView: WKWebView?
    private var automaticTranslationWebViewReady = false
    private var automaticTranslationWebViewLoading = false
    private var automaticTranslationTarget = TranslateLanguagePreferences.target
    private var pendingAutomaticTranslationSource: String?
    private var pendingAutomaticTranslationSession: Int?
    private var pendingPrimaryTranslationSource: String?
    private var pendingPrimaryTranslationSession: Int?
    private let startupTimingOrigin = ProcessInfo.processInfo.systemUptime
    private var didLogFirstTranslationCommand = false
    private var didLogFirstTextInjection = false
    private var didLogFirstTranslationResult = false
    private struct TranslationTimingRequest {
        let id: Int
        let label: String
        let source: String
        var session: Int
        let startedAt: CFTimeInterval
        var didLogEvaluationStart = false
        var didLogExtractionStart = false
        var didLogFirstValidExtraction = false
        var didLogFirstValidJSResult = false
        var didLogFirstDisplay = false
        var didLogStableResult = false
        var didLogFinalDisplay = false
    }
    private var translationTimingRequestCount = 0
    private var translationTimingRequest: TranslationTimingRequest?
    var visualEffect: NSVisualEffectView!
    private var workspaceBackgroundView: NSVisualEffectView?
    private var keepOnTopButton: NSButton!
    private var showOnAllSpacesButton: NSButton!
    private var windowBehaviorBar: WindowBehaviorBarView?
    private var windowBehaviorSettingsGroup: NSView?
    private var windowBehaviorDivider: NSView?
    private var pendingSourceTextForReload: String?
    private var pendingSourceRestoreAttempts = 0
    private var reloadRequestGeneration = 0
    private var applicationAppearanceObservation: NSKeyValueObservation?
    private var connectionOverlay: NSVisualEffectView?
    private var connectionTitleLabel: NSTextField?
    private var connectionDetailLabel: NSTextField?
    private var connectionSpinner: NSProgressIndicator?
    private var connectionRetryButton: NSButton?
    private var loadTimeoutWorkItem: DispatchWorkItem?
    private var delayedConnectionOverlayWorkItem: DispatchWorkItem?
    private var automaticRetryWorkItem: DispatchWorkItem?
    private var translationLoadAttempt = 0
    // The workspace is intentionally a transparent content layer. The main
    // window already owns the single behind-window glass effect used by the
    // pre-rewrite interface; a second visual-effect view made it grey and
    // noticeably less transparent.
    private var longTextOverlay: NSView?
    private var longTextSourceView: NSTextView?
    private var longTextTranslationView: NSTextView?
    private var longTextStatusLabel: NSTextField?
    private var longTextSourceLabel: NSTextField?
    private var longTextTranslationLabel: NSTextField?
    private var sourcePronunciationRow: NSView?
    private var translationPronunciationRow: NSView?
    private var sourcePronunciationLabel: NSTextField?
    private var translationPronunciationLabel: NSTextField?
    private var sourcePronunciationValue: String?
    private var translationPronunciationValue: String?
    private var sourcePronunciationSource: PronunciationSource = .standard
    private var translationPronunciationSource: PronunciationSource = .standard
    private var sourcePronunciationKey: String?
    private var translationPronunciationKey: String?
    private var sourcePronunciationGeneration = 0
    private var translationPronunciationGeneration = 0
    private var workspaceSourceLanguageButton: NSButton?
    private var workspaceTargetLanguageButton: NSButton?
    private var workspaceSwapButton: NSButton?
    private var workspaceSplitView: NSSplitView?
    private var workspaceSourceStack: NSStackView?
    private var workspaceTranslationStack: NSStackView?
    private var workspaceEqualWidthConstraint: NSLayoutConstraint?
    private var workspaceEqualHeightConstraint: NSLayoutConstraint?
    private var workspaceSplitBottomConstraint: NSLayoutConstraint?
    private var workspaceUsesStackedLayout = false
    private var workspaceSourceCountLabel: NSTextField?
    private var workspaceTranslationCountLabel: NSTextField?
    private var isUpdatingNativeWorkspace = false
    private var longTextSource: String?
    private var longTextTranslation = ""
    // Keep the last completed result visible while Google recalculates the
    // complete current source. This is a display buffer only: never use it as
    // a translation prefix, because word order and meaning may change when
    // text is appended.
    private var longTextCompletedSource = ""
    private var longTextCompletedTranslation = ""
    private var longTextCompletedSourceLanguage = ""
    private var longTextCompletedTargetLanguage = ""
    private var longTextReplacesVisibleTranslation = false
    // Inserting or removing only line breaks changes paragraph layout, not
    // the text being translated. Keep the settled result interactive while
    // Google refreshes the corresponding DOM layout in the background.
    private var longTextFormattingOnlyRefresh = false
    private var longTextChunks: [TranslationChunk] = []
    private var longTextChunkIndex = 0
    private var longTextChunkRetryCount = 0
    private var longTextSession = 0
    private var longTextPollAttempts = 0
    private var longTextLastWebTranslation: String?
    private var longTextCandidateTranslation: String?
    // Google Translate Web renders some results incrementally.  A candidate
    // must be quiet for a meaningful interval before it can be considered the
    // final translation; two adjacent 50 ms polls are not sufficient.
    private var longTextCandidateUpdatedAt: Date?
    private var longTextActiveWebViewGeneration = 0
    private var longTextPollInFlightSession: Int?
    private var longTextScheduledPoll: DispatchWorkItem?
    private var longTextWebDeadline: Date?
    private var longTextStatusState: LongTextStatusState = .idle
    private var longTextSourceLanguage = TranslateLanguagePreferences.source.rawValue
    private var longTextTargetLanguage = TranslateLanguagePreferences.target.rawValue
    private var longTextDebounceWorkItem: DispatchWorkItem?
    private var longTextFallbackTask: URLSessionDataTask?
    private var translationInputGeneration = 0
    private var languageSwapInProgress = false
    private var languageSwapPendingText: String?
    private var languageSwapSnapshotText: String?
    private var restoreSourceFocusAfterLanguageSwap = false
    // A committed IME candidate is still part of continuous human typing.
    // Coalesce those edits, while paste and explicit submission stay immediate.
    private let nativeTextTranslationDebounce: TimeInterval = 0.25
    private let longTextTranslationDebounce: TimeInterval = 0.12
    private let longTextPollInterval: TimeInterval = 0.15
    private let longTextResultSettlingInterval: TimeInterval = 0.75
    // Google Translate Web accepts 5,000 UTF-16 code units. Stay close to
    // that native limit while retaining a small safety margin for Web UI
    // changes and characters represented by surrogate pairs.
    private let googleWebChunkUTF16Limit = 4_800
    // Google can publish a provisional result and refine it in a later DOM
    // mutation. Use a shorter quiet period for ordinary short input, while
    // progressively retaining the conservative window for larger one-chunk
    // requests. recordLongTextCandidate resets the timer whenever the valid
    // result text changes, so this is an event-driven debounce rather than a
    // fixed delay from the original input event.
    private func resultSettlingInterval() -> TimeInterval {
        guard longTextChunks.count == 1,
              let chunk = longTextChunks.first else {
            return longTextResultSettlingInterval
        }
        switch chunk.text.utf16.count {
        case ...600:
            return 0.8
        case ...2_000:
            return 1.1
        default:
            return 1.6
        }
    }
    // A completely transparent WKWebView can be deprioritized by WebKit's
    // rendering pipeline. Keep the background translator imperceptibly
    // visible so Google updates its result DOM at normal foreground speed.
    private let backgroundTranslationWebViewAlpha: CGFloat = 0.01
    private var languagePickerPopover: NSPopover?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var activeSpeechPane: SpeechPane?
    // These are the languages of the currently open translation, not the
    // user's persistent defaults in the status-bar menu.
    private var currentSourceLanguage = TranslateLanguagePreferences.source
    private var currentTargetLanguage = TranslateLanguagePreferences.target

    private var currentEffectiveAppearance: NSAppearance {
        guard isViewLoaded else { return NSApp.effectiveAppearance }
        return view.window?.effectiveAppearance ?? view.effectiveAppearance
    }

    var isDarkMode: Bool {
        currentEffectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public func whenReady(_ handler: @escaping () -> Void) {
        if isReady {
            handler()
        } else {
            readyHandlers.append(handler)
        }
    }

    private func markReady() {
        isReady = true
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    private func logStartupTiming(_ event: String) {
#if DEBUG
        let elapsed = ProcessInfo.processInfo.systemUptime - startupTimingOrigin
        startupTimingLogger.info("\(event, privacy: .public) +\(elapsed, format: .fixed(precision: 3))s")
#endif
    }

    private func startTranslationTimingRequest(source: String, session: Int) {
#if DEBUG
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
        logTranslationTiming("user-trigger", details: "chars=\(source.count) utf16=\(source.utf16.count)")
#endif
    }

    private func updateTranslationTimingSession(_ session: Int) {
#if DEBUG
        translationTimingRequest?.session = session
#endif
    }

    private func logTranslationTiming(_ milestone: String, details: String = "") {
#if DEBUG
        guard let request = translationTimingRequest else { return }
        let elapsed = (CACurrentMediaTime() - request.startedAt) * 1_000
        translationPipelineLogger.info(
            "[TranslationTiming][\(request.label, privacy: .public)][request=\(request.id, privacy: .public)][session=\(request.session, privacy: .public)] milestone=\(milestone, privacy: .public) elapsed_ms=\(elapsed, format: .fixed(precision: 3)) \(details, privacy: .public)"
        )
#endif
    }

    private func logTranslationCoordinator(
        _ milestone: String,
        source: String? = nil,
        requestID: Int? = nil,
        session: Int? = nil
    ) {
#if DEBUG
        let resolvedRequestID = requestID ?? translationTimingRequest?.id ?? 0
        let resolvedSession = session ?? longTextSession
        let characterCount = source?.count ?? longTextSourceView?.string.count ?? 0
        let direction = "\(currentSourceLanguage.rawValue)->\(currentTargetLanguage.rawValue)"
        translationPipelineLogger.info(
            "[TranslationTiming][coordinator][request=\(resolvedRequestID, privacy: .public)][session=\(resolvedSession, privacy: .public)] milestone=\(milestone, privacy: .public) chars=\(characterCount, privacy: .public) direction=\(direction, privacy: .public)"
        )
#endif
    }

    private func installUserScripts(on controller: WKUserContentController) {
        controller.removeAllUserScripts()

        // Google measures source text in a hidden 24/32 px layer and later
        // switches visible long text to 18/28 px. Its web font can also swap
        // after the first glyph is painted. Stabilize every visible source
        // layer before first paint while preserving the measurement layer.
        let typographyGuard = WKUserScript(
            source: #"""
                (() => {
                    const styleId = "mac-translate-early-source-typography";
                    const install = () => {
                        if (document.getElementById(styleId)) return true;
                        const root = document.head || document.documentElement;
                        if (!root) return false;

                        const style = document.createElement("style");
                        style.id = styleId;
                        style.textContent = `
                            .QFw9Te .Hapztf,
                            .QFw9Te .cEWAef,
                            .QFw9Te .er8xn,
                            .QFw9Te .fXYY1b,
                            .QFw9Te .sB7Iec {
                                font-family: -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif !important;
                                font-size: 18px !important;
                                line-height: 28px !important;
                                font-weight: 400 !important;
                                letter-spacing: normal !important;
                                transition: none !important;
                            }

                            .QFw9Te .vJwDU {
                                font-family: -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif !important;
                                font-size: 24px !important;
                                line-height: 32px !important;
                                font-weight: 400 !important;
                                letter-spacing: normal !important;
                                transition: none !important;
                            }

                            /* Google uses 24/32 and 18/28 typography for the
                               expanded result at different responsive states.
                               Keep its visible and measurement layers aligned
                               without altering compact result cards. */
                            .QcsUad.sMVRZe .Cbi98e,
                            .QcsUad.sMVRZe .OvtS8d,
                            .QcsUad.sMVRZe .lRu31 {
                                font-size: 18px !important;
                                line-height: 28px !important;
                                transition: none !important;
                            }
                        `;
                        root.appendChild(style);
                        return true;
                    };

                    // Google's textarea auto-height update runs in a later
                    // timer. During a large paste, WebKit therefore scrolls
                    // the still-short textarea to the caret at the end before
                    // Google expands it. Match Google's final height during
                    // the input event, before that intermediate frame paints.
                    //
                    // A replacement paste can also shrink a previously long
                    // source value. Reset the textarea and scrollable parent
                    // positions in that case; otherwise WebKit keeps the old
                    // bottom offset and the new short text appears at its end.
                    const sourceMetrics = new WeakMap();
                    const resetSourceScroll = (textarea) => {
                        const reset = () => {
                            textarea.scrollTop = 0;
                            let parent = textarea.parentElement;
                            for (let level = 0; parent && level < 6; level += 1) {
                                const style = getComputedStyle(parent);
                                const canScroll = /auto|scroll/.test(style.overflowY) &&
                                    parent.scrollHeight > parent.clientHeight;
                                if (canScroll) parent.scrollTop = 0;
                                parent = parent.parentElement;
                            }
                        };
                        reset();
                        requestAnimationFrame(reset);
                        setTimeout(reset, 0);
                    };

                    document.addEventListener("input", (event) => {
                        const textarea = event.target;
                        if (!(textarea instanceof HTMLTextAreaElement) ||
                            !textarea.matches(
                                ".er8xn, textarea[role=\"combobox\"][aria-controls=\"kvLWu\"]"
                            )) {
                            return;
                        }

                        const previous = sourceMetrics.get(textarea);
                        textarea.style.removeProperty("height");
                        const scrollHeight = Math.ceil(textarea.scrollHeight);
                        textarea.style.height = `${scrollHeight}px`;

                        if (previous && textarea.value.length < previous.length &&
                            scrollHeight < previous.scrollHeight) {
                            resetSourceScroll(textarea);
                        }
                        sourceMetrics.set(textarea, {
                            length: textarea.value.length,
                            scrollHeight
                        });
                    }, true);

                    if (!install()) {
                        document.addEventListener("DOMContentLoaded", install, {
                            once: true
                        });
                    }
                })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(typographyGuard)

        let suppressSelectionToolbar = TranslateFeaturePreferences.hideGoogleSelectionToolbar
            ? "true"
            : "false"

        // Install this before Google's scripts. Selection itself is a WebKit
        // default action, so stopping page listeners does not remove native
        // selection or Command+C; it only suppresses Google's optional UI.
        let interactionGuard = WKUserScript(
            source: #"""
                (() => {
                    if (window.__macTranslateEarlyInteractionGuard) return;
                    window.__macTranslateEarlyInteractionGuard = true;
                    const suppressSelectionToolbar = \#(suppressSelectionToolbar);

                    const sourceSelector = "textarea, .er8xn";
                    const resultSelector = [
                        ".QcsUad .ryNqvb",
                        ".QcsUad .HwtZe",
                        ".QcsUad .jCAhz",
                        ".QcsUad .lRu31",
                        ".QcsUad [jsname=\"W297wb\"]"
                    ].join(",");

                    const hit = (event) => {
                        const target = event.target;
                        if (!target || !target.closest) return null;
                        if (target.closest(
                            "#mac-translate-source-copy, #mac-translate-source-clear"
                        )) return null;
                        return {
                            source: target.closest(sourceSelector),
                            result: target.closest(resultSelector)
                        };
                    };

                    document.addEventListener("click", (event) => {
                        const target = event.target;
                        const button = target && target.closest ?
                            target.closest("#mac-translate-custom-swap") : null;
                        if (!button) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "swapLanguages"
                        });
                    }, true);

                    // Replace Google's responsive language wall with the
                    // native searchable picker. The native control avoids
                    // Google’s overlapping labels and hover overlays.
                    const languageControl = (target) => {
                        const control = target && target.closest ? target.closest(
                            'button[aria-label], [role="button"][aria-label]'
                        ) : null;
                        if (!control) return null;
                        const label = (control.getAttribute("aria-label") || "").trim();
                        // Do not match Google's swap control: its label also
                        // contains both “source language” and “target
                        // language”. Only actual language buttons begin with
                        // one of the labels below.
                        return /^(?:源语言|目标语言)(?:[：:\\s]|$)|^(?:Source|Target)\\s+language(?:[：:\\s]|$)/i
                            .test(label) ? control : null;
                    };

                    // Google may begin opening its language wall on press,
                    // before the click handler below runs. Suppress that
                    // early action, while letting the click show the native
                    // picker instead.
                    ["pointerdown", "mousedown"].forEach((type) => {
                        document.addEventListener(type, (event) => {
                            if (!languageControl(event.target)) return;
                            event.preventDefault();
                            event.stopImmediatePropagation();
                        }, true);
                    });

                    document.addEventListener("click", (event) => {
                        const target = event.target;
                        const control = languageControl(target);
                        if (!control) return;
                        const label = control.getAttribute("aria-label") || "";
                        const side = /目标语言|Target language/i.test(label) ? "target" : "source";
                        const rect = control.getBoundingClientRect();
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "showLanguagePicker", side,
                            x: rect.left + rect.width / 2,
                            y: rect.top + rect.height
                        });
                    }, true);

                    window.addEventListener("click", (event) => {
                        const target = event.target;
                        const button = target && target.closest ?
                            target.closest("#mac-translate-source-copy") : null;
                        if (!button) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        const textarea = document.querySelector("textarea");
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "copySource",
                            text: textarea ? textarea.value : ""
                        });
                    }, true);

                    window.addEventListener("click", (event) => {
                        const target = event.target;
                        const button = target && target.closest ?
                            target.closest("#mac-translate-source-clear") : null;
                        if (!button) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "clearSource"
                        });
                    }, true);

                    // Google Translate truncates its editable field at 5,000
                    // characters. Route a larger paste to native code before
                    // Google's handler sees it; native code translates the
                    // text in safe chunks and presents the complete result.
                    document.addEventListener("paste", (event) => {
                        const target = event.target;
                        const textarea = target && target.closest ?
                            target.closest(sourceSelector) : null;
                        const text = event.clipboardData?.getData("text/plain") || "";
                        if (!textarea || text.length <= 5000) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translateLongText",
                            text
                        });
                    }, true);

                    // The same handoff must work for normal typing, not only
                    // for a large paste. Intercept the keystroke that would
                    // cross Google's 5,000-character field limit and move
                    // the complete editable value into the inline workspace.
                    document.addEventListener("beforeinput", (event) => {
                        const target = event.target;
                        const textarea = target && target.closest ?
                            target.closest(sourceSelector) : null;
                        if (!textarea || event.inputType === "insertFromPaste") return;
                        const inserted = event.data ??
                            (event.inputType === "insertLineBreak" ? "\n" : "");
                        if (!inserted) return;
                        const start = typeof textarea.selectionStart === "number" ?
                            textarea.selectionStart : textarea.value.length;
                        const end = typeof textarea.selectionEnd === "number" ?
                            textarea.selectionEnd : start;
                        const next = textarea.value.slice(0, start) + inserted +
                            textarea.value.slice(end);
                        if (next.length <= 5000) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translateLongText",
                            text: next
                        });
                    }, true);

                    const stopPageSelectionHandlers = (event) => {
                        if (!suppressSelectionToolbar) return;
                        const match = hit(event);
                        if (!match || (!match.source && !match.result)) return;
                        event.stopImmediatePropagation();
                        window.__macTranslateScheduleCleanup?.();
                    };

                    window.addEventListener("mouseup", stopPageSelectionHandlers, true);
                    window.addEventListener("pointerup", stopPageSelectionHandlers, true);

                    // Result activation always stays blocked because Google's
                    // compact detail page otherwise becomes an empty overlay.
                    const stopResultActivation = (event) => {
                        const match = hit(event);
                        if (!match || (!match.source && !match.result)) return;
                        if (match.result) {
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            window.__macTranslateScheduleCleanup?.();
                        } else if (suppressSelectionToolbar && match.source) {
                            event.stopImmediatePropagation();
                            window.__macTranslateScheduleCleanup?.();
                        }
                    };

                    window.addEventListener("click", stopResultActivation, true);
                    window.addEventListener("dblclick", stopResultActivation, true);

                    window.addEventListener("selectionchange", (event) => {
                        if (!suppressSelectionToolbar) return;
                        event.stopImmediatePropagation();
                        window.__macTranslateScheduleCleanup?.();
                    }, true);

                    window.addEventListener("contextmenu", (event) => {
                        const match = hit(event);
                        if (!match || (!match.source && !match.result)) return;
                        event.preventDefault();
                        event.stopImmediatePropagation();
                    }, true);
                })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(interactionGuard)
    }

    private func translationURL(
        source: TranslateLanguage,
        target: TranslateLanguage
    ) -> URL {
        var components = URLComponents(string: "https://translate.google.com/")!
        components.queryItems = [
            URLQueryItem(
                name: "sl",
                value: source.rawValue
            ),
            URLQueryItem(
                name: "tl",
                value: target.rawValue
            ),
            URLQueryItem(
                name: "hl",
                value: AppInterfaceLanguagePreferences.current.googleLocale
            ),
            URLQueryItem(name: "op", value: "translate")
        ]
        return components.url!
    }

    private func defaultTranslationURL() -> URL {
        translationURL(
            source: TranslateLanguagePreferences.source,
            target: TranslateLanguagePreferences.target
        )
    }

    private func updateCurrentLanguages(from url: URL?) {
        let items = URLComponents(url: url ?? defaultTranslationURL(),
                                  resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let rawSource = items.first(where: { $0.name == "sl" })?.value,
           let source = TranslateLanguage(rawValue: rawSource),
           source != .automatic {
            currentSourceLanguage = source
        }
        if let rawTarget = items.first(where: { $0.name == "tl" })?.value,
           let target = TranslateLanguage(rawValue: rawTarget), target.canBeTarget {
            currentTargetLanguage = target
        }
    }

    private func interfaceLocalizedURL(from currentURL: URL?) -> URL {
        guard let currentURL,
              var components = URLComponents(
                url: currentURL,
                resolvingAgainstBaseURL: false
              ),
              components.host == "translate.google.com" else {
            return defaultTranslationURL()
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "hl" }
        queryItems.append(
            URLQueryItem(
                name: "hl",
                value: AppInterfaceLanguagePreferences.current.googleLocale
            )
        )
        components.queryItems = queryItems
        return components.url ?? defaultTranslationURL()
    }

    override func loadView() {
        logStartupTiming("WebViews creating")
        let width = CGFloat(Constants.WIDTH)
        let height = CGFloat(Constants.HEIGHT)
        let barHeight = Self.windowBehaviorBarHeight

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "callbackHandler")
        installUserScripts(on: config.userContentController)

        webView = WebView(
            frame: NSRect(
                x: 0,
                y: barHeight,
                width: width,
                height: height - barHeight
            ),
            configuration: config
        )
        webView.autoresizingMask = [.width, .height]
        webView.shortcutHandler = { [weak self] action in
            self?.performShortcut(action) ?? false
        }
        webView.navigationDelegate = self

        webView.wantsLayer = true
        webView.layer?.backgroundColor = .clear
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        // Keep Google Translate mounted and running in the background. A
        // hidden WKWebView can stop updating its dynamic result DOM, while a
        // fully transparent one continues to behave like the old visible
        // WebView without ever flashing its page through the native workspace.
        webView.alphaValue = backgroundTranslationWebViewAlpha

        // Keep a second Google Translate document permanently warmed with
        // source=auto. A single WebView had to reload the whole Google app
        // whenever the entered script did not match the selected source
        // language, adding several seconds before any result could appear.
        let automaticConfig = WKWebViewConfiguration()
        automaticConfig.userContentController.add(self, name: "callbackHandler")
        automaticTranslationWebView = BackgroundTranslationWebView(
            frame: webView.frame,
            configuration: automaticConfig
        )
        automaticTranslationWebView.autoresizingMask = [.width, .height]
        automaticTranslationWebView.navigationDelegate = self
        automaticTranslationWebView.wantsLayer = true
        automaticTranslationWebView.layer?.backgroundColor = .clear
        automaticTranslationWebView.underPageBackgroundColor = .clear
        automaticTranslationWebView.setValue(false, forKey: "drawsBackground")
        automaticTranslationWebView.alphaValue = backgroundTranslationWebViewAlpha
        activeTranslationWebView = webView
        logStartupTiming("WebViews created")

        // Give the native settings bar its own layout space. Previously it
        // was overlaid on WKWebView, so long translations could place the
        // Google copy button underneath the bar.
        let rootView = AppearanceObservingView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
        rootView.addSubview(automaticTranslationWebView)
        rootView.addSubview(webView)
        self.view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        DistributedNotificationCenter.default.addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] _ in
            // The distributed notification can precede AppKit's appearance
            // propagation. Retry briefly so the final pass always observes
            // the new application-level appearance.
            [0.0, 0.1, 0.35].forEach { delay in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    [weak self] in
                    self?.setTheme()
                }
            }
        }

        visualEffect = NSVisualEffectView(frame: self.view.bounds)
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.autoresizingMask = [.width, .height]

        self.view.addSubview(visualEffect, positioned: .below, relativeTo: nil)

        // Google Translate stays mounted at a very low alpha so WebKit keeps
        // its dynamic result DOM active. Put a dedicated behind-window glass
        // surface above both service WebViews: it samples only content behind
        // the app window, never the lower sibling WebViews inside the window.
        // This preserves translucency without allowing Google's page through.
        let workspaceBackground = NSVisualEffectView(frame: self.view.bounds)
        workspaceBackground.autoresizingMask = [.width, .height]
        workspaceBackground.material = isDarkMode ? .dark : .light
        workspaceBackground.blendingMode = .behindWindow
        workspaceBackground.state = .active
        workspaceBackground.isEmphasized = false
        self.view.addSubview(workspaceBackground, positioned: .above, relativeTo: webView)
        workspaceBackgroundView = workspaceBackground

        installWindowBehaviorBar()
        installConnectionOverlay()
        installLongTextOverlay()
        // Present the app-owned empty editor immediately. A cold WebKit load
        // continues in the background and should not make a healthy launch
        // look like a multi-second network check.
        longTextOverlay?.isHidden = false
        refreshWorkspaceLanguageTitles()

        (view as? AppearanceObservingView)?.effectiveAppearanceDidChange = {
            [weak self] in
            self?.setTheme()
        }

        applicationAppearanceObservation = NSApp.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.setTheme()
            }
        }

        // Keep window movement completely outside the web content. The top
        // strip behaves like a conventional title bar; the native behavior
        // bar below handles dragging in its own empty areas, so no full-width
        // overlay can cover the result actions.
        let edgeInset: CGFloat = 4
        let handleHeight: CGFloat = 14
        let topHandle = WindowDragHandleView(
            frame: NSRect(
                x: 0,
                y: self.view.bounds.height - edgeInset - handleHeight,
                width: self.view.bounds.width,
                height: handleHeight
            )
        )
        topHandle.autoresizingMask = [.width, .minYMargin]
        self.view.addSubview(topHandle)

        // Automatic detection handles the common mismatch between the
        // selected source language and freshly pasted text. Start that hidden
        // service first so an immediate cold-launch request is less likely to
        // wait behind the primary page. Both loads remain asynchronous; the
        // native window never waits for either network navigation.
        loadAutomaticTranslationService(target: currentTargetLanguage)
        loadTranslationService()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWorkspaceLayoutIfNeeded()
    }

    private func updateWorkspaceLayoutIfNeeded() {
        guard let splitView = workspaceSplitView,
              let overlay = longTextOverlay else { return }

        // Match the old web view's responsive behavior: once two panes would
        // be narrower than a comfortable reading column, stack them and keep
        // each source/result line close to the full window width.
        let shouldStack = overlay.bounds.width < 720
        guard shouldStack != workspaceUsesStackedLayout else { return }
        workspaceUsesStackedLayout = shouldStack

        // Changing NSSplitView.isVertical during a layout pass otherwise lets
        // AppKit paint one frame of the old divider (a noticeable dark bar).
        // Commit the orientation, constraints, and the resulting layout as a
        // single transaction with implicit layer actions disabled.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        splitView.isVertical = !shouldStack
        workspaceEqualWidthConstraint?.isActive = !shouldStack
        workspaceEqualHeightConstraint?.isActive = shouldStack
        workspaceSplitBottomConstraint?.constant = shouldStack ? 0 : -12

        splitView.needsLayout = true
        view.layoutSubtreeIfNeeded()
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        splitView.displayIfNeeded()

        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    deinit {
        loadTimeoutWorkItem?.cancel()
        delayedConnectionOverlayWorkItem?.cancel()
        automaticRetryWorkItem?.cancel()
        longTextDebounceWorkItem?.cancel()
        stopSpeaking()
    }

    private func installWindowBehaviorBar() {
        let barHeight = Self.windowBehaviorBarHeight
        let bar = WindowBehaviorBarView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: view.bounds.width,
                height: barHeight
            )
        )
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.autoresizingMask = [.width, .maxYMargin]
        bar.wantsLayer = true
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor.separatorColor.cgColor

        keepOnTopButton = makeWindowBehaviorButton(
            title: interfaceText("当前 Space 置顶", "Keep on Top"),
            behavior: .keepOnTop
        )
        showOnAllSpacesButton = makeWindowBehaviorButton(
            title: interfaceText("所有 Space 显示", "Show on All Spaces"),
            behavior: .showOnAllSpaces
        )

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16)
        ])

        let stack = NSStackView(
            views: [keepOnTopButton, divider, showOnAllSpacesButton]
        )
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Visually separate the interactive settings from the draggable blank
        // area on either side of the bottom bar.
        let settingsGroup = NSView()
        settingsGroup.translatesAutoresizingMaskIntoConstraints = false
        settingsGroup.wantsLayer = true
        settingsGroup.layer?.cornerRadius = 9
        settingsGroup.layer?.borderWidth = 0.75
        settingsGroup.addSubview(stack)
        bar.addSubview(settingsGroup)
        NSLayoutConstraint.activate([
            settingsGroup.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            settingsGroup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: settingsGroup.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: settingsGroup.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: settingsGroup.topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: settingsGroup.bottomAnchor, constant: -3)
        ])

        view.addSubview(bar)
        windowBehaviorBar = bar
        windowBehaviorSettingsGroup = settingsGroup
        windowBehaviorDivider = divider
        updateWindowBehaviorBarAppearance()
        syncWindowBehaviorControls()
    }

    private func makeWindowBehaviorButton(
        title: String,
        behavior: TranslateWindowBehavior
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(windowBehaviorButtonChanged(_:)))
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.tag = behavior == .keepOnTop ? 0 : 1
        button.state = TranslateWindowPreferences.isEnabled(behavior) ? .on : .off
        return button
    }

    @objc private func windowBehaviorButtonChanged(_ sender: NSButton) {
        let behavior: TranslateWindowBehavior = sender.tag == 0
            ? .keepOnTop
            : .showOnAllSpaces
        (NSApp.delegate as? AppDelegate)?.setWindowBehavior(
            behavior,
            enabled: sender.state == .on
        )
    }

    func syncWindowBehaviorControls() {
        keepOnTopButton?.title = interfaceText(
            "当前 Space 置顶",
            "Keep on Top"
        )
        showOnAllSpacesButton?.title = interfaceText(
            "所有 Space 显示",
            "Show on All Spaces"
        )
        keepOnTopButton?.state = TranslateWindowPreferences.keepOnTop ? .on : .off
        showOnAllSpacesButton?.state = TranslateWindowPreferences.showOnAllSpaces ? .on : .off
    }

    private func installConnectionOverlay() {
        let overlay = NSVisualEffectView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.material = .popover
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .center
        title.maximumNumberOfLines = 2

        let detail = NSTextField(wrappingLabelWithString: "")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        detail.preferredMaxLayoutWidth = 390

        let retryButton = NSButton(
            title: interfaceText("立即重试", "Retry Now"),
            target: self,
            action: #selector(retryTranslationService)
        )
        retryButton.bezelStyle = .rounded

        let stack = NSStackView(views: [spinner, title, detail, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stack)
        view.addSubview(
            overlay,
            positioned: .above,
            relativeTo: workspaceBackgroundView ?? webView
        )
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Self.windowBehaviorBarHeight
            ),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -24)
        ])

        connectionOverlay = overlay
        connectionTitleLabel = title
        connectionDetailLabel = detail
        connectionSpinner = spinner
        connectionRetryButton = retryButton
        hideConnectionOverlay()
    }

    private func installLongTextOverlay() {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true

        let sourceLanguageButton = WorkspaceLanguageButton(
            target: self,
            action: #selector(workspaceSourceLanguageClicked)
        )
        sourceLanguageButton.toolTip = interfaceText("选择源语言", "Choose source language")

        let swapButton = WorkspaceSwapButton(
            title: "⇄",
            target: self,
            action: #selector(workspaceSwapLanguages)
        )
        swapButton.toolTip = interfaceText("交换源语言和目标语言", "Swap source and target languages")

        let targetLanguageButton = WorkspaceLanguageButton(
            target: self,
            action: #selector(workspaceTargetLanguageClicked)
        )
        targetLanguageButton.toolTip = interfaceText("选择目标语言", "Choose target language")

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        [sourceLanguageButton, swapButton, targetLanguageButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview($0)
        }
        swapButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        swapButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let sourceHeaderGuide = NSLayoutGuide()
        let targetHeaderGuide = NSLayoutGuide()
        header.addLayoutGuide(sourceHeaderGuide)
        header.addLayoutGuide(targetHeaderGuide)
        NSLayoutConstraint.activate([
            sourceHeaderGuide.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            sourceHeaderGuide.trailingAnchor.constraint(equalTo: swapButton.leadingAnchor, constant: -18),
            targetHeaderGuide.leadingAnchor.constraint(equalTo: swapButton.trailingAnchor, constant: 18),
            targetHeaderGuide.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            sourceHeaderGuide.widthAnchor.constraint(equalTo: targetHeaderGuide.widthAnchor),
            sourceLanguageButton.centerXAnchor.constraint(equalTo: sourceHeaderGuide.centerXAnchor),
            targetLanguageButton.centerXAnchor.constraint(equalTo: targetHeaderGuide.centerXAnchor)
        ])

        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sourceLabel = NSTextField(labelWithString: "")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = .labelColor
        sourceLabel.alignment = .right
        let translationLabel = NSTextField(labelWithString: "")
        translationLabel.font = .systemFont(ofSize: 12, weight: .medium)
        translationLabel.textColor = .labelColor
        translationLabel.alignment = .right
        translationLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let sourceView = makeLongTextView(editable: true)
        sourceView.delegate = self
        let translationView = makeLongTextView(editable: false)
        let sourceScroll = makeLongTextScrollView(with: sourceView)
        let translationScroll = makeLongTextScrollView(with: translationView)
        let (sourcePronunciationRow, sourcePronunciationLabel) = makePronunciationRow()
        let (translationPronunciationRow, translationPronunciationLabel) = makePronunciationRow()

        // Keep footer actions secondary to the word/character count.  The
        // 30pt button frame remains an easy click target, while the SF Symbol
        // itself stays visually quieter.
        let footerIconConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let clearButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "trash", accessibilityDescription: interfaceText("清除原文", "Clear source"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceClearSource)
        )
        clearButton.toolTip = interfaceText("清除原文", "Clear source")
        clearButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        clearButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let sourceCopyButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: interfaceText("复制原文", "Copy source"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceCopySource)
        )
        sourceCopyButton.toolTip = interfaceText("复制原文", "Copy source")
        sourceCopyButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sourceCopyButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let sourceSpeakButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: interfaceText("朗读原文", "Speak source"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceSpeakSource)
        )
        sourceSpeakButton.toolTip = interfaceText(
            "朗读原文（再次点击停止）",
            "Speak source (click again to stop)"
        )
        sourceSpeakButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sourceSpeakButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let translationCopyButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: interfaceText("复制译文", "Copy translation"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceCopyTranslation)
        )
        translationCopyButton.toolTip = interfaceText("复制译文", "Copy translation")
        translationCopyButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        translationCopyButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let translationSpeakButton = WorkspaceIconButton(
            image: (NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: interfaceText("朗读译文", "Speak translation"))?
                .withSymbolConfiguration(footerIconConfiguration)) ?? NSImage(),
            target: self,
            action: #selector(workspaceSpeakTranslation)
        )
        translationSpeakButton.toolTip = interfaceText(
            "朗读译文（再次点击停止）",
            "Speak translation (click again to stop)"
        )
        translationSpeakButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        translationSpeakButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // Keep the source count and result status away from the split divider;
        // putting both labels at the centre makes them read as one string.
        let sourceFooter = NSStackView(views: [clearButton, sourceSpeakButton, sourceCopyButton, sourceLabel, NSView()])
        sourceFooter.orientation = .horizontal
        sourceFooter.alignment = .centerY
        sourceFooter.spacing = 12
        sourceFooter.setContentHuggingPriority(.required, for: .vertical)
        sourceFooter.setContentCompressionResistancePriority(.required, for: .vertical)
        sourceFooter.heightAnchor.constraint(equalToConstant: 32).isActive = true
        sourceFooter.views[4].setContentHuggingPriority(.defaultLow, for: .horizontal)
        let translationFooter = NSStackView(views: [NSView(), status, translationSpeakButton, translationCopyButton, translationLabel])
        translationFooter.orientation = .horizontal
        translationFooter.alignment = .centerY
        translationFooter.spacing = 12
        translationFooter.setContentHuggingPriority(.required, for: .vertical)
        translationFooter.setContentCompressionResistancePriority(.required, for: .vertical)
        translationFooter.heightAnchor.constraint(equalToConstant: 32).isActive = true
        translationFooter.views[0].setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Scroll views must take the remaining pane height, rather than
        // collapsing around a short sentence and leaving their footer at the
        // divider.  This also gives both stacked panes identical footers.
        sourceScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        sourceScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        translationScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        translationScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let sourceStack = NSStackView(views: [sourceScroll, sourcePronunciationRow, sourceFooter])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 0
        sourceStack.translatesAutoresizingMaskIntoConstraints = false
        sourceScroll.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
        sourcePronunciationRow.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true
        sourceFooter.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true

        let translationStack = NSStackView(views: [
            translationScroll,
            translationPronunciationRow,
            translationFooter
        ])
        translationStack.orientation = .vertical
        translationStack.alignment = .leading
        translationStack.spacing = 0
        translationStack.translatesAutoresizingMaskIntoConstraints = false
        translationScroll.widthAnchor.constraint(equalTo: translationStack.widthAnchor).isActive = true
        translationPronunciationRow.widthAnchor.constraint(equalTo: translationStack.widthAnchor).isActive = true
        translationFooter.widthAnchor.constraint(equalTo: translationStack.widthAnchor).isActive = true

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sourceStack)
        splitView.addArrangedSubview(translationStack)

        overlay.addSubview(header)
        overlay.addSubview(splitView)
        view.addSubview(
            overlay,
            positioned: .above,
            relativeTo: workspaceBackgroundView ?? webView
        )
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -Self.windowBehaviorBarHeight
            ),
            header.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 4),
            header.heightAnchor.constraint(equalToConstant: 36),
            sourceLanguageButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sourceLanguageButton.widthAnchor.constraint(lessThanOrEqualTo: sourceStack.widthAnchor, constant: -36),
            swapButton.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            swapButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            targetLanguageButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            targetLanguageButton.widthAnchor.constraint(lessThanOrEqualTo: translationStack.widthAnchor, constant: -36),
            splitView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
            splitView.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
            splitView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2)
        ])

        workspaceSplitBottomConstraint = splitView.bottomAnchor.constraint(
            equalTo: overlay.bottomAnchor,
            constant: -12
        )
        workspaceSplitBottomConstraint?.isActive = true

        workspaceEqualWidthConstraint = sourceStack.widthAnchor.constraint(equalTo: translationStack.widthAnchor)
        workspaceEqualHeightConstraint = sourceStack.heightAnchor.constraint(equalTo: translationStack.heightAnchor)
        workspaceEqualWidthConstraint?.isActive = true

        longTextOverlay = overlay
        longTextSourceView = sourceView
        longTextTranslationView = translationView
        longTextStatusLabel = status
        longTextSourceLabel = sourceLabel
        longTextTranslationLabel = translationLabel
        self.sourcePronunciationRow = sourcePronunciationRow
        self.translationPronunciationRow = translationPronunciationRow
        self.sourcePronunciationLabel = sourcePronunciationLabel
        self.translationPronunciationLabel = translationPronunciationLabel
        workspaceSourceLanguageButton = sourceLanguageButton
        workspaceTargetLanguageButton = targetLanguageButton
        workspaceSwapButton = swapButton
        workspaceSplitView = splitView
        workspaceSourceStack = sourceStack
        workspaceTranslationStack = translationStack
        workspaceSourceCountLabel = sourceLabel
        workspaceTranslationCountLabel = translationLabel
        updateLongTextOverlayAppearance()
    }

    private func makePronunciationRow() -> (NSView, NSTextField) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true
        row.isHidden = true

        let leadingInset = NSView()
        leadingInset.translatesAutoresizingMaskIntoConstraints = false
        leadingInset.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)

        let trailingSpace = NSView()
        trailingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(leadingInset)
        row.addArrangedSubview(label)
        row.addArrangedSubview(trailingSpace)
        return (row, label)
    }

    private func makeLongTextView(editable: Bool) -> NSTextView {
        let view: NSTextView = editable ? TranslationSourceTextView() : NSTextView()
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.allowsUndo = true
        // Translation output must remain byte-for-byte equivalent to the
        // service response. Do not let AppKit reinterpret dates, links,
        // quotes, dashes, spelling, or replacement text while rendering it.
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.drawsBackground = false
        // Match the visible Google typography used before the native rewrite:
        // 18 px text on a fixed 28 px line. AppKit's default line metric is
        // much tighter, so define the paragraph style explicitly.
        let font = NSFont.systemFont(ofSize: 18)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = 28
        paragraphStyle.maximumLineHeight = 28
        view.font = font
        view.defaultParagraphStyle = paragraphStyle
        let textColor: NSColor = isDarkMode ? .white : .black
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        // Keep the reading inset comfortable while allowing the final line
        // to sit closer to its footer actions when the text is scrolled down.
        view.textContainerInset = NSSize(width: 18, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = true
        return view
    }

    private func makeLongTextScrollView(with textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView()
        // Let the parent vibrancy material remain visible in both light and
        // dark mode. The standard bezel draws an opaque white background.
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        return scrollView
    }

    private func updateLongTextOverlayAppearance() {
        applyWorkspaceTypography(to: longTextSourceView)
        applyWorkspaceTypography(to: longTextTranslationView)
        let textColor: NSColor = isDarkMode ? .white : .black
        longTextStatusLabel?.textColor = textColor
        longTextSourceLabel?.textColor = textColor
        longTextTranslationLabel?.textColor = textColor
        let pronunciationColor = isDarkMode
            ? NSColor.white.withAlphaComponent(0.72)
            : NSColor.secondaryLabelColor
        sourcePronunciationLabel?.textColor = pronunciationColor
        translationPronunciationLabel?.textColor = pronunciationColor
        refreshPronunciationDisplayLabels()
        refreshWorkspaceLanguageTitles()
    }

    private func applyWorkspaceTypography(to view: NSTextView?) {
        guard let view else { return }
        let font = NSFont.systemFont(ofSize: 18)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = 28
        paragraphStyle.maximumLineHeight = 28
        let textColor: NSColor = isDarkMode ? .white : .black
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        view.font = font
        view.defaultParagraphStyle = paragraphStyle
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.typingAttributes = attributes
        if !view.string.isEmpty {
            view.textStorage?.setAttributes(
                attributes,
                range: NSRange(location: 0, length: (view.string as NSString).length)
            )
        }
    }

    private func showConnectionOverlay(waitingForNetwork: Bool) {
        connectionOverlay?.isHidden = false
        connectionRetryButton?.title = interfaceText("立即重试", "Retry Now")

        if waitingForNetwork {
            connectionTitleLabel?.stringValue = interfaceText(
                "正在连接翻译服务…",
                "Connecting to the translation service…"
            )
            connectionDetailLabel?.stringValue = interfaceText(
                "如果网络或 VPN 正在启动，连接恢复后会自动继续。",
                "If your network or VPN is starting, the app will continue automatically when it is available."
            )
            connectionSpinner?.isHidden = false
            connectionSpinner?.startAnimation(nil)
        } else {
            connectionTitleLabel?.stringValue = interfaceText(
                "暂时无法连接 Google Translate",
                "Google Translate is currently unavailable"
            )
            connectionDetailLabel?.stringValue = interfaceText(
                "请检查网络或开启可访问 Google Translate 的 VPN。软件会自动重试，也可以立即重试。",
                "Check your network or connect a VPN that can reach Google Translate. The app will retry automatically, or you can retry now."
            )
            connectionSpinner?.isHidden = true
            connectionSpinner?.stopAnimation(nil)
        }
    }

    private func hideConnectionOverlay() {
        delayedConnectionOverlayWorkItem?.cancel()
        delayedConnectionOverlayWorkItem = nil
        connectionOverlay?.isHidden = true
        connectionSpinner?.stopAnimation(nil)
    }

    private func scheduleConnectionOverlayIfStillLoading(attempt: Int) {
        delayedConnectionOverlayWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.translationLoadAttempt == attempt,
                  !self.isReady else { return }
            self.showConnectionOverlay(waitingForNetwork: true)
        }
        delayedConnectionOverlayWorkItem = workItem
        // Avoid flashing a connection screen during an ordinary cold launch.
        // It remains available for genuinely slow or unavailable networks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: workItem)
    }

    private func loadTranslationService() {
        automaticRetryWorkItem?.cancel()
        loadTimeoutWorkItem?.cancel()
        translationLoadAttempt += 1
        let attempt = translationLoadAttempt

        // Google is a background translation service only. Keep it mounted so
        // its dynamic result DOM continues updating, but make it fully
        // transparent so its responsive UI can never flash on screen.
        webView.isHidden = false
        webView.alphaValue = backgroundTranslationWebViewAlpha
        isReady = false
        hideConnectionOverlay()
        scheduleConnectionOverlayIfStillLoading(attempt: attempt)
        logStartupTiming("Primary page load started")
        webView.load(
            URLRequest(
                url: defaultTranslationURL(),
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 15
            )
        )

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.translationLoadAttempt == attempt,
                  !self.isReady else {
                return
            }
            self.handleTranslationLoadFailure()
        }
        loadTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 16, execute: timeout)
    }

    @objc private func retryTranslationService() {
        loadTranslationService()
    }

    private func handleTranslationLoadFailure() {
        guard !isReady else { return }
        delayedConnectionOverlayWorkItem?.cancel()
        delayedConnectionOverlayWorkItem = nil
        loadTimeoutWorkItem?.cancel()
        showConnectionOverlay(waitingForNetwork: false)
        scheduleAutomaticRetry()
    }

    private func scheduleAutomaticRetry() {
        automaticRetryWorkItem?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            self.loadTranslationService()
        }
        automaticRetryWorkItem = retry
        // VPN connection changes are not exposed as a reliable AppKit event.
        // A gentle retry loop lets a newly connected VPN recover without an
        // app restart and avoids polling while the page is already ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: retry)
    }

    override func keyDown(with event: NSEvent) {
        // Keyboard shortcuts inside the page are handled by the injected JS.
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // The compact app has no usable secondary/detail page.  In
        // particular, Google's selection UI links to /details, which appears
        // blank after our compact-page CSS is applied.
        let isTranslateHome = url.scheme == "https" &&
            url.host == "translate.google.com" &&
            (url.path.isEmpty || url.path == "/")
        decisionHandler(isTranslateHome ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView !== automaticTranslationWebView else {
            automaticTranslationWebViewReady = false
            automaticTranslationWebViewLoading = false
            return
        }
        handleTranslationLoadFailure()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView !== automaticTranslationWebView else {
            automaticTranslationWebViewReady = false
            automaticTranslationWebViewLoading = false
            return
        }
        handleTranslationLoadFailure()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logStartupTiming(webView === automaticTranslationWebView
            ? "Automatic navigation finished"
            : "Primary navigation finished")
        waitForTranslationDOM(in: webView)
    }

    private func waitForTranslationDOM(in webView: WKWebView) {
        let service = webView === automaticTranslationWebView ? "automatic" : "primary"
        webView.evaluateJavaScript(#"""
            (() => {
                const notify = () => {
                    if (!document.querySelector("textarea")) return false;
                    window.webkit.messageHandlers.callbackHandler.postMessage({
                        action: "translationServiceDOMReady",
                        service: "\#(service)"
                    });
                    return true;
                };
                if (notify()) return true;
                window.__macTranslateDOMReadyObserver?.disconnect();
                window.__macTranslateDOMReadyObserver = new MutationObserver(() => {
                    if (notify()) window.__macTranslateDOMReadyObserver?.disconnect();
                });
                window.__macTranslateDOMReadyObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
                return false;
            })();
        """#, completionHandler: nil)
    }

    private func configureTranslationPageAfterDOMReady(_ webView: WKWebView) {
        logStartupTiming(webView === automaticTranslationWebView
            ? "Automatic DOM ready"
            : "Primary DOM ready")
        installTranslationTimingRuntime(in: webView)
        logInputMethodTiming(
            webView === automaticTranslationWebView
                ? "automatic-webview-dom-ready"
                : "primary-webview-dom-ready",
            webFocus: false
        )
        if webView === automaticTranslationWebView {
            guard translationPageMatches(
                source: .automatic,
                target: automaticTranslationTarget,
                in: automaticTranslationWebView
            ), automaticTranslationTarget == currentTargetLanguage else {
                return
            }
            automaticTranslationWebViewLoading = false
            automaticTranslationWebViewReady = true
            if let source = pendingAutomaticTranslationSource,
               pendingAutomaticTranslationSession == longTextSession,
               longTextSource == source,
               longTextSourceView?.string == source {
                pendingAutomaticTranslationSource = nil
                pendingAutomaticTranslationSession = nil
                beginLongTextTranslation(source)
            } else if pendingAutomaticTranslationSource != nil {
                translationPipelineLogger.info(
                    "Discarded stale automatic-language request after page load"
                )
                pendingAutomaticTranslationSource = nil
                pendingAutomaticTranslationSession = nil
            }
            return
        }
        updateCurrentLanguages(from: webView.url)
        let hidePinyin = TranslateFeaturePreferences.hidePinyin ? "true" : "false"
        let hideGoogleSelectionToolbar = TranslateFeaturePreferences.hideGoogleSelectionToolbar
            ? "true"
            : "false"
        let simplifyActionButtons = TranslateFeaturePreferences.simplifyActionButtons
            ? "true"
            : "false"
        let highlightSelectedLanguage = TranslateFeaturePreferences.highlightSelectedLanguage
            ? "true"
            : "false"
        let sourceCopyLabel = interfaceText("复制原文", "Copy Source Text")
        let sourceClearLabel = interfaceText("清除", "Clear")
        let swapLanguagesLabel = interfaceText("交换源语言和目标语言", "Swap source and target languages")
        let wordCountLabel = interfaceText("单词", "Words")
        let chineseCharacterCountLabel = interfaceText("汉字", "Chinese characters")

        // Google changes its generated class names frequently.  This script
        // uses stable accessibility markers where possible and also performs
        // a conservative visual/text check for the pinyin line that is shown
        // next to Chinese results.
        self.webView.evaluateJavaScript(#"""
            (() => {
                const preferences = {
                    hidePinyin: \#(hidePinyin),
                    hideGoogleSelectionToolbar: \#(hideGoogleSelectionToolbar),
                    simplifyActionButtons: \#(simplifyActionButtons),
                    highlightSelectedLanguage: \#(highlightSelectedLanguage)
                };
                const styleId = "mac-translate-style";
                const styleText = `
                    header,
                    #kvLWu,
                    .VjFXz,
                    .VlPnLc,
                    .gp-footer,
                    .hgbeOc.EjH7wc {
                        display: none !important;
                    }

                    .leDWne {
                        display: none !important;
                    }

                    .QcsUad:not(.FkMbO) .lRu31,
                    .er8xn {
                        min-height: 65px;
                    }

                    /* Keep visible source layers on a local, stable font and
                       preserve Google's hidden 24/32 px line-count layer. */
                    .QFw9Te .Hapztf,
                    .QFw9Te .cEWAef,
                    .QFw9Te .er8xn,
                    .QFw9Te .fXYY1b,
                    .QFw9Te .sB7Iec {
                        font-family: -apple-system, BlinkMacSystemFont,
                            "Helvetica Neue", Arial, sans-serif !important;
                        font-size: 18px !important;
                        line-height: 28px !important;
                        font-weight: 400 !important;
                        letter-spacing: normal !important;
                        transition: none !important;
                    }

                    .QFw9Te .vJwDU {
                        font-family: -apple-system, BlinkMacSystemFont,
                            "Helvetica Neue", Arial, sans-serif !important;
                        font-size: 24px !important;
                        line-height: 32px !important;
                        font-weight: 400 !important;
                        letter-spacing: normal !important;
                        transition: none !important;
                    }

                    /* Keep the expanded result and its two hidden measurement
                       layers aligned across Google's responsive states. */
                    .QcsUad.sMVRZe .Cbi98e,
                    .QcsUad.sMVRZe .OvtS8d,
                    .QcsUad.sMVRZe .lRu31 {
                        font-size: 18px !important;
                        line-height: 28px !important;
                        transition: none !important;
                    }

                    html {
                        overflow: hidden;
                    }

                    .QcsUad .zWhQbb,
                    .QcsUad .mDTU0c {
                        display: none !important;
                    }

                    ${preferences.highlightSelectedLanguage ? `
                        /* Make the selected source and target languages clear. */
                        [role="tab"][data-language-code][aria-selected="true"],
                        [role="tab"][data-language-code][aria-selected="true"] * {
                            font-weight: 900 !important;
                        }
                    ` : ""}

                    /* Google reveals a wide-screen language ribbon when the
                       window grows. Keep the app's compact language bar at
                       every width: only the active source and target tabs
                       remain, with the custom swap control between them. */
                    [role="tab"][data-language-code][aria-selected="false"] {
                        display: none !important;
                    }

                    /* Keep selecting/copying available while suppressing the
                       WebKit text-selection callout actions. */
                    body,
                    textarea,
                    .er8xn,
                    .QcsUad .ryNqvb,
                    .QcsUad .jCAhz,
                    .QcsUad .HwtZe {
                        -webkit-user-select: text !important;
                        -webkit-touch-callout: none !important;
                    }

                    body::-webkit-scrollbar {
                        width: 0;
                        height: 0;
                        display: none;
                        -webkit-appearance: none;
                    }

                    ${preferences.hidePinyin ? `
                        [aria-label*="transliteration" i],
                        [aria-label*="romanization" i],
                        [aria-label*="pronunciation" i],
                        [data-testid*="transliteration" i],
                        [data-testid*="romanization" i],
                        [class*="transliteration" i],
                        [class*="romanization" i],
                        [class*="phonetic" i],
                        [class*="pinyin" i],
                        .QcsUad .UdTY9,
                        .QcsUad .kO6q6e,
                        .QcsUad [jsname="c3wAjc"] {
                            display: none !important;
                        }
                    ` : ""}

                    ${preferences.hideGoogleSelectionToolbar ? `
                        [aria-label*="dictionary" i],
                        [aria-label*="查字典"],
                        [data-tooltip*="dictionary" i],
                        [data-tooltip*="查字典"],
                        [title*="dictionary" i],
                        [title*="查字典"],
                        [jsname="SDSjce"],
                        [jsname="tD3Ohc"],
                        button[aria-label="朗读所选文字"],
                        button[aria-label="复制文字"],
                        button[aria-label*="selected text" i],
                        .ebT7ne,
                        .F0pQVc,
                        [jscontroller="ZR6Gve"],
                        [jsname="PbDcyb"],
                        [jsaction*="lysa9c"] {
                            display: none !important;
                        }
                    ` : ""}

                    ${preferences.simplifyActionButtons ? `
                        button[aria-label="语音翻译"],
                        button[aria-label="听取原文"],
                        button[aria-label="Voice input"],
                        button[aria-label="Listen to source text"],
                        .xMmqsf button[aria-label*="voice" i],
                        .xMmqsf button[aria-label*="microphone" i],
                        .xMmqsf button[aria-label*="speak" i],
                        .xMmqsf button[aria-label*="listen" i],
                        .xMmqsf button[data-tooltip*="voice" i],
                        .xMmqsf button[data-tooltip*="microphone" i],
                        .QcsUad button[aria-label="保存翻译"],
                        .QcsUad button[aria-label="听取译文"],
                        .QcsUad a[aria-label="使用 Google 搜索"],
                        .QcsUad button[aria-label="请对此翻译评分"],
                        .QcsUad button[aria-label="分享此译文"],
                        .QcsUad button[aria-label="Save translation"],
                        .QcsUad button[aria-label="Listen to translation"],
                        .QcsUad a[aria-label="Search with Google"],
                        .QcsUad button[aria-label="Rate this translation"],
                        .QcsUad button[aria-label="Share translation"],
                        .QcsUad .VO9ucd a,
                        .QcsUad a[aria-label*="Google" i],
                        .QcsUad a[href*="google.com/search" i],
                        [aria-label="发送反馈"],
                        [aria-label="Send feedback"],
                        [jsname="N7Eqid"],
                        .feedback-link {
                            display: none !important;
                        }

                        /* A result toolbar is rebuilt in stages by Google:
                           the Google-search button can be painted before its
                           final accessibility label exists. Keep the whole
                           toolbar invisible until the lightweight cleanup has
                           positively retained its copy button. */
                        .QcsUad .VO9ucd {
                            opacity: 0 !important;
                            pointer-events: none !important;
                        }

                    .QcsUad .VO9ucd[data-mac-translate-actions-ready="1"] {
                        opacity: 1 !important;
                        pointer-events: auto !important;
                    }
                    ` : ""}

                    .mac-translate-text-count {
                        display: block !important;
                        color: rgba(60, 64, 67, 0.72) !important;
                        font-family: -apple-system, BlinkMacSystemFont,
                            "Helvetica Neue", Arial, sans-serif !important;
                        font-size: 12px !important;
                        line-height: 16px !important;
                        font-variant-numeric: tabular-nums !important;
                        pointer-events: none !important;
                        user-select: none !important;
                    }

                    [data-mac-translate-count-placement="toolbar"] {
                        position: static !important;
                        flex: 0 0 auto !important;
                        margin-left: auto !important;
                        padding: 0 8px !important;
                        align-self: center !important;
                    }

                    [data-mac-translate-count-placement="fallback"] {
                        position: absolute !important;
                        z-index: 5 !important;
                        right: 12px !important;
                        bottom: 8px !important;
                    }

                    /* Native controls replace Google's language chooser, so
                       its floating hover hints only create leftover text
                       over the compact header. */
                    [role="tooltip"] {
                        display: none !important;
                    }

                    /* Google's source quota is exposed as an image in some
                       layouts, so text-only cleanup cannot always remove it. */
                    [aria-label*="目前为"][aria-label*="个字符"],
                    [aria-label*="上限为"][aria-label*="字符"],
                    [aria-label*="characters" i][aria-label*="limit" i],
                    [aria-label*="characters" i][aria-label*="maximum" i],
                    [aria-label*="characters" i][aria-label*="out of" i] {
                        display: none !important;
                    }
                `;

                let style = document.getElementById(styleId);
                if (!style) {
                    style = document.createElement("style");
                    style.id = styleId;
                    (document.head || document.body).appendChild(style);
                }
                style.textContent = styleText;

                let theme = document.getElementById("mac-translate-theme-style");
                if (!theme) {
                    theme = document.createElement("style");
                    theme.id = "mac-translate-theme-style";
                    (document.head || document.body).appendChild(theme);
                }

                const roots = [];
                const collectRoots = (root) => {
                    roots.push(root);
                    root.querySelectorAll("*").forEach((element) => {
                        if (element.shadowRoot) {
                            collectRoots(element.shadowRoot);
                        }
                    });
                };

                const forEachElement = (callback) => {
                    roots.length = 0;
                    collectRoots(document);
                    roots.forEach((root) => root.querySelectorAll("*").forEach(callback));
                };

                const textOf = (element) => (element.innerText || element.textContent || "")
                    .replace(/\\s+/g, " ")
                    .trim();

                const isRightPane = (element) => {
                    const rect = element.getBoundingClientRect();
                    if (!rect.width || !rect.height) return false;
                    return rect.left > window.innerWidth * 0.42 ||
                        (rect.left + rect.width > window.innerWidth * 0.55 &&
                         rect.width < window.innerWidth * 0.70);
                };

                const hasChineseSibling = (element) => {
                    let parent = element.parentElement;
                    for (let level = 0; parent && level < 4; level += 1) {
                        const siblings = Array.from(parent.children)
                            .filter((child) => child !== element);
                        if (siblings.some((sibling) => /[\\u3400-\\u9fff]/.test(textOf(sibling)))) {
                            return true;
                        }
                        parent = parent.parentElement;
                    }
                    return false;
                };

                const looksLikePinyin = (text) => {
                    if (text.length < 2 || text.length > 400 || /[\\u3400-\\u9fff]/.test(text)) {
                        return false;
                    }
                    const letters = (text.match(/[A-Za-zÀ-ÖØ-öø-ÿ]/g) || []).length;
                    const toneMarks = /[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]/i.test(text);
                    const apostrophe = /['’]/.test(text);
                    return letters > 3 && /\\s/.test(text) && (toneMarks || apostrophe);
                };

                const detailLabel = (element) => [
                    element.getAttribute("aria-label") || "",
                    element.getAttribute("data-tooltip") || "",
                    textOf(element)
                ].join(" ").trim();

                const isDetailControl = (element) => {
                    const label = detailLabel(element);
                    return /^(展开|收起|expand|collapse|show more|hide details|详细|word[- ]by[- ]word)/i.test(label) ||
                        /\\b(word[- ]by[- ]word|show more|expand details)\\b/i.test(label);
                };

                const hide = (element) => {
                    if (element.getAttribute("data-mac-translate-hidden") === "1") return;
                    element.setAttribute("data-mac-translate-hidden", "1");
                    element.style.setProperty("display", "none", "important");
                };

                const isFeedbackElement = (element) => {
                    const label = (element.getAttribute("aria-label") || "").trim();
                    const text = textOf(element);
                    return /^(发送反馈|Send feedback)$/i.test(label) ||
                        /^(发送反馈|Send feedback)$/i.test(text);
                };

                // Google keeps an accessibility hint for its history sidebar
                // in the document. With the compact page layout it can be
                // positioned over the source textarea after a long input.
                // This exact hint is not translation content, so hide only
                // the node whose complete text matches it.
                const isSidebarTranslationHint = (text) =>
                    /^(使用箭头按钮可查看完整译文|use (?:the )?arrow buttons? to view (?:the )?full translation)\.?$/i
                        .test(text.trim());

                const isLongTextLimitNotice = (text) =>
                    /(如需翻译超过\s*5[,，]?000\s*个字符.*复制.*粘贴原文|translate more than\s*5,?000\s*characters.*copy.*paste)/i
                        .test(text.replace(/\s+/g, " "));

                const isLanguageSwapHint = (text) =>
                    /(交换源语言和目标语言|swap source and target languages?)/i
                        .test(text.replace(/\s+/g, " "));

                const copyActionPattern = /(copy translation|copy|content_copy|复制译文|复制翻译|复制)/i;

                const controlLabel = (element) => [
                    element.getAttribute("aria-label") || "",
                    element.getAttribute("data-tooltip") || "",
                    element.getAttribute("title") || "",
                    element.getAttribute("jsname") || "",
                    textOf(element)
                ].join(" ").replace(/\s+/g, " ").trim();

                const countLabels = {
                    words: "\#(wordCountLabel)",
                    chineseCharacters: "\#(chineseCharacterCountLabel)"
                };

                const visible = (element) => {
                    const style = getComputedStyle(element);
                    const rect = element.getBoundingClientRect();
                    return style.display !== "none" && style.visibility !== "hidden" &&
                        rect.width > 0 && rect.height > 0;
                };

                const textCount = (text) => {
                    const hanCharacters = (text.match(/[\u3400-\u9fff\uf900-\ufaff]/g) || []).length;
                    // Unicode class \p{L} includes Han characters. Remove
                    // them before counting word-like runs so Chinese text is
                    // reported as 汉字, not as a misleading series of words.
                    const nonHanText = text.replace(/[\u3400-\u9fff\uf900-\ufaff]/g, " ");
                    const words = (nonHanText.match(
                        /[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*/gu
                    ) || []).length;
                    return { words, hanCharacters };
                };

                const countText = (text) => {
                    const { words, hanCharacters } = textCount(text);
                    const parts = [];
                    if (words > 0) parts.push(`${countLabels.words} ${words}`);
                    if (hanCharacters > 0) {
                        parts.push(`${countLabels.chineseCharacters} ${hanCharacters}`);
                    }
                    return parts.join(" · ");
                };

                const countNode = (host, side, toolbar) => {
                    if (!host) return null;
                    host.style.setProperty("position", "relative", "important");
                    const id = `mac-translate-text-count-${side}`;
                    let node = document.getElementById(id);
                    if (!node) {
                        node = document.createElement("span");
                        node.id = id;
                        node.className = "mac-translate-text-count";
                        node.setAttribute("data-mac-translate-count-side", side);
                        node.setAttribute("aria-live", "polite");
                    }
                    const placement = toolbar || host;
                    if (node.parentElement !== placement) placement.appendChild(node);
                    node.setAttribute(
                        "data-mac-translate-count-placement",
                        toolbar ? "toolbar" : "fallback"
                    );
                    return node;
                };

                const hideNativeSourceCharacterCount = (sourceHost) => {
                    if (!sourceHost) return;
                    // Google places its character quota beside, rather than
                    // inside, the textarea in some layouts. Check the local
                    // input container and a few ancestors, without touching
                    // any unrelated numeric controls elsewhere on the page.
                    let container = sourceHost;
                    for (let level = 0; container && level < 4; level += 1) {
                        Array.from(container.querySelectorAll("*")).forEach((element) => {
                            if (element.classList.contains("mac-translate-text-count") ||
                                element.children.length > 0) {
                                return;
                            }
                            const text = textOf(element);
                            const label = [
                                element.getAttribute("aria-label") || "",
                                element.getAttribute("data-tooltip") || ""
                            ].join(" ");
                            const isCharacterQuota =
                                /^\d[\d,]*\s*\/\s*\d[\d,]*$/.test(text) ||
                                /(目前为.*个字符.*上限|上限为.*字符|characters?.*(limit|maximum|out of))/i
                                    .test(label);
                            if (isCharacterQuota) {
                                element.style.setProperty("display", "none", "important");
                            }
                        });
                        container = container.parentElement;
                    }
                };

                const updateTextCounts = () => {
                    const textarea = document.querySelector("textarea.er8xn, textarea");
                    if (textarea) {
                        const sourceHost = textarea.closest(".QFw9Te") || textarea.parentElement;
                        const sourceToolbar = document.querySelector(".xMmqsf");
                        const node = countNode(sourceHost, "source", sourceToolbar);
                        if (node) node.textContent = countText(textarea.value);
                        hideNativeSourceCharacterCount(sourceHost);
                    }

                    const results = Array.from(document.querySelectorAll(resultTextSelector))
                        .filter(visible)
                        // Google marks several nested wrappers as result text.
                        // Prefer the innermost wrapper so its text is counted
                        // once instead of once per nested element.
                        .filter((element, _, all) => !all.some((other) =>
                            other !== element && element.contains(other) &&
                            textOf(other) === textOf(element)
                        ));
                    const result = results.find((element) => textOf(element)) || results[0];
                    if (!result) return;
                    const resultHost = result.closest(".QcsUad") || result.parentElement;
                    const resultToolbar = resultHost.querySelector(".VO9ucd");
                    const node = countNode(resultHost, "result", resultToolbar);
                    if (node) node.textContent = countText(textOf(result));
                };

                const ensureSourceToolbarButtons = () => {
                    const toolbar = document.querySelector(".xMmqsf");
                    const resultToolbar = document.querySelector(".QcsUad .VO9ucd");
                    if (!toolbar || !resultToolbar) return;

                    const resultCopyButton = Array.from(
                        resultToolbar.querySelectorAll("button")
                    ).find((button) => copyActionPattern.test(controlLabel(button)));
                    if (!resultCopyButton) return;

                    let slot = document.getElementById("mac-translate-source-copy-slot");
                    const existingButton = document.getElementById("mac-translate-source-copy");
                    const existingClear = document.getElementById("mac-translate-source-clear");
                    if (slot && slot.parentElement === toolbar && existingButton && existingClear) return;
                    if (slot) slot.remove();
                    document.getElementById("mac-translate-source-clear-slot")?.remove();

                    slot = document.createElement("div");
                    slot.id = "mac-translate-source-copy-slot";
                    slot.style.setProperty("width", "48px", "important");
                    slot.style.setProperty("height", "48px", "important");
                    slot.style.setProperty("flex", "0 0 48px", "important");
                    slot.style.setProperty("display", "flex", "important");
                    slot.style.setProperty("align-items", "center", "important");
                    slot.style.setProperty("justify-content", "center", "important");

                    // Clone Google's real result-copy button so the left and
                    // right icons use the exact same DOM, classes and SVG.
                    const button = resultCopyButton.cloneNode(true);
                    button.querySelectorAll("[id]").forEach((element) => {
                        element.removeAttribute("id");
                    });
                    [button, ...button.querySelectorAll("*")].forEach((element) => {
                        element.removeAttribute("jscontroller");
                        element.removeAttribute("jsname");
                        element.removeAttribute("jsaction");
                        element.removeAttribute("data-mac-translate-hidden");
                    });
                    button.id = "mac-translate-source-copy";
                    button.setAttribute("aria-label", "\#(sourceCopyLabel)");
                    button.setAttribute("title", "\#(sourceCopyLabel)");
                    button.removeAttribute("data-tooltip");

                    slot.appendChild(button);

                    const clearSlot = document.createElement("div");
                    clearSlot.id = "mac-translate-source-clear-slot";
                    clearSlot.style.setProperty("height", "48px", "important");
                    clearSlot.style.setProperty("flex", "0 0 auto", "important");
                    clearSlot.style.setProperty("display", "flex", "important");
                    clearSlot.style.setProperty("align-items", "center", "important");
                    const clearButton = button.cloneNode(false);
                    clearButton.id = "mac-translate-source-clear";
                    clearButton.innerHTML = `<svg viewBox="0 0 24 24" width="22" height="22"
                        aria-hidden="true" fill="none" stroke="currentColor" stroke-width="2"
                        stroke-linecap="round" stroke-linejoin="round">
                        <path d="M3 6h18"></path><path d="M8 6V4h8v2"></path>
                        <path d="M6 6l1 14h10l1-14"></path><path d="M10 10v6"></path>
                        <path d="M14 10v6"></path></svg>`;
                    clearButton.setAttribute("aria-label", "\#(sourceClearLabel)");
                    clearButton.setAttribute("title", "\#(sourceClearLabel)");
                    clearButton.style.setProperty("width", "48px", "important");
                    clearButton.style.setProperty("min-width", "48px", "important");
                    clearButton.style.setProperty("padding", "0", "important");
                    clearSlot.appendChild(clearButton);
                    toolbar.prepend(clearSlot, slot);
                };

                const swapControlPattern = /^(?:交换源语言和目标语言|swap source and target languages?)/i;

                const ensureCustomSwapButton = () => {
                    const original = Array.from(document.querySelectorAll(
                        'button[aria-label], [role="button"][aria-label]'
                    )).find((element) =>
                        element.id !== "mac-translate-custom-swap" &&
                        swapControlPattern.test(controlLabel(element))
                    );
                    if (!original) return;

                    const rect = original.getBoundingClientRect();
                    if (!rect.width || !rect.height) return;
                    original.style.setProperty("visibility", "hidden", "important");

                    let button = document.getElementById("mac-translate-custom-swap");
                    if (!button) {
                        button = document.createElement("button");
                        button.id = "mac-translate-custom-swap";
                        button.type = "button";
                        button.textContent = "⇄";
                        button.setAttribute("aria-label", "\#(swapLanguagesLabel)");
                        button.setAttribute("title", "\#(swapLanguagesLabel)");
                        button.style.cssText = [
                            "position:fixed", "z-index:10002", "display:flex",
                            "align-items:center", "justify-content:center",
                            "border:0", "border-radius:8px", "padding:0",
                            "background:transparent", "color:inherit", "cursor:pointer",
                            "font:600 31px/1 -apple-system, BlinkMacSystemFont, sans-serif"
                        ].join(" !important;") + " !important;";
                        document.body.appendChild(button);
                    }
                    button.style.setProperty("left", `${rect.left}px`, "important");
                    button.style.setProperty("top", `${rect.top}px`, "important");
                    button.style.setProperty("width", `${rect.width}px`, "important");
                    button.style.setProperty("height", `${rect.height}px`, "important");
                };

                const keepOnlyResultCopyButton = () => {
                    const toolbar = document.querySelector(".QcsUad .VO9ucd");
                    if (!toolbar) return;
                    const copyControl = Array.from(
                        toolbar.querySelectorAll("button")
                    ).find((button) => copyActionPattern.test(controlLabel(button)));
                    if (!copyControl) return;

                    const actionGroup = copyControl.closest(".YJGJsb");
                    if (actionGroup) {
                        Array.from(actionGroup.children).forEach((child) => {
                            if (!child.contains(copyControl)) hide(child);
                        });
                        actionGroup.style.setProperty("width", "48px", "important");
                        actionGroup.style.setProperty("min-width", "48px", "important");
                        actionGroup.style.setProperty("display", "flex", "important");
                    }

                    Array.from(toolbar.children).forEach((child) => {
                        if (child !== actionGroup && !child.contains(copyControl) &&
                            !child.classList.contains("mac-translate-text-count")) {
                            hide(child);
                        }
                    });
                    toolbar.style.setProperty("justify-content", "flex-end", "important");
                    toolbar.setAttribute("data-mac-translate-actions-ready", "1");
                };

                // “查字典/Lookup” is unique to Google's contextual selection
                // row.  Do not key this rule off Copy/Listen: those controls
                // also exist in the two permanent source/result toolbars.
                const selectionActionPattern = /(查字典|dictionary|look up|lookup|menu_book|definitions?)/i;

                const hideSelectionAction = (element, selectedText) => {
                    if (!selectedText) return false;
                    const role = element.getAttribute("role") || "";
                    const className = typeof element.className === "string" ? element.className : "";
                    const isControl = element.tagName === "BUTTON" || element.tagName === "A" ||
                        role === "button" ||
                        element.hasAttribute("aria-label") ||
                        element.hasAttribute("data-tooltip") ||
                        element.hasAttribute("title") ||
                        /material-icons|google-symbols/i.test(className);
                    if (!isControl) return false;

                    const label = [
                        element.getAttribute("aria-label") || "",
                        element.getAttribute("data-tooltip") || "",
                        element.getAttribute("title") || "",
                        element.getAttribute("jsname") || "",
                        textOf(element)
                    ].join(" ").trim();
                    if (!selectionActionPattern.test(label)) return false;

                    // The current and recent Google layouts put these controls
                    // in a compact floating row.  Walk upward to hide that
                    // row, while avoiding the main result container and its
                    // persistent copy/listen controls when no text is selected.
                    let candidate = element;
                    for (let level = 0; candidate && level < 6; level += 1) {
                        const ownsEditableText = candidate.matches(
                            `textarea, .er8xn, ${resultTextSelector}`
                        ) || candidate.querySelector(
                            `textarea, .er8xn, ${resultTextSelector}`
                        );
                        if (ownsEditableText) break;

                        const rect = candidate.getBoundingClientRect();
                        const style = window.getComputedStyle(candidate);
                        const controls = candidate.querySelectorAll(
                            'button, a, [role="button"], [jsname]'
                        ).length;
                        const compact = rect.width > 0 && rect.height > 0 &&
                            rect.height <= 120 && rect.width <= window.innerWidth * 0.9;
                        const floating = style.position === "absolute" || style.position === "fixed";
                        if (controls >= 2 && compact && (floating || level > 0) &&
                            !candidate.matches(".QcsUad")) {
                            hide(candidate);
                            return true;
                        }
                        candidate = candidate.parentElement;
                    }

                    hide(element);
                    return true;
                };

                const resultTextSelector = [
                    ".QcsUad .ryNqvb",
                    ".QcsUad .HwtZe",
                    ".QcsUad .jCAhz",
                    ".QcsUad .lRu31",
                    ".QcsUad [jsname=\"W297wb\"]"
                ].join(",");

                const detailSelector = [
                    ".QcsUad .zWhQbb",
                    ".QcsUad .mDTU0c",
                    ".QcsUad .UdTY9",
                    ".QcsUad [aria-expanded=\"true\"]"
                ].join(",");

                const cleanup = () => {
                    const selection = window.getSelection();
                    const active = document.activeElement;
                    let selectedText = selection && !selection.isCollapsed ?
                        selection.toString().trim() : "";
                    if (!selectedText && active &&
                        (active.tagName === "TEXTAREA" || active.tagName === "INPUT") &&
                        typeof active.selectionStart === "number" &&
                        active.selectionEnd > active.selectionStart) {
                        selectedText = active.value.slice(active.selectionStart, active.selectionEnd).trim();
                    }

                    forEachElement((element) => {
                        const tag = element.tagName;
                        if (["SCRIPT", "STYLE", "TEXTAREA", "INPUT", "SELECT", "OPTION"].includes(tag)) {
                            return;
                        }

                        const marker = [
                            element.className || "",
                            element.getAttribute("aria-label") || "",
                            element.getAttribute("data-testid") || "",
                            element.getAttribute("data-tooltip") || "",
                            element.getAttribute("title") || "",
                            element.getAttribute("href") || ""
                        ].join(" ");

                        const ariaLabel = (element.getAttribute("aria-label") || "").trim();
                        const sourceControlLabel = [
                            ariaLabel,
                            element.getAttribute("data-tooltip") || "",
                            element.getAttribute("title") || ""
                        ].join(" ").trim();
                        if (preferences.simplifyActionButtons &&
                            element.tagName === "BUTTON" &&
                            element.closest(".xMmqsf") &&
                            /(语音翻译|听取原文|voice|microphone|speak|listen)/i.test(sourceControlLabel)) {
                            hide(element);
                            return;
                        }

                        if (preferences.simplifyActionButtons && element.tagName === "A" && isRightPane(element) &&
                            /google/i.test(marker) && /(search|搜索)/i.test(marker)) {
                            hide(element);
                            return;
                        }

                        // These are the current result/pinyin nodes.  The
                        // pinyin line is deliberately removed as a whole,
                        // including the hidden 展开/收起 controls inside it.
                        if (preferences.hidePinyin && element.matches(".QcsUad .UdTY9, .QcsUad .kO6q6e, .QcsUad [jsname=\"c3wAjc\"]")) {
                            hide(element.closest(".UdTY9") || element);
                            return;
                        }

                        // Current Google input/result text-selection popover.
                        if (preferences.hideGoogleSelectionToolbar && element.matches(
                            "[jsname=\"SDSjce\"], [jsname=\"tD3Ohc\"], " +
                            "button[aria-label=\"朗读所选文字\"], " +
                            "button[aria-label=\"复制文字\"], " +
                            "button[aria-label*=\"selected text\" i]"
                        )) {
                            hide(element.closest("[jsname=\"SDSjce\"]") || element);
                            return;
                        }

                        // Google reuses this row for the selection actions
                        // (speaker, copy, dictionary, etc.).  Remove the
                        // complete row, not only the dictionary link, so no
                        // floating action icons are left behind.
                        if (preferences.hideGoogleSelectionToolbar && element.matches(".ebT7ne, .F0pQVc, [jscontroller=\"ZR6Gve\"], [jsname=\"PbDcyb\"], [jsaction*=\"lysa9c\"]")) {
                            hide(element);
                            return;
                        }

                        if (preferences.hideGoogleSelectionToolbar && hideSelectionAction(element, selectedText)) {
                            return;
                        }

                        if (preferences.simplifyActionButtons && isFeedbackElement(element)) {
                            const feedback = element.closest(".cJ1Ndf") || element;
                            hide(feedback);
                            return;
                        }

                        if (preferences.hidePinyin && /(transliteration|romanization|phonetic|pinyin|pronunciation)/i.test(marker)) {
                            hide(element);
                            return;
                        }

                        const text = textOf(element);
                        // This is Google's floating hover hint for the swap
                        // button. Recent layouts duplicate its text in nested
                        // absolutely positioned nodes, so hiding only a
                        // standard role=tooltip is not sufficient.
                        if (isLanguageSwapHint(text) && element.tagName !== "BUTTON") {
                            const style = getComputedStyle(element);
                            if (element.getAttribute("role") === "tooltip" ||
                                style.position === "absolute" || style.position === "fixed" ||
                                element.children.length <= 2) {
                                hide(element);
                                return;
                            }
                        }
                        if ((isSidebarTranslationHint(text) || isLongTextLimitNotice(text)) &&
                            (element.children.length <= 3 ||
                             element.matches('[role="alert"], [role="dialog"]'))) {
                            hide(element.closest('[role="alert"], [role="dialog"]') || element);
                            return;
                        }
                        const rect = element.getBoundingClientRect();
                        if (preferences.hidePinyin && isRightPane(element) && rect.height < 100 &&
                            element.children.length <= 3 && looksLikePinyin(text) &&
                            hasChineseSibling(element)) {
                            hide(element);
                        }

                        if (element.getAttribute("aria-expanded") === "true" && isDetailControl(element)) {
                            element.setAttribute("aria-expanded", "false");
                        }
                    });

                    if (preferences.simplifyActionButtons) {
                        ensureSourceToolbarButtons();
                        keepOnlyResultCopyButton();
                    }

                    ensureCustomSwapButton();

                    updateTextCounts();

                };

                var cleanupScheduled = false;
                var cleanupTimer = null;
                const scheduleCleanup = (delay = 160) => {
                    if (cleanupTimer) clearTimeout(cleanupTimer);
                    cleanupScheduled = true;
                    cleanupTimer = setTimeout(() => {
                        cleanupTimer = null;
                        cleanupScheduled = false;
                        cleanup();
                    }, delay);
                };
                window.__macTranslateScheduleCleanup = scheduleCleanup;

                if (!window.__macTranslateInstalled) {
                    window.__macTranslateInstalled = true;
                    // Google changes many DOM nodes for every individual
                    // keystroke.  Watching style/class changes made this
                    // custom cleanup scan the entire page repeatedly while
                    // typing. New UI (results, pinyin and selection bars)
                    // still arrives as child nodes, so observe only those
                    // and coalesce the work after the page settles.
                    const observer = new MutationObserver((records) => {
                        let resultToolbarChanged = false;
                        for (const record of records) {
                            for (const node of record.addedNodes) {
                                const element = node.nodeType === Node.ELEMENT_NODE
                                    ? node
                                    : node.parentElement;
                                const toolbar = element && (
                                    element.matches?.(".QcsUad .VO9ucd")
                                        ? element
                                        : element.closest?.(".QcsUad .VO9ucd")
                                );
                                if (toolbar) {
                                    // This synchronous, local operation runs
                                    // before a frame is painted. It prevents
                                    // Google's G action from flashing while
                                    // avoiding the expensive full-page scan.
                                    toolbar.setAttribute("data-mac-translate-actions-ready", "0");
                                    resultToolbarChanged = true;
                                }
                            }
                        }
                        scheduleCleanup(resultToolbarChanged ? 50 : 240);
                    });
                    observer.observe(document.documentElement, {
                        childList: true,
                        subtree: true
                    });

                    // Google attaches a click action to .ryNqvb/.jCAhz that
                    // opens the overlapping word-by-word panel.  Block only
                    // that action; native mouse dragging and text selection
                    // remain untouched because mousedown is not cancelled.
                    const blockResultClick = (event) => {
                        const target = event.target;
                        const element = target && target.closest ? target : null;
                        if (!element) return;

                        // Result toolbars can be nested inside the result text
                        // container. Let their native actions receive the
                        // click instead of treating the button as a text
                        // click that opens Google's word-by-word panel.
                        if (element.closest(
                            'button, a, [role="button"], input, select, textarea'
                        )) return;

                        const detail = element.closest(detailSelector);
                        const result = element.closest(resultTextSelector);
                        if (detail || result) {
                            event.preventDefault();
                            event.stopImmediatePropagation();
                            scheduleCleanup(40);
                        }
                    };

                    document.addEventListener("click", blockResultClick, true);
                    document.addEventListener("dblclick", blockResultClick, true);
                    document.addEventListener("selectionchange", () => scheduleCleanup(40), true);
                    // Do not scan Google's complete page on every typed
                    // character. Pasting remains immediate because its DOM
                    // update is handled by the child-node observer above.
                    document.addEventListener("input", (event) => {
                        const target = event.target;
                        if (target instanceof HTMLTextAreaElement) {
                            updateTextCounts();
                        }
                        scheduleCleanup(320);
                    }, true);

                    // Do not let Google install a page-level context menu or
                    // selection callout.  Native text selection and Cmd+C
                    // continue to work; the AppKit WebView subclass also
                    // removes any native menu that WebKit tries to present.
                    document.addEventListener("contextmenu", (event) => {
                        event.preventDefault();
                        event.stopImmediatePropagation();
                    }, true);

                }

                cleanup();
            })();
        """#) { [weak self] _, _ in
            guard let self else { return }
            self.setTheme { [weak self] in
                guard let self else { return }
                self.restorePendingSourceTextIfNeeded()
                // The visible translation workspace is app-owned. Google is
                // kept only as the background document and direct endpoint,
                // so its responsive language pages never surface in the UI.
                // Activate the native workspace immediately. The WebView is
                // hidden before any asynchronous JavaScript work begins, so
                // no Google frame can appear during startup or reload.
                self.activateCustomTranslationWorkspace()
                self.markReady()
                self.logStartupTiming("Primary CSS and scripts ready")
                self.logInputMethodTiming("primary-css-scripts-ready", webFocus: false)
                self.completeLanguageSwapIfReady()
                self.submitPendingPrimaryTranslationIfCurrent()
                self.loadTimeoutWorkItem?.cancel()
                self.automaticRetryWorkItem?.cancel()
                self.hideConnectionOverlay()
            }
        }
    }

    private func installTranslationTimingRuntime(in webView: WKWebView) {
        webView.evaluateJavaScript(#"""
            (() => {
                if (window.__macTranslateTimingRuntimeReady) return true;
                window.__macTranslateTimingRuntimeReady = true;
                window.__macTranslateActiveTiming = null;
                window.__macTranslateTimingObserver = new MutationObserver((records) => {
                    const timing = window.__macTranslateActiveTiming;
                    if (!timing || timing.firstResultMutationAt != null) return;
                    const touchesResult = records.some((record) => {
                        const target = record.target?.nodeType === Node.ELEMENT_NODE
                            ? record.target
                            : record.target?.parentElement;
                        if (target?.closest?.(".QcsUad")) return true;
                        return Array.from(record.addedNodes || []).some((node) => {
                            const element = node.nodeType === Node.ELEMENT_NODE
                                ? node
                                : node.parentElement;
                            return element?.matches?.(".QcsUad") ||
                                element?.closest?.(".QcsUad") ||
                                element?.querySelector?.(".QcsUad");
                        });
                    });
                    if (!touchesResult) return;
                    timing.firstResultMutationAt = performance.now();
                    window.webkit.messageHandlers.callbackHandler.postMessage({
                        action: "translationTimingJS",
                        requestID: timing.requestID,
                        session: timing.session,
                        milestone: "first-result-dom-mutation",
                        jsElapsedMS: timing.firstResultMutationAt - timing.jsStartedAt
                    });
                });
                window.__macTranslateTimingObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                return true;
            })();
        """#) { [weak self] result, error in
            guard let self, result as? Bool == true, error == nil else { return }
            self.logStartupTiming(webView === self.automaticTranslationWebView
                ? "Automatic timing observer ready"
                : "Primary timing observer ready")
        }
    }

    func setTheme(completion: (() -> Void)? = nil) {
        let appearance = currentEffectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        visualEffect.material = dark ? .dark : .light
        workspaceBackgroundView?.material = dark ? .dark : .light
        updateWindowBehaviorBarAppearance()
        updateLongTextOverlayAppearance()
        let webColorScheme = dark ? "dark" : "light"
        let webTextColor = dark ? "white" : "black"
        let webSelectedColor = dark ? "#A8C7FA" : "#0B57D0"
        let webSelectedBackground = dark
            ? "rgba(168, 199, 250, 0.20)"
            : "rgba(11, 87, 208, 0.14)"
        let selectedLanguageStyle = TranslateFeaturePreferences.highlightSelectedLanguage
            ? #"""
                [role="tab"][data-language-code][aria-selected="true"] {
                    background: var(--translate-selected-background) !important;
                    color: var(--translate-selected-color) !important;
                    border-radius: 10px !important;
                    box-shadow: inset 0 -3px 0 var(--translate-selected-color) !important;
                    font-weight: 900 !important;
                }

                [role="tab"][data-language-code][aria-selected="true"] * {
                    color: var(--translate-selected-color) !important;
                    font-weight: 900 !important;
                }
            """#
            : ""

        self.webView.evaluateJavaScript(#"""
            let theme = document.getElementById("mac-translate-theme-style");
            if (!theme) {
                theme = document.createElement("style");
                theme.id = "mac-translate-theme-style";
                (document.head || document.documentElement).appendChild(theme);
            }
            theme.textContent = `
                :root {
                    color-scheme: \#(webColorScheme) !important;
                    --translate-text-color: \#(webTextColor);
                    --translate-selected-color: \#(webSelectedColor);
                    --translate-selected-background: \#(webSelectedBackground);
                }

                *, *:before, *:after {
                    background: transparent !important;
                    color: var(--translate-text-color) !important;
                    box-shadow: none !important;
                    border-color: var(--translate-text-color) !important;
                    border: none !important;
                    border-top: none !important;
                }

                \#(selectedLanguageStyle)

                .zXU7Rb, .ccvoYb.EjH7wc {
                    border: none !important;
                }
            `;
        """#) { _, _ in
            completion?()
        }
    }

    private func updateWindowBehaviorBarAppearance() {
        let dark = isDarkMode
        windowBehaviorBar?.material = dark ? .dark : .light
        windowBehaviorBar?.layer?.borderColor = NSColor.separatorColor.cgColor

        windowBehaviorSettingsGroup?.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(dark ? 0.12 : 0.055).cgColor
        windowBehaviorSettingsGroup?.layer?.borderColor = NSColor.separatorColor.cgColor
        windowBehaviorDivider?.wantsLayer = true
        windowBehaviorDivider?.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    private func logInputMethodTiming(_ event: String, webFocus: Bool = false) {
#if DEBUG
        let responder = view.window?.firstResponder
        let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let marked = longTextSourceView?.hasMarkedText() ?? false
        let markedRange = longTextSourceView?.markedRange() ?? NSRange(location: NSNotFound, length: 0)
        inputMethodTimingLogger.info(
            "[InputMethodTiming] event=\(event, privacy: .public) firstResponder=\(responderType, privacy: .public) marked=\(marked, privacy: .public) markedRange={\(markedRange.location, privacy: .public),\(markedRange.length, privacy: .public)} webFocus=\(webFocus, privacy: .public)"
        )
#endif
    }

    public func focusAndSelectField(selectContents: Bool = true) {
        if longTextOverlay?.isHidden == false, let sourceView = longTextSourceView {
            logInputMethodTiming("native-focus-request select=\(selectContents)")
            guard !sourceView.hasMarkedText() else {
                logInputMethodTiming("native-focus-skipped-marked-text")
                return
            }
            if sourceView.window?.firstResponder !== sourceView {
                sourceView.window?.makeFirstResponder(sourceView)
            }
            if selectContents {
                sourceView.selectAll(nil)
            }
            logInputMethodTiming("native-focus-completed select=\(selectContents)")
            return
        }
        // Both WKWebViews are background services and intentionally reject
        // first responder. Never focus their hidden textarea as a fallback.
        logInputMethodTiming("web-focus-skipped-no-native-editor", webFocus: false)
    }

    public func reloadWithCurrentPreferences() {
        reloadPreservingSource(for: .currentPage)
    }

    public func applyDefaultLanguagesPreservingSource() {
        currentSourceLanguage = TranslateLanguagePreferences.source
        currentTargetLanguage = TranslateLanguagePreferences.target
        reloadPreservingSource(for: .defaultLanguages)
    }

    private func applyCurrentLanguagesPreservingSource() {
        loadAutomaticTranslationService(target: currentTargetLanguage)
        reloadPreservingSource(
            for: .translationURL(
                translationURL(
                    source: currentSourceLanguage,
                    target: currentTargetLanguage
                )
            )
        )
    }

    private func loadAutomaticTranslationService(target: TranslateLanguage) {
        if automaticTranslationTarget == target,
           automaticTranslationWebViewReady || automaticTranslationWebViewLoading {
            return
        }
        automaticTranslationWebViewReady = false
        automaticTranslationWebViewLoading = true
        automaticTranslationTarget = target
        logStartupTiming("Automatic page load started")
        automaticTranslationWebView.load(
            URLRequest(
                url: translationURL(source: .automatic, target: target),
                cachePolicy: .useProtocolCachePolicy,
                timeoutInterval: 15
            )
        )
    }

    public func applyInterfaceLanguagePreservingSource() {
        // The visible translator is native. Reloading the hidden Google page
        // would read its empty textarea and recreate the workspace, erasing
        // the user's active source/result pair. Refresh native labels only.
        updateLongTextLabels()
        setTheme()
    }

    private func reloadPreservingSource(for destination: ReloadDestination) {
        reloadRequestGeneration += 1
        let generation = reloadRequestGeneration

        let startReload: (String) -> Void = { [weak self] source in
            guard let self else { return }
            DispatchQueue.main.async {
                guard generation == self.reloadRequestGeneration else { return }
                // The visible editor is app-owned. Prefer it over the
                // transparent Google textarea, which can still contain the
                // previous text after the user clears the editor.
                self.pendingSourceTextForReload = source
                self.pendingSourceRestoreAttempts = 0
                self.installUserScripts(on: self.webView.configuration.userContentController)
                // Never expose the Google document during a reload. The
                // native workspace remains visible while the new language
                // pair is applied in the background.
                self.webView.isHidden = false
                self.webView.alphaValue = self.backgroundTranslationWebViewAlpha
                self.isReady = false

                switch destination {
                case .currentPage:
                    self.webView.reload()
                case .defaultLanguages:
                    self.webView.load(URLRequest(url: self.defaultTranslationURL()))
                case .interfaceLanguage:
                    self.webView.load(
                        URLRequest(
                            url: self.interfaceLocalizedURL(from: self.webView.url)
                        )
                    )
                case .translationURL(let url):
                    self.webView.load(URLRequest(url: url))
                }
            }
        }

        if let sourceView = longTextSourceView {
            startReload(sourceView.string)
        } else {
            webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
                result, _ in
                startReload(result as? String ?? "")
            }
        }
    }

    public func copyAllSource() {
        if let longTextSource {
            copyToPasteboard(longTextSource)
            return
        }
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let text = result as? String else { return }
            self?.copyToPasteboard(text)
        }
    }

    public func copyAllTranslation() {
        if longTextSource != nil {
            copyToPasteboard(longTextTranslation)
            return
        }
        webView.evaluateJavaScript(#"""
            (() => {
                const visible = (element) => {
                    const style = getComputedStyle(element);
                    const rect = element.getBoundingClientRect();
                    return style.display !== "none" && style.visibility !== "hidden" &&
                        rect.width > 0 && rect.height > 0;
                };
                const primary = Array.from(document.querySelectorAll(".QcsUad .ryNqvb"));
                const nodes = primary.length ? primary : Array.from(document.querySelectorAll(
                    '.QcsUad [jsname="W297wb"], .QcsUad .HwtZe, .QcsUad .jCAhz'
                ));
                const candidates = nodes
                    .filter((element) => visible(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c"));
                return candidates
                    .filter((element) => !candidates.some((other) =>
                        other !== element && element.contains(other) &&
                        (other.innerText || other.textContent || "").trim() ===
                            (element.innerText || element.textContent || "").trim()
                    ))
                    .map((element) => (element.innerText || element.textContent || "").trim())
                    .filter(Boolean)
                    .join(" ");
            })();
        """#) { [weak self] result, _ in
            guard let text = result as? String else { return }
            self?.copyToPasteboard(text)
        }
    }

    private func beginLongTextTranslation(_ source: String) {
        // Do not write into the editor while an IME has marked (uncommitted)
        // text, otherwise Chinese/Japanese composition is committed or lost.
        guard longTextSourceView?.hasMarkedText() != true else { return }
        // The native editor is authoritative. Navigation and automatic-
        // detection callbacks are asynchronous and can arrive after a swap or
        // a later edit. Never let such a stale callback replace the complete
        // text that is currently visible in the source pane.
        if let visibleSource = longTextSourceView?.string,
           visibleSource != source {
            translationPipelineLogger.info(
                "Discarded stale translation request: visibleChars=\(visibleSource.count, privacy: .public), requestChars=\(source.count, privacy: .public)"
            )
            return
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }
        startTranslationTimingRequest(source: source, session: longTextSession)
        logTranslationTiming("swift-begin-translation")
        if !didLogFirstTranslationCommand {
            didLogFirstTranslationCommand = true
            logStartupTiming("First translation command received")
        }

        let effectiveSourceLanguage = effectiveSourceLanguage(for: source)
        let targetLanguage = currentTargetLanguage
        if effectiveSourceLanguage == .automatic {
            pendingPrimaryTranslationSource = nil
            pendingPrimaryTranslationSession = nil
            activeTranslationWebView = automaticTranslationWebView
            guard automaticTranslationWebViewReady,
                  translationPageMatches(
                      source: .automatic,
                      target: targetLanguage,
                      in: automaticTranslationWebView
                  ) else {
                pendingAutomaticTranslationSource = source
                pendingAutomaticTranslationSession = longTextSession
                loadAutomaticTranslationService(target: targetLanguage)
                return
            }
            pendingAutomaticTranslationSource = nil
            pendingAutomaticTranslationSession = nil
        } else {
            guard isReady else {
                pendingPrimaryTranslationSource = source
                pendingPrimaryTranslationSession = longTextSession
                return
            }
            pendingPrimaryTranslationSource = nil
            pendingPrimaryTranslationSession = nil
            pendingAutomaticTranslationSource = nil
            pendingAutomaticTranslationSession = nil
            activeTranslationWebView = webView
            if !translationPageMatches(
                source: effectiveSourceLanguage,
                target: targetLanguage
            ) {
                reloadPreservingSource(
                    for: .translationURL(
                        translationURL(
                            source: effectiveSourceLanguage,
                            target: targetLanguage
                        )
                    )
                )
                return
            }
        }

        // Google Translate evaluates the complete source text on every edit;
        // it does not translate a newly typed suffix and concatenate it to the
        // old result. Keep the old native result visible only until the first
        // stable result for this full source arrives.
        let keepsCompatibleVisibleResult = !longTextCompletedTranslation.isEmpty &&
            longTextCompletedTargetLanguage == targetLanguage.rawValue
        let formattingOnlyRefresh = keepsCompatibleVisibleResult &&
            longTextCompletedSourceLanguage == effectiveSourceLanguage.rawValue &&
            !longTextCompletedSource.isEmpty &&
            longTextCompletedSource != source &&
            textRemovingLineBreaks(longTextCompletedSource) == textRemovingLineBreaks(source)
        let chunks = splitLongText(source)
        // Each completed start owns one WebView channel.  A delayed DOM
        // callback from the other preloaded Google page must never complete
        // this request, even if its text happens to match the current chunk.
        longTextActiveWebViewGeneration += 1
        longTextSession += 1
        updateTranslationTimingSession(longTextSession)
        longTextSource = source
        longTextReplacesVisibleTranslation = keepsCompatibleVisibleResult
        longTextFormattingOnlyRefresh = formattingOnlyRefresh
        longTextTranslation = keepsCompatibleVisibleResult ? longTextCompletedTranslation : ""
        longTextChunks = chunks
        longTextChunkIndex = 0
        longTextPollAttempts = 0
        longTextLastWebTranslation = nil
        longTextCandidateTranslation = nil
        longTextCandidateUpdatedAt = nil
        longTextScheduledPoll?.cancel()
        longTextScheduledPoll = nil
        longTextPollInFlightSession = nil
        longTextSourceLanguage = effectiveSourceLanguage.rawValue
        longTextTargetLanguage = targetLanguage.rawValue
        longTextOverlay?.isHidden = false
        if longTextSourceView?.string != source {
            logInputMethodTiming("native-source-rewrite-before-translation")
            isUpdatingNativeWorkspace = true
            longTextSourceView?.string = source
            isUpdatingNativeWorkspace = false
        }
        longTextTranslationView?.string = longTextTranslation
        guard !chunks.isEmpty else {
            setLongTextStatus(.idle)
            updateLongTextLabels()
            return
        }
        updateLongTextLabels()
        translateNextLongTextChunk(session: longTextSession)
    }

    private func submitPendingPrimaryTranslationIfCurrent() {
        guard let source = pendingPrimaryTranslationSource,
              pendingPrimaryTranslationSession == longTextSession,
              longTextSource == source,
              longTextSourceView?.string == source else {
            pendingPrimaryTranslationSource = nil
            pendingPrimaryTranslationSession = nil
            return
        }
        pendingPrimaryTranslationSource = nil
        pendingPrimaryTranslationSession = nil
        beginLongTextTranslation(source)
    }

    private func activateCustomTranslationWorkspace() {
        // Keep the page mounted and transparent. This preserves Google's
        // proven WebView translation behavior without exposing its UI.
        webView.isHidden = false
        webView.alphaValue = backgroundTranslationWebViewAlpha
        // A language swap owns the pending source until the new page is fully
        // configured. Do not let page activation submit the swapped snapshot
        // in parallel with newer native input.
        if languageSwapInProgress {
            return
        }
        // Once the native workspace exists, its editor is the sole source of
        // truth. Google's hidden textarea can contain only the most recently
        // translated chunk after a long-text session. Reading it here after a
        // language swap would either restart with an incomplete source or be
        // rejected as stale, leaving the UI stuck at "Preparing".
        if let nativeSource = longTextSourceView?.string {
            beginLongTextTranslation(nativeSource)
            restoreSourceFocusAfterLanguageSwapIfNeeded()
            return
        }
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let self else { return }
            let source = self.pendingSourceTextForReload ?? (result as? String ?? "")
            self.beginLongTextTranslation(source)
            self.webView.isHidden = false
            self.webView.alphaValue = self.backgroundTranslationWebViewAlpha
            self.restoreSourceFocusAfterLanguageSwapIfNeeded()
        }
    }

    private func completeLanguageSwapIfReady() {
        guard languageSwapInProgress,
              isReady,
              translationPageMatches(
                  source: currentSourceLanguage,
                  target: currentTargetLanguage
              ) else { return }

        let latestSource = languageSwapPendingText ?? longTextSourceView?.string ?? ""
        languageSwapInProgress = false
        languageSwapPendingText = nil
        languageSwapSnapshotText = nil
        logTranslationCoordinator("language-swap-ready", source: latestSource)
        guard !latestSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        logTranslationCoordinator("language-swap-latest-text-submitted", source: latestSource)
        queueLongTextTranslation(latestSource, mode: .immediate)
    }

    private func restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: Int = 0) {
        guard restoreSourceFocusAfterLanguageSwap else { return }

        guard let sourceView = longTextSourceView,
              let window = sourceView.window else {
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: attempt + 1)
                }
            } else {
                restoreSourceFocusAfterLanguageSwap = false
            }
            return
        }

        // Reassigning an NSTextView that is already first responder interrupts
        // marked text owned by Chinese/Japanese input methods. An existing
        // responder needs no restoration at all.
        if window.firstResponder === sourceView {
            restoreSourceFocusAfterLanguageSwap = false
            return
        }

        // Never change responders while an IME composition is active.
        if sourceView.hasMarkedText() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: attempt)
            }
            return
        }

        if window.makeFirstResponder(sourceView) {
            restoreSourceFocusAfterLanguageSwap = false
            return
        }

        if attempt < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.restoreSourceFocusAfterLanguageSwapIfNeeded(attempt: attempt + 1)
            }
        } else {
            restoreSourceFocusAfterLanguageSwap = false
        }
    }

    private func cancelPendingTranslationDebounce(source: String? = nil) {
        guard longTextDebounceWorkItem != nil else { return }
        longTextDebounceWorkItem?.cancel()
        longTextDebounceWorkItem = nil
        logTranslationCoordinator("translation-debounce-cancelled", source: source)
    }

    private func invalidateActiveTranslationWork(source: String?) {
        let invalidatedRequestID = translationTimingRequest?.id
        let invalidatedSession = longTextSession
        let hadActiveRequest = translationTimingRequest != nil ||
            longTextScheduledPoll != nil || longTextFallbackTask != nil ||
            !longTextChunks.isEmpty

        longTextSession += 1
        longTextActiveWebViewGeneration += 1
        pendingAutomaticTranslationSource = nil
        pendingAutomaticTranslationSession = nil
        pendingPrimaryTranslationSource = nil
        pendingPrimaryTranslationSession = nil
        longTextPollInFlightSession = nil
        longTextWebDeadline = nil
        longTextCandidateTranslation = nil
        longTextCandidateUpdatedAt = nil
        longTextChunks = []
        longTextChunkIndex = 0

        if longTextScheduledPoll != nil {
            longTextScheduledPoll?.cancel()
            longTextScheduledPoll = nil
            logTranslationCoordinator(
                "stability-timer-cancelled",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidatedSession
            )
        }
        if longTextFallbackTask != nil {
            longTextFallbackTask?.cancel()
            longTextFallbackTask = nil
            logTranslationCoordinator(
                "fallback-cancelled-as-stale",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidatedSession
            )
        }

        for serviceWebView in [webView, automaticTranslationWebView] {
            serviceWebView?.evaluateJavaScript(#"""
                window.__macTranslateResultObserver?.disconnect();
                clearTimeout(window.__macTranslateResultNotificationTimer);
            """#, completionHandler: nil)
        }
        if hadActiveRequest {
            logTranslationCoordinator(
                "observer-disconnected",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidatedSession
            )
            logTranslationCoordinator(
                "request-invalidated-by-new-input",
                source: source,
                requestID: invalidatedRequestID,
                session: invalidatedSession
            )
        }
#if DEBUG
        translationTimingRequest = nil
#endif
    }

    private func queueLongTextTranslation(
        _ source: String,
        mode: TranslationSubmissionMode = .immediate
    ) {
        cancelPendingTranslationDebounce(source: source)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }

        translationInputGeneration += 1
        let inputGeneration = translationInputGeneration
        invalidateActiveTranslationWork(source: source)

        if languageSwapInProgress {
            languageSwapPendingText = source
            longTextSource = source
            updateLongTextLabels()
            logTranslationCoordinator("language-swap-pending-text-updated", source: source)
            if languageSwapSnapshotText != nil {
                languageSwapSnapshotText = nil
                logTranslationCoordinator("language-swap-snapshot-cancelled", source: source)
            }
            return
        }

        longTextSource = source
        updateLongTextLabels()
        let status = setLongTextStatus(.preparing)
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)

        let scheduledSourceLanguage = currentSourceLanguage
        let scheduledTargetLanguage = currentTargetLanguage
        let delay: TimeInterval
        switch mode {
        case .debouncedNativeInput:
            delay = nativeTextTranslationDebounce
        case .immediate:
            delay = source.utf16.count > googleWebChunkUTF16Limit
                ? longTextTranslationDebounce
                : 0
        }

        let submit = { [weak self] in
            guard let self else { return }
            self.longTextDebounceWorkItem = nil
            guard inputGeneration == self.translationInputGeneration,
                  !self.languageSwapInProgress,
                  scheduledSourceLanguage == self.currentSourceLanguage,
                  scheduledTargetLanguage == self.currentTargetLanguage,
                  self.longTextSourceView?.hasMarkedText() != true,
                  self.longTextSourceView?.string == source,
                  self.longTextSource == source else {
                return
            }
            if mode == .debouncedNativeInput {
                self.logTranslationCoordinator("translation-debounce-fired", source: source)
            }
            self.startTranslationTimingRequest(
                source: source,
                session: self.longTextSession + 1
            )
            self.logTranslationTiming("swift-input-processing-started")
            self.longTextSession += 1
            self.updateTranslationTimingSession(self.longTextSession)
            self.logTranslationTiming("native-input-processing-completed")
            self.beginLongTextTranslation(source)
        }

        if delay == 0 {
            submit()
            return
        }
        let workItem = DispatchWorkItem(block: submit)
        longTextDebounceWorkItem = workItem
        if mode == .debouncedNativeInput {
            logTranslationCoordinator("translation-debounce-scheduled", source: source)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func clearLongTextTranslationForEmptyInput() {
        cancelPendingTranslationDebounce(source: "")
        translationInputGeneration += 1
        invalidateActiveTranslationWork(source: "")
        longTextSource = nil
        longTextTranslation = ""
        longTextCompletedSource = ""
        longTextCompletedTranslation = ""
        longTextCompletedSourceLanguage = ""
        longTextCompletedTargetLanguage = ""
        longTextReplacesVisibleTranslation = false
        longTextFormattingOnlyRefresh = false
        longTextChunks = []
        longTextChunkIndex = 0
        longTextPollAttempts = 0
        longTextLastWebTranslation = nil
        longTextCandidateTranslation = nil
        longTextCandidateUpdatedAt = nil
        longTextScheduledPoll?.cancel()
        longTextScheduledPoll = nil
        longTextPollInFlightSession = nil
        longTextOverlay?.isHidden = false

        isUpdatingNativeWorkspace = true
        longTextSourceView?.string = ""
        longTextTranslationView?.string = ""
        isUpdatingNativeWorkspace = false

        // Keep the background Google document in the same empty state. This
        // prevents a later language swap or copy action from reviving stale
        // text that is no longer present in the visible editor.
        webView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateResultObserver?.disconnect();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)
        automaticTranslationWebView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateResultObserver?.disconnect();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)

        setLongTextStatus(.idle)
        updateLongTextLabels()
        // Keep the app-owned inline workspace in sync when this path is
        // reached from its editable source, without showing a network error.
        updateInlineLongText(source: "", translation: "", status: "")
    }

    // Google measures its 5,000-character limit with JavaScript's UTF-16
    // length. Use the same unit instead of Swift grapheme count so emoji and
    // supplementary-plane characters can never push a request over the web
    // limit. At 4,800 units, ordinary input remains on Google's continuous
    // one-page path until it is genuinely close to the service limit.
    private func textRemovingLineBreaks(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined()
    }

    private func splitLongText(_ text: String) -> [TranslationChunk] {
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
            // Preserve sentence context whenever possible. Falling back to a
            // whitespace boundary still guarantees we do not split a word.
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

    private func translateNextLongTextChunk(session: Int) {
        guard session == longTextSession else { return }
        guard longTextChunkIndex < longTextChunks.count else {
            longTextScheduledPoll?.cancel()
            longTextScheduledPoll = nil
            longTextPollInFlightSession = nil
            longTextWebDeadline = nil
            activeTranslationWebView?.evaluateJavaScript(
                "window.__macTranslateResultObserver?.disconnect();",
                completionHandler: nil
            )
            // The native result view is what the user actually sees. Capture
            // that exact, settled value as the only swappable snapshot rather
            // than trusting a potentially older in-memory assembly buffer.
            // This is important for multi-part results: a delayed old chunk
            // must never make a later language swap lose the final sections.
            let visibleCompletedTranslation = longTextTranslationView?.string
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let completedTranslation = visibleCompletedTranslation.isEmpty
                ? longTextTranslation
                : visibleCompletedTranslation
            if let source = longTextSource, !completedTranslation.isEmpty {
                longTextCompletedSource = source
                longTextCompletedTranslation = completedTranslation
                longTextCompletedSourceLanguage = longTextSourceLanguage
                longTextCompletedTargetLanguage = longTextTargetLanguage
                translationPipelineLogger.info(
                    "Completed translation snapshot: sourceChars=\(source.count, privacy: .public), translationChars=\(completedTranslation.count, privacy: .public), chunks=\(self.longTextChunks.count, privacy: .public)"
                )
            }
            let status = setLongTextStatus(.completed)
            longTextFormattingOnlyRefresh = false
            updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
            updateLongTextLabels()
            return
        }

        let chunk = longTextChunks[longTextChunkIndex].text
        if chunk.isEmpty {
            longTextTranslation.append(longTextChunks[longTextChunkIndex].separatorAfter)
            longTextTranslationView?.string = longTextTranslation
            longTextChunkIndex += 1
            translateNextLongTextChunk(session: session)
            return
        }
        longTextPollAttempts = 0
        longTextChunkRetryCount = 0
        longTextWebDeadline = Date().addingTimeInterval(6)
        longTextCandidateTranslation = nil
        longTextCandidateUpdatedAt = nil
        // A Return-only edit should behave like Google Translate Web: retain
        // the completed result and controls while the paragraph boundaries
        // are refreshed, instead of flashing a new translation cycle.
        let status = setLongTextStatus(
            longTextFormattingOnlyRefresh ? .completed : .translating
        )
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)

        // Keep the WebView hidden, but prefer the same Google Translate Web
        // result that the pre-1.0 versions displayed.  The Web and
        // translate_a/single endpoints do not always produce the same
        // translation for medical phrases such as "gravida 4 para 3".
        translateLongTextChunkUsingGoogleWeb(
            chunk,
            session: session
        )
    }

    private func translateLongTextChunkUsingGoogleWeb(
        _ chunk: String,
        session: Int
    ) {
        guard session == longTextSession else { return }
        guard let serviceWebView = activeTranslationWebView else {
            translateLongTextChunkUsingAPI(chunk, session: session)
            return
        }
        let encodingStartedAt = CACurrentMediaTime()
        let encoded = Data(chunk.utf8).base64EncodedString()
        logTranslationTiming(
            "text-encoding-completed",
            details: String(format: "duration_ms=%.3f", (CACurrentMediaTime() - encodingStartedAt) * 1_000)
        )
        let serviceGeneration = longTextActiveWebViewGeneration
        let timingRequestID = translationTimingRequest?.id ?? 0
        let evaluationStartedAt = CACurrentMediaTime()
        logTranslationTiming("evaluate-javascript-started")

        serviceWebView.evaluateJavaScript(#"""
            (() => {
                const jsStartedAt = performance.now();
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;
                window.__macTranslateActiveTiming = {
                    requestID: \#(timingRequestID),
                    session: \#(session),
                    jsStartedAt,
                    firstResultMutationAt: null
                };
                const value = new TextDecoder().decode(
                    Uint8Array.from(atob("\#(encoded)"), (character) =>
                        character.charCodeAt(0))
                );
                const inputAlreadyCurrent = textarea.value === value;
                window.__macTranslateReadCurrentResult = () => {
                    const visible = (element) => {
                        const style = getComputedStyle(element);
                        const rect = element.getBoundingClientRect();
                        return style.display !== "none" && style.visibility !== "hidden" &&
                            rect.width > 0 && rect.height > 0;
                    };
                    // Google reuses .ryNqvb for dictionary alternatives.
                    // Prefer the main translation wrappers first and only
                    // fall back to the generic word nodes when no wrapper is
                    // present. This prevents synonyms from being concatenated
                    // into an ordinary translation.
                    // Google renders dictionary alternatives in additional
                    // .QcsUad cards. Restrict extraction to the main result
                    // card so entries such as “不是” do not become
                    // “no blame”. Keep all text nodes inside that one card so
                    // multi-segment sentence and long-text results stay whole.
                    const resultRoot = document.querySelector(".QcsUad.sMVRZe") ||
                        document.querySelector(".QcsUad:not(.FkMbO)") ||
                        document.querySelector(".QcsUad");
                    const resultGroups = [
                        // W297wb/ryNqvb are Google's actual translated text
                        // nodes. HwtZe is an outer responsive container and
                        // can also contain a duplicate rendering layer plus
                        // dictionary details for longer input.
                        "[jsname=\"W297wb\"]",
                        ".ryNqvb",
                        ".jCAhz",
                        ".lRu31",
                        ".HwtZe"
                    ];
                    let nodes = [];
                    for (const selector of resultGroups) {
                        nodes = resultRoot
                            ? Array.from(resultRoot.querySelectorAll(selector)).filter(visible)
                            : [];
                        if (nodes.length) break;
                    }
                    const candidates = nodes.filter((element) =>
                        visible(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c")
                    );
                    const textGroups = [];
                    const groupIndexByHost = new Map();
                    for (const element of candidates) {
                        const text = (element.innerText || element.textContent || "").trim();
                        if (!text) continue;
                        // Ignore an outer accessibility/responsive wrapper
                        // when a descendant exposes the same translated text.
                        const duplicatesDescendant = candidates.some((other) =>
                            other !== element && element.contains(other) &&
                            (other.innerText || other.textContent || "").trim() === text
                        );
                        if (duplicatesDescendant) continue;
                        // Google places all translated sentence nodes for one
                        // source paragraph in the same HwtZe result block.
                        // Preserve that block boundary instead of flattening
                        // every node with a space (which erased a single
                        // Return), while still joining sentence fragments
                        // inside the same paragraph naturally.
                        const host = element.closest(".HwtZe") || element.parentElement;
                        let groupIndex = groupIndexByHost.get(host);
                        if (groupIndex === undefined) {
                            groupIndex = textGroups.length;
                            groupIndexByHost.set(host, groupIndex);
                            textGroups.push([]);
                        }
                        if (!textGroups[groupIndex].includes(text)) {
                            textGroups[groupIndex].push(text);
                        }
                    }
                    const texts = textGroups
                        .map((group, index) => {
                            const host = Array.from(groupIndexByHost.keys())
                                .find((candidate) => groupIndexByHost.get(candidate) === index);
                            // innerText on the concrete translation block is
                            // the only Google value that retains explicit
                            // source Returns. This is safe here because `host`
                            // comes from an already accepted W297wb/ryNqvb
                            // translation node, not from a global HwtZe scan.
                            const hostText = host?.matches?.(".HwtZe")
                                ? (host.innerText || "").trim()
                                : "";
                            return hostText || group.join(" ").trim();
                        })
                        .filter((text, index, all) => Boolean(text) && all.indexOf(text) === index);
                    const source = document.querySelector("textarea")?.value || "";
                    const trimmedSource = source.trim();
                    const latinWord = /^[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’\-][A-Za-zÀ-ÖØ-öø-ÿ]+)*$/
                        .test(trimmedSource);
                    const containsCJK = /[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]/
                        .test(trimmedSource);
                    // A single CJK character can safely use Google's primary
                    // dictionary meaning. Never extend this heuristic to two
                    // or more characters: short phrases such as “是这样吗”
                    // and “貌似还行” must retain their complete translation.
                    const singleCJKCharacter = containsCJK &&
                        Array.from(trimmedSource).length === 1;
                    const translation = (latinWord && !containsCJK) ||
                        singleCJKCharacter
                        ? (texts[0] || "").split(/\s+/).filter(Boolean)[0] || ""
                        : texts.join("\n");
                    if (window.__macTranslateWaitForDifferentResult &&
                        translation === window.__macTranslateBlockedTranslation) {
                        return [source, ""];
                    }
                    if (translation) {
                        window.__macTranslateWaitForDifferentResult = false;
                    }
                    return [source, translation];
                };
                // Snapshot the old result with the exact same parser used for
                // the eventual result.  The earlier implementation collected
                // every matching selector here but used only the first
                // preferred result group later. Those two strings could
                // differ, allowing the still-visible old translation through.
                if (!inputAlreadyCurrent) {
                    window.__macTranslateWaitForDifferentResult = false;
                    const previousPayload = window.__macTranslateReadCurrentResult();
                    window.__macTranslateBlockedTranslation = previousPayload?.[1] || "";
                    window.__macTranslateWaitForDifferentResult =
                        Boolean(window.__macTranslateBlockedTranslation);
                }
                window.__macTranslateResultObserver?.disconnect();
                clearTimeout(window.__macTranslateResultNotificationTimer);
                const notifyResultChanged = (records) => {
                    const touchesResult = records.some((record) => {
                        const target = record.target?.nodeType === Node.ELEMENT_NODE
                            ? record.target
                            : record.target?.parentElement;
                        if (target?.closest?.(".QcsUad")) return true;
                        return Array.from(record.addedNodes || []).some((node) => {
                            const element = node.nodeType === Node.ELEMENT_NODE
                                ? node
                                : node.parentElement;
                            return element?.matches?.(".QcsUad") ||
                                element?.closest?.(".QcsUad") ||
                                element?.querySelector?.(".QcsUad");
                        });
                    });
                    if (!touchesResult) return;
                    clearTimeout(window.__macTranslateResultNotificationTimer);
                    window.__macTranslateResultNotificationTimer = setTimeout(() => {
                        // Mutations inside Google's translation card are not
                        // proof that the result belongs to the new source: the
                        // input replacement itself also mutates this subtree.
                        // Keep blocking the baseline until the parsed result
                        // really changes. If the correct new translation is
                        // legitimately identical, the current request's API
                        // fallback will resolve it without exposing stale DOM.
                        const payload = window.__macTranslateReadCurrentResult?.();
                        if (!payload || !payload[1]) return;
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translationDOMResult",
                            session: \#(session),
                            chunkIndex: \#(longTextChunkIndex),
                            serviceGeneration: \#(serviceGeneration),
                            source: payload[0],
                            translation: payload[1],
                            jsElapsedMS: performance.now() - jsStartedAt,
                            firstMutationMS: window.__macTranslateActiveTiming?.firstResultMutationAt == null
                                ? -1
                                : window.__macTranslateActiveTiming.firstResultMutationAt - jsStartedAt
                        });
                    }, 45);
                };
                window.__macTranslateResultObserver = new MutationObserver(
                    notifyResultChanged
                );
                window.__macTranslateResultObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true,
                    characterData: true
                });
                const observerReadyAt = performance.now();
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype,
                    "value"
                ).set;

                if (!inputAlreadyCurrent) {
                    // Behave like direct typing in the original Google-DOM
                    // version. Replacing the value once is sufficient;
                    // clearing it first starts a second Google translation
                    // cycle and materially delays short translations.
                    setter.call(textarea, value);
                    const textareaWrittenAt = performance.now();
                    textarea.dispatchEvent(new Event("input", { bubbles: true }));
                    const inputDispatchedAt = performance.now();
                    window.webkit.messageHandlers.callbackHandler.postMessage({
                        action: "translationTimingJS",
                        requestID: \#(timingRequestID),
                        session: \#(session),
                        milestone: "injection-completed",
                        observerReadyMS: observerReadyAt - jsStartedAt,
                        textareaWrittenMS: textareaWrittenAt - jsStartedAt,
                        inputDispatchedMS: inputDispatchedAt - jsStartedAt
                    });
                } else {
                    // The result may have completed before this observer was
                    // installed. Deliver it immediately instead of waiting
                    // for another mutation or polling interval.
                    setTimeout(() => {
                        const payload = window.__macTranslateReadCurrentResult?.();
                        if (!payload || !payload[1]) return;
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "translationDOMResult",
                            session: \#(session),
                            chunkIndex: \#(longTextChunkIndex),
                            serviceGeneration: \#(serviceGeneration),
                            source: payload[0],
                            translation: payload[1],
                            jsElapsedMS: performance.now() - jsStartedAt,
                            firstMutationMS: window.__macTranslateActiveTiming?.firstResultMutationAt == null
                                ? -1
                                : window.__macTranslateActiveTiming.firstResultMutationAt - jsStartedAt
                        });
                    }, 0);
                }
                return [textarea.value, {
                    jsStartedMS: jsStartedAt,
                    completionMS: performance.now() - jsStartedAt
                }];
            })();
        """#) { [weak self] result, _ in
            guard let self,
                  session == self.longTextSession,
                  self.longTextActiveWebViewGeneration == serviceGeneration,
                  self.activeTranslationWebView === serviceWebView else { return }
            self.logTranslationTiming(
                "evaluate-javascript-completion",
                details: String(format: "swift_duration_ms=%.3f", (CACurrentMediaTime() - evaluationStartedAt) * 1_000)
            )
            let resultPayload = result as? [Any]
            let returnedSource = resultPayload?.first as? String
            if !self.didLogFirstTextInjection,
               let injectedSource = returnedSource,
               injectedSource == chunk {
                self.didLogFirstTextInjection = true
                self.logStartupTiming("First text injection completed")
            }
            guard let actualSource = returnedSource,
                  actualSource == chunk else {
                self.translateLongTextChunkUsingAPI(chunk, session: session)
                return
            }
            self.longTextPollAttempts = 0
            self.longTextCandidateTranslation = nil
            self.longTextCandidateUpdatedAt = nil
            self.pollLongTextTranslation(session: session)
        }
    }

    private func translateLongTextChunkUsingAPI(
        _ chunk: String,
        session: Int
    ) {
        guard isCurrentTranslationWork(session: session),
              let request = googleTranslationRequest(for: chunk) else {
            logTranslationCoordinator("fallback-cancelled-as-stale", source: longTextSource)
            return
        }
        logTranslationTiming("api-fallback-started")

        guard session == longTextSession else {
            finishLongTextTranslationWithError(session: session)
            return
        }

        translationPipelineLogger.info(
            "Google Web translation unavailable; using API fallback for chunk: \(chunk, privacy: .public)"
        )
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let translation = data.flatMap(Self.translationText(from:))
            let succeeded = error == nil &&
                (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true &&
                !(translation?.isEmpty ?? true)

            DispatchQueue.main.async {
                guard let self, self.isCurrentTranslationWork(session: session) else {
                    self?.logTranslationCoordinator(
                        "fallback-cancelled-as-stale",
                        source: self?.longTextSource
                    )
                    return
                }
                self.longTextFallbackTask = nil
                guard succeeded, let translation else {
                    if self.longTextChunkRetryCount == 0 {
                        self.longTextChunkRetryCount = 1
                        translationPipelineLogger.error(
                            "Translation chunk failed; performing the single permitted retry: chunkIndex=\(self.longTextChunkIndex, privacy: .public), error=\(String(describing: error), privacy: .public)"
                        )
                        self.translateLongTextChunkUsingAPI(chunk, session: session)
                        return
                    }
                    translationPipelineLogger.error(
                        "Translation chunk failed after retry: chunkIndex=\(self.longTextChunkIndex, privacy: .public), status=\((response as? HTTPURLResponse)?.statusCode ?? -1, privacy: .public), error=\(String(describing: error), privacy: .public)"
                    )
                    self.finishLongTextTranslationWithError(session: session)
                    return
                }
                self.appendLongTextTranslation(
                    translation,
                    session: session,
                    source: "direct API fallback"
                )
            }
        }
        longTextFallbackTask?.cancel()
        longTextFallbackTask = task
        task.resume()
    }

    private func isCurrentTranslationWork(session: Int) -> Bool {
        guard session == longTextSession,
              !languageSwapInProgress,
              longTextDebounceWorkItem == nil,
              languageSwapPendingText == nil,
              let source = longTextSource,
              longTextSourceView?.string == source,
              longTextTargetLanguage == currentTargetLanguage.rawValue else {
            return false
        }
        return longTextSourceLanguage == effectiveSourceLanguage(for: source).rawValue
    }

    private func appendLongTextTranslation(
        _ translation: String,
        session: Int,
        source: String
    ) {
        guard session == longTextSession,
              let currentSource = longTextSource,
              longTextSourceView?.string == currentSource else {
            translationPipelineLogger.info(
                "Discarded result whose source no longer matches the native editor"
            )
            return
        }
        let separator = longTextChunks[longTextChunkIndex].separatorAfter
        if longTextReplacesVisibleTranslation && longTextChunkIndex == 0 {
            longTextTranslation = translation + separator
            longTextReplacesVisibleTranslation = false
        } else {
            longTextTranslation.append(translation)
            longTextTranslation.append(separator)
        }
        longTextWebDeadline = nil
        longTextTranslationView?.string = longTextTranslation
#if DEBUG
        if translationTimingRequest?.didLogFinalDisplay == false {
            translationTimingRequest?.didLogFinalDisplay = true
            logTranslationTiming("final-result-displayed", details: "source=\(source)")
        }
#endif
        translationPipelineLogger.info(
            "Final displayed translation (\(source)): \(self.longTextTranslation, privacy: .public)"
        )
        updateInlineLongText(
            source: nil,
            translation: longTextTranslation,
            status: longTextStatusLabel?.stringValue ?? ""
        )
        longTextChunkIndex += 1
        updateLongTextLabels()
        translateNextLongTextChunk(session: session)
    }

    private func longTextLanguageCodes() -> (source: String, target: String) {
        (currentSourceLanguage.rawValue, currentTargetLanguage.rawValue)
    }

    private func translationPageMatches(
        source: TranslateLanguage,
        target: TranslateLanguage,
        in page: WKWebView? = nil
    ) -> Bool {
        guard let url = (page ?? webView).url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let pageSource = items.first(where: { $0.name == "sl" })?.value,
              let pageTarget = items.first(where: { $0.name == "tl" })?.value else {
            return false
        }
        return pageSource == source.rawValue && pageTarget == target.rawValue
    }

    private func effectiveSourceLanguage(for text: String) -> TranslateLanguage {
        guard currentSourceLanguage != .automatic else { return .automatic }
        return inputMatchesLanguage(text, currentSourceLanguage)
            ? currentSourceLanguage
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
        let hasKana = scalars.contains {
            (0x3040...0x30FF).contains($0.value)
        }
        let hasHangul = scalars.contains {
            (0xAC00...0xD7AF).contains($0.value)
        }
        let hasCyrillic = scalars.contains {
            (0x0400...0x052F).contains($0.value)
        }
        let hasArabic = scalars.contains {
            (0x0600...0x06FF).contains($0.value)
        }
        let hasHebrew = scalars.contains {
            (0x0590...0x05FF).contains($0.value)
        }
        let hasGreek = scalars.contains {
            (0x0370...0x03FF).contains($0.value)
        }
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
            // For languages whose script cannot be identified reliably from
            // a short fragment, preserve the user's selected source rather
            // than forcing auto-detection unnecessarily.
            return true
        }
    }

    private func googleTranslationRequest(for text: String) -> URLRequest? {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: longTextSourceLanguage),
            URLQueryItem(name: "tl", value: longTextTargetLanguage),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Translate/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func translationText(from data: Data) -> String? {
        let rawResponse = String(data: data, encoding: .utf8) ?? "<non-UTF8 response>"
        translationPipelineLogger.info(
            "Google raw response: \(rawResponse, privacy: .public)"
        )
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = response.first as? [[Any]] else {
            translationPipelineLogger.error("Google response JSON parsing failed")
            return nil
        }
        let translation = segments.compactMap { $0.first as? String }.joined()
        translationPipelineLogger.info(
            "Google parsed translation: \(translation, privacy: .public)"
        )
        return translation.isEmpty ? nil : translation
    }

    private func presentNativeLanguagePicker(
        side: NativeLanguagePickerSide,
        webPointX: CGFloat,
        webPointY: CGFloat
    ) {
        languagePickerPopover?.performClose(nil)
        let selectedLanguage = side == .source
            ? currentSourceLanguage
            : currentTargetLanguage
        let picker = NativeLanguagePickerController(
            side: side,
            selectedLanguage: selectedLanguage
        ) { [weak self] language in
            self?.selectNativeLanguage(language, for: side)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        languagePickerPopover = popover

        let anchor = NSRect(
            x: max(0, webPointX - 8),
            y: max(0, webView.isFlipped
                ? webPointY - 8
                : webView.bounds.height - webPointY - 8),
            width: 16,
            height: 16
        )
        popover.show(relativeTo: anchor, of: webView, preferredEdge: .maxY)
    }

    private func presentNativeLanguagePicker(
        side: NativeLanguagePickerSide,
        relativeTo button: NSButton
    ) {
        languagePickerPopover?.performClose(nil)
        let selectedLanguage = side == .source
            ? currentSourceLanguage
            : currentTargetLanguage
        let picker = NativeLanguagePickerController(
            side: side,
            selectedLanguage: selectedLanguage
        ) { [weak self] language in
            self?.selectNativeLanguage(language, for: side)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        languagePickerPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func selectNativeLanguage(
        _ language: TranslateLanguage,
        for side: NativeLanguagePickerSide
    ) {
        let oldSource = currentSourceLanguage
        let oldTarget = currentTargetLanguage
        var source = oldSource
        var target = oldTarget

        switch side {
        case .source:
            source = language
            if source != .automatic && source == target {
                target = oldSource.canBeTarget && oldSource != source
                    ? oldSource
                    : (source == .simplifiedChinese ? .english : .simplifiedChinese)
            }
        case .target:
            guard language.canBeTarget else { return }
            target = language
            if source != .automatic && source == target {
                source = oldTarget != target ? oldTarget : .automatic
            }
        }

        guard source != oldSource || target != oldTarget else { return }
        currentSourceLanguage = source
        currentTargetLanguage = target
        languagePickerPopover?.performClose(nil)

        if let longTextSource {
            updateLongTextLabels()
            queueLongTextTranslation(longTextSource)
        } else {
            applyCurrentLanguagesPreservingSource()
        }
    }

    private func swapCurrentTranslationLanguages() {
        guard longTextSourceView?.hasMarkedText() != true else {
            logInputMethodTiming("language-swap-skipped-marked-text")
            return
        }
        // Google cannot meaningfully swap an automatically detected source.
        // For all explicit pairs, exchange only the active session languages;
        // the persistent defaults in the menu remain untouched.
        guard currentSourceLanguage != .automatic else { return }

        // A multi-part translation is only safe to swap after every part has
        // completed. Prefer the current native result pane, which is the
        // complete text the user can see; the assembly cache is only a
        // fallback in case the view is temporarily unavailable.
        let completedTranslation: String?
        if longTextSource != nil {
            let visibleTranslation = longTextTranslationView?.string
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let translationToSwap = visibleTranslation.isEmpty
                ? longTextCompletedTranslation
                : visibleTranslation
            guard longTextStatusState == .completed,
                  !translationToSwap.isEmpty else {
                return
            }
            completedTranslation = translationToSwap
            translationPipelineLogger.info(
                "Swapping completed translation snapshot: sourceChars=\(self.longTextSource?.count ?? 0, privacy: .public), translationChars=\(translationToSwap.count, privacy: .public), cachedTranslationChars=\(self.longTextCompletedTranslation.count, privacy: .public)"
            )
        } else {
            completedTranslation = nil
        }

        logTranslationCoordinator(
            "language-swap-start",
            source: completedTranslation ?? longTextSourceView?.string
        )
        cancelPendingTranslationDebounce(source: longTextSourceView?.string)
        translationInputGeneration += 1
        languageSwapInProgress = true
        languageSwapPendingText = completedTranslation ?? longTextSourceView?.string
        languageSwapSnapshotText = completedTranslation
        invalidateActiveTranslationWork(source: languageSwapPendingText)

        let source = currentSourceLanguage
        currentSourceLanguage = currentTargetLanguage
        currentTargetLanguage = source

        // With two empty panes there is no text snapshot to preserve. Treat
        // the language pair as native editor state only. In particular, do
        // not navigate either hidden Google page and do not touch the first
        // responder here: an asynchronous WebKit navigation can finish while
        // a Chinese/Japanese input method owns marked text and truncate that
        // composition. The first committed source edit will prepare the
        // matching background translation page without disturbing AppKit's
        // editor lifecycle.
        let panesAreEmpty = longTextSourceView?.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false &&
            longTextTranslationView?.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        if panesAreEmpty {
            languageSwapInProgress = false
            languageSwapPendingText = nil
            languageSwapSnapshotText = nil
            refreshWorkspaceLanguageTitles()
            logTranslationCoordinator("language-swap-ready", source: "")
            return
        }

        if let swappedSource = completedTranslation {
            // Cancel every old result callback before loading the reversed
            // language pair. The hidden Google textarea contains only its
            // latest chunk, so it must never be used as the swap source.
            longTextSource = swappedSource
            longTextTranslation = ""
            longTextCompletedSource = ""
            longTextCompletedTranslation = ""
            longTextCompletedSourceLanguage = ""
            longTextCompletedTargetLanguage = ""
            longTextReplacesVisibleTranslation = false
            longTextFormattingOnlyRefresh = false
            longTextChunks = []
            longTextChunkIndex = 0
            longTextCandidateTranslation = nil
            longTextCandidateUpdatedAt = nil
            isUpdatingNativeWorkspace = true
            longTextSourceView?.string = swappedSource
            longTextTranslationView?.string = ""
            isUpdatingNativeWorkspace = false
            longTextSourceView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
            longTextTranslationView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
            let status = setLongTextStatus(.preparing)
            updateInlineLongText(source: swappedSource, translation: "", status: status)
            updateLongTextLabels()
            // Reload the hidden Google page so it uses the new language pair.
            restoreSourceFocusAfterLanguageSwap = true
            applyCurrentLanguagesPreservingSource()
            // NSTextView can preserve its previous clip-view offset when its
            // content is replaced. Scroll again on the next layout pass so
            // the user always sees the beginning of the complete swapped text.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.longTextSource == swappedSource else { return }
                self.longTextSourceView?.scrollRangeToVisible(
                    NSRange(location: 0, length: 0)
                )
            }
        } else {
            restoreSourceFocusAfterLanguageSwap = true
            applyCurrentLanguagesPreservingSource()
        }
    }

    private func activateInlineLongText(source: String) {
        let encodedSource = Data(source.utf8).base64EncodedString()
        let sourceClearLabel = interfaceText("清除", "Clear")
        let sourceLanguageTitle = currentSourceLanguage.title
        let targetLanguageTitle = currentTargetLanguage.title
        let swapLanguagesLabel = interfaceText("交换语言", "Swap languages")
        webView.evaluateJavaScript(#"""
            (() => {
                const decode = (encoded) => new TextDecoder().decode(
                    Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0))
                );
                const source = decode("\#(encodedSource)");
                const id = "mac-translate-inline-long-text";
                const styleId = "mac-translate-inline-long-text-style";
                let state = window.__macTranslateInlineLongText;

                if (!state) {
                    const textarea = document.querySelector("textarea.er8xn, textarea");
                    const sourceHost = textarea?.closest(".QFw9Te") || textarea?.parentElement;
                    // Google's result host class changes across compact and
                    // wide layouts. The app-owned workspace no longer needs
                    // that host; only an editable source is required.
                    const resultHost = document.querySelector(".QcsUad");
                    if (!textarea) return false;

                    let style = document.getElementById(styleId);
                    if (!style) {
                        style = document.createElement("style");
                        style.id = styleId;
                        style.textContent = `
                            #${id} {
                                position: fixed; inset: 0; z-index: 10000; display: grid;
                                grid-template-rows: 58px minmax(0, 1fr);
                                overflow: hidden; pointer-events: auto;
                                background: rgba(246,246,246,.88) !important;
                                backdrop-filter: blur(22px);
                            }
                            #${id} .mac-inline-header {
                                display: grid; grid-template-columns: minmax(0,1fr) 54px minmax(0,1fr);
                                align-items: center; padding: 0 14px; border-bottom: 1px solid rgba(0,0,0,.08);
                            }
                            #${id} .mac-inline-language, #${id} .mac-inline-swap {
                                appearance: none; border: 0; background: transparent !important;
                                color: inherit; cursor: pointer; font: 600 17px/24px -apple-system, BlinkMacSystemFont, sans-serif;
                                padding: 7px 10px; border-radius: 8px;
                            }
                            #${id} .mac-inline-language:first-child { justify-self: start; }
                            #${id} .mac-inline-language:last-child { justify-self: end; }
                            #${id} .mac-inline-swap { font-size: 25px; justify-self: center; }
                            #${id} .mac-inline-panes { display: flex; min-height: 0; gap: 1px; }
                            #${id} .mac-inline-pane {
                                display: flex; flex: 1 1 0; height: 100%;
                                min-width: 0; min-height: 0;
                                flex-direction: column; pointer-events: auto;
                                background: transparent !important;
                            }
                            #${id} .mac-inline-editor, #${id} .mac-inline-result {
                                flex: 1; min-height: 0; overflow: auto; padding: 16px 18px;
                                font: 18px/28px -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif;
                                color: var(--translate-text-color, #000); white-space: pre-wrap;
                                overflow-wrap: anywhere; outline: none;
                            }
                            #${id} .mac-inline-editor { cursor: text; }
                            #${id} .mac-inline-footer {
                                display: flex; flex: 0 0 34px; align-items: center;
                                margin-top: auto; gap: 8px; padding: 0 10px 2px;
                                color: rgba(60,64,67,.75);
                                font: 12px/16px -apple-system, BlinkMacSystemFont,
                                    "Helvetica Neue", Arial, sans-serif;
                                font-variant-numeric: tabular-nums;
                            }
                            #${id} .mac-inline-count { margin-left: auto; text-align: right; }
                            #${id} .mac-inline-copy, #${id} .mac-inline-clear {
                                appearance: none; border: 0; border-radius: 7px; padding: 4px 7px;
                                color: inherit; background: transparent !important; cursor: pointer;
                                font: inherit;
                            }
                            @media (prefers-color-scheme: dark) {
                                #${id} { background: rgba(30,30,30,.88) !important; }
                                #${id} .mac-inline-header { border-color: rgba(255,255,255,.12); }
                                #${id} .mac-inline-footer { color: rgba(255,255,255,.68); }
                            }
                        `;
                        (document.head || document.documentElement).appendChild(style);
                    }

                    const root = document.createElement("div");
                    root.id = id;
                    const header = document.createElement("div");
                    header.className = "mac-inline-header";
                    const sourceLanguage = document.createElement("button");
                    sourceLanguage.className = "mac-inline-language";
                    sourceLanguage.type = "button";
                    sourceLanguage.textContent = "\#(sourceLanguageTitle)";
                    const swap = document.createElement("button");
                    swap.className = "mac-inline-swap";
                    swap.type = "button";
                    swap.textContent = "⇄";
                    swap.setAttribute("aria-label", "\#(swapLanguagesLabel)");
                    const targetLanguage = document.createElement("button");
                    targetLanguage.className = "mac-inline-language";
                    targetLanguage.type = "button";
                    targetLanguage.textContent = "\#(targetLanguageTitle)";
                    const showPicker = (side, button) => {
                        const rect = button.getBoundingClientRect();
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "showLanguagePicker", side,
                            x: rect.left + rect.width / 2, y: rect.bottom
                        });
                    };
                    sourceLanguage.addEventListener("click", () => showPicker("source", sourceLanguage));
                    targetLanguage.addEventListener("click", () => showPicker("target", targetLanguage));
                    swap.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({ action: "swapLanguages" });
                    });
                    header.append(sourceLanguage, swap, targetLanguage);
                    const makePane = (editable) => {
                        const pane = document.createElement("section");
                        pane.className = "mac-inline-pane";
                        const text = document.createElement("div");
                        text.className = editable ? "mac-inline-editor" : "mac-inline-result";
                        text.contentEditable = editable ? "true" : "false";
                        text.tabIndex = 0;
                        text.spellcheck = editable;
                        const footer = document.createElement("div");
                        footer.className = "mac-inline-footer";
                        const status = document.createElement("span");
                        const copy = document.createElement("button");
                        copy.className = "mac-inline-copy";
                        copy.type = "button";
                        copy.textContent = "复制";
                        const clear = document.createElement("button");
                        clear.className = "mac-inline-clear";
                        clear.type = "button";
                        clear.innerHTML = `<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"
                            fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                            <path d="M3 6h18"></path><path d="M8 6V4h8v2"></path><path d="M6 6l1 14h10l1-14"></path>
                            <path d="M10 10v6"></path><path d="M14 10v6"></path></svg>`;
                        clear.setAttribute("aria-label", "\#(sourceClearLabel)");
                        clear.setAttribute("title", "\#(sourceClearLabel)");
                        const count = document.createElement("span");
                        count.className = "mac-inline-count";
                        if (editable) {
                            footer.append(status, clear, copy, count);
                        } else {
                            footer.append(status, copy, count);
                        }
                        pane.append(text, footer);
                        return { pane, text, status, copy, clear, count };
                    };
                    const left = makePane(true);
                    const right = makePane(false);
                    left.status.textContent = "原文";
                    right.status.textContent = "译文";
                    left.copy.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "copySource", text: left.text.innerText
                        });
                    });
                    left.clear.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "clearSource"
                        });
                    });
                    right.copy.addEventListener("click", () => {
                        window.webkit.messageHandlers.callbackHandler.postMessage({
                            action: "copyTranslation", text: right.text.innerText
                        });
                    });
                    let typingTimer;
                    left.text.addEventListener("input", () => {
                        const text = left.text.innerText.replace(/\n$/, "");
                        clearTimeout(typingTimer);
                        typingTimer = setTimeout(() => {
                            window.webkit.messageHandlers.callbackHandler.postMessage({
                                action: "updateLongText", text
                            });
                        }, 160);
                    });
                    const panes = document.createElement("div");
                    panes.className = "mac-inline-panes";
                    panes.append(left.pane, right.pane);
                    root.append(header, panes);
                    document.body.appendChild(root);
                    sourceHost?.style.setProperty("visibility", "hidden", "important");
                    resultHost?.style.setProperty("visibility", "hidden", "important");

                    const isHan = (character) => /[\u3400-\u9fff\uf900-\ufaff]/.test(character);
                    const describe = (text) => {
                        const han = (text.match(/[\u3400-\u9fff\uf900-\ufaff]/g) || []).length;
                        const nonHan = text.replace(/[\u3400-\u9fff\uf900-\ufaff]/g, " ");
                        const words = (nonHan.match(/[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*/gu) || []).length;
                        const values = [];
                        if (words) values.push(`单词 ${words}`);
                        if (han) values.push(`汉字 ${han}`);
                        return values.join(" · ") || "单词 0";
                    };
                    state = window.__macTranslateInlineLongText = {
                        root, left, right, sourceLanguage, targetLanguage, describe,
                        close: () => {
                            root.remove();
                            sourceHost?.style.removeProperty("visibility");
                            resultHost?.style.removeProperty("visibility");
                            window.__macTranslateInlineLongText = null;
                        }
                    };
                }

                state.sourceLanguage.textContent = "\#(sourceLanguageTitle)";
                state.targetLanguage.textContent = "\#(targetLanguageTitle)";
                state.left.text.innerText = source;
                state.left.count.textContent = state.describe(source);
                state.right.text.innerText = "";
                state.right.count.textContent = "单词 0";
                state.right.status.textContent = "正在准备翻译…";
                return true;
            })();
        """#) { _, _ in }
    }

    private func updateInlineLongText(source: String?, translation: String, status: String) {
        translationPipelineLogger.info(
            "Final displayed translation (inline workspace): \(translation, privacy: .public)"
        )
        let encodedSource = source.map { Data($0.utf8).base64EncodedString() } ?? ""
        let encodedTranslation = Data(translation.utf8).base64EncodedString()
        let encodedStatus = Data(status.utf8).base64EncodedString()
        let hasSource = source == nil ? "false" : "true"
        webView.evaluateJavaScript(#"""
            (() => {
                const state = window.__macTranslateInlineLongText;
                if (!state) return;
                const decode = (encoded) => new TextDecoder().decode(
                    Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0))
                );
                if (\#(hasSource)) {
                    state.left.text.innerText = decode("\#(encodedSource)");
                    state.left.count.textContent = state.describe(state.left.text.innerText);
                }
                state.right.text.innerText = decode("\#(encodedTranslation)");
                state.right.count.textContent = state.describe(state.right.text.innerText);
                state.right.status.textContent = decode("\#(encodedStatus)");
            })();
        """#, completionHandler: nil)
    }

    private func returnToNormalTranslation(_ source: String) {
        longTextDebounceWorkItem?.cancel()
        longTextSession += 1
        longTextSource = nil
        longTextTranslation = ""
        longTextChunks = []
        longTextChunkIndex = 0
        let encoded = Data(source.utf8).base64EncodedString()
        webView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateInlineLongText?.close();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const value = new TextDecoder().decode(Uint8Array.from(
                    atob("\#(encoded)"), (character) => character.charCodeAt(0)
                ));
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype, "value"
                ).set;
                setter.call(textarea, value);
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)
    }

    private func pollLongTextTranslation(session: Int) {
        guard session == longTextSession else { return }
        guard longTextChunks.indices.contains(longTextChunkIndex) else { return }
        guard longTextPollInFlightSession == nil else { return }
        let pollingChunkIndex = longTextChunkIndex
        longTextScheduledPoll?.cancel()
        longTextScheduledPoll = nil
        longTextPollAttempts += 1
        guard longTextWebDeadline.map({ Date() <= $0 }) ?? false else {
            let chunk = longTextChunks[longTextChunkIndex].text
            translateLongTextChunkUsingAPI(chunk, session: session)
            return
        }

        longTextPollInFlightSession = session
        guard let serviceWebView = activeTranslationWebView else {
            longTextPollInFlightSession = nil
            translateLongTextChunkUsingAPI(
                longTextChunks[longTextChunkIndex].text,
                session: session
            )
            return
        }
        let serviceGeneration = longTextActiveWebViewGeneration
        let extractionStartedAt = CACurrentMediaTime()
#if DEBUG
        if translationTimingRequest?.didLogExtractionStart == false {
            translationTimingRequest?.didLogExtractionStart = true
            logTranslationTiming("swift-result-extraction-started")
        }
#endif
        serviceWebView.evaluateJavaScript(#"""
            (() => {
                const selectors = [
                    ".QcsUad .ryNqvb",
                    ".QcsUad .HwtZe",
                    ".QcsUad .jCAhz",
                    ".QcsUad .lRu31",
                    ".QcsUad [jsname=\"W297wb\"]"
                ].join(",");
                const visible = (element) => {
                    const style = getComputedStyle(element);
                    const rect = element.getBoundingClientRect();
                    return style.display !== "none" && style.visibility !== "hidden" &&
                        rect.width > 0 && rect.height > 0;
                };
                const resultRoot = document.querySelector(".QcsUad.sMVRZe") ||
                    document.querySelector(".QcsUad:not(.FkMbO)") ||
                    document.querySelector(".QcsUad");
                const resultGroups = [
                    "[jsname=\"W297wb\"]",
                    ".ryNqvb",
                    ".jCAhz",
                    ".lRu31",
                    ".HwtZe"
                ];
                let nodes = [];
                for (const selector of resultGroups) {
                    nodes = resultRoot
                        ? Array.from(resultRoot.querySelectorAll(selector)).filter(visible)
                        : [];
                    if (nodes.length) break;
                }
                const candidates = nodes
                    .filter((element) => visible(element) &&
                        !element.closest(".UdTY9, .zWhQbb, .mDTU0c"));
                const candidateTextGroups = [];
                const groupIndexByHost = new Map();
                for (const element of candidates) {
                    const text = (element.innerText || element.textContent || "").trim();
                    if (!text) continue;
                    const duplicatesDescendant = candidates.some((other) =>
                        other !== element && element.contains(other) &&
                        (other.innerText || other.textContent || "").trim() === text
                    );
                    if (duplicatesDescendant) continue;
                    const host = element.closest(".HwtZe") || element.parentElement;
                    let groupIndex = groupIndexByHost.get(host);
                    if (groupIndex === undefined) {
                        groupIndex = candidateTextGroups.length;
                        groupIndexByHost.set(host, groupIndex);
                        candidateTextGroups.push([]);
                    }
                    if (!candidateTextGroups[groupIndex].includes(text)) {
                        candidateTextGroups[groupIndex].push(text);
                    }
                }
                const candidateTexts = candidateTextGroups
                    .map((group, index) => {
                        const host = Array.from(groupIndexByHost.keys())
                            .find((candidate) => groupIndexByHost.get(candidate) === index);
                        const hostText = host?.matches?.(".HwtZe")
                            ? (host.innerText || "").trim()
                            : "";
                        return hostText || group.join(" ").trim();
                    })
                    .filter((text, index, all) => Boolean(text) && all.indexOf(text) === index);
                const source = document.querySelector("textarea")?.value || "";
                const trimmedSource = source.trim();
                // Keep this deliberately compatible with older WebKit
                // JavaScript engines. A CJK range check is used instead of
                // Unicode property escapes because the latter are not
                // available in every macOS runtime supported by the app.
                const looksLikeLatinStyleWord = /^[A-Za-zÀ-ÖØ-öø-ÿ]+(?:['’\-][A-Za-zÀ-ÖØ-öø-ÿ]+)*$/
                    .test(trimmedSource);
                // Chinese, Japanese, and Korean text normally has no spaces,
                // so a full sentence must never be reduced to one token.
                const containsCJKScript = /[\u3400-\u4DBF\u4E00-\u9FFF\u3040-\u30FF\uAC00-\uD7AF]/
                    .test(trimmedSource);
                // Only one CJK character is unambiguously atomic here. Two or
                // more characters may already form a complete short phrase.
                const isSingleCJKCharacter = containsCJKScript &&
                    Array.from(trimmedSource).length === 1;
                const isSingleWord =
                    (looksLikeLatinStyleWord && !containsCJKScript) ||
                    isSingleCJKCharacter;
                const translation = isSingleWord
                    ? (candidateTexts[0] || "").split(/\s+/).filter(Boolean)[0] || ""
                    : candidateTexts.join("\n");
                if (window.__macTranslateWaitForDifferentResult &&
                    translation === window.__macTranslateBlockedTranslation) {
                    return [source, ""];
                }
                if (translation) {
                    window.__macTranslateWaitForDifferentResult = false;
                }
                return [source, translation];
            })();
        """#) { [weak self] result, _ in
            guard let self else { return }
            if self.longTextPollInFlightSession == session {
                self.longTextPollInFlightSession = nil
            }
            guard session == self.longTextSession,
                  self.longTextActiveWebViewGeneration == serviceGeneration,
                  self.activeTranslationWebView === serviceWebView else { return }
            guard pollingChunkIndex == self.longTextChunkIndex else { return }
            guard self.longTextChunks.indices.contains(self.longTextChunkIndex) else {
                return
            }
            let payload = result as? [Any]
            let observedSource = (payload?.first as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedSource = self.longTextChunks[self.longTextChunkIndex].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = (payload?.dropFirst().first as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Do not accept a result until Google's textarea contains the
            // exact chunk currently being translated. This prevents a
            // previous chunk's DOM result from being appended to the next.
            guard observedSource == expectedSource else {
                self.scheduleLongTextPoll(session: session)
                return
            }
            let isLoading = translation.isEmpty ||
                translation.range(
                    of: "正在翻译|translating|loading",
                    options: .regularExpression.union(.caseInsensitive)
                ) != nil

            if isLoading {
                self.scheduleLongTextPoll(session: session)
                return
            }

#if DEBUG
            if self.translationTimingRequest?.didLogFirstValidExtraction == false {
                self.translationTimingRequest?.didLogFirstValidExtraction = true
                self.logTranslationTiming(
                    "swift-valid-result-extracted",
                    details: String(format: "extraction_ms=%.3f", (CACurrentMediaTime() - extractionStartedAt) * 1_000)
                )
            }
#endif

            // A cleared Google input can retain the preceding translation for
            // a moment. Do not append that stale result.  Google also writes
            // sentence translations in stages (for example, it can expose
            // "Test it again." before later appending a second clause), so
            // wait until the candidate has been unchanged for a real quiet
            // interval rather than accepting two adjacent short polls.
            if translation == self.longTextLastWebTranslation && self.longTextPollAttempts < 10 {
                self.scheduleLongTextPoll(session: session)
                return
            }
            self.recordLongTextCandidate(translation)
            self.previewSingleChunkTranslationIfSafe(
                translation,
                session: session,
                chunkIndex: pollingChunkIndex
            )
            guard let candidateUpdatedAt = self.longTextCandidateUpdatedAt else {
                self.scheduleLongTextPoll(session: session)
                return
            }
            let settlingInterval = self.resultSettlingInterval()
            let remainingQuietTime = settlingInterval -
                Date().timeIntervalSince(candidateUpdatedAt)
            guard remainingQuietTime <= 0 else {
                self.scheduleLongTextPoll(
                    session: session,
                    delay: max(0.05, remainingQuietTime)
                )
                return
            }

            self.longTextLastWebTranslation = translation
#if DEBUG
            if self.translationTimingRequest?.didLogStableResult == false {
                self.translationTimingRequest?.didLogStableResult = true
                self.logTranslationTiming(
                    "result-declared-stable",
                    details: String(format: "quiet_ms=%.0f", settlingInterval * 1_000)
                )
            }
#endif
            self.appendLongTextTranslation(
                translation,
                session: session,
                source: "Google Web"
            )
        }
    }

    private func recordLongTextCandidate(_ translation: String) {
        guard translation != longTextCandidateTranslation else {
            // Repeated observer notifications for the same DOM content do
            // not restart the quiet timer. Only actual result changes do.
            return
        }
        longTextCandidateTranslation = translation
        longTextCandidateUpdatedAt = Date()
    }

    /// Match Google Translate's perceived speed without weakening completion
    /// validation. Google paints an updated DOM result immediately and may
    /// refine it over the next few mutations. For a one-chunk request we can
    /// mirror that verified candidate in the native result pane at once while
    /// keeping the 750 ms quiet-period check before committing the swappable
    /// translation snapshot. Multi-chunk requests deliberately skip previews
    /// because a partial chunk cannot safely replace the assembled document.
    private func previewSingleChunkTranslationIfSafe(
        _ translation: String,
        session: Int,
        chunkIndex: Int
    ) {
        guard session == longTextSession,
              chunkIndex == 0,
              longTextChunks.count == 1,
              longTextChunks.indices.contains(chunkIndex),
              let currentSource = longTextSource,
              longTextSourceView?.string == currentSource,
              !translation.isEmpty else { return }

        longTextTranslationView?.string = translation
#if DEBUG
        if translationTimingRequest?.didLogFirstDisplay == false {
            translationTimingRequest?.didLogFirstDisplay = true
            logTranslationTiming("first-valid-result-displayed")
        }
#endif
        updateInlineLongText(
            source: nil,
            translation: translation,
            status: longTextStatusLabel?.stringValue ?? ""
        )
        workspaceTranslationCountLabel?.stringValue =
            textCountDescription(translation)
        longTextTranslationLabel?.stringValue =
            textCountDescription(translation)
    }

    private func scheduleLongTextPoll(
        session: Int,
        delay: TimeInterval? = nil
    ) {
        guard session == longTextSession else { return }
        longTextScheduledPoll?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollLongTextTranslation(session: session)
        }
        longTextScheduledPoll = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (delay ?? longTextPollInterval),
            execute: workItem
        )
    }

    private func finishLongTextTranslationWithError(session: Int) {
        guard session == longTextSession else { return }
        if longTextFormattingOnlyRefresh && !longTextCompletedTranslation.isEmpty {
            longTextFormattingOnlyRefresh = false
            longTextTranslation = longTextCompletedTranslation
            let status = setLongTextStatus(.completed)
            updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
            updateLongTextLabels()
            return
        }
        let status = setLongTextStatus(.failed)
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
        updateLongTextLabels()
    }

    @objc private func closeLongTextMode() {
        stopSpeaking()
        longTextDebounceWorkItem?.cancel()
        longTextSession += 1
        longTextOverlay?.isHidden = true
        longTextSource = nil
        longTextTranslation = ""
        longTextCompletedSource = ""
        longTextCompletedTranslation = ""
        longTextCompletedSourceLanguage = ""
        longTextCompletedTargetLanguage = ""
        longTextReplacesVisibleTranslation = false
        longTextFormattingOnlyRefresh = false
        longTextChunks = []
        longTextChunkIndex = 0
        setLongTextStatus(.idle)
        webView.evaluateJavaScript(#"""
            (() => {
                window.__macTranslateInlineLongText?.close();
                const textarea = document.querySelector("textarea");
                if (!textarea) return;
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype, "value"
                ).set;
                setter.call(textarea, "");
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
            })();
        """#, completionHandler: nil)
        focusAndSelectField()
    }

    private func updateLongTextLabels() {
        guard let source = longTextSource else {
            longTextStatusLabel?.stringValue = ""
            let emptyCount = textCountDescription("")
            workspaceSourceCountLabel?.stringValue = emptyCount
            workspaceTranslationCountLabel?.stringValue = emptyCount
            longTextSourceLabel?.stringValue = emptyCount
            longTextTranslationLabel?.stringValue = emptyCount
            updatePronunciationLabels(source: "", translation: "")
            refreshWorkspaceLanguageTitles()
            return
        }
        refreshWorkspaceLanguageTitles()
        longTextStatusLabel?.stringValue = longTextStatusText()
        let sourceCount = textCountDescription(source)
        let translationCount = textCountDescription(longTextTranslation)
        workspaceSourceCountLabel?.stringValue = sourceCount
        workspaceTranslationCountLabel?.stringValue = translationCount
        longTextSourceLabel?.stringValue = sourceCount
        longTextTranslationLabel?.stringValue = translationCount
        updatePronunciationLabels(source: source, translation: longTextTranslation)
    }

    private func updatePronunciationLabels(source: String, translation: String) {
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

    private func updatePronunciationLabel(
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

    private func refreshPronunciationDisplayLabels() {
        refreshPronunciationDisplayLabel(for: .source)
        refreshPronunciationDisplayLabel(for: .translation)
    }

    private func refreshPronunciationDisplayLabel(for pane: PronunciationPane) {
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

    private func singleWordForPronunciation(_ text: String) -> String? {
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

    @discardableResult
    private func setLongTextStatus(_ state: LongTextStatusState) -> String {
        longTextStatusState = state
        // Never offer a long-text swap while its Google result is still
        // being assembled. The completed snapshot is the only valid source
        // for a reverse translation.
        workspaceSwapButton?.isEnabled = currentSourceLanguage != .automatic &&
            (longTextSource == nil ||
                (state == .completed && !longTextCompletedTranslation.isEmpty))
        let text = longTextStatusText()
        longTextStatusLabel?.stringValue = text
        return text
    }

    private func longTextStatusText() -> String {
        switch longTextStatusState {
        case .idle:
            return ""
        case .preparing:
            return interfaceText("正在准备翻译…", "Preparing translation…")
        case .translating:
            guard longTextChunks.count > 1 else {
                return interfaceText("正在翻译…", "Translating…")
            }
            return interfaceText(
                "正在翻译第 \(longTextChunkIndex + 1) / \(longTextChunks.count) 段…",
                "Translating part \(longTextChunkIndex + 1) of \(longTextChunks.count)…"
            )
        case .completed:
            return longTextChunks.count > 1
                ? interfaceText("长文本翻译完成", "Long-text translation complete")
                : interfaceText("翻译完成", "Translation complete")
        case .failed:
            return interfaceText(
                "部分内容未能完成翻译；请重试。",
                "Some content could not be translated. Please try again."
            )
        }
    }

    private func refreshWorkspaceLanguageTitles() {
        setWorkspaceLanguageTitle(workspaceSourceLanguageButton, language: currentSourceLanguage)
        setWorkspaceLanguageTitle(workspaceTargetLanguageButton, language: currentTargetLanguage)
        let color = isDarkMode ? NSColor.white : NSColor.labelColor
        workspaceSwapButton?.attributedTitle = NSAttributedString(
            string: "⇄",
            attributes: [
                .font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: color
            ]
        )
    }

    private func setWorkspaceLanguageTitle(_ button: NSButton?, language: TranslateLanguage) {
        button?.attributedTitle = NSAttributedString(
            string: language.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: isDarkMode ? NSColor.white : NSColor.labelColor
            ]
        )
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingNativeWorkspace,
              let sourceView = longTextSourceView,
              let changedView = notification.object as? NSTextView,
              changedView === sourceView else {
            return
        }
        if sourceView.hasMarkedText() {
            logInputMethodTiming("text-did-change-marked-text")
            cancelPendingTranslationDebounce(source: sourceView.string)
            translationInputGeneration += 1
            invalidateActiveTranslationWork(source: sourceView.string)
            return
        }
        let source = sourceView.string
        logTranslationCoordinator("native-text-committed", source: source)
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stopSpeaking()
        }

        // A line break appended at the end is only formatting. Keep the
        // existing translation until the user enters actual text after it;
        // otherwise every standalone Return would start a new network request.
        let sourceWithoutTrailingLineBreaks = source.trimmingCharacters(in: .newlines)
        let previousWithoutTrailingLineBreaks = longTextSource?.trimmingCharacters(in: .newlines)
        if !sourceWithoutTrailingLineBreaks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sourceWithoutTrailingLineBreaks == previousWithoutTrailingLineBreaks {
            return
        }

        let isPaste = (sourceView as? TranslationSourceTextView)?
            .consumeImmediatePasteFlag() == true
        queueLongTextTranslation(
            source,
            mode: isPaste ? .immediate : .debouncedNativeInput
        )
    }

    @objc private func workspaceClearSource() {
        stopSpeaking()
        isUpdatingNativeWorkspace = true
        longTextSourceView?.string = ""
        isUpdatingNativeWorkspace = false
        queueLongTextTranslation("")
        longTextSourceView?.window?.makeFirstResponder(longTextSourceView)
    }

    @objc private func workspaceCopySource() {
        copyToPasteboard(longTextSourceView?.string ?? longTextSource ?? "")
    }

    @objc private func workspaceCopyTranslation() {
        copyToPasteboard(longTextTranslationView?.string ?? longTextTranslation)
    }

    @objc private func workspaceSpeakSource() {
        speakSource()
    }

    @objc private func workspaceSpeakTranslation() {
        speakTranslation()
    }

    private func speakSource() {
        if longTextOverlay?.isHidden == false {
            let source = selectedText(in: longTextSourceView) ??
                longTextSourceView?.string ?? longTextSource ?? ""
            speak(source, language: currentSourceLanguage, pane: .source)
            return
        }
        webView.evaluateJavaScript(#"""
            (() => window.getSelection()?.toString().trim() ||
                document.querySelector("textarea")?.value || "")();
        """#) { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            DispatchQueue.main.async {
                self.speak(text, language: self.currentSourceLanguage, pane: .source)
            }
        }
    }

    private func speakTranslation() {
        if longTextOverlay?.isHidden == false {
            let translation = selectedText(in: longTextTranslationView) ??
                longTextTranslationView?.string ?? longTextTranslation
            speak(translation, language: currentTargetLanguage, pane: .translation)
            return
        }
        webView.evaluateJavaScript(#"""
            (() => {
                const selected = window.getSelection()?.toString().trim();
                if (selected) return selected;
                const selectors = [
                    ".QcsUad .ryNqvb",
                    ".QcsUad .HwtZe",
                    ".QcsUad .jCAhz",
                    ".QcsUad .lRu31"
                ];
                for (const selector of selectors) {
                    const text = document.querySelector(selector)?.innerText?.trim();
                    if (text) return text;
                }
                return "";
            })();
        """#) { [weak self] result, _ in
            guard let self, let text = result as? String else { return }
            DispatchQueue.main.async {
                self.speak(text, language: self.currentTargetLanguage, pane: .translation)
            }
        }
    }

    private func selectedText(in view: NSTextView?) -> String? {
        guard let view, view.selectedRange().length > 0 else { return nil }
        let range = view.selectedRange()
        return (view.string as NSString).substring(with: range)
    }

    private func speak(_ text: String, language: TranslateLanguage, pane: SpeechPane) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // The same control toggles an active utterance off. Starting the
        // opposite pane always interrupts the previous one immediately.
        if speechSynthesizer.isSpeaking, activeSpeechPane == pane {
            stopSpeaking()
            return
        }
        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if language != .automatic {
            utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        }
        speechSynthesizer.speak(utterance)
        activeSpeechPane = pane
    }

    private func stopSpeaking() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        activeSpeechPane = nil
    }

    @objc private func workspaceSourceLanguageClicked(_ sender: NSButton) {
        presentNativeLanguagePicker(side: .source, relativeTo: sender)
    }

    @objc private func workspaceTargetLanguageClicked(_ sender: NSButton) {
        presentNativeLanguagePicker(side: .target, relativeTo: sender)
    }

    @objc private func workspaceSwapLanguages() {
        swapCurrentTranslationLanguages()
    }

    private func textCountDescription(_ text: String) -> String {
        let hanCharacters = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
        }.count
        let nonHanText = String(text.unicodeScalars.filter {
            !((0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value))
        }.map(Character.init))
        let pattern = #"[\p{L}\p{M}]+(?:['’-][\p{L}\p{M}]+)*"#
        let wordCount = (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(
            in: nonHanText,
            range: NSRange(nonHanText.startIndex..., in: nonHanText)
        ) ?? 0
        var values: [String] = []
        if wordCount > 0 {
            values.append(interfaceText("单词 \(wordCount)", "Words \(wordCount)"))
        }
        if hanCharacters > 0 {
            values.append(interfaceText("汉字 \(hanCharacters)", "Chinese characters \(hanCharacters)"))
        }
        return values.isEmpty ? interfaceText("单词 0", "Words 0") : values.joined(separator: " · ")
    }

    public func swapLanguages() {
        (workspaceSwapButton as? WorkspaceSwapButton)?.flashForKeyboardShortcut()
        swapCurrentTranslationLanguages()
    }

    func performShortcut(_ action: ShortcutAction) -> Bool {
        switch action {
        case .showHideWindow:
            // This action is registered as a Carbon global hotkey. Handling
            // it here too would toggle twice while the app is active.
            return false
        case .closeWindow:
            stopSpeaking()
            view.window?.performClose(nil)
        case .hideApplication:
            stopSpeaking()
            NSApp.hide(nil)
        case .quitApplication:
            stopSpeaking()
            NSApp.terminate(nil)
        case .selectAllSource:
            focusAndSelectField()
        case .listenSource:
            speakSource()
        case .listenTranslation:
            speakTranslation()
        case .stopSpeaking:
            stopSpeaking()
        case .swapLanguages:
            swapLanguages()
        case .undo:
            return NSApp.sendAction(Selector(("undo:")), to: nil, from: longTextSourceView ?? webView)
        case .redo:
            return NSApp.sendAction(Selector(("redo:")), to: nil, from: longTextSourceView ?? webView)
        case .cut:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: longTextSourceView ?? webView)
        case .copy:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: longTextSourceView ?? webView)
        case .paste:
            if let sourceView = longTextSourceView,
               longTextOverlay?.isHidden == false {
                sourceView.window?.makeFirstResponder(sourceView)
                sourceView.paste(nil)
                return true
            }
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: webView)
        }
        return true
    }

    private func restorePendingSourceTextIfNeeded() {
        guard let sourceText = pendingSourceTextForReload else { return }
        guard pendingSourceRestoreAttempts < 40 else {
            pendingSourceTextForReload = nil
            pendingSourceRestoreAttempts = 0
            return
        }
        pendingSourceRestoreAttempts += 1
        let encoded = Data(sourceText.utf8).base64EncodedString()

        webView.evaluateJavaScript(#"""
            (() => {
                const textarea = document.querySelector("textarea");
                if (!textarea) return false;
                const bytes = Uint8Array.from(atob("\#(encoded)"), (character) =>
                    character.charCodeAt(0));
                const value = new TextDecoder().decode(bytes);
                const setter = Object.getOwnPropertyDescriptor(
                    HTMLTextAreaElement.prototype, "value"
                ).set;
                setter.call(textarea, value);
                textarea.dispatchEvent(new Event("input", { bubbles: true }));
                return true;
            })();
        """#) { [weak self] result, _ in
            guard let self,
                  self.pendingSourceTextForReload == sourceText else {
                return
            }

            if result as? Bool == true {
                self.pendingSourceTextForReload = nil
                self.pendingSourceRestoreAttempts = 0
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.restorePendingSourceTextIfNeeded()
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension ViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let payload = message.body as? [String: Any],
           let action = payload["action"] as? String {
            if action == "translationTimingJS",
               let requestID = (payload["requestID"] as? NSNumber)?.intValue,
               let session = (payload["session"] as? NSNumber)?.intValue,
               requestID == translationTimingRequest?.id,
               session == translationTimingRequest?.session,
               let milestone = payload["milestone"] as? String {
                let details = payload
                    .filter { !["action", "requestID", "session", "milestone"].contains($0.key) }
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                logTranslationTiming("js-\(milestone)", details: details)
                return
            }

            if action == "translationServiceDOMReady",
               let service = payload["service"] as? String {
                let serviceWebView: WKWebView = service == "automatic"
                    ? automaticTranslationWebView
                    : webView
                configureTranslationPageAfterDOMReady(serviceWebView)
                return
            }

            if action == "copySource", let text = payload["text"] as? String {
                copyToPasteboard(longTextSource ?? text)
                return
            }

            if action == "clearSource" {
                DispatchQueue.main.async { [weak self] in
                    self?.queueLongTextTranslation("")
                }
                return
            }

            if action == "swapLanguages" {
                DispatchQueue.main.async { [weak self] in
                    self?.swapCurrentTranslationLanguages()
                }
                return
            }

            if action == "translationDOMResult",
               let observedSession = (payload["session"] as? NSNumber)?.intValue,
               let observedChunkIndex = (payload["chunkIndex"] as? NSNumber)?.intValue,
               let observedServiceGeneration = (payload["serviceGeneration"] as? NSNumber)?.intValue,
               observedSession == longTextSession,
               observedChunkIndex == longTextChunkIndex,
               observedServiceGeneration == longTextActiveWebViewGeneration,
               longTextChunks.indices.contains(observedChunkIndex),
               let observedSource = payload["source"] as? String,
               let observedTranslation = payload["translation"] as? String {
                let expectedSource = longTextChunks[observedChunkIndex].text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let source = observedSource
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let translation = observedTranslation
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard source == expectedSource,
                      !translation.isEmpty,
                      translation.range(
                        of: "正在翻译|translating|loading",
                        options: .regularExpression.union(.caseInsensitive)
                      ) == nil else {
                    return
                }

                if !didLogFirstTranslationResult {
                    didLogFirstTranslationResult = true
                    logStartupTiming("First translation result appeared")
                }

#if DEBUG
                if translationTimingRequest?.didLogFirstValidJSResult == false {
                    translationTimingRequest?.didLogFirstValidJSResult = true
                    let jsElapsed = (payload["jsElapsedMS"] as? NSNumber)?.doubleValue ?? -1
                    let firstMutation = (payload["firstMutationMS"] as? NSNumber)?.doubleValue ?? -1
                    logTranslationTiming(
                        "js-first-valid-result",
                        details: String(format: "js_elapsed_ms=%.3f first_mutation_ms=%.3f", jsElapsed, firstMutation)
                    )
                }
#endif

                // This is only a candidate. Preview a source-verified
                // one-chunk result immediately, but keep the observer alive
                // and require the normal quiet interval before committing it
                // as the final, swappable translation.
                recordLongTextCandidate(translation)
                previewSingleChunkTranslationIfSafe(
                    translation,
                    session: observedSession,
                    chunkIndex: observedChunkIndex
                )
                let settlingInterval = resultSettlingInterval()
                let elapsedQuietTime = longTextCandidateUpdatedAt.map {
                    Date().timeIntervalSince($0)
                } ?? 0
                scheduleLongTextPoll(
                    session: observedSession,
                    delay: max(0.05, settlingInterval - elapsedQuietTime)
                )
                return
            }

            if action == "translateLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.queueLongTextTranslation(text, mode: .immediate)
                }
                return
            }

            if action == "updateLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.queueLongTextTranslation(text)
                }
                return
            }

            if action == "exitLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.returnToNormalTranslation(text)
                }
                return
            }

            if action == "copyTranslation", let text = payload["text"] as? String {
                copyToPasteboard(longTextSource == nil ? text : longTextTranslation)
                return
            }

            if action == "showLanguagePicker",
               let sideValue = payload["side"] as? String,
               let x = (payload["x"] as? NSNumber)?.doubleValue,
               let y = (payload["y"] as? NSNumber)?.doubleValue {
                let side: NativeLanguagePickerSide = sideValue == "target" ? .target : .source
                DispatchQueue.main.async { [weak self] in
                    self?.presentNativeLanguagePicker(
                        side: side,
                        webPointX: CGFloat(x),
                        webPointY: CGFloat(y)
                    )
                }
                return
            }
        }

        let keyCode = message.body as? Int
        if keyCode == 9 {
            let appDelegate = NSApplication.shared.delegate as! AppDelegate
            appDelegate.panel.resignKey()
        }
    }
}
