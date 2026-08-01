import Cocoa

class AlignmentTextView: NSTextView {
    var onFindCorrespondingText: ((NSTextView) -> Void)?
    var alignmentIsEnabled: ((NSTextView) -> Bool)?
    var alignmentMenuTitle = "定位对应句"

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(
            title: alignmentMenuTitle,
            action: #selector(findCorrespondingText(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.isEnabled = alignmentIsEnabled?(self) ?? (selectedRange().length > 0)
        menu.insertItem(item, at: 0)
        menu.insertItem(NSMenuItem.separator(), at: 1)
        return menu
    }

    @objc private func findCorrespondingText(_ sender: Any?) {
        onFindCorrespondingText?(self)
    }
}

final class TranslationSourceTextView: AlignmentTextView {
    private var hasPendingImmediatePaste = false
    private var beginsNewSessionAfterPaste = false
    private let sourceUndoGrouping = SourceTextUndoGrouping()
    private(set) var isPerformingHistoryNavigation = false
    var onPasteReceived: ((String?) -> Void)?

    func consumeImmediatePasteFlag() -> Bool {
        let pending = hasPendingImmediatePaste
        hasPendingImmediatePaste = false
        return pending
    }

    func prepareUndoGrouping(
        affectedRange: NSRange,
        replacementString: String?
    ) {
        sourceUndoGrouping.prepareChange(
            in: self,
            affectedRange: affectedRange,
            replacementString: replacementString,
            isPaste: hasPendingImmediatePaste
        )
    }

    func completeUndoGroupingAfterTextChange() -> Bool {
        sourceUndoGrouping.textDidChange(in: self)
        guard beginsNewSessionAfterPaste else { return false }
        beginsNewSessionAfterPaste = false
        sourceUndoGrouping.beginNewSession(in: self)
        return true
    }

    func finishPendingIMEUndoGrouping() {
        sourceUndoGrouping.finishPendingComposition(in: self)
    }

    func beginNewUndoSession() {
        sourceUndoGrouping.beginNewSession(in: self)
    }

    func performGroupedUndo() -> Bool {
        isPerformingHistoryNavigation = true
        defer { isPerformingHistoryNavigation = false }
        return sourceUndoGrouping.performUndo(in: self)
    }

    func performGroupedRedo() -> Bool {
        isPerformingHistoryNavigation = true
        defer { isPerformingHistoryNavigation = false }
        return sourceUndoGrouping.performRedo(in: self)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        sourceUndoGrouping.willSetMarkedText(in: self)
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    override func unmarkText() {
        super.unmarkText()
        sourceUndoGrouping.didUnmarkText(in: self)
    }

    override func paste(_ sender: Any?) {
        let sourceBeforePaste = string
        hasPendingImmediatePaste = true
        let selection = selectedRange()
        // Replacing the complete source is a new document. Once the paste is
        // committed, discard the preceding document's undo history and keep
        // the pasted text as the new baseline.
        beginsNewSessionAfterPaste = !string.isEmpty &&
            selection.location == 0 &&
            selection.length == (string as NSString).length
        let pasteboardText = NSPasteboard.general.string(forType: .string)
        onPasteReceived?(pasteboardText)
        logTextPipelineSnapshot(
            "1-nspasteboard-raw-string",
            pasteboardText
        )
        if let text = PlainTextPasteboardReader.read(from: .general) {
            logTextPipelineSnapshot("2-plain-text-reader-output", text)
            insertText(text, replacementRange: selectedRange())
            if string == sourceBeforePaste {
                hasPendingImmediatePaste = false
                beginsNewSessionAfterPaste = false
            }
            return
        }
        super.paste(sender)
        if string == sourceBeforePaste {
            hasPendingImmediatePaste = false
            beginsNewSessionAfterPaste = false
        }
    }
}

final class TranslationResultTextView: AlignmentTextView {}

enum TranslationServiceTextNormalizer {
    private static let citationSuperscriptExpression = try? NSRegularExpression(
        pattern: #"(?i)<sup(?:\s+[^<>]*)?>([0-9\s,;\-–—]+)</sup\s*>"#
    )

    static func normalize(_ translation: String, forSource source: String) -> String {
        // Google Translate's result DOM can expose citation superscripts as
        // literal markup even though its textarea received ordinary numbers.
        // Preserve intentional HTML/code by making this correction only when
        // the submitted source did not itself contain a sup tag.
        guard source.range(of: "<sup", options: .caseInsensitive) == nil,
              let expression = citationSuperscriptExpression else {
            return translation
        }
        let range = NSRange(translation.startIndex..., in: translation)
        return expression.stringByReplacingMatches(
            in: translation,
            range: range,
            withTemplate: "$1"
        )
    }
}

enum PlainTextPasteboardReader {
    private static let serializedSuperscriptExpression = try? NSRegularExpression(
        pattern: #"(?i)<sup(?:\s+[^<>]*)?>([0-9\s,;\-–—]+)</sup\s*>"#
    )

