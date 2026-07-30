//
//  GooglePronunciationLookup.swift
//  translate
//

import Foundation
import WebKit

/// Last-resort, no-key lookup. This WebView is never attached to the app's
/// visible view hierarchy; it only reads a public Google Search result after
/// the dictionary sources have failed. Search and AI results can change or be
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
