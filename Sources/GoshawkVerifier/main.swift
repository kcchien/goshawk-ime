import Foundation
import GoshawkCore

struct EquivalenceKey: Hashable {
    let state: EngineStateKind
    let buffer: String
    let selectedCandidateIndex: Int
    let selectedEnglishIndex: Int
    let pendingAutoSpace: Bool
    let capsLockEnabled: Bool
    let readingLookup: ReadingLookup?
    let documentText: String
    let usageHistory: UsageHistory
    /// 有沒有反悔紀錄會改變下一個 Shift+空白 的結果，所以是狀態的一部分。
    let revertRecord: RevertRecord?
    /// 片段語境改變空白、Tab、數字與標點的結果，所以是狀態的一部分。
    let snippet: SnippetContext

    /// `ignoringReadingLookup` 用來證明 Esc 只清掉反查，底下的組字完全沒動過。
    /// `ignoringRevertRecord` 用來比對反悔後的引擎與直接按另一個鍵的引擎。
    /// `ignoringDocumentText` 用來證明標點寬度對調只動文件裡那一個字元，其他欄位都沒變。
    init(
        engine: InputEngine,
        ignoringReadingLookup: Bool = false,
        ignoringRevertRecord: Bool = false,
        ignoringDocumentText: Bool = false
    ) {
        self.revertRecord = ignoringRevertRecord ? nil : engine.revertRecord
        self.snippet = engine.snippet
        self.usageHistory = engine.usageHistory
        self.readingLookup = ignoringReadingLookup ? nil : engine.readingLookup
        self.state = engine.state
        self.buffer = engine.buffer
        self.selectedCandidateIndex = engine.selectedCandidateIndex
        self.selectedEnglishIndex = engine.selectedEnglishIndex
        self.pendingAutoSpace = engine.pendingAutoSpace
        self.capsLockEnabled = engine.capsLockEnabled
        // Repeated Backspace can expose any earlier character in this bounded replay.
        self.documentText = ignoringDocumentText ? "" : engine.documentText
    }
}

struct QueueNode {
    let engine: InputEngine
    let path: [KeyInput]
    let depth: Int
}

struct Violation {
    let invariant: String
    let message: String
    let path: [KeyInput]
}

// u 與 n 讓 une 進得了探索範圍：加上完整英文詞保護規則後，une 是兩份碼表唯一的差異，
// 「函」的五代原生碼是 une、三代是 nue，而 une 是完整英文詞，不補進三代。少了這兩鍵，
// 三代與五代兩組設定會探索出一模一樣的狀態空間，cangjie3+mixed 就驗不到跨代差異。
let alphabetTokens = [
    "a", "b", "i", "s", "d", "o", "t", "h", "e", "z", "k", "u", "n", "8",
    "SPACE", "TAB", "ENTER", "BKSP", "ESC", "DOWN", "UP",
    "DIGIT1", "DIGIT2", "COMMA", "BANG", "DBL_SHIFT",
    "SHIFT_2", "DQUOTE",
    "PERIOD", "OPT_.", "SHIFT_SPACE", "CAPS_ON", "CAPS_OFF",
    // Ctrl 全形標點走一張表，`、` 在自動規則下沒有鍵打得出來，所以放它當代表鍵。
    "CTRL_BACKSLASH",
    "LOOKUP", "PGDN",
    // 反引號開關行內程式片段語境，片段裡空白、Tab、數字與標點的結果都不同。
    "BACKTICK"
]

/// 片段裡英文優先：空白鍵送原字母，不送倉頡首選字。黏中時不算。
func snippetPrefersEnglish(_ engine: InputEngine) -> Bool {
    engine.configuration.mixedModeEnabled && engine.snippet.isInside && !engine.snippet.stickyChinese
}

func inSnippet(_ engine: InputEngine) -> Bool {
    engine.configuration.mixedModeEnabled && engine.snippet.isInside
}

struct CheckedConfiguration {
    let label: String
    let configuration: EngineConfiguration
    var usageHistory = UsageHistory()
}

/// 預存的學習紀錄。英文詞都以代表鍵能打出的短詞為前綴，檢查學習紀錄不會擠掉短詞鎖定；
/// 倉頡的兩個碼都是代表鍵打得出來的重碼，且次數已達門檻，所以探索一開始順序就被調整過；
/// 反查的字取自 `a8`（ㄇㄚ）查得到的候選。
let learnedHistory = UsageHistory(
    englishWords: ["idea", "this", "issue", "about", "doctor", "that"],
    cangjieChoices: [("a", "曰"), ("a", "曰"), ("no", "欠"), ("no", "欠")],
    readingChoices: ["馬", "馬", "嗎"]
)

let checkedConfigurations = [
    CheckedConfiguration(label: "cangjie5+mixed", configuration: EngineConfiguration(cangjieVersion: .v5)),
    CheckedConfiguration(label: "cangjie3+mixed", configuration: EngineConfiguration(cangjieVersion: .v3)),
    CheckedConfiguration(
        label: "cangjie5+chinese-only",
        configuration: EngineConfiguration(mixedModeEnabled: false, cangjieVersion: .v5)
    ),
    CheckedConfiguration(
        label: "cangjie5+mixed+learned",
        configuration: EngineConfiguration(cangjieVersion: .v5),
        usageHistory: learnedHistory
    ),
    // 三個學習都關閉卻帶著同一份紀錄：LearningOffIgnoresHistory 證明紀錄不影響任何結果。
    CheckedConfiguration(
        label: "cangjie5+mixed+learning-off",
        configuration: EngineConfiguration(
            cangjieVersion: .v5,
            learnsEnglishPredictions: false,
            learnsCangjieOrder: false,
            learnsReadingLookupOrder: false
        ),
        usageHistory: learnedHistory
    ),
    // 關閉一鍵反悔：RevertEqualsAlternative 證明永遠沒有紀錄，而且每個按鍵的結果
    // 都與「開啟但沒有紀錄」時相同，也就是這個功能只改變送出後那一個 Shift+空白。
    CheckedConfiguration(
        label: "cangjie5+mixed+revert-off",
        configuration: EngineConfiguration(cangjieVersion: .v5, revertEnabled: false)
    )
]

