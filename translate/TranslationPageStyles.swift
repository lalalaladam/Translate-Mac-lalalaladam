//
//  TranslationPageStyles.swift
//  translate
//

import Foundation

/// CSS applied to the embedded translation page.
enum TranslationPageStyles {
    static let javaScriptTemplateLiteral = #"""
        `
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
        `
    """#
}
