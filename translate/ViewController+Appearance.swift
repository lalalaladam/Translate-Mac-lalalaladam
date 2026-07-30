//
//  ViewController+Appearance.swift
//  translate
//

import Cocoa
import WebKit

extension ViewController {
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

    func updateWindowBehaviorBarAppearance() {
        let dark = isDarkMode
        windowBehaviorBar?.material = dark ? .dark : .light
        windowBehaviorBar?.layer?.borderColor = NSColor.separatorColor.cgColor

        windowBehaviorSettingsGroup?.layer?.backgroundColor = NSColor.labelColor
            .withAlphaComponent(dark ? 0.12 : 0.055).cgColor
        windowBehaviorSettingsGroup?.layer?.borderColor = NSColor.separatorColor.cgColor
        windowBehaviorDivider?.wantsLayer = true
        windowBehaviorDivider?.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