func checkStateInvariants(engine: InputEngine, path: [KeyInput]) -> Violation? {
    let overlay = engine.currentOverlay

    // Caps Lock 半形層不組字：亮燈時必須已送出緩衝，停在閒置或純英文。
    if engine.capsLockEnabled, engine.state != .idle, engine.state != .pureEnglish {
        return Violation(
            invariant: "DualTrackConsistency",
            message: "Caps Lock layer must not compose (state=\(engine.state.rawValue), buffer='\(engine.buffer)').",
            path: path
        )
    }

    switch engine.state {
    case .idle, .pureEnglish:
        if !engine.buffer.isEmpty || overlay != nil || engine.selectedCandidateIndex != 0 || engine.selectedEnglishIndex != 0 {
            return Violation(
                invariant: "DualTrackConsistency",
                message: "State \(engine.state.rawValue) must have empty buffer, nil overlay, and zero selection indices (buffer='\(engine.buffer)').",
                path: path
            )
        }
    case .composingDual:
        guard (1...5).contains(engine.buffer.count),
              CangjieDictionary.isValidCangjieCodeShape(engine.buffer),
              engine.cangjie.hasCandidatesOrPrefix(for: engine.buffer),
              let ov = overlay,
              ov.cangjieTrack != nil else {
            return Violation(
                invariant: "DualTrackConsistency",
                message: "composingDual must hold 1..5 valid Cangjie code/prefix and non-nil cangjieTrack (buffer='\(engine.buffer)').",
                path: path
            )
        }

        // 浮窗顯示的第一個字就是空白鍵要送出的字，所以比對的是引擎目前顯示的候選。
        let candidates = ov.cangjieTrack?.candidates ?? []
        // 關閉倉頡學習時，顯示的順序必須就是碼表順序。
        if !engine.configuration.learnsCangjieOrder,
           candidates != Array(engine.cangjie.candidates(for: engine.buffer).prefix(engine.configuration.maxVisibleCandidates)) {
            return Violation(
                invariant: "CangjieCommitPreservation",
                message: "學習關閉時 '\(engine.buffer)' 的候選必須是碼表順序；實得 \(candidates)。",
                path: path
            )
        }
        // 反查開啟時空白鍵屬於反查，倉頡首選的送出由 ReadingLookupIsolation 與關閉後的狀態涵蓋。
        if engine.readingLookup == nil, let first = candidates.first {
            var copy = engine
            let effect = copy.handle(.space)
            if snippetPrefersEnglish(engine) {
                // 片段裡英文優先：空白鍵送原字母加一格空格，而且那一格不可收合。
                // 浮窗的第一個字仍是「先按 Shift+空白 聚焦再按空白」會送出的那個字。
                var focused = engine
                focused.handle(.shiftSpace)
                let focusedEffect = focused.handle(.space)
                if effect.committedCore != engine.buffer
                    || effect.committedText != engine.buffer + " "
                    || effect.commitKind != .rawEnglish
                    || copy.pendingAutoSpace
                    || copy.state != .idle || !copy.buffer.isEmpty
                    || focusedEffect.committedCore != first
                    || focusedEffect.commitKind != .chinese
                    || focused.state != .idle {
                    return Violation(
                        invariant: "CangjieCommitPreservation",
                        message: "片段裡 '\(engine.buffer)' 的空白鍵應送出原字母加空格、Shift+空白 再按空白應送出 '\(first)'；實得 '\(effect.committedText ?? "nil")' 與 '\(focusedEffect.committedCore ?? "nil")'。",
                        path: path + [.space]
                    )
                }
            } else if effect.committedCore != first || effect.commitKind != .chinese || copy.state != .idle || !copy.buffer.isEmpty {
                return Violation(
                    invariant: "CangjieCommitPreservation",
                    message: "Expected SPACE on '\(engine.buffer)' to commit '\(first)' as Chinese and return to idle; got committedCore='\(effect.committedCore ?? "nil")', state=\(copy.state.rawValue).",
                    path: path + [.space]
                )
            }
        }
    case .composingEnglishOnly:
        guard !engine.buffer.isEmpty,
              !engine.cangjie.hasCandidatesOrPrefix(for: engine.buffer),
              let ov = overlay,
              ov.cangjieTrack == nil else {
            return Violation(
                invariant: "DualTrackConsistency",
                message: "composingEnglishOnly must hold non-empty non-Cangjie buffer and nil cangjieTrack (buffer='\(engine.buffer)').",
                path: path
            )
        }
    case .selectingCandidate:
        let candidates = engine.currentOverlay?.cangjieTrack?.candidates ?? []
        guard !candidates.isEmpty,
              candidates.indices.contains(engine.selectedCandidateIndex),
              let ov = overlay,
              ov.cangjieTrack != nil else {
            return Violation(
                invariant: "DualTrackConsistency",
                message: "selectingCandidate must hold valid candidate index (buffer='\(engine.buffer)', index=\(engine.selectedCandidateIndex)).",
                path: path
            )
        }

        let focused = candidates[engine.selectedCandidateIndex]
        if engine.readingLookup == nil {
            var copy = engine
            let effect = copy.handle(.space)
            if effect.committedCore != focused || effect.commitKind != .chinese || copy.state != .idle || !copy.buffer.isEmpty {
                return Violation(
                    invariant: "CangjieCommitPreservation",
                    message: "Expected SPACE while selecting on '\(engine.buffer)' to commit focused '\(focused)' and return to idle; got committedCore='\(effect.committedCore ?? "nil")', state=\(copy.state.rawValue).",
                    path: path + [.space]
                )
            }
        }
    }

    // The overlay must never point its highlight outside the lists it shows.
    if let ov = overlay {
        let englishFocusValid = ov.englishTrack.predictions.isEmpty
            ? ov.englishTrack.selectedIndex == 0
            : ov.englishTrack.predictions.indices.contains(ov.englishTrack.selectedIndex)
        let cangjieFocusValid = ov.cangjieTrack.map {
            $0.candidates.isEmpty ? $0.selectedIndex == 0 : $0.candidates.indices.contains($0.selectedIndex)
        } ?? true
        if !englishFocusValid || !cangjieFocusValid || ov.englishTrack.typed != engine.buffer {
            return Violation(
                invariant: "DualTrackConsistency",
                message: "Overlay focus or typed text out of step with the engine (buffer='\(engine.buffer)', englishIndex=\(ov.englishTrack.selectedIndex), cangjieIndex=\(ov.cangjieTrack?.selectedIndex ?? -1)).",
                path: path
            )
        }
    }

    if engine.configuration.mixedModeEnabled,
       engine.state == .composingDual || engine.state == .composingEnglishOnly {
        if engine.english.isKnownShortExactWord(
            engine.buffer,
            includeDeveloperTerms: engine.configuration.developerVocabularyEnabled
        ) {
            let firstPrediction = overlay?.englishTrack.predictions.first
            if firstPrediction?.lowercased() != engine.buffer.lowercased() {
                return Violation(
                    invariant: "ShortWordTabExactMatch",
                    message: "Short exact English word '\(engine.buffer)' must rank 1st in predictions; got '\(firstPrediction ?? "nil")'.",
                    path: path
                )
            }
            if engine.selectedEnglishIndex == 0, engine.readingLookup == nil {
                var tabCopy = engine
                let tabEffect = tabCopy.handle(.tab)
                // 片段裡的英文不附尾端空格，也不留可收合的空格；其餘不變。
                let expectedSuffix = engine.buffer.lowercased() + (inSnippet(engine) ? "" : " ")
                if tabEffect.committedCore?.lowercased() != engine.buffer.lowercased()
                    || !(tabEffect.committedText?.lowercased().hasSuffix(expectedSuffix) ?? false)
                    || tabCopy.pendingAutoSpace == inSnippet(engine)
                    || tabCopy.state != .idle {
                    return Violation(
                        invariant: "ShortWordTabExactMatch",
                        message: "TAB on short exact word '\(engine.buffer)' at default selection must commit '\(expectedSuffix)' with pendingAutoSpace=\(!inSnippet(engine)) and return to idle.",
                        path: path + [.tab]
                    )
                }
            }
        }
    }

    if let violation = checkCandidateOrder(engine: engine, path: path) {
        return violation
    }

    if let violation = checkReadingLookupState(engine: engine, path: path) {
        return violation
    }

    return nil
}

