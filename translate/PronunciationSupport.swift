import Cocoa

import WebKit

/// pronunciation until a reliable language-specific dictionary is available.
struct PronunciationResult {
    let ipa: String
    let source: PronunciationSource
}

enum PronunciationService {
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
final class BackgroundGooglePronunciationLookup: NSObject, WKNavigationDelegate {
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
