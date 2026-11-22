import Foundation
import GoshawkCore

struct EquivalenceKey: Hashable {
    let state: EngineStateKind
    let buffer: String
    let selectedCandidateIndex: Int
    let selectedEnglishIndex: Int
    let pendingAutoSpace: Bool
    let capsLockEnabled: Bool
    let chineseContinuation: String?
    /// 疊加層（讀音反查或符號面板）連同它的查詢、分頁與焦點。
    let layer: InputLayer?
    let readingScheme: PhoneticScheme
    let documentText: String
    /// 鏡像之前有沒有看不到的前文會改變落單的全形右方括號留下哪一種紀錄，所以是狀態的一部分。
    let mirrorIsClipped: Bool
    let usageHistory: UsageHistory
    /// 有沒有反悔紀錄會改變下一個 Shift+空白 的結果，所以是狀態的一部分。
    let revertRecord: RevertRecord?
    /// 片段語境改變空白、Tab、數字與標點的結果，所以是狀態的一部分。
    let snippet: SnippetContext

    /// `ignoringLayer` 用來證明 Esc 只清掉疊加層，底下的組字完全沒動過。
    /// `ignoringRevertRecord` 用來比對反悔後的引擎與直接按另一個鍵的引擎。
    /// `ignoringDocumentText` 用來證明標點寬度對調只動文件裡那一個字元，其他欄位都沒變。
    init(
        engine: InputEngine,
        ignoringLayer: Bool = false,
        ignoringRevertRecord: Bool = false,
        ignoringDocumentText: Bool = false
    ) {
        self.revertRecord = ignoringRevertRecord ? nil : engine.revertRecord
        self.snippet = engine.snippet
        self.usageHistory = engine.usageHistory
        self.layer = ignoringLayer ? nil : engine.layer
        self.readingScheme = engine.configuration.readingScheme
        self.state = engine.state
        self.buffer = engine.buffer
        self.selectedCandidateIndex = engine.selectedCandidateIndex
        self.selectedEnglishIndex = engine.selectedEnglishIndex
        self.pendingAutoSpace = engine.pendingAutoSpace
        self.capsLockEnabled = engine.capsLockEnabled
        self.chineseContinuation = engine.chineseContinuation
        // Repeated Backspace can expose any earlier character in this bounded replay.
        self.documentText = ignoringDocumentText ? "" : engine.documentText
        self.mirrorIsClipped = engine.mirrorIsClipped
    }
}