/// `CandidateOrderIsPermutation`：學習只重排候選，不增減。倉頡軌必須是碼表該碼候選的
/// 一個排列，反查面板的每一列必須是候選清單本頁那一段，而候選清單是索引那一串的排列。
func checkCandidateOrder(engine: InputEngine, path: [KeyInput]) -> Violation? {
    func violation(_ message: String) -> Violation {
        Violation(invariant: "CandidateOrderIsPermutation", message: message, path: path)
    }

    if let track = engine.currentOverlay?.cangjieTrack {
        let table = engine.cangjie.candidates(for: engine.buffer)
        guard table.count <= engine.configuration.maxVisibleCandidates else {
            return violation("碼 '\(engine.buffer)' 的候選數 \(table.count) 超過可選數量，重排後會有字選不到。")
        }
        if track.candidates.sorted() != table.sorted() {
            return violation("碼 '\(engine.buffer)' 的候選 \(track.candidates) 不是碼表 \(table) 的排列。")
        }
    }

    guard engine.readingLookup != nil else {
        return nil
    }
    let ordered = engine.readingLookupCandidates()
    let indexed = indexReadingCandidates(engine)
    if ordered.map(\.character).sorted() != indexed.map(\.character).sorted() {
        return violation("反查候選不是索引那一串的排列（\(ordered.count) 對 \(indexed.count)）。")
    }
    if let panel = engine.currentReadingLookupPanel {
        let start = (panel.page - 1) * ReadingLookup.rowsPerPage
        let expected = ordered.dropFirst(start).prefix(ReadingLookup.rowsPerPage).map(\.character)
        if panel.rows.map(\.character) != Array(expected) {
            return violation("面板第 \(panel.page) 頁的列與候選清單那一段不符。")
        }
    }
    return nil
}

/// 索引原本的候選順序，沒有套用學習。用來證明學習只是重排。
func indexReadingCandidates(_ engine: InputEngine) -> [ReadingCandidate] {
    guard let lookup = engine.readingLookup,
          case .syllable(let query) = ReadingIndex.shared.interpret(lookup.keys, scheme: lookup.scheme) else {
        return []
    }
    return ReadingIndex.shared.candidates(for: query, version: engine.configuration.cangjieVersion)
}

