//
//  ViewController.swift
//  translate
//

import Cocoa
import AVFoundation
import WebKit
import os

let translationPipelineLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "TranslationPipeline"
)

let startupTimingLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "StartupTiming"
)

let inputMethodTimingLogger = Logger(
    subsystem: "com.lalalaladam.translate",
    category: "InputMethodTiming"
)

#if DEBUG
func logTextPipelineSnapshot(_ stage: String, _ text: String?) {
    let value = text ?? "<nil>"
    let containsSup = value.localizedCaseInsensitiveContains("<sup")
    translationPipelineLogger.info(
        "TextSnapshot stage=\(stage, privacy: .public) chars=\(value.count, privacy: .public) containsSup=\(containsSup, privacy: .public)"
    )
}
#else
func logTextPipelineSnapshot(_ stage: String, _ text: String?) {}
#endif

/// A deliberately plain-text editor for the app-owned source pane.  It does
/// not depend on WebKit's 5,000-character field, and inserting the pasteboard
/// string directly keeps very large pastes on the standard NSTextView path.
class ViewController: NSViewController, WKNavigationDelegate, NSTextViewDelegate {
    static let windowBehaviorBarHeight: CGFloat = 34

    enum ReloadDestination {
        case currentPage
        case defaultLanguages
        case interfaceLanguage
        case translationURL(URL)
    }

    enum LongTextStatusState {
        case idle
        case preparing
        case translating
        case completed
        case failed
    }

    enum TranslationResultProvider: Hashable {
        case web
        case api
    }

    enum SpeechPane {
        case source
        case translation
    }

    enum PronunciationPane: Equatable {
        case source
        case translation
    }

    enum PrimaryWebWarmupState: Equatable {
        case idle
        case running
        case finished
    }

    public var isReady = false
    private var readyHandlers: [() -> Void] = []