    static func read(from pasteboard: NSPasteboard) -> String? {
        // Word, Pages and browsers normally publish a faithful public.utf8-plain-text
        // representation. Prefer it so HTML/RTF styling and embedded objects never
        // reach Google Translate.
        if let plain = pasteboard.string(forType: .string) {
            let sanitized = minimallySanitized(plain)
            guard containsSerializedSuperscript(in: sanitized) else {
                return sanitized
            }
            return textByUnwrappingSerializedSuperscripts(
                in: sanitized,
                whenConfirmedBy: attributedStrings(from: pasteboard)
            )
        }

        // Some producers expose only attributed data. AppKit converts that data to
        // visible text while preserving paragraph breaks and tabs.
        if let attributed = attributedStrings(from: pasteboard).first {
            return attributed
        }
        return nil
    }

    private static func attributedStrings(from pasteboard: NSPasteboard) -> [String] {
        [NSPasteboard.PasteboardType.rtf, .rtfd, .html].compactMap { type in
            guard let data = pasteboard.data(forType: type),
                  let attributed = try? NSAttributedString(
                    data: data,
                    options: [:],
                    documentAttributes: nil
                  ) else { return nil }
            return minimallySanitized(attributed.string)
        }
    }

    private static func textByUnwrappingSerializedSuperscripts(
        in plain: String,
        whenConfirmedBy attributedFallbacks: [String]
    ) -> String {
        // A few PDF producers publish literal markup in public.utf8-plain-text while
        // their rich representation correctly describes the same characters as a
        // superscript. Only unwrap citation-shaped, paired tags, and only when the
        // resulting text exactly matches a rich representation's visible string.
        // Thus a user copying literal HTML/XML/code keeps the markup unchanged.
        guard let expression = serializedSuperscriptExpression else {
            return plain
        }
        let range = NSRange(plain.startIndex..., in: plain)
        guard expression.firstMatch(in: plain, range: range) != nil else {
            return plain
        }

        let unwrapped = expression.stringByReplacingMatches(
            in: plain,
            range: range,
            withTemplate: "$1"
        )
        let confirmed = attributedFallbacks.contains { visibleText in
            visibleText == unwrapped || visibleText == unwrapped + "\n"
        }
        return confirmed ? unwrapped : plain
    }

    private static func containsSerializedSuperscript(in text: String) -> Bool {
        guard let expression = serializedSuperscriptExpression else { return false }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private static func minimallySanitized(_ text: String) -> String {
        // RTF itself never reaches the translator: AppKit has already exposed its
        // visible plain-text representation. Word does, however, commonly retain
        // invisible layout controls in that string. Normalize only controls which
        // are not visible text, preserve tabs and language-sensitive joiners, and use NFC
        // so the WebView sees the same text representation as ordinary pasteboards.
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
            .unicodeScalars.reduce(into: "") {
            result, scalar in
            switch scalar.value {
            case 0, 0x00AD, 0x200B, 0x2060, 0xFEFF, 0xFFFC:
                // NUL, soft hyphen, zero-width space, word joiner, BOM and
                // attachment placeholders are not visible source text.
                break
            case 0x000D, 0x2028, 0x2029:
                // Word may use CR, line separator, or paragraph separator.
                result.append("\n")
            case 0x00A0, 0x2007, 0x202F:
                // Convert Word's non-breaking spaces to ordinary source spaces.
                result.append(" ")
            default:
                result.unicodeScalars.append(scalar)
            }
        }
    }
}

struct TranslationChunk {
    let text: String
    let separatorAfter: String
}

struct AlignmentSelection {
    let range: NSRange
    let text: String
    let sentenceCount: Int
}

struct AlignmentCandidate {
    let range: NSRange
    let text: String
    let score: Double
    let unitCount: Int
    let evaluatedCount: Int
    let similarity: Double
    let positionalScore: Double
    let coverageScore: Double
    let scoringMilliseconds: Double
}

enum TranslationSubmissionMode {
    case debouncedNativeInput
    case immediate
}

enum PronunciationSource {
    case standard
    case ai
    case estimated
}

/// Fetches standard IPA for English words without loading a web page into the
/// visible translation workspace. Other languages intentionally return no