/// ReadingLookupIsolation 的狀態部分：面板內容自洽，而且 Esc 只清掉反查。
func checkReadingLookupState(engine: InputEngine, path: [KeyInput]) -> Violation? {
    func violation(_ message: String, path: [KeyInput] = path) -> Violation {
        Violation(invariant: "ReadingLookupIsolation", message: message, path: path)
    }

    guard let lookup = engine.readingLookup else {
        if engine.currentReadingLookupPanel != nil {
            return violation("反查未開啟時不得有面板。")
        }
        return nil
    }

    guard let panel = engine.currentReadingLookupPanel else {
        return violation("反查開啟時必須有面板（keys='\(lookup.keys)'）。")
    }

    let perPage = ReadingLookup.rowsPerPage
    guard panel.rows.count <= perPage,
          panel.pageCount >= 1,
          (1...panel.pageCount).contains(panel.page),
          panel.rows.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }),
          panel.scheme == lookup.scheme,
          panel.isSelecting == lookup.isSelecting,
          panel.cangjieVersion == engine.configuration.cangjieVersion,
          (panel.status == .results) == !panel.rows.isEmpty,
          panel.page == panel.pageCount || panel.rows.count == perPage else {
        return violation(
            "面板自身不一致（rows=\(panel.rows.count), page=\(panel.page)/\(panel.pageCount), status=\(panel.status.rawValue)）。"
        )
    }

    if panel.rows.isEmpty {
        if panel.focusedRow != nil || panel.pageCount != 1 {
            return violation("沒有候選時焦點必為 nil 且只有一頁。")
        }
    } else if panel.focusedRow != lookup.focusIndex - (panel.page - 1) * perPage
                || !panel.rows.indices.contains(panel.focusedRow ?? -1) {
        return violation(
            "焦點與頁碼不相符（focusIndex=\(lookup.focusIndex), focusedRow=\(panel.focusedRow.map(String.init) ?? "nil"), page=\(panel.page)）。"
        )
    }

    // Esc 從任何開啟狀態回到「沒開過反查」的同一個狀態：底下的組字一個欄位都沒動。
    var escaped = engine
    let effect = escaped.handle(.escape)
    if escaped.readingLookup != nil
        || !effect.handled
        || effect.committedText != nil
        || effect.deletedBackwardCount != 0
        || EquivalenceKey(engine: escaped, ignoringReadingLookup: true)
            != EquivalenceKey(engine: engine, ignoringReadingLookup: true) {
        return violation(
            "ESC 沒有完整還原（state=\(escaped.state.rawValue), buffer='\(escaped.buffer)', committed='\(effect.committedText ?? "nil")'）。",
            path: path + [.escape]
        )
    }

    return nil
}

/// ReadingLookupIsolation 的轉移部分：反查開啟期間每個按鍵都 handled，不是選字就什麼都不動。
func checkReadingLookupTransition(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect
) -> String? {
    guard let lookup = before.readingLookup else {
        return nil
    }
    if !effect.handled {
        return "反查開啟時按鍵 '\(key.tokenName)' 被放行給宿主，宿主會收到查詢字元。"
    }
    if case .capsLock = key {
        // 亮燈先關閉反查再走原本的 Caps Lock 流程，那條路徑由其他不變量涵蓋。
        return after.readingLookup == nil || before.capsLockEnabled == after.capsLockEnabled
            ? nil
            : "Caps Lock 改變時必須關閉反查。"
    }

    let unchanged = before.state == after.state
        && before.buffer == after.buffer
        && before.selectedCandidateIndex == after.selectedCandidateIndex
        && before.selectedEnglishIndex == after.selectedEnglishIndex
        && before.documentText == after.documentText
        && before.pendingAutoSpace == after.pendingAutoSpace

    guard effect.commitKind != .none else {
        if effect.committedText != nil || effect.deletedBackwardCount != 0 {
            return "'\(key.tokenName)' 沒有選字卻送出文字或回刪。"
        }
        return unchanged ? nil : "'\(key.tokenName)' 沒有選字卻改動了被暫停的組字。"
    }

    // 唯一會送出文字的路徑是選字：送出面板上對應列的字，然後回到閒置。
    guard let panel = before.currentReadingLookupPanel else {
        return "反查開啟時缺少面板，無法比對選字結果。"
    }
    let expected: String?
    switch key {
    case .enter, .space:
        expected = panel.focusedRow.flatMap { panel.rows.indices.contains($0) ? panel.rows[$0].character : nil }
    case .readingLookupPick(let row):
        expected = panel.rows.indices.contains(row - 1) ? panel.rows[row - 1].character : nil
    case .character(let ch):
        guard lookup.isSelecting, let row = ch.wholeNumberValue, (1...ReadingLookup.rowsPerPage).contains(row) else {
            return "'\(key.tokenName)' 不是選字鍵卻送出了文字。"
        }
        expected = panel.rows.indices.contains(row - 1) ? panel.rows[row - 1].character : nil
    default:
        return "'\(key.tokenName)' 不是選字鍵卻送出了文字。"
    }
    if effect.commitKind != .chinese
        || effect.committedCore != expected
        || effect.deletedBackwardCount != 0
        || after.readingLookup != nil
        || after.state != .idle
        || !after.buffer.isEmpty {
        return "選字鍵 '\(key.tokenName)' 應送出 '\(expected ?? "nil")' 並回到閒置；實得 '\(effect.committedCore ?? "nil")'、state=\(after.state.rawValue)。"
    }
    return nil
}

/// 拿掉反悔欄位的 StepEffect，用來比對「開啟但沒有紀錄」與「關閉」兩種設定的結果。
func strippingRevert(_ effect: StepEffect) -> StepEffect {
    StepEffect(
        state: effect.state,
        buffer: effect.buffer,
        committedText: effect.committedText,
        committedCore: effect.committedCore,
        commitKind: effect.commitKind,
        deletedBackwardCount: effect.deletedBackwardCount,
        overlay: effect.overlay,
        readingLookupPanel: effect.readingLookupPanel,
        handled: effect.handled,
        documentText: effect.documentText,
        pendingAutoSpace: effect.pendingAutoSpace
    )
}

/// 「另一邊」的參考答案：用真實按鍵重播出來的引擎，或片段裡算得出來的預期結果。
enum OtherSide {
    case replayed(engine: InputEngine, effect: StepEffect)
    case expected(text: String, documentText: String)

    var committedText: String? {
        switch self {
        case .replayed(_, let effect):
            return effect.committedText
        case .expected(let text, _):
            return text
        }
    }
}