    var webView: WebView!
    var automaticTranslationWebView: BackgroundTranslationWebView!
    var standbyTranslationWebView: WebView!
    var parallelTranslationWebView: BackgroundTranslationWebView!
    weak var activeTranslationWebView: WKWebView?
    var automaticTranslationWebViewReady = false
    var automaticTranslationWebViewLoading = false
    var automaticTranslationTarget = TranslateLanguagePreferences.target
    var standbyTranslationWebViewReady = false
    var standbyTranslationWebViewLoading = false
    var standbyTranslationSource = TranslateLanguagePreferences.target
    var standbyTranslationTarget = TranslateLanguagePreferences.source
    var parallelTranslationWebViewReady = false
    var parallelTranslationWebViewLoading = false
    var parallelTranslationSource = TranslateLanguagePreferences.source
    var parallelTranslationTarget = TranslateLanguagePreferences.target
    var prefersParallelTranslationWebView = false
    var parallelWebTranslationBatch: ParallelWebTranslationBatch?
    var pendingAutomaticTranslationSource: String?
    var pendingAutomaticTranslationSession: Int?
    var pendingPrimaryTranslationSource: String?
    var pendingPrimaryTranslationSession: Int?
    let startupTimingOrigin = ProcessInfo.processInfo.systemUptime
    var didLogFirstTranslationCommand = false
    var didLogFirstTextInjection = false
    var didLogFirstTranslationResult = false
    struct TranslationTimingRequest {
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
        var didLogFirstVerifiedDisplay = false
        var didLogStableResult = false
        var didLogFinalDisplay = false
        var webKitDispatchRoundTripMilliseconds: Double?
    }
    var translationTimingRequestCount = 0
    var translationTimingRequest: TranslationTimingRequest?
    var translationWebViewLastActivityAt: [ObjectIdentifier: Date] = [:]
    var visualEffect: NSVisualEffectView!
    var workspaceBackgroundView: NSVisualEffectView?
    var keepOnTopButton: NSButton!
    var showOnAllSpacesButton: NSButton!
    var windowBehaviorBar: WindowBehaviorBarView?
    var windowBehaviorSettingsGroup: NSView?
    var windowBehaviorDivider: NSView?
    var pendingSourceTextForReload: String?
    var pendingSourceRestoreAttempts = 0
    var reloadRequestGeneration = 0
    var applicationAppearanceObservation: NSKeyValueObservation?
    var connectionOverlay: NSVisualEffectView?
    var connectionTitleLabel: NSTextField?
    var connectionDetailLabel: NSTextField?
    var connectionSpinner: NSProgressIndicator?
    var connectionRetryButton: NSButton?
    var loadTimeoutWorkItem: DispatchWorkItem?
    var delayedConnectionOverlayWorkItem: DispatchWorkItem?
    var automaticRetryWorkItem: DispatchWorkItem?
    var automaticTranslationWarmupWorkItem: DispatchWorkItem?
    var secondaryWebViewWarmupWorkItem: DispatchWorkItem?
    var primaryWebWarmupState: PrimaryWebWarmupState = .idle
    var primaryWebWarmupGeneration = 0
    var primaryWebWarmupTimeoutWorkItem: DispatchWorkItem?
    var translationLoadAttempt = 0
    // The workspace is intentionally a transparent content layer. The main
    // window already owns the single behind-window glass effect used by the
    // pre-rewrite interface; a second visual-effect view made it grey and
    // noticeably less transparent.
    var longTextOverlay: NSView?
    var longTextSourceView: NSTextView?
    var longTextTranslationView: NSTextView?
    var alignmentRequestGeneration = 0
    var alignmentRequestCount = 0
    var alignmentTask: URLSessionDataTask?
    var sourceAlignmentHighlightRange: NSRange?
    var translationAlignmentHighlightRange: NSRange?
    var isShowingAlignmentPresentation = false
    var longTextStatusLabel: NSTextField?
    var longTextSourceLabel: NSTextField?
    var longTextTranslationLabel: NSTextField?
    var sourcePronunciationRow: NSView?
    var translationPronunciationRow: NSView?
    var sourcePronunciationLabel: NSTextField?
    var translationPronunciationLabel: NSTextField?
    var sourcePronunciationValue: String?
    var translationPronunciationValue: String?
    var sourcePronunciationSource: PronunciationSource = .standard
    var translationPronunciationSource: PronunciationSource = .standard
    var sourcePronunciationKey: String?
    var translationPronunciationKey: String?
    var sourcePronunciationGeneration = 0
    var translationPronunciationGeneration = 0
    var workspaceSourceLanguageButton: NSButton?
    var workspaceTargetLanguageButton: NSButton?
    var workspaceSwapButton: NSButton?
    var workspaceSplitView: NSSplitView?
    var workspaceSourceStack: NSStackView?
    var workspaceTranslationStack: NSStackView?
    var workspaceEqualWidthConstraint: NSLayoutConstraint?
    var workspaceEqualHeightConstraint: NSLayoutConstraint?
    var workspaceSplitBottomConstraint: NSLayoutConstraint?
    var workspaceUsesStackedLayout = false
    var workspaceSourceCountLabel: NSTextField?
    var workspaceTranslationCountLabel: NSTextField?
    var isUpdatingNativeWorkspace = false
    var longTextSource: String?
    var longTextTranslation = ""
    var translationResultProviders: Set<TranslationResultProvider> = []
    var completedTranslationResultProviders: Set<TranslationResultProvider> = []
    var parallelWebTranslationCache = ParallelWebTranslationCache()
    let translationCoordinator = TranslationServiceCoordinator()
    var longTextStatusState: LongTextStatusState = .idle
    var longTextSourceLanguage = TranslateLanguagePreferences.source.rawValue
    var longTextTargetLanguage = TranslateLanguagePreferences.target.rawValue
    var imeCompositionEndCheck: DispatchWorkItem?
    var imeCompositionGeneration = 0
    var translationInputGeneration = 0
    var languageSwapInProgress = false
    var languageSwapPendingText: String?
    var languageSwapSnapshotText: String?
    var restoreSourceFocusAfterLanguageSwap = false
    // A committed IME candidate is still part of continuous human typing.
    // Coalesce those edits, while paste and explicit submission stay immediate.
    let nativeTextTranslationDebounce: TimeInterval = 0.25
    let longTextTranslationDebounce: TimeInterval = 0.12
    let longTextPollInterval: TimeInterval = 0.15
    let longTextResultSettlingInterval: TimeInterval = 0.55
    let webStallRecoveryDelay: TimeInterval = 1.35
    let coldResumeIdleThreshold: TimeInterval = 30 * 60
    // Give Google a short, bounded chance to produce its preferred result.
    // API work starts earlier as a provisional safety net, so a stalled chunk
    // does not add the former six-second delay to every oversized document.
    let longTextWebResultDeadline: TimeInterval = 3.0
    let concurrentAPIChunkThreshold = 3
    // A completely transparent WKWebView can be deprioritized by WebKit's
    // rendering pipeline. Keep the background translator imperceptibly
    // visible so Google updates its result DOM at normal foreground speed.
    let backgroundTranslationWebViewAlpha: CGFloat = 0.01
    var languagePickerPopover: NSPopover?
    let speechSynthesizer = AVSpeechSynthesizer()
    var activeSpeechPane: SpeechPane?
    // These are the languages of the currently open translation, not the
    // user's persistent defaults in the status-bar menu.
    var currentSourceLanguage = TranslateLanguagePreferences.source
    var currentTargetLanguage = TranslateLanguagePreferences.target

    var currentEffectiveAppearance: NSAppearance {
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

    func markReady() {
        isReady = true
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    deinit {
        loadTimeoutWorkItem?.cancel()
        delayedConnectionOverlayWorkItem?.cancel()
        automaticRetryWorkItem?.cancel()
        automaticTranslationWarmupWorkItem?.cancel()
        secondaryWebViewWarmupWorkItem?.cancel()
        primaryWebWarmupTimeoutWorkItem?.cancel()
        translationCoordinator.debounceWorkItem?.cancel()
        stopSpeaking()
    }
}
