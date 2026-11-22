import Foundation
import GoshawkCore

final class PreferencesStore {
    private enum Key {
        static let mixedModeEnabled = "goshawk.mixedModeEnabled"
        static let cangjieVersion = "goshawk.cangjieVersion"
        static let autoSpaceEnabled = "goshawk.autoSpaceEnabled"
        static let autoPunctuationEnabled = "goshawk.autoPunctuationEnabled"
        static let ctrlBracketsQuotesEnabled = "goshawk.ctrlBracketsQuotesEnabled"
        static let developerVocabularyEnabled = "goshawk.developerVocabularyEnabled"
        static let chineseContinuationEnabled = "goshawk.chineseContinuationEnabled"
        static let personalTermsEnabled = "goshawk.personalTermsEnabled"
        static let personalTerms = "goshawk.personalTerms"
        static let learnsEnglishPredictions = "goshawk.learnsEnglishPredictions"
        static let learnsCangjieOrder = "goshawk.learnsCangjieOrder"
        static let learnsReadingLookupOrder = "goshawk.learnsReadingLookupOrder"
        static let readingScheme = "goshawk.readingScheme"
        static let revertEnabled = "goshawk.revertEnabled"
        static let maxVisibleEnglishPredictions = "goshawk.maxVisibleEnglishPredictions"
        static let overlayFontSize = "goshawk.overlayFontSize"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.mixedModeEnabled: true,
            Key.cangjieVersion: CangjieVersion.v3.rawValue,
            Key.autoSpaceEnabled: true,
            Key.autoPunctuationEnabled: true,
            Key.ctrlBracketsQuotesEnabled: true,
            Key.developerVocabularyEnabled: true,
            Key.learnsEnglishPredictions: true,
            Key.learnsCangjieOrder: true,
            Key.learnsReadingLookupOrder: true,
            Key.readingScheme: PhoneticScheme.dachen.rawValue,
            Key.revertEnabled: true,
            Key.maxVisibleEnglishPredictions: 5,
            Key.overlayFontSize: OverlayFontSize.medium.rawValue
        ])
    }

    /// 浮窗字級只影響顯示，所以不放進引擎設定。存的值不認得時用標準。
    func loadOverlayFontSize() -> OverlayFontSize {
        defaults.string(forKey: Key.overlayFontSize).flatMap(OverlayFontSize.init(rawValue:)) ?? .medium
    }

    func saveOverlayFontSize(_ size: OverlayFontSize) {
        defaults.set(size.rawValue, forKey: Key.overlayFontSize)
    }

    func loadConfiguration() -> EngineConfiguration {
        let versionRaw = defaults.string(forKey: Key.cangjieVersion) ?? CangjieVersion.v3.rawValue
        let version = CangjieVersion(rawValue: versionRaw) ?? .v3
        let maxPreds = max(1, min(9, defaults.integer(forKey: Key.maxVisibleEnglishPredictions)))
        let schemeRaw = defaults.string(forKey: Key.readingScheme) ?? PhoneticScheme.dachen.rawValue
        var configuration = EngineConfiguration(
            mixedModeEnabled: defaults.bool(forKey: Key.mixedModeEnabled),
            cangjieVersion: version,
            autoSpaceEnabled: defaults.bool(forKey: Key.autoSpaceEnabled),
            autoPunctuationEnabled: defaults.bool(forKey: Key.autoPunctuationEnabled),
            ctrlBracketsQuotesEnabled: defaults.bool(forKey: Key.ctrlBracketsQuotesEnabled),
            developerVocabularyEnabled: defaults.bool(forKey: Key.developerVocabularyEnabled),
            learnsEnglishPredictions: defaults.bool(forKey: Key.learnsEnglishPredictions),
            learnsCangjieOrder: defaults.bool(forKey: Key.learnsCangjieOrder),
            learnsReadingLookupOrder: defaults.bool(forKey: Key.learnsReadingLookupOrder),
            readingScheme: PhoneticScheme(rawValue: schemeRaw) ?? .dachen,
            revertEnabled: defaults.bool(forKey: Key.revertEnabled),
            maxVisibleCandidates: 9,
            maxVisibleEnglishPredictions: maxPreds
        )
        configuration.chineseContinuationEnabled = defaults.bool(forKey: Key.chineseContinuationEnabled)
        configuration.personalTermsEnabled = defaults.bool(forKey: Key.personalTermsEnabled)
        configuration.personalTerms = PersonalTerms(defaults.stringArray(forKey: Key.personalTerms) ?? [])
        return configuration
    }

    func save(_ config: EngineConfiguration) {
        defaults.set(config.mixedModeEnabled, forKey: Key.mixedModeEnabled)
        defaults.set(config.cangjieVersion.rawValue, forKey: Key.cangjieVersion)
        defaults.set(config.autoSpaceEnabled, forKey: Key.autoSpaceEnabled)
        defaults.set(config.autoPunctuationEnabled, forKey: Key.autoPunctuationEnabled)
        defaults.set(config.ctrlBracketsQuotesEnabled, forKey: Key.ctrlBracketsQuotesEnabled)
        defaults.set(config.developerVocabularyEnabled, forKey: Key.developerVocabularyEnabled)
        defaults.set(config.chineseContinuationEnabled, forKey: Key.chineseContinuationEnabled)
        defaults.set(config.personalTermsEnabled, forKey: Key.personalTermsEnabled)
        defaults.set(config.personalTerms.words, forKey: Key.personalTerms)
        defaults.set(config.learnsEnglishPredictions, forKey: Key.learnsEnglishPredictions)
        defaults.set(config.learnsCangjieOrder, forKey: Key.learnsCangjieOrder)
        defaults.set(config.learnsReadingLookupOrder, forKey: Key.learnsReadingLookupOrder)
        defaults.set(config.readingScheme.rawValue, forKey: Key.readingScheme)
        defaults.set(config.revertEnabled, forKey: Key.revertEnabled)
        defaults.set(config.maxVisibleEnglishPredictions, forKey: Key.maxVisibleEnglishPredictions)
    }
}