/// RevertEqualsAlternative：反悔後的引擎等同當初直接按另一個鍵，連按兩次回到反悔前；
/// 紀錄只會由空白或 Tab 的送出產生，而且只活一個按鍵；設定關閉時永遠沒有紀錄。
/// 回傳違反時的說明與要接在路徑後面的按鍵。
func checkRevertTransition(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect
) -> (message: String, extraKeys: [KeyInput])? {
    if !before.configuration.revertEnabled {
        if after.revertRecord != nil || effect.revertible || effect.revertPreview != nil {
            return ("設定關閉時 '\(key.tokenName)' 仍產生了反悔紀錄。", [])
        }
        // 開啟設定、但沒有紀錄可用時，同一個按鍵的結果必須與關閉時完全相同。
        var enabled = before
        enabled.configuration.revertEnabled = true
        let enabledEffect = enabled.handle(key)
        if strippingRevert(enabledEffect) != effect
            || EquivalenceKey(engine: enabled, ignoringRevertRecord: true) != EquivalenceKey(engine: after) {
            return ("沒有反悔紀錄時，開啟設定改變了 '\(key.tokenName)' 的結果。", [])
        }
        return nil
    }

    // 「另一邊」用真實按鍵重建，不讀引擎的紀錄：中文是空白鍵（片段裡英文優先時先按
    // Shift+空白 聚焦再按空白），英文是 Tab（聚焦候選時先按 Esc）。片段裡黏中時空白鍵
    // 送的是中文，英文那一邊的「原字母加一格空格」沒有單一按鍵做得到，
    // 改由本檢查器依片段語境的規格直接算出預期結果，仍然不讀引擎的紀錄。
    func commitOtherSide(
        of committedKind: CommitKind,
        englishStyle: RevertEnglishStyle,
        from engine: InputEngine
    ) -> OtherSide {
        var reference = engine
        if committedKind == .chinese {
            if englishStyle == .rawWithSpace {
                return .expected(
                    text: engine.buffer + " ",
                    documentText: engine.documentText + engine.buffer + " "
                )
            }
            if reference.state == .selectingCandidate {
                reference.handle(.escape)
            }
            let effect = reference.handle(.tab)
            return .replayed(engine: reference, effect: effect)
        }
        if snippetPrefersEnglish(engine) {
            reference.handle(.shiftSpace)
        }
        let effect = reference.handle(.space)
        return .replayed(engine: reference, effect: effect)
    }

    // 片段裡按空白、又沒聚焦候選時，英文那一邊是原字母加一格空格。
    let focusedBefore = before.state == .selectingCandidate
    let englishStyle: RevertEnglishStyle =
        key == .tab || focusedBefore || !inSnippet(before) ? .tab : .rawWithSpace

    let isRevert = key == .shiftSpace && before.revertRecord != nil
    let couldRecord = before.configuration.mixedModeEnabled
        && !before.isLiteralLayer
        && before.readingLookup == nil
        && (before.state == .composingDual || before.state == .selectingCandidate)
        && (key == .space || key == .tab)
    // 標點寬度對調的紀錄只能由鍵面有兩種寬度的標點鍵產生，與緩衝、片段、模式都無關。
    let widthKey = punctuationWidthKey(key)
    let couldRecordWidth = !before.isLiteralLayer && before.readingLookup == nil && widthKey != nil

    guard let record = after.revertRecord else {
        if effect.revertible || effect.revertPreview != nil {
            return ("'\(key.tokenName)' 的結果標示可反悔，引擎卻沒有紀錄。", [])
        }
        if isRevert {
            return ("有反悔紀錄時 Shift+空白 沒有對調。", [])
        }
        // 兩邊都有東西可送時一定要留下紀錄。
        if couldRecord, before.currentOverlay?.cangjieTrack?.candidates.isEmpty == false,
           let committed = effect.committedText {
            let other = commitOtherSide(of: effect.commitKind, englishStyle: englishStyle, from: before)
            if let otherText = other.committedText, otherText != committed {
                return ("'\(key.tokenName)' 送出 '\(committed)'，另一邊是 '\(otherText)'，卻沒有留下反悔紀錄。", [])
            }
        }
        // 有兩種寬度的標點鍵只要送出了東西，寬度就一定換得掉。
        if couldRecordWidth, effect.committedText != nil {
            return ("標點鍵 '\(key.tokenName)' 送出了文字，卻沒有留下可對調寬度的紀錄。", [])
        }
        return nil
    }

    guard effect.handled, effect.revertible,
          effect.committedText == record.committedText,
          effect.committedCore == record.committedCore else {
        return ("'\(key.tokenName)' 的結果與反悔紀錄不一致。", [])
    }
    // 每種對調各自的一致性：送出的種類、要不要提示、另一邊會是什麼。
    switch record.kind {
    case .track(let committedSide, _):
        guard effect.revertPreview == record.alternativeCore,
              (committedSide == .chinese) == (effect.commitKind == .chinese) else {
            return ("'\(key.tokenName)' 的結果與中英對調的紀錄不一致。", [])
        }
    case .punctuationWidth(let recordedKey, let swapToFullwidth):
        if let message = checkPunctuationWidthEffect(
            key: key,
            effect: effect,
            record: record,
            recordedKey: recordedKey,
            swapToFullwidth: swapToFullwidth,
            couldRecordWidth: couldRecordWidth,
            isRevert: isRevert
        ) {
            return (message, [])
        }
    }
    if isRevert {
        // 這一步本身就是對調，產生它的那次送出已經在下面檢查過兩次對調。
        // 它留下的紀錄指向更早的狀態（還是原本那個按鍵之前），所以下面的比對不適用。
        return nil
    }
    guard record.snapshot.state == before.state,
          record.snapshot.buffer == before.buffer,
          record.snapshot.selectedCandidateIndex == before.selectedCandidateIndex,
          record.snapshot.selectedEnglishIndex == before.selectedEnglishIndex,
          record.snapshot.documentText == before.documentText,
          record.snapshot.pendingAutoSpace == before.pendingAutoSpace,
          record.snapshot.usageHistory == before.usageHistory,
          record.snapshot.snippet == before.snippet else {
        return ("'\(key.tokenName)' 留下的反悔紀錄不是這個按鍵之前的狀態。", [])
    }

    if case .punctuationWidth(let recordedKey, let swapToFullwidth) = record.kind {
        if let message = checkPunctuationWidthSwap(
            before: before,
            after: after,
            record: record,
            recordedKey: recordedKey,
            swapToFullwidth: swapToFullwidth
        ) {
            return (message, [.shiftSpace])
        }
        return checkSwapsBack(after: after)
    }

    guard case .track(_, let recordedEnglishStyle) = record.kind else {
        return ("'\(key.tokenName)' 留下的反悔紀錄種類無法判讀。", [])
    }
    guard couldRecord else {
        return ("'\(key.tokenName)' 不是雙軌或選字中的空白、Tab，卻留下了中英對調的紀錄。", [])
    }
    guard recordedEnglishStyle == englishStyle else {
        return ("'\(key.tokenName)' 留下的紀錄記錯了英文那一邊的送出方式。", [])
    }
    let other = commitOtherSide(of: effect.commitKind, englishStyle: englishStyle, from: before)
    var reverted = after
    let revertEffect = reverted.handle(.shiftSpace)
    let sharedOK = revertEffect.deletedBackwardCount == record.committedText.count
        && revertEffect.revertible
        && revertEffect.revertPreview == effect.committedCore
        && trackSide(of: reverted.revertRecord) == trackSide(of: record)?.opposite
    switch other {
    case .replayed(let otherEngine, let otherEffect):
        if !sharedOK
            || EquivalenceKey(engine: reverted, ignoringRevertRecord: true)
                != EquivalenceKey(engine: otherEngine, ignoringRevertRecord: true)
            || revertEffect.committedText != otherEffect.committedText
            || revertEffect.committedCore != otherEffect.committedCore
            || revertEffect.commitKind != otherEffect.commitKind {
            return (
                "反悔後應等同直接按另一個鍵（送出 '\(otherEffect.committedText ?? "nil")'、文件 '\(otherEngine.documentText)'）；實得送出 '\(revertEffect.committedText ?? "nil")'、文件 '\(reverted.documentText)'。",
                [.shiftSpace]
            )
        }
    case .expected(let text, let documentText):
        // 片段裡黏中時的英文那一邊：原字母加一格空格、不補前導空格、黏中解除、不留學習紀錄。
        if !sharedOK
            || revertEffect.committedText != text
            || revertEffect.committedCore != before.buffer
            || revertEffect.commitKind != .rawEnglish
            || reverted.documentText != documentText
            || reverted.pendingAutoSpace
            || reverted.state != .idle || !reverted.buffer.isEmpty
            || reverted.usageHistory != before.usageHistory
            || !inSnippet(reverted) || reverted.snippet.stickyChinese {
            return (
                "反悔後應送出 '\(text)' 並解除黏中（文件 '\(documentText)'）；實得送出 '\(revertEffect.committedText ?? "nil")'、文件 '\(reverted.documentText)'。",
                [.shiftSpace]
            )
        }
    }

    return checkSwapsBack(after: after)
}