struct QueueNode {
    let engine: InputEngine
    let path: [KeyInput]
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
    // 符號面板只放開關鍵：面板裡的數字、方向鍵、空白、Enter、Tab、Esc 與翻頁都已經在上面。
    "SYMBOLS",
    // 反引號開關行內程式片段語境，片段裡空白、Tab、數字與標點的結果都不同。
    "BACKTICK",
    // 方括號鍵打出成對符號：右方括號要跟隨游標前未關閉的開頭，開頭也可能來自符號面板
    //（「符號」分頁第一列的【、「標點」分頁第二頁的「，以及預存紀錄裡的「）。
    "LBRACKET", "RBRACKET"
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
/// 反查的字取自 `a8`（ㄇㄚ）查得到的候選；最近使用的符號放三個不在初始清單裡的：
/// 兩個收尾標點夾著一個成對符號的開頭。「最近使用」分頁一開始就有紀錄、超過一頁，
/// 選第一列就會走到收合空格那條路。初始清單裡沒有方括號鍵打得出來的成對符號，
/// 所以開頭放在第二列：`SYMBOLS DIGIT2 RBRACKET` 三個按鍵就走到「從面板選出開頭再用
/// 右方括號關上」，後面還留得下切換與直選的按鍵。
let learnedHistory = UsageHistory(
    englishWords: ["idea", "this", "issue", "about", "doctor", "that"],
    cangjieChoices: [("a", "曰"), ("a", "曰"), ("no", "欠"), ("no", "欠")],
    readingChoices: ["馬", "馬", "嗎"],
    recentSymbols: ["，", "「", "）"]
)

/// 只留下最近使用的符號，三類候選學習清空。最近使用不受學習開關管，
/// LearningOffIgnoresHistory 換掉紀錄時要保留它。
func keepingOnlyRecentSymbols(_ history: UsageHistory) -> UsageHistory {
    UsageHistory(recentSymbols: history.symbols)
}

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
        // 疊加層開啟時空白鍵屬於那一層，倉頡首選的送出由 LayerIsolation 與關閉後的狀態涵蓋。
        if engine.layer == nil, let first = candidates.first {
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
        if engine.layer == nil {
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
            if engine.selectedEnglishIndex == 0, engine.layer == nil {
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

    if let violation = checkLayerState(engine: engine, path: path) {
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

/// LayerIsolation 的狀態部分：兩個疊加層各自只在開著時有面板，面板內容自洽，
/// 而且 Esc 只清掉疊加層。
func checkLayerState(engine: InputEngine, path: [KeyInput]) -> Violation? {
    func violation(_ message: String, path: [KeyInput] = path) -> Violation {
        Violation(invariant: "LayerIsolation", message: message, path: path)
    }

    let message: String?
    switch engine.layer {
    case nil:
        if engine.currentReadingLookupPanel != nil || engine.currentSymbolPanelContent != nil {
            return violation("疊加層未開啟時不得有面板。")
        }
        return nil
    case .readingLookup(let lookup):
        if engine.currentSymbolPanelContent != nil {
            return violation("反查開啟時不得有符號面板的內容。")
        }
        message = checkReadingLookupPanel(engine: engine, lookup: lookup)
    case .symbolPanel(let panel):
        if engine.currentReadingLookupPanel != nil {
            return violation("符號面板開啟時不得有反查面板的內容。")
        }
        message = checkSymbolPanelContent(engine: engine, panel: panel)
    }
    if let message {
        return violation(message)
    }

    // Esc 從任何開啟狀態回到「沒開過疊加層」的同一個狀態：底下的組字一個欄位都沒動。
    var escaped = engine
    let effect = escaped.handle(.escape)
    if escaped.layer != nil
        || !effect.handled
        || effect.committedText != nil
        || effect.deletedBackwardCount != 0
        || EquivalenceKey(engine: escaped, ignoringLayer: true)
            != EquivalenceKey(engine: engine, ignoringLayer: true) {
        return violation(
            "ESC 沒有完整還原（state=\(escaped.state.rawValue), buffer='\(escaped.buffer)', committed='\(effect.committedText ?? "nil")'）。",
            path: path + [.escape]
        )
    }

    return nil
}

/// 「最近使用」分頁該有的清單，由本檢查器依規格直接算，不讀引擎的結果：
/// 紀錄裡在符號表內的符號（最近的在前、不重複），後面接初始符號裡還沒出現的，至多兩頁。
func expectedRecentSymbols(_ history: UsageHistory) -> [String] {
    var result: [String] = []
    for symbol in history.symbols where SymbolTable.shared.entry(for: symbol) != nil && !result.contains(symbol) {
        result.append(symbol)
    }
    for entry in SymbolTable.shared.entries where entry.isInitialRecent && !result.contains(entry.symbol) {
        result.append(entry.symbol)
    }
    return Array(result.prefix(2 * SymbolPanel.rowsPerPage))
}

/// 符號面板的內容自洽：清單只含符號表裡的符號且不重複，列、焦點與頁碼對得上，
/// 每一列的名稱與分組就是符號表那一筆。
func checkSymbolPanelContent(engine: InputEngine, panel: SymbolPanel) -> String? {
    guard let content = engine.currentSymbolPanelContent else {
        return "符號面板開啟時必須有面板內容。"
    }
    let table = SymbolTable.shared
    let entries = engine.symbolPanelEntries()
    let expectedSymbols: [String]
    switch panel.tab {
    case .recent:
        expectedSymbols = expectedRecentSymbols(engine.usageHistory)
    case .punctuation, .symbols:
        // 符號表的每個符號只屬於「標點」或「符號」其中一個分頁，兩個分頁各自照檔案順序。
        expectedSymbols = table.entries.filter { $0.tab == panel.tab }.map(\.symbol)
    }
    guard entries.map(\.symbol) == expectedSymbols,
          table.entries.allSatisfy({ $0.tab == .punctuation || $0.tab == .symbols }),
          Set(expectedSymbols).count == expectedSymbols.count,
          entries.allSatisfy({ table.entry(for: $0.symbol) == $0 }) else {
        return "符號面板「\(content.tab.rawValue)」分頁的清單與符號表或最近使用紀錄不符。"
    }

    let perPage = SymbolPanel.rowsPerPage
    let start = (content.page - 1) * perPage
    guard content.tab == panel.tab,
          content.pageCount == max(1, (entries.count + perPage - 1) / perPage),
          (1...content.pageCount).contains(content.page),
          content.page == panel.pageIndex + 1,
          content.rows.count <= perPage,
          content.page == content.pageCount || content.rows.count == perPage,
          content.rows.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }),
          content.rows.map(\.symbol) == Array(entries.dropFirst(start).prefix(perPage).map(\.symbol)),
          zip(content.rows, entries.dropFirst(start)).allSatisfy({ row, entry in
              row.name == entry.name && row.englishName == entry.englishName
                  && row.group == entry.group && row.englishGroup == entry.englishGroup
          }) else {
        return "符號面板自身不一致（rows=\(content.rows.count), page=\(content.page)/\(content.pageCount)）。"
    }
    if content.rows.isEmpty {
        return content.focusedRow == nil && panel.focusIndex == 0 ? nil : "符號面板沒有列時焦點必為 nil。"
    }
    if content.focusedRow != panel.focusIndex - start || !content.rows.indices.contains(content.focusedRow ?? -1) {
        return "符號面板的焦點與頁碼不相符（focusIndex=\(panel.focusIndex), page=\(content.page)）。"
    }
    return nil
}

/// 反查面板的內容自洽。
func checkReadingLookupPanel(engine: InputEngine, lookup: ReadingLookup) -> String? {
    guard let panel = engine.currentReadingLookupPanel else {
        return "反查開啟時必須有面板（keys='\(lookup.keys)'）。"
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
        return "面板自身不一致（rows=\(panel.rows.count), page=\(panel.page)/\(panel.pageCount), status=\(panel.status.rawValue)）。"
    }

    if panel.rows.isEmpty {
        if panel.focusedRow != nil || panel.pageCount != 1 {
            return "沒有候選時焦點必為 nil 且只有一頁。"
        }
    } else if panel.focusedRow != lookup.focusIndex - (panel.page - 1) * perPage
                || !panel.rows.indices.contains(panel.focusedRow ?? -1) {
        return "焦點與頁碼不相符（focusIndex=\(lookup.focusIndex), focusedRow=\(panel.focusedRow.map(String.init) ?? "nil"), page=\(panel.page)）。"
    }
    return nil
}

/// LayerIsolation 的轉移部分：疊加層開啟期間每個按鍵都 handled，不是選取就什麼都不動，
/// 兩個疊加層不會互相切換；選取送出的是面板上對應的那一列。
func checkLayerTransition(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect
) -> String? {
    // 最近使用只由符號面板的選取改動，其他任何按鍵（不論有沒有疊加層）都不得寫進去。
    let isSymbolPick: Bool
    if case .symbolPanel = before.layer, effect.commitKind != .none {
        isSymbolPick = true
    } else {
        isSymbolPick = false
    }
    if !isSymbolPick, after.usageHistory.symbols != before.usageHistory.symbols {
        return "'\(key.tokenName)' 不是符號面板的選取，卻改動了最近使用的符號。"
    }

    guard let layer = before.layer else {
        guard after.layer != nil else {
            return nil
        }
        // 開啟疊加層的那一步：只多出疊加層，底下的組字、文件、待收合空格與片段語境都不動。
        // `handle` 一進來就清掉舊的反悔紀錄與接詞提示，所以拿清掉這兩樣的開啟前狀態來比。
        var settled = before
        settled.discardRevertRecord()
        settled.dismissChineseContinuation()
        if key != .toggleReadingLookup && key != .toggleSymbolPanel {
            return "'\(key.tokenName)' 不是開關鍵卻開啟了疊加層。"
        }
        if !effect.handled || effect.committedText != nil || effect.deletedBackwardCount != 0
            || EquivalenceKey(engine: after, ignoringLayer: true) != EquivalenceKey(engine: settled, ignoringLayer: true) {
            return "'\(key.tokenName)' 開啟疊加層時改動了底下的組字（state=\(after.state.rawValue), buffer='\(after.buffer)', document='\(after.documentText)'）。"
        }
        return nil
    }
    if !effect.handled {
        return "疊加層開啟時按鍵 '\(key.tokenName)' 被放行給宿主，宿主會收到面板的按鍵。"
    }
    // 開著一層時不會換成另一層，另一層的開關鍵也不得動到這一層。
    switch (layer, after.layer) {
    case (.readingLookup, .symbolPanel), (.symbolPanel, .readingLookup):
        return "'\(key.tokenName)' 把一個疊加層換成了另一個。"
    case (.readingLookup, _) where key == .toggleSymbolPanel,
         (.symbolPanel, _) where key == .toggleReadingLookup:
        if after.layer != before.layer {
            return "'\(key.tokenName)' 是另一個疊加層的開關鍵，卻改動了開著的這一層。"
        }
    // 開著的那一層再按自己的開關鍵就關閉；底下沒動由後面的非選取檢查負責。
    case (.readingLookup, _) where key == .toggleReadingLookup,
         (.symbolPanel, _) where key == .toggleSymbolPanel:
        if after.layer != nil {
            return "疊加層開著時再按 '\(key.tokenName)' 必須關閉它。"
        }
    default:
        break
    }
    if case .capsLock = key {
        // 亮燈先關閉疊加層再走原本的 Caps Lock 流程，那條路徑由其他不變量涵蓋。
        return after.layer == nil || before.capsLockEnabled == after.capsLockEnabled
            ? nil
            : "Caps Lock 改變時必須關閉疊加層。"
    }

    let unchanged = before.state == after.state
        && before.buffer == after.buffer
        && before.selectedCandidateIndex == after.selectedCandidateIndex
        && before.selectedEnglishIndex == after.selectedEnglishIndex
        && before.documentText == after.documentText
        && before.pendingAutoSpace == after.pendingAutoSpace
        && before.snippet == after.snippet
        && before.usageHistory == after.usageHistory

    guard effect.commitKind != .none else {
        if effect.committedText != nil || effect.deletedBackwardCount != 0 {
            return "'\(key.tokenName)' 沒有選取卻送出文字或回刪。"
        }
        if key == .tab, case .symbolPanel(let panel) = layer {
            // Tab 依「最近使用、標點、符號」的順序輪流，焦點回第一列。順序由本檢查器寫死，不讀引擎的。
            let order: [SymbolPanel.Tab] = [.recent, .punctuation, .symbols]
            let next = order[((order.firstIndex(of: panel.tab) ?? 0) + 1) % order.count]
            if after.symbolPanel != SymbolPanel(tab: next, focusIndex: 0) {
                return "符號面板在「\(panel.tab.rawValue)」分頁按 Tab 應切到「\(next.rawValue)」的第一列；實得 \(String(describing: after.symbolPanel))。"
            }
        }
        return unchanged ? nil : "'\(key.tokenName)' 沒有選取卻改動了被暫停的組字。"
    }

    switch layer {
    case .readingLookup(let lookup):
        return checkReadingLookupPick(before: before, key: key, after: after, effect: effect, lookup: lookup)
    case .symbolPanel:
        return checkSymbolPick(before: before, key: key, after: after, effect: effect)
    }
}

/// 從面板選出來會收合英文後自動補上那一格空格的符號。由本檢查器從收尾標點鍵的清單推出：
/// 各鍵的鍵面字元本身（半形寫法）與它的全形寫法（，。；：！？）」』），
/// 不呼叫引擎選取時用的那個判斷。
let closingSymbols = Set(
    AutoSpacer.spaceCollapsingPunctuation.map { String($0) }
        + AutoSpacer.spaceCollapsingPunctuation.compactMap(PunctuationMapper.fullwidthForm(for:))
)

/// 符號面板唯一會送出文字的路徑是選取：等同按下一個會直接打出那個符號的標點鍵。
/// 底下的組字怎麼結束與同一個狀態按逗號鍵相同，符號本身不補空格，
/// 只有收尾標點收合英文後自動補上的那一格，不留反悔紀錄，並記到最近使用的第一個。
func checkSymbolPick(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect
) -> String? {
    guard let content = before.currentSymbolPanelContent else {
        return "符號面板開啟時缺少面板內容，無法比對選取結果。"
    }
    let row: Int?
    switch key {
    case .enter, .space:
        row = content.focusedRow
    case .panelPick(let number):
        row = number - 1
    case .character(let ch):
        guard ch.isASCII, let number = ch.wholeNumberValue, (1...SymbolPanel.rowsPerPage).contains(number) else {
            return "'\(key.tokenName)' 不是選取鍵卻送出了文字。"
        }
        row = number - 1
    default:
        return "'\(key.tokenName)' 不是選取鍵卻送出了文字。"
    }
    guard let row, content.rows.indices.contains(row) else {
        return "'\(key.tokenName)' 對應的列不存在卻送出了文字。"
    }
    let symbol = content.rows[row].symbol

    // 底下的組字該送出什麼：拿開面板之前的那個狀態直接按逗號鍵，送出的文字去掉最後那個逗號。
    // 這裡重播的是逗號鍵，不經過面板的選取。
    var comma = before
    comma.dismissLayer()
    let commaEffect = comma.handle(.character(","))
    guard let commaText = commaEffect.committedText, commaText.last == "，" || commaText.last == "," else {
        return "對照用的逗號鍵沒有送出逗號（'\(commaEffect.committedText ?? "nil")'），無法比對選取結果。"
    }
    let settled = String(commaText.dropLast())
    // 符號自己前後都不補空格，所以送出的文字就是那段前綴接上符號。
    let text = effect.committedText ?? ""
    let textOK = text == settled + symbol

    let collapses = before.buffer.isEmpty
        && before.pendingAutoSpace
        && before.documentText.hasSuffix(" ")
        && closingSymbols.contains(symbol)

    if effect.commitKind != .punctuation
        || effect.committedCore != symbol
        || !textOK
        || effect.deletedBackwardCount != (collapses ? 1 : 0)
        || after.layer != nil
        || after.state != .idle
        || !after.buffer.isEmpty
        || after.pendingAutoSpace {
        return "選取鍵 '\(key.tokenName)' 應送出 '\(settled + symbol)' 並回到閒置；實得 '\(text)'、回刪 \(effect.deletedBackwardCount)、state=\(after.state.rawValue)。"
    }
    if after.revertRecord != nil || effect.revertible || effect.revertPreview != nil || effect.pairChoice != nil {
        return "符號面板的選取不得留下反悔紀錄。"
    }
    if before.snippet.isInside != after.snippet.isInside || after.snippet.stickyChinese {
        return "符號面板的選取不得開關片段語境，而且要解除黏中。"
    }
    // 結束組字時的學習紀錄照逗號鍵那條路徑記：三類候選學習與按逗號鍵之後完全相同。
    if after.usageHistory.english != comma.usageHistory.english
        || after.usageHistory.cangjie != comma.usageHistory.cangjie
        || after.usageHistory.reading != comma.usageHistory.reading {
        return "選取 '\(symbol)' 時結束組字留下的學習紀錄與同一狀態按逗號鍵不同。"
    }
    let recents = after.usageHistory.symbols
    if recents.first != symbol
        || Set(recents).count != recents.count
        || recents.count > UsageHistory.symbolCapacity
        || recents.dropFirst() != before.usageHistory.symbols.filter({ $0 != symbol }).prefix(recents.count - 1) {
        return "選取 '\(symbol)' 後最近使用應以它開頭、其餘順序不變且不重複；實得 \(recents)。"
    }
    return nil
}

/// 反查唯一會送出文字的路徑是選字：送出面板上對應列的字，然後回到閒置。
func checkReadingLookupPick(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect,
    lookup: ReadingLookup
) -> String? {
    guard let panel = before.currentReadingLookupPanel else {
        return "反查開啟時缺少面板，無法比對選字結果。"
    }
    let expected: String?
    switch key {
    case .enter, .space:
        expected = panel.focusedRow.flatMap { panel.rows.indices.contains($0) ? panel.rows[$0].character : nil }
    case .panelPick(let row):
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
        symbolPanel: effect.symbolPanel,
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
    // 成對切換被擋下的原因只能出現在一種按鍵上：紀錄是換不了的結尾時的 Shift+空白。
    // 那一步該不該帶由 `checkPairSwitchRefused` 驗，這裡驗其餘按鍵一律不帶。
    if effect.pairSwitchNotice != nil {
        let refusedCloser = key == .shiftSpace && before.revertRecord.map(closerCannotSwitch) == true
        if !refusedCloser {
            return ("'\(key.tokenName)' 不是被擋下的成對切換，效果卻帶著 \(String(describing: effect.pairSwitchNotice))。", [])
        }
    }
    if !before.configuration.revertEnabled {
        if after.revertRecord != nil || effect.revertible || effect.revertPreview != nil || effect.pairChoice != nil {
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

    let isRevert = isRevertKey(key, record: before.revertRecord)
    let couldRecord = before.configuration.mixedModeEnabled
        && !before.isLiteralLayer
        && before.layer == nil
        && (before.state == .composingDual || before.state == .selectingCandidate)
        && (key == .space || key == .tab)
    // 標點寬度對調的紀錄只能由鍵面有兩種寬度的標點鍵產生，與緩衝、片段、模式都無關。
    let widthKey = punctuationWidthKey(key)
    let couldRecordWidth = !before.isLiteralLayer && before.layer == nil && widthKey != nil

    guard let record = after.revertRecord else {
        if effect.revertible || effect.revertPreview != nil || effect.pairChoice != nil {
            return ("'\(key.tokenName)' 的結果標示可反悔，引擎卻沒有紀錄。", [])
        }
        if isRevert {
            // 只有換不了的成對結尾可以不對調：按鍵被吃掉，什麼都不動。中英與寬度對調不適用這一條。
            if let previous = before.revertRecord, closerCannotSwitch(previous) {
                return checkPairSwitchRefused(from: before, after: after, effect: effect).map { ($0, []) }
            }
            return ("有反悔紀錄時 '\(key.tokenName)' 沒有對調。", [])
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

    // 紀錄的文字就是這次送出的文字。只有剛打出來的成對結尾例外：紀錄記的是從開頭起的整段，
    // 所以改成「文件以紀錄文字結尾，而且紀錄文字以這次送出的文字結尾」。
    let recordMatchesCommit: Bool
    if case .pair(let pair) = record.kind, pair.side == .closer, pair.step == .typed {
        recordMatchesCommit = after.documentText.hasSuffix(record.committedText)
            && effect.committedText.map(record.committedText.hasSuffix) == true
    } else {
        recordMatchesCommit = effect.committedText == record.committedText
    }
    guard effect.handled, effect.revertible, recordMatchesCommit,
          effect.committedCore == record.committedCore else {
        return ("'\(key.tokenName)' 的結果與反悔紀錄不一致。", [])
    }
    // 每種對調各自的一致性：送出的種類、要不要提示、另一邊會是什麼。
    switch record.kind {
    case .track(let committedSide, _):
        guard effect.revertPreview == record.alternativeCore, effect.pairChoice == nil,
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
    case .pair(let pair):
        if let message = checkPairEffect(
            before: before,
            key: key,
            after: after,
            effect: effect,
            record: record,
            pair: pair,
            couldRecordWidth: couldRecordWidth
        ) {
            return (message, [])
        }
    case .unresolvedCloser:
        // 只能由剛打出來的右方括號留下：鏡像之前還有看不到的前文、本檢查器自己掃也找不到開頭，
        // 而且送出的是全形結尾。它不是切換的結果，所以這一步不能是反悔。
        guard !isRevert, couldRecordWidth, key == .character("]"), before.mirrorIsClipped,
              independentUnclosedOpener(in: before.documentText, afterLastBacktick: inSnippet(before)) == nil,
              effect.commitKind == .punctuation, effect.revertPreview == nil, effect.pairChoice == nil,
              record.committedCore == "」" else {
            return ("'\(key.tokenName)' 留下了「看不到開頭的結尾」紀錄，條件卻不符（鏡像之前有沒有看不到的前文：\(before.mirrorIsClipped)）。", [])
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

    if case .pair(let pair) = record.kind, pair.side == .opener {
        return checkOpenerCycle(before: before, after: after)
    }

    if case .pair = record.kind {
        return checkCloserCycle(after: after)
    }

    if case .unresolvedCloser = record.kind {
        // 末層的狀態不會再被展開，所以在這裡就把緊接的 Shift+空白 走一次：必須被吃掉並帶原因。
        var refused = after
        let refusedEffect = refused.handle(.shiftSpace)
        return checkPairSwitchRefused(from: after, after: refused, effect: refusedEffect).map { ($0, [.shiftSpace]) }
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

/// 數字直選選的是第幾種（0 起算）；不是直選就回 nil。條件由本檢查器自己判，不呼叫核心：
/// 紀錄在結尾側、上一步是一次 Shift+空白 切換，按的是不帶修飾鍵的 1 到 8。
func pickedPairKind(_ key: KeyInput, record: RevertRecord?) -> Int? {
    guard case .pair(let pair) = record?.kind, pair.side == .closer, pair.step == .cycled,
          case .character(let ch) = key else {
        return nil
    }
    return Array("12345678").firstIndex(of: ch)
}

/// 這個按鍵會不會被當成反悔：有紀錄時的 Shift+空白，或數字直選。
func isRevertKey(_ key: KeyInput, record: RevertRecord?) -> Bool {
    record != nil && (key == .shiftSpace || pickedPairKind(key, record: record) != nil)
}

/// 八種成對符號的開頭與結尾，順序就是編號。由本檢查器寫死，不讀核心的清單。
let pairSymbols: [(opener: Character, closer: Character)] = [
    ("「", "」"), ("[", "]"), ("『", "』"), ("《", "》"), ("〈", "〉"), ("【", "】"), ("“", "”"), ("‘", "’")
]

/// 游標前最近一個未關閉的開頭：它是第幾種，以及它在 `text` 裡是第幾個字元。
/// 與核心的做法不同：這裡從頭往後走，每一種各留一疊還開著的位置，結尾只關掉同一種最近的那個，
/// 最後取各疊頂端最靠近游標的。`afterLastBacktick` 用在片段裡，只看最後一個反引號之後。
func independentUnclosedOpener(in text: String, afterLastBacktick: Bool) -> (kind: Int, offset: Int)? {
    let characters = Array(text)
    let start = afterLastBacktick ? (characters.lastIndex(of: "`").map { $0 + 1 } ?? 0) : 0
    var open = Array(repeating: [Int](), count: pairSymbols.count)
    for offset in start..<characters.count {
        let ch = characters[offset]
        if let kind = pairSymbols.firstIndex(where: { $0.opener == ch }) {
            open[kind].append(offset)
        } else if let kind = pairSymbols.firstIndex(where: { $0.closer == ch }), !open[kind].isEmpty {
            open[kind].removeLast()
        }
    }
    return open.enumerated()
        .compactMap { kind, offsets in offsets.last.map { (kind: kind, offset: $0) } }
        .max { $0.offset < $1.offset }
}

/// PairClosure：右方括號一定關上游標前未關閉的那個開頭，而且之後的 Shift+空白 不會只換掉結尾：
/// 要嘛開頭與結尾一起換成同一種，要嘛文件不變。
/// 開頭由本檢查器自己掃前文鏡像得到，不呼叫核心的掃描。
func checkPairClosure(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect
) -> String? {
    // 右方括號鍵送出的結尾。半形層直出鍵面字元、疊加層開著時按鍵歸它，都不適用；
    // 一鍵反悔關閉時照樣適用。結束組字送出的字母與漢字不含括號，所以掃按鍵前的鏡像就夠了。
    if key == .character("]"), !before.isLiteralLayer, before.layer == nil, effect.committedText != nil {
        if let opener = independentUnclosedOpener(in: before.documentText, afterLastBacktick: inSnippet(before)) {
            let expected = String(pairSymbols[opener.kind].closer)
            if effect.committedCore != expected {
                return "游標前有未關閉的 '\(pairSymbols[opener.kind].opener)'，右方括號應送出 '\(expected)'；實得 '\(effect.committedCore ?? "nil")'。"
            }
            // 配到開頭的結尾必須留成對紀錄：留成寬度對調的紀錄，下一個 Shift+空白 就會只換結尾。
            if before.configuration.revertEnabled {
                guard case .pair(let pair) = after.revertRecord?.kind, pair.side == .closer else {
                    return "右方括號配到了開頭 '\(pairSymbols[opener.kind].opener)'，卻沒有留下結尾側的成對紀錄。"
                }
            }
        } else if effect.committedCore != "]" && effect.committedCore != "」" {
            return "游標前沒有未關閉的開頭，右方括號卻送出了 '\(effect.committedCore ?? "nil")'。"
        } else if before.configuration.revertEnabled, before.mirrorIsClipped, effect.committedCore == "」" {
            // 鏡像之前還有看不到的前文時，找不到開頭不等於沒有開頭。全形結尾留成寬度對調的紀錄，
            // 下一個 Shift+空白 就可能把某一對的結尾單獨換成半形。
            guard case .unresolvedCloser = after.revertRecord?.kind else {
                return "鏡像之前還有看不到的前文，右方括號送出的全形結尾卻沒有留下「看不到開頭的結尾」紀錄。"
            }
        }
    }

    // 上一個按鍵送出的結尾配到了開頭時，Shift+空白 之後那一對仍然同種：文件只可能在開頭與
    // 結尾兩個位置改變，而且改成同一種。開頭從文件與上一次送出的字元認，不讀紀錄記的整段。
    // 只在上一個按鍵是剛打出來的結尾時掃：切換過的內容可能含新種類的落單結尾，重掃會認到別的開頭；
    // 之後每一下由 `checkCloserCycle` 用同一個開頭位置驗。
    // 只適用右方括號留下的結尾側成對紀錄：右花括號鍵也會送出清單內的結尾，但它維持兩種寬度互換，
    // 只換結尾是它該有的結果。右方括號配到開頭卻留成寬度紀錄的情形，上面那一段已經擋下。
    if key == .shiftSpace,
       case .pair(let typed) = before.revertRecord?.kind, typed.side == .closer, typed.step == .typed,
       let closer = before.revertRecord?.committedCore, closer.count == 1,
       before.documentText.hasSuffix(closer),
       let closerKind = pairSymbols.firstIndex(where: { String($0.closer) == closer }),
       let opener = independentUnclosedOpener(
           in: String(before.documentText.dropLast()),
           afterLastBacktick: inSnippet(before)
       ),
       opener.kind == closerKind {
        let old = Array(before.documentText)
        let new = Array(after.documentText)
        let paired = new.count == old.count && pairSymbols.contains {
            $0.opener == new[opener.offset] && $0.closer == new[new.count - 1]
        }
        let restUnchanged = new.count == old.count && old.indices.allSatisfy {
            $0 == opener.offset || $0 == old.count - 1 || old[$0] == new[$0]
        }
        if !paired || !restUnchanged {
            return "Shift+空白 之後 '\(before.documentText)' 那一對不再成對，或改到了別的字元；實得 '\(after.documentText)'。"
        }
    }
    return nil
}

/// 成對紀錄與送出效果是否相符。左方括號留開頭側的紀錄，右方括號配到開頭時留結尾側的紀錄，
/// 整段與種類由本檢查器自己從文件認出來比對。
func checkPairEffect(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    effect: StepEffect,
    record: RevertRecord,
    pair: PairSwitch,
    couldRecordWidth: Bool
) -> String? {
    guard effect.commitKind == .punctuation, effect.revertPreview == nil else {
        return "'\(key.tokenName)' 留下成對紀錄，送出的卻不是標點，或是顯示了提示。"
    }
    // 選項列只在切換之後出現，內容就是紀錄上目前的種類。
    // 編號只在下一個數字會直選時顯示：結尾側，而且這一步是 Shift+空白 切換。
    let expectedChoice = pair.step == .typed
        ? nil
        : PairChoice(current: pair.current, digitsPick: pair.side == .closer && pair.step == .cycled)
    guard effect.pairChoice == expectedChoice else {
        return "'\(key.tokenName)' 的選項列與成對紀錄不一致：紀錄是 \(pair.current.rawValue)（\(pair.step)），效果是 \(String(describing: effect.pairChoice))。"
    }
    if pair.side == .opener {
        return checkOpenerPairRecord(before: before, key: key, after: after, record: record, pair: pair,
                                     couldRecordWidth: couldRecordWidth)
    }
    let pickedKind = pickedPairKind(key, record: before.revertRecord)
    if key == .shiftSpace || pickedKind != nil {
        // 切換留下的紀錄：上一筆是同一個起點的結尾側紀錄，整段等長、仍在文件尾端、兩端同種。
        // 開頭的位置與八種的順序由 `checkCloserCycle` 從剛打出來的那個狀態另外驗。
        // 數字直選留下的紀錄記成「選到的」，種類就是那個編號，下一個數字因此不再直選。
        guard let previousRecord = before.revertRecord,
              case .pair(let previous) = previousRecord.kind, previous.side == .closer,
              previous.origin == pair.origin, pair.step == (pickedKind == nil ? .cycled : .picked),
              let kind = pairSymbols.firstIndex(where: { $0.opener == pair.current.opener }),
              pickedKind == nil || pickedKind == kind,
              let origin = pairSymbols.firstIndex(where: { $0.opener == pair.origin.opener }) else {
            return "'\(key.tokenName)' 留下結尾側的成對紀錄，上一筆卻不是同一個起點的結尾側紀錄，或種類不是選的那一種。"
        }
        // Shift+空白 從上一筆的種類往後走一個。`checkCloserCycle` 只從剛打出來的狀態衍生八下，
        // 數字直選之後的那一下只有這裡看得到。
        if pickedKind == nil {
            guard let previousKind = pairSymbols.firstIndex(where: { $0.opener == previous.current.opener }),
                  kind == nextPairKind(after: previousKind, origin: origin) else {
                return "Shift+空白 應從 '\(previous.current.opener)' 換到循環上的下一種；實得 '\(pair.current.opener)'。"
            }
        }
        let symbols = pairSymbols[kind]
        let next = pairSymbols[nextPairKind(after: kind, origin: origin)].closer
        guard pair.current.closer == symbols.closer,
              record.committedText.count == previousRecord.committedText.count,
              after.documentText.hasSuffix(record.committedText),
              record.committedText.first == symbols.opener, record.committedText.last == symbols.closer,
              record.committedCore == String(symbols.closer),
              record.alternativeCore == String(next) else {
            return "切換後的成對紀錄應為兩端是 '\(symbols.opener)' 與 '\(symbols.closer)' 的整段、下一種的結尾 '\(next)'；實得 '\(record.committedText)' 與 '\(record.alternativeCore)'。"
        }
        return nil
    }
    guard key == .character("]"), couldRecordWidth,
          pair.side == .closer, pair.step == .typed, pair.origin == pair.current else {
        return "'\(key.tokenName)' 不是剛打出來的右方括號，卻留下了結尾側的成對紀錄。"
    }
    guard let opener = independentUnclosedOpener(
        in: String(after.documentText.dropLast()),
        afterLastBacktick: inSnippet(after)
    ) else {
        return "成對紀錄對應的開頭不在前文鏡像裡（文件 '\(after.documentText)'）。"
    }
    let symbols = pairSymbols[opener.kind]
    // 下一個種類：半形方括號先到角引號，其餘往後一個，最後一個接回第一個。
    let order = opener.kind == 1 ? [1, 0, 2, 3, 4, 5, 6, 7] : Array(0..<pairSymbols.count)
    let next = order[((order.firstIndex(of: opener.kind) ?? 0) + 1) % order.count]
    let span = String(Array(after.documentText)[opener.offset...])
    guard pair.current.opener == symbols.opener, pair.current.closer == symbols.closer,
          record.committedCore == String(symbols.closer),
          record.alternativeCore == String(pairSymbols[next].closer),
          record.committedText == span else {
        return "成對紀錄應為整段 '\(span)'、下一種的結尾 '\(pairSymbols[next].closer)'；實得 '\(record.committedText)' 與 '\(record.alternativeCore)'。"
    }
    return nil
}

/// 循環上的下一種。順序由本檢查器寫死：半形方括號起點先到角引號再往後走，
/// 其餘起點從自己的位置往後一個，最後一個接回第一個。
func nextPairKind(after current: Int, origin: Int) -> Int {
    let order = origin == 1
        ? [1, 0, 2, 3, 4, 5, 6, 7]
        : Array(origin..<pairSymbols.count) + Array(0..<origin)
    return order[((order.firstIndex(of: current) ?? 0) + 1) % order.count]
}

/// 開頭側的成對紀錄：只由左方括號鍵與它之後的切換產生，記的是文件最後那個開頭，
/// 下一種照循環順序。種類從文件上的字元認，不讀核心的清單。
func checkOpenerPairRecord(
    before: InputEngine,
    key: KeyInput,
    after: InputEngine,
    record: RevertRecord,
    pair: PairSwitch,
    couldRecordWidth: Bool
) -> String? {
    if key == .shiftSpace {
        guard case .pair(let previous) = before.revertRecord?.kind, previous.side == .opener,
              previous.origin == pair.origin, pair.step == .cycled else {
            return "Shift+空白 留下開頭側的成對紀錄，上一筆卻不是同一個起點的開頭側紀錄。"
        }
    } else {
        guard key == .character("["), couldRecordWidth, pair.step == .typed, pair.origin == pair.current else {
            return "'\(key.tokenName)' 不是剛打出來的左方括號，卻留下了開頭側的成對紀錄。"
        }
    }
    guard let last = after.documentText.last,
          let kind = pairSymbols.firstIndex(where: { $0.opener == last }),
          let origin = pairSymbols.firstIndex(where: { $0.opener == pair.origin.opener }) else {
        return "開頭側的成對紀錄對應的開頭不在文件尾端（文件 '\(after.documentText)'）。"
    }
    let next = pairSymbols[nextPairKind(after: kind, origin: origin)].opener
    guard pair.current.opener == last, pair.current.closer == pairSymbols[kind].closer,
          record.committedCore == String(last),
          record.alternativeCore == String(next) else {
        return "開頭側的成對紀錄應為 '\(last)'、下一種 '\(next)'；實得 '\(record.committedCore)' 與 '\(record.alternativeCore)'。"
    }
    return nil
}

/// 左方括號送出之後，把八種各走到一次：每一下只把文件最後那個字元換成該種類的開頭，
/// 回刪上一筆紀錄的整段，文件與紀錄以外的欄位都與送出後相同；八下之後回到原樣，
/// 從第一下之後起再按八下回到同一個狀態（含紀錄）。空緩衝又不在片段裡時，
/// 換到角引號、雙角引號與半形方括號的結果另外比對直接送出它們的那個鍵。
func checkOpenerCycle(before: InputEngine, after: InputEngine) -> (message: String, extraKeys: [KeyInput])? {
    guard let last = after.documentText.last,
          let origin = pairSymbols.firstIndex(where: { $0.opener == last }) else {
        return ("左方括號留下成對紀錄，文件尾端卻不是清單內的開頭（文件 '\(after.documentText)'）。", [])
    }
    let stem = String(after.documentText.dropLast())
    let settledAfter = EquivalenceKey(engine: after, ignoringRevertRecord: true, ignoringDocumentText: true)
    var directKeys: [Int: KeyInput] = [1: .optionLiteral("[")]
    if before.configuration.ctrlBracketsQuotesEnabled {
        directKeys[0] = .ctrlLeftBracket
        directKeys[2] = .ctrlShiftLeftBracket
    }

    var current = after
    var kind = origin
    var afterFirst = after
    for press in 1...pairSymbols.count {
        let presses = Array(repeating: KeyInput.shiftSpace, count: press)
        let previousLength = current.revertRecord?.committedText.count
        kind = nextPairKind(after: kind, origin: origin)
        let symbol = pairSymbols[kind].opener
        let effect = current.handle(.shiftSpace)
        guard effect.handled, effect.revertible, effect.revertPreview == nil,
              effect.commitKind == .punctuation,
              effect.committedCore == String(symbol),
              effect.deletedBackwardCount == previousLength,
              effect.pairChoice?.current.opener == symbol,
              effect.pairChoice?.digitsPick == false,
              current.documentText == stem + String(symbol),
              EquivalenceKey(engine: current, ignoringRevertRecord: true, ignoringDocumentText: true) == settledAfter else {
            return (
                "第 \(press) 下 Shift+空白 應把開頭換成 '\(symbol)'（文件 '\(stem + String(symbol))'），而且只換那一個字元；實得 '\(current.documentText)'。",
                presses
            )
        }
        if before.buffer.isEmpty, !inSnippet(before), let directKey = directKeys[kind] {
            var direct = before
            direct.handle(directKey)
            if EquivalenceKey(engine: current, ignoringRevertRecord: true) != EquivalenceKey(engine: direct) {
                return (
                    "換到 '\(symbol)' 應等同直接按 '\(directKey.tokenName)'（文件 '\(direct.documentText)'）；實得 '\(current.documentText)'。",
                    presses
                )
            }
        }
        if press == 1 {
            afterFirst = current
        }
    }
    let fullCircle = Array(repeating: KeyInput.shiftSpace, count: pairSymbols.count)
    if EquivalenceKey(engine: current, ignoringRevertRecord: true) != EquivalenceKey(engine: after, ignoringRevertRecord: true) {
        return ("連按八次 Shift+空白 沒有回到切換前的文件與狀態（文件 '\(current.documentText)'）。", fullCircle)
    }
    var again = afterFirst
    for _ in fullCircle {
        again.handle(.shiftSpace)
    }
    if EquivalenceKey(engine: again) != EquivalenceKey(engine: afterFirst) {
        return (
            "從第一次切換之後再按八次 Shift+空白 沒有回到同一個狀態（文件 '\(again.documentText)'）。",
            [.shiftSpace] + fullCircle
        )
    }
    return nil
}

/// 整段換不換得了：不超過上限、不跨行、不含附件占位字元。上限讀核心的常數，
/// 把它設成 0 關掉成對切換時，這裡的條文跟著變成「一律被吃掉」。
func pairSpanIsSwitchable(_ span: String) -> Bool {
    span.count <= InputEngine.pairSwitchSpanLimit
        && !span.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{FFFC}" }
}

/// 這筆紀錄是不是「換不了的結尾」：配到開頭但整段換不了，或是開頭可能在看不到的前文裡。
/// 只有這兩種紀錄之後的 Shift+空白 可以不對調，也只有它們可以帶被擋下的原因。
func closerCannotSwitch(_ record: RevertRecord) -> Bool {
    switch record.kind {
    case .pair(let pair):
        return pair.side == .closer && !pairSpanIsSwitchable(record.committedText)
    case .unresolvedCloser:
        return true
    case .track, .punctuationWidth:
        return false
    }
}

/// 右方括號配到開頭之後，把八種各走到一次：每一下只把開頭與結尾兩個字元換成該種類，
/// 回刪上一筆紀錄的整段、送出新的整段，文件與紀錄以外的欄位都與送出後相同；八下之後回到原樣，
/// 從第一下之後起再按八下回到同一個狀態（含紀錄）。開頭的位置由本檢查器從送出後的文件
/// 自己掃出來，只掃這一次：切換後的內容可能含新種類的落單結尾，重掃會認錯。
/// 整段換不了時改驗按鍵被吃掉。
func checkCloserCycle(after: InputEngine) -> (message: String, extraKeys: [KeyInput])? {
    let characters = Array(after.documentText)
    guard let opener = independentUnclosedOpener(
        in: String(characters.dropLast()),
        afterLastBacktick: inSnippet(after)
    ) else {
        return ("右方括號留下成對紀錄，文件上卻找不到它的開頭（文件 '\(after.documentText)'）。", [])
    }
    guard pairSpanIsSwitchable(String(characters[opener.offset...])) else {
        // 末層的狀態不會再被展開，所以在這裡就把緊接的 Shift+空白 走一次。
        var refused = after
        let refusedEffect = refused.handle(.shiftSpace)
        return checkPairSwitchRefused(from: after, after: refused, effect: refusedEffect).map { ($0, [.shiftSpace]) }
    }
    let origin = opener.kind
    let settledAfter = EquivalenceKey(engine: after, ignoringRevertRecord: true, ignoringDocumentText: true)

    var current = after
    var kind = origin
    var afterFirst = after
    for press in 1...pairSymbols.count {
        let presses = Array(repeating: KeyInput.shiftSpace, count: press)
        let previousLength = current.revertRecord?.committedText.count
        kind = nextPairKind(after: kind, origin: origin)
        let symbols = pairSymbols[kind]
        var expected = characters
        expected[opener.offset] = symbols.opener
        expected[expected.count - 1] = symbols.closer
        let expectedDocument = String(expected)
        let expectedSpan = String(expected[opener.offset...])
        let effect = current.handle(.shiftSpace)
        guard effect.handled, effect.revertible, effect.revertPreview == nil,
              effect.commitKind == .punctuation,
              effect.committedText == expectedSpan,
              effect.committedCore == String(symbols.closer),
              effect.deletedBackwardCount == previousLength,
              effect.deletedBackwardCount == expectedSpan.count,
              effect.pairChoice?.current.opener == symbols.opener,
              effect.pairChoice?.current.closer == symbols.closer,
              effect.pairChoice?.digitsPick == true,
              current.documentText == expectedDocument,
              EquivalenceKey(engine: current, ignoringRevertRecord: true, ignoringDocumentText: true) == settledAfter else {
            return (
                "第 \(press) 下 Shift+空白 應把那一對換成 '\(symbols.opener)' 與 '\(symbols.closer)'（文件 '\(expectedDocument)'），而且只換這兩個字元；實得 '\(current.documentText)'。",
                presses
            )
        }
        // 每一下切換之後數字都能直選：1 到 8 各試一次，結果等於循環到那一種（不比紀錄），
        // 而且選完之後同一個數字不再是反悔，等同沒有紀錄時按它。
        for picked in pairSymbols.indices {
            let digit = KeyInput.character(Character(String(picked + 1)))
            var pickedExpected = characters
            pickedExpected[opener.offset] = pairSymbols[picked].opener
            pickedExpected[pickedExpected.count - 1] = pairSymbols[picked].closer
            var chosen = current
            let pickEffect = chosen.handle(digit)
            guard pickEffect.handled, pickEffect.revertible, pickEffect.revertPreview == nil,
                  pickEffect.commitKind == .punctuation,
                  pickEffect.committedText == String(pickedExpected[opener.offset...]),
                  pickEffect.committedCore == String(pairSymbols[picked].closer),
                  pickEffect.deletedBackwardCount == expectedSpan.count,
                  pickEffect.pairChoice?.current.opener == pairSymbols[picked].opener,
                  pickEffect.pairChoice?.current.closer == pairSymbols[picked].closer,
                  pickEffect.pairChoice?.digitsPick == false,
                  chosen.documentText == String(pickedExpected),
                  EquivalenceKey(engine: chosen, ignoringRevertRecord: true, ignoringDocumentText: true) == settledAfter else {
                return (
                    "切換後按 \(picked + 1) 應把那一對換成 '\(pairSymbols[picked].opener)' 與 '\(pairSymbols[picked].closer)'（文件 '\(String(pickedExpected))'）；實得 '\(chosen.documentText)'。",
                    presses + [digit]
                )
            }
            var plain = chosen
            plain.discardRevertRecord()
            let plainEffect = plain.handle(digit)
            let againEffect = chosen.handle(digit)
            if againEffect != plainEffect || EquivalenceKey(engine: chosen) != EquivalenceKey(engine: plain) {
                return (
                    "直選之後再按 \(picked + 1) 應該是內容，不再選種類；實得文件 '\(chosen.documentText)'。",
                    presses + [digit, digit]
                )
            }
        }
        if press == 1 {
            afterFirst = current
        }
    }
    let fullCircle = Array(repeating: KeyInput.shiftSpace, count: pairSymbols.count)
    if EquivalenceKey(engine: current, ignoringRevertRecord: true) != EquivalenceKey(engine: after, ignoringRevertRecord: true) {
        return ("連按八次 Shift+空白 沒有回到成對切換前的文件與狀態（文件 '\(current.documentText)'）。", fullCircle)
    }
    var again = afterFirst
    for _ in fullCircle {
        again.handle(.shiftSpace)
    }
    if EquivalenceKey(engine: again) != EquivalenceKey(engine: afterFirst) {
        return (
            "從第一次成對切換之後再按八次 Shift+空白 沒有回到同一個狀態（文件 '\(again.documentText)'）。",
            [.shiftSpace] + fullCircle
        )
    }
    return nil
}

/// 成對符號的結尾換不了時（整段換不了，或開頭可能在看不到的前文裡），Shift+空白 被吃掉：
/// 不送出、不回刪，除了紀錄與接詞提示被清掉，引擎的每個欄位都與按鍵前相同。
func checkPairSwitchRefused(from before: InputEngine, after: InputEngine, effect: StepEffect) -> String? {
    var settled = before
    settled.discardRevertRecord()
    settled.dismissChineseContinuation()
    if !effect.handled || effect.committedText != nil || effect.deletedBackwardCount != 0
        || effect.revertible || effect.revertPreview != nil
        || EquivalenceKey(engine: after) != EquivalenceKey(engine: settled) {
        return "成對符號的結尾換不了時 Shift+空白 應被吃掉、文件不變；實得送出 '\(effect.committedText ?? "nil")'、文件 '\(after.documentText)'。"
    }
    if effect.pairSwitchNotice != .spanUnsupported {
        return "成對符號的結尾換不了時，效果應帶著原因 spanUnsupported；實得 \(String(describing: effect.pairSwitchNotice))。"
    }
    return nil
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
    // 左方括號送出的一定是清單內的開頭，只能留開頭側的成對紀錄：留成寬度紀錄的話，
    // Shift+空白 會退回兩種寬度互換，八種循環就沒了。沒配到開頭的右方括號仍留寬度紀錄。
    guard recordedKey != "[" else {
        return "左方括號留下的是寬度對調的紀錄，不是開頭側的成對紀錄。"
    }
    let halfwidth = String(recordedKey)
    guard effect.commitKind == .punctuation,
          effect.revertPreview == nil,
          effect.pairChoice == nil,
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

    if let message = checkPairClosure(before: before, key: key, after: after, effect: effect) {
        return Violation(invariant: "PairClosure", message: message, path: pathAfter)
    }

    // DualTrackConsistency (shell contract): the IMK shell only sees the StepEffect, so it
    // must describe the engine exactly, and the engine's document mirror must equal what
    // the shell will have inserted.
    if let message = checkLayerTransition(before: before, key: key, after: after, effect: effect) {
        return Violation(invariant: "LayerIsolation", message: message, path: pathAfter)
    }

    // LearningOffIgnoresHistory：三個學習都關閉時，已存的三類候選學習紀錄既不影響結果也不會增加。
    // 最近使用的符號不是候選學習、不受這三個開關管，所以換成空紀錄時保留它，比對時也只比那三類。
    let learningFreeBefore = keepingOnlyRecentSymbols(before.usageHistory)
    if !before.configuration.learnsEnglishPredictions,
       !before.configuration.learnsCangjieOrder,
       !before.configuration.learnsReadingLookupOrder,
       before.usageHistory != learningFreeBefore,
       // 換掉學習紀錄會讓反悔紀錄作廢，這一步的 Shift+空白 就不是同一個動作了。
       // 反悔的結果由 RevertEqualsAlternative 對到「直接按另一個鍵」，而那個鍵在這裡有檢查。
       !isRevertKey(key, record: before.revertRecord) {
        var blank = before
        blank.usageHistory = learningFreeBefore
        let blankEffect = blank.handle(key)
        if blankEffect != effect {
            return Violation(
                invariant: "LearningOffIgnoresHistory",
                message: "學習關閉時 '\(key.tokenName)' 的結果仍受已存紀錄影響。",
                path: pathAfter
            )
        }
        if after.usageHistory.english != before.usageHistory.english
            || after.usageHistory.cangjie != before.usageHistory.cangjie
            || after.usageHistory.reading != before.usageHistory.reading
            || blank.usageHistory != keepingOnlyRecentSymbols(blank.usageHistory)
            // 兩邊的最近使用從同一份出發、按同一個鍵，結果也必須相同。
            || blank.usageHistory.symbols != after.usageHistory.symbols {
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
        || effect.readingLookupPanel != after.currentReadingLookupPanel
        || effect.symbolPanel != after.currentSymbolPanelContent {
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
       before.layer == nil,
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
    var frontier = [QueueNode(engine: initial, path: [])]
    var visited = Set([EquivalenceKey(engine: initial)])
    var transitionsChecked = 0

    if let violation = checkStateInvariants(engine: initial, path: []) {
        printViolation(violation, statesExplored: visited.count, transitionsChecked: 0)
        return 1
    }

    for depth in 0..<maxDepth {
        var nextFrontier: [QueueNode] = []
        for node in frontier {
            for key in alphabet {
                var nextEngine = node.engine
                let effect = nextEngine.handle(key)
                let nextPath = node.path + [key]
                transitionsChecked += 1
                if let violation = checkTransitionInvariants(
                    before: node.engine, key: key, after: nextEngine, effect: effect, pathAfter: nextPath
                ) {
                    printViolation(violation, statesExplored: visited.count, transitionsChecked: transitionsChecked)
                    return 1
                }

                guard visited.insert(EquivalenceKey(engine: nextEngine)).inserted else { continue }
                if let violation = checkStateInvariants(engine: nextEngine, path: nextPath) {
                    printViolation(violation, statesExplored: visited.count, transitionsChecked: transitionsChecked)
                    return 1
                }
                // 末層的狀態已檢查完，不再保留整份引擎與按鍵路徑。
                if depth + 1 < maxDepth {
                    nextFrontier.append(QueueNode(engine: nextEngine, path: nextPath))
                }
            }
        }
        if nextFrontier.isEmpty { break }
        frontier = nextFrontier
    }

    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000.0
    print(String(
        format: "PASS [%@]: Checked %d distinct abstract states and %d transitions (maxDepth=%d, alphabet=%d) in %.1f ms. All 10 invariants hold.",
        checked.label,
        visited.count,
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
