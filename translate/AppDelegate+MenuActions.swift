//
//  AppDelegate+MenuActions.swift
//  translate
//

import Cocoa

extension AppDelegate {
    @objc func copyAllSourceFromMenu() {
        viewController?.copyAllSource()
    }

    @objc func copyAllTranslationFromMenu() {
        viewController?.copyAllTranslation()
    }

    @objc func swapLanguagesFromMenu() {
        viewController?.swapLanguages()
    }

    @objc func setDefaultSourceLanguageFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let newSource = TranslateLanguage(rawValue: rawValue) else {
            return
        }

        let oldSource = TranslateLanguagePreferences.source
        let oldTarget = TranslateLanguagePreferences.target
        guard newSource != oldSource else { return }

        var newTarget = oldTarget
        if newSource != .automatic && newSource == oldTarget {
            if oldSource.canBeTarget && oldSource != newSource {
                newTarget = oldSource
            } else {
                newTarget = newSource == .simplifiedChinese ? .english : .simplifiedChinese
            }
        }

        TranslateLanguagePreferences.set(source: newSource, target: newTarget)
        updateLanguageMenuStates()
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc func setDefaultTargetLanguageFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let newTarget = TranslateLanguage(rawValue: rawValue),
              newTarget.canBeTarget else {
            return
        }

        let oldSource = TranslateLanguagePreferences.source
        let oldTarget = TranslateLanguagePreferences.target
        guard newTarget != oldTarget else { return }

        var newSource = oldSource
        if oldSource != .automatic && newTarget == oldSource {
            newSource = oldTarget != newTarget ? oldTarget : .automatic
        }

        TranslateLanguagePreferences.set(source: newSource, target: newTarget)
        updateLanguageMenuStates()
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc func applyDefaultLanguagesFromMenu() {
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc func restoreInitialLanguagesFromMenu() {
        TranslateLanguagePreferences.restoreInitialPair()
        updateLanguageMenuStates()
        viewController?.applyDefaultLanguagesPreservingSource()
    }

    @objc func toggleFeatureFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let feature = TranslateFeature(rawValue: rawValue) else {
            return
        }

        let enabled = !TranslateFeaturePreferences.isEnabled(feature)
        TranslateFeaturePreferences.set(feature, enabled: enabled)
        sender.state = enabled ? .on : .off
        viewController?.reloadWithCurrentPreferences()
    }

    @objc func restoreRecommendedFeatures() {
        TranslateFeaturePreferences.restoreRecommendedSettings()
        TranslateFeature.allCases.forEach { feature in
            featureMenuItems[feature]?.state = .on
        }
        viewController?.reloadWithCurrentPreferences()
    }
}