/// 紀錄目前指向中英的哪一邊；不是中英對調就回 nil。
func trackSide(of record: RevertRecord?) -> RevertSide? {
    if case .track(let side, _) = record?.kind {
        return side
    }
    return nil
}

/// 鍵面有兩種寬度的標點鍵，寬度對調只由這些鍵產生。
func punctuationWidthKey(_ key: KeyInput) -> Character? {
    guard case .character(let ch) = key, PunctuationMapper.fullwidthForm(for: ch) != nil else {
        return nil
    }
    return ch
}

/// 送出同一個全形標點的那一個鍵。角引號有自己的 `Ctrl` 鍵，其餘查 `Ctrl` 全形標點表。
func directFullwidthKey(for ch: Character) -> KeyInput? {
    switch ch {
    case "[":
        return .ctrlLeftBracket
    case "]":
        return .ctrlRightBracket
    case "{":
        return .ctrlShiftLeftBracket
    case "}":
        return .ctrlShiftRightBracket
    default:
        return KeyInput.ctrlFullwidthTokens.values.contains(ch) ? .ctrlFullwidth(ch) : nil
    }
}

/// 連按兩次 Shift+空白 必須回到反悔前的同一個狀態（含紀錄）。
func checkSwapsBack(after: InputEngine) -> (message: String, extraKeys: [KeyInput])? {
    var again = after
    again.handle(.shiftSpace)
    again.handle(.shiftSpace)
    if EquivalenceKey(engine: again) != EquivalenceKey(engine: after) {
        return ("連按兩次 Shift+空白 沒有回到反悔前的狀態（文件 '\(again.documentText)'）。", [.shiftSpace, .shiftSpace])
    }
    return nil
}

/// 標點寬度對調的紀錄與送出效果是否相符：種類、兩個寬度，以及不顯示提示。
/// 這一步本身是對調時，按的是 `SHIFT_SPACE`，所以不檢查鍵。
func checkPunctuationWidthEffect(
    key: KeyInput,
    effect: StepEffect,
    record: RevertRecord,
    recordedKey: Character,
    swapToFullwidth: Bool,
    couldRecordWidth: Bool,
    isRevert: Bool
) -> String? {
    guard let fullwidth = PunctuationMapper.fullwidthForm(for: recordedKey) else {
        return "寬度對調的紀錄記了一個沒有全形寫法的鍵 '\(recordedKey)'。"
    }
    let halfwidth = String(recordedKey)
    guard effect.commitKind == .punctuation,
          effect.revertPreview == nil,
          record.committedCore == (swapToFullwidth ? halfwidth : fullwidth),
          record.alternativeCore == (swapToFullwidth ? fullwidth : halfwidth) else {
        return "'\(key.tokenName)' 的結果與寬度對調的紀錄不一致，或是標點對調顯示了提示。"
    }
    guard isRevert || (couldRecordWidth && recordedKey == punctuationWidthKey(key)) else {
        return "'\(key.tokenName)' 不是有兩種寬度的標點鍵，卻留下了寬度對調的紀錄。"
    }
    return nil
}

