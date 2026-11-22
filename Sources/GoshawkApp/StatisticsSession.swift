import Carbon.HIToolbox
import Foundation
import GoshawkCore

/// 宿主可用文字服務的密碼模式或 macOS 的安全鍵盤輸入宣告保護。
struct StatisticsInputProtection {
    private var passwordMode = false

    mutating func set(_ value: Any?, forTag tag: Int) {
        if tag == Int(kTextServiceInputModePropertyTag) {
            passwordMode = value as? String == kTextServiceInputModePassword as String
        }
    }

    func suspended(secureEventInput: Bool) -> Bool { passwordMode || secureEventInput }
}

/// 每個控制器保管目前這次組字的操作數。浮窗只取候選個數與焦點，不保留候選文字。
final class StatisticsSession {
    struct Observation {
        let group: StatisticsGroup
        let start: UInt64
        let readingPage: Int?
        /// 按鍵進來時符號面板開著。這種按鍵屬於面板，不算進組字的任何計數。
        let inSymbolPanel: Bool
        let wasSelecting: Bool
    }

    private let store: LocalUsageStatistics
    private let isSecureInput: () -> Bool
    private var generation = -1
    private var previousEnglishCount = 0
    private var previousEnglishIndex = 0
    private var previousChineseCount = 0
    private var navigationKeys = 0
    private var lookupGroup: StatisticsGroup?
    private var continuationGroup: StatisticsGroup?
    private var offeredPersonalTerm = false
    private var displayedPersonalTermIndices: [Int] = []
    // 記首次送出所屬的分組。跨午夜、或來回對調時，分子才對得上原分母。
    private var opportunity: (group: StatisticsGroup, track: Bool)?

