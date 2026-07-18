//
//  ViewController.swift
//  translate
//

import Cocoa
import AVFoundation
import WebKit

/// A deliberately plain-text editor for the app-owned source pane.  It does
/// not depend on WebKit's 5,000-character field, and inserting the pasteboard
/// string directly keeps very large pastes on the standard NSTextView path.
private final class TranslationSourceTextView: NSTextView {
    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
            return
        }
        super.paste(sender)
    }
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
        guard language == .english,
              let encodedWord = word.addingPercentEncoding(
                  withAllowedCharacters: .urlPathAllowed
              ),
              let url = URL(string: "\(dictionaryAPIBaseURL)\(encodedWord)") else {
            DispatchQueue.main.async { completion(nil) }
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
                fetchFromGoogleSearch(word: word, completion: completion)
                return
            }
            DispatchQueue.main.async {
                completion(PronunciationResult(ipa: pronunciation, source: .standard))
            }
        }.resume()
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
    var visualEffect: NSVisualEffectView!
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
    private var longTextChunks: [String] = []
    private var longTextChunkIndex = 0
    private var longTextSession = 0
    private var longTextPollAttempts = 0
    private var longTextLastWebTranslation: String?
    private var longTextCandidateTranslation: String?
    private var longTextCandidateStablePolls = 0
    private var longTextStatusState: LongTextStatusState = .idle
    private var longTextSourceLanguage = TranslateLanguagePreferences.source.rawValue
    private var longTextTargetLanguage = TranslateLanguagePreferences.target.rawValue
    private var longTextDebounceWorkItem: DispatchWorkItem?
    private var languagePickerPopover: NSPopover?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var activeSpeechPane: SpeechPane?
    // These are the languages of the currently open translation, not the
    // user's persistent defaults in the status-bar menu.
    private var currentSourceLanguage = TranslateLanguagePreferences.source
    private var currentTargetLanguage = TranslateLanguagePreferences.target

    var isDarkMode: Bool {
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
           let source = TranslateLanguage(rawValue: rawSource) {
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

        // Give the native settings bar its own layout space. Previously it
        // was overlaid on WKWebView, so long translations could place the
        // Google copy button underneath the bar.
        let rootView = AppearanceObservingView(
            frame: NSRect(x: 0, y: 0, width: width, height: height)
        )
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

        installWindowBehaviorBar()
        installConnectionOverlay()
        installLongTextOverlay()

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

        // Do not leave a blank panel while a network service or VPN is still
        // starting. The overlay is replaced by Google Translate as soon as
        // the first successful navigation finishes.
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
        bar.blendingMode = .behindWindow
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
        view.addSubview(overlay, positioned: .above, relativeTo: webView)
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
        showConnectionOverlay(waitingForNetwork: true)
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

        let swapButton = NSButton(
            title: "⇄",
            target: self,
            action: #selector(workspaceSwapLanguages)
        )
        swapButton.bezelStyle = .inline
        swapButton.isBordered = false
        swapButton.focusRingType = .none
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
        view.addSubview(overlay, positioned: .above, relativeTo: webView)
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
        connectionOverlay?.isHidden = true
        connectionSpinner?.stopAnimation(nil)
    }

    private func loadTranslationService() {
        automaticRetryWorkItem?.cancel()
        loadTimeoutWorkItem?.cancel()
        translationLoadAttempt += 1
        let attempt = translationLoadAttempt

        // Google is a background translation service only. Keep its page
        // hidden while it loads so retries cannot expose its responsive UI.
        webView.isHidden = true
        isReady = false
        showConnectionOverlay(waitingForNetwork: true)
        webView.load(
            URLRequest(
                url: defaultTranslationURL(),
                cachePolicy: .reloadIgnoringLocalCacheData,
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
        handleTranslationLoadFailure()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleTranslationLoadFailure()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
                self.loadTimeoutWorkItem?.cancel()
                self.automaticRetryWorkItem?.cancel()
                self.hideConnectionOverlay()
            }
        }
    }

    func setTheme(completion: (() -> Void)? = nil) {
        visualEffect.material = isDarkMode ? .dark : .light
        updateWindowBehaviorBarAppearance()
        updateLongTextOverlayAppearance()
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
                    color-scheme: light dark !important;
                    --translate-text-color: black;
                    --translate-selected-color: #0B57D0;
                    --translate-selected-background: rgba(11, 87, 208, 0.14);
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --translate-text-color: white;
                        --translate-selected-color: #A8C7FA;
                        --translate-selected-background: rgba(168, 199, 250, 0.20);
                    }
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

    public func focusAndSelectField() {
        if longTextOverlay?.isHidden == false, let sourceView = longTextSourceView {
            sourceView.window?.makeFirstResponder(sourceView)
            sourceView.selectAll(nil)
            return
        }
        self.webView.evaluateJavaScript("""
            setTimeout(function() {
                var inlineState = window.__macTranslateInlineLongText;
                var active = document.activeElement;
                var inlineEditor = inlineState &&
                    (active === inlineState.left.text || active === inlineState.right.text) ?
                    active : inlineState?.left?.text;
                if (inlineEditor) {
                    inlineEditor.focus();
                    var range = document.createRange();
                    range.selectNodeContents(inlineEditor);
                    var selection = window.getSelection();
                    selection.removeAllRanges();
                    selection.addRange(range);
                    return;
                }
                var textarea = document.getElementsByTagName("textarea")[0];
                if (textarea) {
                    textarea.focus();
                    textarea.select();
                }
            }, 20);
        """, completionHandler: nil)
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
        reloadPreservingSource(
            for: .translationURL(
                translationURL(
                    source: currentSourceLanguage,
                    target: currentTargetLanguage
                )
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

        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let self else { return }

            DispatchQueue.main.async {
                guard generation == self.reloadRequestGeneration else { return }
                self.pendingSourceTextForReload = result as? String ?? ""
                self.pendingSourceRestoreAttempts = 0
                self.installUserScripts(on: self.webView.configuration.userContentController)
                // Never expose the Google document during a reload. The
                // native workspace remains visible while the new language
                // pair is applied in the background.
                self.webView.isHidden = true
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
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }
        let chunks = splitLongText(source)
        longTextSession += 1
        longTextSource = source
        longTextTranslation = ""
        longTextChunks = chunks
        longTextChunkIndex = 0
        longTextPollAttempts = 0
        longTextLastWebTranslation = nil
        longTextCandidateTranslation = nil
        longTextCandidateStablePolls = 0
        let languageCodes = longTextLanguageCodes()
        longTextSourceLanguage = languageCodes.source
        longTextTargetLanguage = languageCodes.target
        longTextOverlay?.isHidden = false
        if longTextSourceView?.string != source {
            isUpdatingNativeWorkspace = true
            longTextSourceView?.string = source
            isUpdatingNativeWorkspace = false
        }
        longTextTranslationView?.string = ""
        guard !chunks.isEmpty else {
            setLongTextStatus(.idle)
            updateLongTextLabels()
            return
        }
        updateLongTextLabels()
        translateNextLongTextChunk(session: longTextSession)
    }

    private func activateCustomTranslationWorkspace() {
        // Evaluation is asynchronous; hide first so there is no visible
        // frame of Google's page during startup or a language change.
        webView.isHidden = true
        webView.evaluateJavaScript("document.querySelector('textarea')?.value || ''") {
            [weak self] result, _ in
            guard let self else { return }
            let source = self.pendingSourceTextForReload ?? (result as? String ?? "")
            self.beginLongTextTranslation(source)
            self.webView.isHidden = true
        }
    }

    private func queueLongTextTranslation(_ source: String) {
        longTextDebounceWorkItem?.cancel()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearLongTextTranslationForEmptyInput()
            return
        }
        longTextSession += 1
        longTextSource = source
        longTextTranslation = ""
        // Language controls and counts update at interaction time instead of
        // waiting for the debounce interval or a network response.
        updateLongTextLabels()
        let status = setLongTextStatus(.preparing)
        updateInlineLongText(
            source: nil,
            translation: "",
            status: status
        )

        let workItem = DispatchWorkItem { [weak self] in
            self?.beginLongTextTranslation(source)
        }
        longTextDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    private func clearLongTextTranslationForEmptyInput() {
        longTextDebounceWorkItem?.cancel()
        longTextSession += 1
        longTextSource = nil
        longTextTranslation = ""
        longTextChunks = []
        longTextChunkIndex = 0
        longTextPollAttempts = 0
        longTextLastWebTranslation = nil
        longTextCandidateTranslation = nil
        longTextCandidateStablePolls = 0
        longTextOverlay?.isHidden = false

        isUpdatingNativeWorkspace = true
        longTextSourceView?.string = ""
        longTextTranslationView?.string = ""
        isUpdatingNativeWorkspace = false

        setLongTextStatus(.idle)
        updateLongTextLabels()
        // Keep the app-owned inline workspace in sync when this path is
        // reached from its editable source, without showing a network error.
        updateInlineLongText(source: "", translation: "", status: "")
    }

    // Google accepts roughly 5,000 source characters, but its web result DOM
    // can duplicate sentence fragments near that limit. Smaller chunks keep
    // the web result stable while the native view still presents one complete,
    // continuous source/translation pair to the user.
    private func splitLongText(_ text: String, limit: Int = 1_600) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            let maximumEnd = text.index(
                start,
                offsetBy: limit,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            if maximumEnd == text.endIndex {
                chunks.append(String(text[start..<text.endIndex]))
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
                chunks.append(String(text[start..<next]))
                start = next
            } else {
                chunks.append(String(text[start..<maximumEnd]))
                start = maximumEnd
            }
        }

        return chunks.filter { !$0.isEmpty }
    }

    private func translateNextLongTextChunk(session: Int) {
        guard session == longTextSession else { return }
        guard longTextChunkIndex < longTextChunks.count else {
            let status = setLongTextStatus(.completed)
            updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
            updateLongTextLabels()
            return
        }

        let chunk = longTextChunks[longTextChunkIndex]
        longTextPollAttempts = 0
        longTextCandidateTranslation = nil
        longTextCandidateStablePolls = 0
        let status = setLongTextStatus(.translating)
        updateInlineLongText(source: nil, translation: longTextTranslation, status: status)
        guard let request = googleTranslationRequest(for: chunk) else {
            finishLongTextTranslationWithError(session: session)
            return
        }

        // The web page is retained for normal translation. For long text,
        // read Google's structured response directly: the page's generated
        // result DOM can repeat or omit fragments as it is re-rendered.
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let translation = data.flatMap(Self.translationText(from:))
            let succeeded = error == nil &&
                (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true &&
                !(translation?.isEmpty ?? true)

            DispatchQueue.main.async {
                guard let self, session == self.longTextSession else { return }
                guard succeeded, let translation else {
                    self.finishLongTextTranslationWithError(session: session)
                    return
                }

                if !self.longTextTranslation.isEmpty {
                    self.longTextTranslation.append("\n\n")
                }
                self.longTextTranslation.append(translation)
                self.longTextTranslationView?.string = self.longTextTranslation
                self.updateInlineLongText(
                    source: nil,
                    translation: self.longTextTranslation,
                    status: self.longTextStatusLabel?.stringValue ?? ""
                )
                self.longTextChunkIndex += 1
                self.updateLongTextLabels()
                self.translateNextLongTextChunk(session: session)
            }
        }.resume()
    }

    private func longTextLanguageCodes() -> (source: String, target: String) {
        (currentSourceLanguage.rawValue, currentTargetLanguage.rawValue)
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
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = response.first as? [[Any]] else {
            return nil
        }
        let translation = segments.compactMap { $0.first as? String }.joined()
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
        // Google cannot meaningfully swap an automatically detected source.
        // For all explicit pairs, exchange only the active session languages;
        // the persistent defaults in the menu remain untouched.
        guard currentSourceLanguage != .automatic else { return }
        let source = currentSourceLanguage
        currentSourceLanguage = currentTargetLanguage
        currentTargetLanguage = source

        if let longTextSource {
            // Behave like a normal translation app: once a result exists it
            // becomes the new editable source.  During an in-flight request,
            // retain the user's original text rather than swapping in a
            // partial result.
            let swappedSource = longTextTranslation.isEmpty
                ? longTextSource
                : longTextTranslation
            isUpdatingNativeWorkspace = true
            longTextSourceView?.string = swappedSource
            isUpdatingNativeWorkspace = false
            updateLongTextLabels()
            queueLongTextTranslation(swappedSource)
        } else {
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
                textarea.focus();
            })();
        """#, completionHandler: nil)
    }

    private func pollLongTextTranslation(session: Int) {
        guard session == longTextSession else { return }
        longTextPollAttempts += 1
        guard longTextPollAttempts <= 80 else {
            finishLongTextTranslationWithError(session: session)
            return
        }

        webView.evaluateJavaScript(#"""
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
                const primary = Array.from(document.querySelectorAll(".QcsUad .ryNqvb"));
                const nodes = primary.length ? primary : Array.from(document.querySelectorAll(selectors));
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
            guard let self, session == self.longTextSession else { return }
            let translation = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let isLoading = translation.isEmpty ||
                translation.range(
                    of: "正在翻译|translating|loading",
                    options: .regularExpression.union(.caseInsensitive)
                ) != nil

            if isLoading {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.pollLongTextTranslation(session: session)
                }
                return
            }

            // A cleared Google input can retain the preceding translation for
            // a moment. Do not append that stale result, and only accept a
            // new result after it has remained unchanged for two polls.
            if translation == self.longTextLastWebTranslation && self.longTextPollAttempts < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.pollLongTextTranslation(session: session)
                }
                return
            }
            if translation == self.longTextCandidateTranslation {
                self.longTextCandidateStablePolls += 1
            } else {
                self.longTextCandidateTranslation = translation
                self.longTextCandidateStablePolls = 1
            }
            guard self.longTextCandidateStablePolls >= 2 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.pollLongTextTranslation(session: session)
                }
                return
            }

            if !self.longTextTranslation.isEmpty {
                self.longTextTranslation.append("\n\n")
            }
            self.longTextTranslation.append(translation)
            self.longTextTranslationView?.string = self.longTextTranslation
            self.longTextLastWebTranslation = translation
            self.longTextChunkIndex += 1
            self.updateLongTextLabels()
            self.translateNextLongTextChunk(session: session)
        }
    }

    private func finishLongTextTranslationWithError(session: Int) {
        guard session == longTextSession else { return }
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
                "部分内容未能完成翻译；请检查网络后重试。",
                "Some content could not be translated. Check the network and try again."
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
            // A previous debounce must not fire while a candidate is still
            // being composed; wait for the final committed text change.
            longTextDebounceWorkItem?.cancel()
            longTextSession += 1
            return
        }
        let source = sourceView.string
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

        queueLongTextTranslation(source)
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

            if action == "translateLongText", let text = payload["text"] as? String {
                DispatchQueue.main.async { [weak self] in
                    self?.beginLongTextTranslation(text)
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