/// 對調之後的文件與「只換那一個字元」。預期的文件由本檢查器依規格算（把最後一個字元
/// 換成另一個寬度），不讀引擎的紀錄；空緩衝又不在片段裡時另外比對真實按鍵
/// （全形是 `Ctrl` 加同一個鍵，半形是 `Option` 加同一個鍵）。
func checkPunctuationWidthSwap(
    before: InputEngine,
    after: InputEngine,
    record: RevertRecord,
    recordedKey: Character,
    swapToFullwidth: Bool
) -> String? {
    var reverted = after
    let revertEffect = reverted.handle(.shiftSpace)
    let expectedDocument = String(after.documentText.dropLast()) + record.alternativeCore
    guard revertEffect.revertible,
          revertEffect.revertPreview == nil,
          revertEffect.commitKind == .punctuation,
          revertEffect.committedCore == record.alternativeCore,
          revertEffect.deletedBackwardCount == record.committedText.count,
          reverted.documentText == expectedDocument,
          // 只換那個標點：文件以外的每個欄位都與這個按鍵之後相同，前綴與學習紀錄都沒動。
          EquivalenceKey(engine: reverted, ignoringRevertRecord: true, ignoringDocumentText: true)
              == EquivalenceKey(engine: after, ignoringRevertRecord: true, ignoringDocumentText: true) else {
        return "對調寬度後文件應為 '\(expectedDocument)'，而且只換那一個字元；實得 '\(reverted.documentText)'。"
    }

    guard before.buffer.isEmpty, !inSnippet(before) else {
        return nil
    }
    let directKey: KeyInput? = swapToFullwidth ? directFullwidthKey(for: recordedKey) : .optionLiteral(recordedKey)
    guard let directKey else {
        return nil
    }
    var direct = before
    direct.handle(directKey)
    if EquivalenceKey(engine: reverted, ignoringRevertRecord: true) != EquivalenceKey(engine: direct) {
        return "對調寬度後應等同直接按 '\(directKey.tokenName)'（文件 '\(direct.documentText)'）；實得 '\(reverted.documentText)'。"
    }
    return nil
}

func checkTransitionInvariants(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect,
    pathAfter: [KeyInput]
) -> Violation? {
    if let violation = checkRevertTransition(before: before, key: key, after: after, effect: effect) {
        return Violation(
            invariant: "RevertEqualsAlternative",
            message: violation.message,
            path: pathAfter + violation.extraKeys
        )
    }

    // DualTrackConsistency (shell contract): the IMK shell only sees the StepEffect, so it
    // must describe the engine exactly, and the engine's document mirror must equal what
    // the shell will have inserted.
    if let message = checkReadingLookupTransition(before: before, key: key, after: after, effect: effect) {
        return Violation(invariant: "ReadingLookupIsolation", message: message, path: pathAfter)
    }

    // LearningOffIgnoresHistory：三個學習都關閉時，已存的紀錄既不影響結果也不會增加。
    if !before.configuration.learnsEnglishPredictions,
       !before.configuration.learnsCangjieOrder,
       !before.configuration.learnsReadingLookupOrder,
       !before.usageHistory.isEmpty,
       // 換掉學習紀錄會讓反悔紀錄作廢，這一步的 Shift+空白 就不是同一個動作了。
       // 反悔的結果由 RevertEqualsAlternative 對到「直接按另一個鍵」，而那個鍵在這裡有檢查。
       !(key == .shiftSpace && before.revertRecord != nil) {
        var blank = before
        blank.usageHistory = UsageHistory()
        let blankEffect = blank.handle(key)
        if blankEffect != effect {
            return Violation(
                invariant: "LearningOffIgnoresHistory",
                message: "學習關閉時 '\(key.tokenName)' 的結果仍受已存紀錄影響。",
                path: pathAfter
            )
        }
        if after.usageHistory != before.usageHistory || !blank.usageHistory.isEmpty {
            return Violation(
                invariant: "LearningOffIgnoresHistory",
                message: "學習關閉時 '\(key.tokenName)' 仍寫進了學習紀錄。",
                path: pathAfter
            )
        }
    }

    if effect.state != after.state
        || effect.buffer != after.buffer
        || effect.documentText != after.documentText
        || effect.pendingAutoSpace != after.pendingAutoSpace
        || effect.overlay != after.currentOverlay
        || effect.readingLookupPanel != after.currentReadingLookupPanel {
        return Violation(
            invariant: "DualTrackConsistency",
            message: "StepEffect for '\(key.tokenName)' disagrees with the engine state after the key.",
            path: pathAfter
        )
    }
    if effect.handled {
        let expectedDocument = String(before.documentText.dropLast(effect.deletedBackwardCount)) + (effect.committedText ?? "")
        if after.documentText != expectedDocument
            || effect.deletedBackwardCount > before.documentText.count
            || (effect.committedText == nil) != (effect.commitKind == .none) {
            return Violation(
                invariant: "DualTrackConsistency",
                message: "Handled key '\(key.tokenName)' left the document mirror at '\(after.documentText)' but the committed text implies '\(expectedDocument)'.",
                path: pathAfter
            )
        }
    } else if !before.buffer.isEmpty || !after.buffer.isEmpty || effect.committedText != nil || effect.deletedBackwardCount != 0 {
        // A key forwarded to the client mid-composition would let the client drop or move
        // its marked text while the engine keeps the buffer.
        return Violation(
            invariant: "DualTrackConsistency",
            message: "Key '\(key.tokenName)' was passed through while composing (buffer='\(before.buffer)').",
            path: pathAfter
        )
    }

    // BackspaceReversibility: whenever an alphanumeric key appends to the composing buffer,
    // an immediate BKSP must restore the exact prior state and buffer.
    if (before.state == .idle || before.state == .composingDual || before.state == .composingEnglishOnly),
       case .character(let ch) = key,
       (AutoSpacer.isASCIILetter(ch) || AutoSpacer.isASCIIDigit(ch)),
       (after.state == .composingDual || after.state == .composingEnglishOnly),
       after.buffer.count == before.buffer.count + 1 {
        var reversed = after
        _ = reversed.handle(.backspace)
        if reversed.state != before.state
            || reversed.buffer != before.buffer
            || reversed.documentText != before.documentText
            || reversed.pendingAutoSpace != before.pendingAutoSpace {
            return Violation(
                invariant: "BackspaceReversibility",
                message: "BKSP after '\(key.tokenName)' failed to restore prior state/buffer (expected \(before.state.rawValue):'\(before.buffer)', got \(reversed.state.rawValue):'\(reversed.buffer)').",
                path: pathAfter + [.backspace]
            )
        }
    }

    // NoDoubleAutoSpace
    if effect.commitKind == .chinese
        || effect.commitKind == .english
        || effect.commitKind == .rawEnglish
        || effect.commitKind == .number {
        // 反悔會先回刪上一次送出的文字，前導空格要對照回刪後的前文。
        if let prevLast = before.documentText.dropLast(effect.deletedBackwardCount).last,
           AutoSpacer.isWhitespace(prevLast),
           effect.committedText?.hasPrefix(" ") == true {
            return Violation(
                invariant: "NoDoubleAutoSpace",
                message: "Inserted leading space after existing whitespace.",
                path: pathAfter
            )
        }
        if effect.committedText?.contains("  ") == true {
            return Violation(
                invariant: "NoDoubleAutoSpace",
                message: "Single commit produced double spaces: '\(effect.committedText ?? "")'.",
                path: pathAfter
            )
        }
    }

    if before.state == .idle,
       before.readingLookup == nil,
       before.pendingAutoSpace,
       before.documentText.hasSuffix(" "),
       !before.documentText.hasSuffix("  "),
       case .character(let ch) = key,
       AutoSpacer.spaceCollapsingPunctuation.contains(ch) {
        let effectivePrev = before.documentText.dropLast().last
        let englishPrev = effectivePrev.map {
            AutoSpacer.isASCIILetter($0) || AutoSpacer.isASCIIDigit($0) || AutoSpacer.closingASCIIPunctuation.contains($0)
        } ?? false
        if englishPrev {
            if effect.deletedBackwardCount != 1
                || after.documentText.hasSuffix(" \(ch)") {
                return Violation(
                    invariant: "NoDoubleAutoSpace",
                    message: "Closing punctuation '\(ch)' after pending auto-space failed to collapse trailing space (doc='\(after.documentText)').",
                    path: pathAfter
                )
            }
        }
    }

    return nil
}