    init(store: LocalUsageStatistics, isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }) {
        self.store = store
        self.isSecureInput = isSecureInput
    }

    func reset() {
        opportunity = nil
        lookupGroup = nil
        continuationGroup = nil
        offeredPersonalTerm = false
        displayedPersonalTermIndices = []
        previousEnglishCount = 0
        previousEnglishIndex = 0
        previousChineseCount = 0
        navigationKeys = 0
    }

    func begin(engine: InputEngine, start: UInt64) -> Observation? {
        if generation != store.generation {
            reset()
            generation = store.generation
        }
        guard store.enabled, !isSecureInput() else {
            reset()
            return nil
        }
        return Observation(group: store.group(for: engine), start: start,
                           readingPage: engine.readingLookup?.pageIndex, inSymbolPanel: engine.symbolPanel != nil,
                           wasSelecting: engine.state == .selectingCandidate)
    }

    func finish(_ observation: Observation, key: KeyInput, effect: StepEffect?, engine: InputEngine,
                isRevert: Bool, staged: Bool, refused: Bool, updatesOverlay: Bool) {
        guard generation == store.generation, store.enabled, !isSecureInput() else {
            reset()
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - observation.start
        recordCompletionTrials(group: observation.group, key: key, effect: effect, engine: engine,
                               isRevert: isRevert, updatesOverlay: updatesOverlay)
        let reading = observation.readingPage != nil
        let opened = !reading && engine.readingLookup != nil
        let committed = effect?.committedText != nil
        let route: StatisticsRoute = reading || opened ? .lookup : (committed || refused ? .commit : .composing)
        store.update(observation.group) { counts in
            counts.sample(route, nanoseconds: elapsed)
            if opened { counts.add(.lookupOpens) }
            if !reading && !observation.inSymbolPanel && !isRevert {
                if committed, previousEnglishCount > 0 {
                    counts.add(.completionsWithEnglishPredictions)
                    if effect?.commitKind == .english {
                        let rank: Int
                        if case .selectEnglishPrediction(let selected) = key { rank = selected }
                        else { rank = previousEnglishIndex + 1 }
                        if (1...min(9, previousEnglishCount)).contains(rank) { counts.englishRanks[rank - 1] += 1 }
                    }
                }
                if previousChineseCount > 1 {
                    switch key {
                    case .arrowDown, .arrowUp, .shiftSpace:
                        if observation.wasSelecting || engine.state == .selectingCandidate { navigationKeys += 1 }
                    default:
                        break
                    }
                    if effect?.commitKind == .chinese {
                        counts.add(.ambiguousChineseCommits)
                        counts.add(.candidateNavigationKeys, navigationKeys)
                    }
                }
            }
        }

        if opened { lookupGroup = observation.group }
        if reading, let group = lookupGroup {
            if let nextPage = engine.readingLookup?.pageIndex {
                if (key == .pageUp || key == .pageDown || key == .arrowUp || key == .arrowDown),
                   nextPage != observation.readingPage { store.update(group) { $0.add(.lookupPageTurns) } }
            } else {
                store.update(group) { $0.add(effect?.commitKind == .chinese ? .lookupSelections : .lookupCancellations) }
                lookupGroup = nil
            }
        }

        if isRevert {
            if let original = opportunity, refused || (committed && effect?.revertible == true) {
                let metric: StatisticsMetric
                if refused { metric = original.track ? .refusedTrackSwaps : .refusedPunctuationSwaps }
                else if staged { metric = original.track ? .stagedTrackSwaps : .stagedPunctuationSwaps }
                else { metric = original.track ? .committedTrackSwaps : .committedPunctuationSwaps }
                store.update(original.group) { $0.add(metric) }
            }
            // 對調回去不會產生第二個修正機會。
            opportunity = nil
        } else {
            opportunity = nil
            if effect?.revertible == true, let record = engine.revertRecord {
                let track: Bool
                switch record.kind {
                case .track: track = true
                case .punctuationWidth, .pair, .unresolvedCloser: track = false
                }
                store.update(observation.group) { $0.add(track ? .trackOpportunities : .punctuationOpportunities) }
                opportunity = (observation.group, track)
            }
        }

        if committed || engine.buffer.isEmpty { navigationKeys = 0 }
        if let effect {
            previousChineseCount = effect.overlay?.cangjieTrack?.candidates.count ?? 0
            previousEnglishCount = effect.overlay?.englishTrack.predictions.count ?? 0
            previousEnglishIndex = effect.overlay?.englishTrack.selectedIndex ?? 0
        }
    }

    private func recordCompletionTrials(group: StatisticsGroup, key: KeyInput, effect: StepEffect?,
                                        engine: InputEngine, isRevert: Bool, updatesOverlay: Bool) {
        if let origin = continuationGroup, key == .acceptChineseContinuation, effect?.commitKind == .chinese {
            store.update(origin) { $0.add(.chineseContinuationAcceptances) }
        }
        continuationGroup = nil
        if updatesOverlay, effect?.handled == true, engine.chineseContinuation != nil {
            store.update(group) { $0.add(.chineseContinuationOffers) }
            continuationGroup = group
        }

        // 同一組字可能顯示同一術語很多次，只在首次送出時記一次分母。
        // Shift+Space 的替換、取消組字、以及沒有顯示的名次都不算採用。
        if let effect, effect.committedText != nil, !isRevert, offeredPersonalTerm {
            store.update(group) { counts in
                counts.add(.compositionsWithPersonalTermOffer)
                let index: Int
                switch key {
                case .tab: index = previousEnglishIndex
                case .selectEnglishPrediction(let rank): index = rank - 1
                default: return
                }
                if effect.commitKind == .english, displayedPersonalTermIndices.contains(index) {
                    counts.add(.personalTermAcceptances)
                }
            }
        }
        if effect?.committedText != nil || engine.buffer.isEmpty { offeredPersonalTerm = false }
        displayedPersonalTermIndices = []
        let config = engine.configuration
        if updatesOverlay, config.personalTermsEnabled, !config.personalTerms.words.isEmpty,
           effect?.readingLookupPanel == nil, effect?.symbolPanel == nil, let track = effect?.overlay?.englishTrack {
            let showsActions = config.mixedModeEnabled && (engine.state == .composingDual || engine.state == .composingEnglishOnly)
            displayedPersonalTermIndices = track.displayedPredictionIndices(showsActions: showsActions).filter {
                config.personalTerms.contains(track.predictions[$0])
            }
            if !displayedPersonalTermIndices.isEmpty { offeredPersonalTerm = true }
        }
    }

    func hostEndedComposition(engine: InputEngine, deliversText: Bool) {
        if lookupGroup != nil || offeredPersonalTerm, let observation = begin(engine: engine, start: 0) {
            if engine.readingLookup != nil, let group = lookupGroup {
                store.update(group) { $0.add(.lookupCancellations) }
            }
            if deliversText, !engine.buffer.isEmpty, offeredPersonalTerm {
                store.update(observation.group) { $0.add(.compositionsWithPersonalTermOffer) }
            }
        }
        reset()
    }
}