func runModelCheck(maxDepth: Int) -> Int32 {
    for checked in checkedConfigurations {
        let status = runModelCheck(maxDepth: maxDepth, checked: checked)
        if status != 0 {
            return status
        }
    }
    return 0
}

func runModelCheck(maxDepth: Int, checked: CheckedConfiguration) -> Int32 {
    let startTime = DispatchTime.now()
    let alphabet = alphabetTokens.compactMap(KeyInput.parse(token:))
    precondition(alphabet.count == alphabetTokens.count)

    let initial = InputEngine(configuration: checked.configuration, usageHistory: checked.usageHistory)
    var queue: [QueueNode] = [QueueNode(engine: initial, path: [], depth: 0)]
    var visited = Set<EquivalenceKey>([EquivalenceKey(engine: initial)])
    var transitionsChecked = 0
    var statesExplored = 0

    var head = 0
    while head < queue.count {
        let node = queue[head]
        head += 1
        statesExplored += 1

        if let violation = checkStateInvariants(engine: node.engine, path: node.path) {
            printViolation(violation, statesExplored: statesExplored, transitionsChecked: transitionsChecked)
            return 1
        }

        if node.depth >= maxDepth {
            continue
        }

        for key in alphabet {
            var nextEngine = node.engine
            let effect = nextEngine.handle(key)
            transitionsChecked += 1
            let nextPath = node.path + [key]

            if let violation = checkTransitionInvariants(
                before: node.engine,
                key: key,
                after: nextEngine,
                effect: effect,
                pathAfter: nextPath
            ) {
                printViolation(violation, statesExplored: statesExplored, transitionsChecked: transitionsChecked)
                return 1
            }

            let eqKey = EquivalenceKey(engine: nextEngine)
            if !visited.contains(eqKey) {
                visited.insert(eqKey)
                queue.append(QueueNode(engine: nextEngine, path: nextPath, depth: node.depth + 1))
            }
        }
    }

    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
    print(String(
        format: "PASS [%@]: Checked %d distinct abstract states and %d transitions (maxDepth=%d, alphabet=%d) in %.1f ms. All 9 invariants hold.",
        checked.label,
        statesExplored,
        transitionsChecked,
        maxDepth,
        alphabet.count,
        elapsedMs
    ))
    return 0
}

func printViolation(_ violation: Violation, statesExplored: Int, transitionsChecked: Int) {
    let pathStr = violation.path.map(\.tokenName).joined(separator: " ")
    fputs("FAIL [\(violation.invariant)]: \(violation.message)\n", stderr)
    fputs("Shortest counterexample (\(violation.path.count) steps): \(pathStr)\n", stderr)
    fputs("Explored \(statesExplored) states, \(transitionsChecked) transitions before failure.\n", stderr)
}

var maxDepth = 4
let args = Array(CommandLine.arguments.dropFirst())
var idx = 0
while idx < args.count {
    if args[idx] == "--max-depth" {
        idx += 1
        if idx < args.count, let parsed = Int(args[idx]), parsed >= 1 {
            maxDepth = parsed
        } else {
            fputs("Invalid --max-depth value\n", stderr)
            exit(2)
        }
    } else {
        fputs("Unknown argument: \(args[idx])\n", stderr)
        exit(2)
    }
    idx += 1
}

exit(runModelCheck(maxDepth: maxDepth))
