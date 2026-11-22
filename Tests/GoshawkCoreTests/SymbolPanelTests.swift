import Foundation
import GoshawkCore
@testable import GoshawkVerifier
import Testing

/// 依序送出一串命令列代號，回傳每一步的效果。
@discardableResult
private func play(_ script: String, on engine: inout InputEngine) throws -> [StepEffect] {
    try script.split(separator: " ").map { token in
        engine.handle(try #require(KeyInput.parse(token: String(token)), "未知代號 \(token)"))
    }
}

private func played(
    _ script: String,
    configuration: EngineConfiguration = EngineConfiguration(),
    context: String = "",
    history: UsageHistory = UsageHistory()
) throws -> (engine: InputEngine, effects: [StepEffect]) {
    var engine = InputEngine(configuration: configuration, initialDocumentText: context, usageHistory: history)
    let effects = try play(script, on: &engine)
    return (engine, effects)
}

private func symbols(_ content: SymbolPanelContent?) -> String {
    (content?.rows ?? []).map(\.symbol).joined()
}

/// 初始的最近使用，順序照它們在符號表裡出現的順序。都是鍵盤直接打不出來的符號；
/// 方括號鍵打得出來的成對符號不列在這裡。
private let initialRecents = ["——", "……", "‧", "〔", "〕", "※", "→", "×", "±"]
/// 「標點」與「符號」分頁的第一頁。
private let punctuationFirstPage = "。．.，,、；;："
private let symbolsFirstPage = "【】〔〕［］｛｝〖"

@Suite("符號表")
struct SymbolTableTests {
    @Test("隨附的符號表通過載入驗證：欄位數正確、符號不重複，初始的最近使用是九個常用符號")
    func bundledTableIsValid() throws {
        let table = try SymbolTable.loadBundled()
        #expect(table.entries.count == 151)
        #expect(Set(table.entries.map(\.symbol)).count == table.entries.count)
        #expect(table.entries.allSatisfy { !$0.symbol.isEmpty && !$0.name.isEmpty && !$0.englishName.isEmpty })
        #expect(table.entries.filter(\.isInitialRecent).map(\.symbol) == initialRecents)
        // 方括號鍵與 Shift+空白 打得出來的八種成對符號不占初始的最近使用。
        let bracketKeyPairs: Set<String> = ["「", "」", "[", "]", "『", "』", "《", "》", "〈", "〉", "【", "】", "“", "”", "‘", "’"]
        #expect(bracketKeyPairs.isDisjoint(with: initialRecents))
        #expect(table.entries.first?.symbol == "。")
        #expect(table.entries.first?.group == "句號" && table.entries.first?.englishGroup == "Period")
        #expect(Set(table.entries.map(\.group)).count == 23)
        // 全形空格是一個符號，載入時不能被當成空白去掉。
        #expect(table.entry(for: "\u{3000}")?.name == "全形空格")
        #expect(table.entry(for: "【")?.englishName == "Left black lenticular bracket")
        #expect(SymbolTable.shared.entries == table.entries)
    }

    @Test("每個符號只屬於「標點」或「符號」分頁；標點分頁是十五種標準標點的全形與半形寫法")
    func entriesAreSplitIntoTwoTabs() throws {
        let table = try SymbolTable.loadBundled()
        let punctuation = table.entries(in: .punctuation)
        let others = table.entries(in: .symbols)
        #expect(punctuation.count == 40 && others.count == 111)
        #expect(table.entries(in: .recent).isEmpty)
        #expect(punctuation + others == table.entries)
        var groups: [String] = []
        for entry in punctuation where groups.last != entry.group { groups.append(entry.group) }
        #expect(groups == ["句號", "逗號", "頓號", "分號", "冒號", "引號", "夾注號", "問號", "驚嘆號",
                           "破折號", "刪節號", "書名號", "專名號", "間隔號", "連接號"])
        #expect(Set(others.map(\.group)).count == 8)
        #expect(String(punctuation.prefix(9).map(\.symbol).joined()) == punctuationFirstPage)
        #expect(String(others.prefix(9).map(\.symbol).joined()) == symbolsFirstPage)
        // 半形寫法也在標點分頁；反引號會開關片段語境，表裡沒有。
        for halfwidth in [".", ",", ";", ":", "\"", "'", "(", ")", "?", "!"] {
            #expect(table.entry(for: halfwidth)?.tab == .punctuation, "\(halfwidth)")
        }
        #expect(table.entry(for: "`") == nil)
        #expect(table.entry(for: "【")?.tab == .symbols && table.entry(for: "《")?.tab == .punctuation)
    }

    @Test("格式不對的符號表整份拒絕，錯誤指出是哪一行")
    func malformedTablesAreRejected() {
        func error(_ tsv: String) -> SymbolTable.ParseError? {
            do {
                _ = try SymbolTable(tsv: tsv)
                return nil
            } catch {
                return error as? SymbolTable.ParseError
            }
        }
        #expect(error("# 註解\n@組\tGroup\tpunctuation\n，\t逗號\tComma\n@另一組\tOther\tsymbols\n、\t頓號\tComma\t*\n") == nil)
        #expect(error("@組\tGroup\tsymbols\n，\t逗號\n") == .fieldCount(line: 2))
        #expect(error("@組\tGroup\tsymbols\n，\t逗號\tComma\t*\t多的\n") == .fieldCount(line: 2))
        #expect(error("@組\n，\t逗號\tComma\n") == .fieldCount(line: 1))
        // 分組列少了分頁那一欄，或多出一欄，都不收。
        #expect(error("@組\tGroup\n，\t逗號\tComma\n") == .fieldCount(line: 1))
        #expect(error("@組\tGroup\tsymbols\t多的\n") == .fieldCount(line: 1))
        #expect(error("@\tGroup\tsymbols\n") == .emptyField(line: 1))
        #expect(error("@組\t\tsymbols\n") == .emptyField(line: 1))
        // 分頁只能是 punctuation 或 symbols；「最近使用」不是符號表能指定的分頁。
        #expect(error("# 註解\n@組\tGroup\tother\n") == .unknownTab(line: 2))
        #expect(error("@組\tGroup\t\n") == .unknownTab(line: 1))
        #expect(error("@組\tGroup\trecent\n") == .unknownTab(line: 1))
        #expect(error("@組\tGroup\tPunctuation\n") == .unknownTab(line: 1))
        #expect(error("@組\tGroup\tsymbols\n\t逗號\tComma\n") == .emptyField(line: 2))
        #expect(error("@組\tGroup\tsymbols\n，\t\tComma\n") == .emptyField(line: 2))
        #expect(error("@組\tGroup\tsymbols\n，\t逗號\tComma\t+\n") == .unknownMarker(line: 2))
        #expect(error("，\t逗號\tComma\n") == .symbolBeforeGroup(line: 1))
        #expect(error("# 註解\n，\t逗號\tComma\n@組\tGroup\tsymbols\n") == .symbolBeforeGroup(line: 2))
        #expect(error("@組\tGroup\tpunctuation\n，\t逗號\tComma\n# 註解\n@另一組\tOther\tsymbols\n，\t另一個\tAgain\n")
                == .duplicateSymbol(line: 5, symbol: "，"))
    }

    @Test("分組列的第三欄決定符號列在哪個分頁，兩個分頁各自照檔案順序")
    func groupTabColumnAssignsEntries() throws {
        let table = try SymbolTable(tsv: "@甲\tA\tsymbols\n→\t箭頭\tArrow\n@乙\tB\tpunctuation\n，\t逗號\tComma\n@丙\tC\tsymbols\n★\t星\tStar\n")
        #expect(table.entries(in: .punctuation).map(\.symbol) == ["，"])
        #expect(table.entries(in: .symbols).map(\.symbol) == ["→", "★"])
        #expect(table.entry(for: "★")?.group == "丙" && table.entry(for: "★")?.tab == .symbols)
    }

    @Test("最近使用的清單：選過的在前、初始符號補在後面、不重複、至多兩頁，表外的符號略過")
    func recentEntries() throws {
        let table = try SymbolTable.loadBundled()
        #expect(table.recentEntries(history: []).map(\.symbol) == initialRecents)
        #expect(table.recentEntries(history: ["〕", "，", "不在表內", "，"]).map(\.symbol)
                == ["〕", "，"] + initialRecents.filter { $0 != "〕" })
        let many = table.entries.filter { !$0.isInitialRecent }.prefix(20).map(\.symbol)
        #expect(table.recentEntries(history: Array(many)).map(\.symbol) == Array(many.prefix(18)))
    }
}

@Suite("符號面板：開關與按鍵")
struct SymbolPanelKeyTests {
    @Test("代號 SYMBOLS 與 PICK_n 對應到符號面板開關與共用的點選鍵")
    func tokens() {
        #expect(KeyInput.parse(token: "SYMBOLS") == .toggleSymbolPanel)
        #expect(KeyInput.toggleSymbolPanel.tokenName == "SYMBOLS")
        #expect(KeyInput.parse(token: "PICK_3") == .panelPick(3))
        #expect(KeyInput.panelPick(3).tokenName == "PICK_3")
    }

    @Test("開啟時停在最近使用的第一列，底下的組字、文件、待收合空格與片段語境都不動")
    func openingLeavesCompositionAlone() throws {
        var engine = InputEngine(initialDocumentText: "前文")
        try play("BACKTICK i d TAB m y", on: &engine)
        let before = engine
        let effect = engine.handle(.toggleSymbolPanel)
        #expect(effect.handled && effect.committedText == nil && effect.deletedBackwardCount == 0)
        #expect(engine.symbolPanel == SymbolPanel(tab: .recent, focusIndex: 0))
        #expect(engine.readingLookup == nil)
        #expect(engine.state == before.state && engine.buffer == "my")
        #expect(engine.selectedCandidateIndex == before.selectedCandidateIndex)
        #expect(engine.selectedEnglishIndex == before.selectedEnglishIndex)
        #expect(engine.documentText == before.documentText)
        #expect(engine.pendingAutoSpace == before.pendingAutoSpace)
        #expect(engine.snippet == before.snippet && engine.snippet.isInside)
        #expect(effect.overlay == before.currentOverlay)
        let content = try #require(effect.symbolPanel)
        #expect(content.tab == .recent && content.focusedRow == 0 && content.page == 1 && content.pageCount == 1)
        #expect(content.rows.map(\.symbol) == initialRecents)
        #expect(content.rows.map(\.number) == Array(1...9))
        #expect(content.rows[7] == SymbolPanelContent.Row(
            number: 8, symbol: "×", name: "乘號", englishName: "Multiplication sign",
            group: "數學", englishGroup: "Mathematics"
        ))
        #expect(effect.readingLookupPanel == nil)
    }

    @Test("Caps Lock 亮燈或純英文層不開面板，快捷鍵交還宿主")
    func literalLayersPassThrough() throws {
        for script in ["CAPS_ON", "DBL_SHIFT"] {
            var (engine, _) = try played(script)
            let effect = engine.handle(.toggleSymbolPanel)
            #expect(!effect.handled && effect.symbolPanel == nil, "\(script)")
            #expect(engine.layer == nil, "\(script)")
        }
    }

    @Test("兩個疊加層不同時開：開著一個時另一個的開關鍵吃掉、不動；同一個開關鍵關閉")
    func layersAreMutuallyExclusive() throws {
        var lookup = try played("m y LOOKUP j").engine
        let lookupBefore = lookup.layer
        let onLookup = lookup.handle(.toggleSymbolPanel)
        #expect(onLookup.handled && onLookup.symbolPanel == nil && onLookup.readingLookupPanel != nil)
        #expect(lookup.layer == lookupBefore && lookup.symbolPanel == nil)

        var panel = try played("m y SYMBOLS DOWN").engine
        let panelBefore = panel.layer
        let onPanel = panel.handle(.toggleReadingLookup)
        #expect(onPanel.handled && onPanel.readingLookupPanel == nil && onPanel.symbolPanel?.focusedRow == 1)
        #expect(panel.layer == panelBefore && panel.readingLookup == nil)

        let closed = panel.handle(.toggleSymbolPanel)
        #expect(closed.handled && closed.symbolPanel == nil && panel.layer == nil)
        #expect(panel.buffer == "my" && panel.state == .composingDual)
    }

    @Test("數字一律直選本頁那一列，不必先按方向鍵；那一列不存在就吃掉", arguments: [
        ("SYMBOLS 1", "——"), ("SYMBOLS 9", "±"), ("SYMBOLS TAB 5", ","), ("SYMBOLS TAB PGDN 1", ":"),
        ("SYMBOLS TAB TAB 1", "【"), ("SYMBOLS TAB TAB PGDN 2", "／")
    ])
    func digitsPickDirectly(script: String, expected: String) throws {
        let (engine, effects) = try played(script)
        #expect(effects.last?.committedText == expected)
        #expect(effects.last?.committedCore == expected)
        #expect(effects.last?.commitKind == .punctuation)
        #expect(engine.documentText == expected && engine.layer == nil && engine.state == .idle)
    }

    @Test("末頁不足九列時，按不存在的列號與 0 都吃掉，面板留著")
    func missingRowIsSwallowed() throws {
        var (engine, _) = try played("SYMBOLS TAB TAB")
        for _ in 0..<12 { engine.handle(.pageDown) }
        let content = try #require(engine.currentSymbolPanelContent)
        #expect(content.page == 13 && content.pageCount == 13 && content.rows.count == 3)
        for key in [KeyInput.character("4"), .character("9"), .character("0"), .panelPick(4)] {
            let effect = engine.handle(key)
            #expect(effect.handled && effect.committedText == nil && effect.symbolPanel == content, "\(key.tokenName)")
        }
        #expect(engine.documentText.isEmpty && engine.usageHistory.symbols.isEmpty)
        #expect(engine.handle(.character("2")).committedText == content.rows[1].symbol)

        var punctuation = try played("SYMBOLS TAB PGDN PGDN PGDN PGDN").engine
        let last = try #require(punctuation.currentSymbolPanelContent)
        #expect(last.page == 5 && last.pageCount == 5 && last.rows.map(\.symbol) == ["‧", "·", "—", "～"])
        #expect(punctuation.handle(.character("5")).committedText == nil)
        #expect(punctuation.handle(.character("4")).committedText == "～")
    }

    @Test("空白與 Enter 選焦點列", arguments: ["SPACE", "ENTER"])
    func spaceAndEnterPickFocus(key: String) throws {
        let (engine, effects) = try played("SYMBOLS DOWN DOWN \(key)")
        #expect(effects[2].symbolPanel?.focusedRow == 2)
        #expect(effects.last?.committedText == "‧")
        #expect(engine.documentText == "‧" && engine.layer == nil)
    }

    @Test("點選第 n 列選的是本頁那一列，與焦點在哪無關")
    func clickPicksRowOnCurrentPage() throws {
        let (engine, effects) = try played("SYMBOLS TAB PGDN DOWN PICK_1")
        #expect(effects[3].symbolPanel?.focusedRow == 1)
        #expect(effects.last?.committedText == ":")
        #expect(engine.documentText == ":")
    }

    @Test("上下鍵一次移一列、可以跨頁，到頭尾就停，不循環")
    func arrowsMoveAcrossPagesWithoutWrapping() throws {
        var (engine, effects) = try played("SYMBOLS UP")
        #expect(effects.last?.symbolPanel?.focusedRow == 0 && effects.last?.symbolPanel?.page == 1)
        for _ in 0..<20 { engine.handle(.arrowDown) }
        #expect(engine.symbolPanel?.focusIndex == 8)
        #expect(engine.currentSymbolPanelContent?.focusedRow == 8)

        var paged = try played("SYMBOLS TAB").engine
        for _ in 0..<9 { paged.handle(.arrowDown) }
        var content = try #require(paged.currentSymbolPanelContent)
        #expect(content.page == 2 && content.focusedRow == 0 && content.rows.first?.symbol == ":")
        content = try #require(paged.handle(.arrowUp).symbolPanel)
        #expect(content.page == 1 && content.focusedRow == 8 && content.rows.last?.symbol == "：")
        for _ in 0..<300 { paged.handle(.arrowDown) }
        #expect(paged.symbolPanel?.focusIndex == 39)
        #expect(paged.currentSymbolPanelContent?.focusedRow == 3)

        var symbolsTab = try played("SYMBOLS TAB TAB").engine
        for _ in 0..<300 { symbolsTab.handle(.arrowDown) }
        #expect(symbolsTab.symbolPanel?.focusIndex == 110)
        #expect(symbolsTab.currentSymbolPanelContent?.focusedRow == 2)
    }

    @Test("PageDown 與 PageUp 跳到下一頁、上一頁的第一列；沒有那一頁就不動")
    func pagingJumpsToFirstRow() throws {
        let single = try played("SYMBOLS DOWN DOWN PGDN PGUP").effects
        #expect(single[3].symbolPanel == single[2].symbolPanel)
        #expect(single[4].symbolPanel == single[2].symbolPanel)

        var (engine, effects) = try played("SYMBOLS TAB DOWN DOWN PGDN")
        #expect(effects.last?.symbolPanel?.page == 2 && effects.last?.symbolPanel?.focusedRow == 0)
        #expect(engine.symbolPanel?.focusIndex == 9)
        try play("DOWN DOWN PGUP", on: &engine)
        #expect(engine.symbolPanel?.focusIndex == 0)
        for _ in 0..<40 { engine.handle(.pageDown) }
        #expect(engine.symbolPanel?.focusIndex == 36)
    }

    @Test("Tab 依最近使用、標點、符號的順序輪流，第三次回到最近使用，焦點都回第一列")
    func tabCyclesThroughThreeTabs() throws {
        let effects = try played("SYMBOLS DOWN DOWN TAB DOWN TAB DOWN TAB").effects
        #expect(effects[0].symbolPanel?.tab == .recent)
        let punctuation = try #require(effects[3].symbolPanel)
        #expect(punctuation.tab == .punctuation && punctuation.focusedRow == 0 && punctuation.page == 1)
        #expect(punctuation.pageCount == 5)
        #expect(symbols(punctuation) == punctuationFirstPage)
        #expect(punctuation.rows[3] == SymbolPanelContent.Row(
            number: 4, symbol: "，", name: "逗號", englishName: "Fullwidth comma", group: "逗號", englishGroup: "Comma"
        ))
        #expect(punctuation.rows[4].name == "半形逗號" && punctuation.rows[4].group == "逗號")
        let symbolsTab = try #require(effects[5].symbolPanel)
        #expect(symbolsTab.tab == .symbols && symbolsTab.focusedRow == 0 && symbolsTab.page == 1)
        #expect(symbolsTab.pageCount == 13)
        #expect(symbols(symbolsTab) == symbolsFirstPage)
        #expect(symbolsTab.rows[0].group == "其他括號" && symbolsTab.rows[0].englishGroup == "Other brackets")
        let back = try #require(effects[7].symbolPanel)
        #expect(back.tab == .recent && back.focusedRow == 0 && back.rows.map(\.symbol) == initialRecents)
        #expect(SymbolPanel.Tab.recent.next == .punctuation && SymbolPanel.Tab.punctuation.next == .symbols
                && SymbolPanel.Tab.symbols.next == .recent)
    }

    @Test("標點分頁列出標準標點的全形與半形寫法，一頁一頁翻得到每一個")
    func punctuationTabListsBothWidths() throws {
        var engine = try played("SYMBOLS TAB").engine
        var pages: [String] = []
        for _ in 0..<5 {
            pages.append(symbols(engine.currentSymbolPanelContent))
            engine.handle(.pageDown)
        }
        #expect(pages == [
            punctuationFirstPage, ":「」『』“”‘’", "\"'（）()？?！", "!——……《》〈〉﹏＿", "‧·—～"
        ])
    }

    @Test("Esc 關閉面板，底下的組字完全不變，之後空白照舊出字")
    func escapeRestoresComposition() throws {
        var engine = try played("m y").engine
        let before = EquivalenceKey(engine: engine)
        let effects = try play("SYMBOLS TAB PGDN DOWN ESC", on: &engine)
        #expect(effects.last?.handled == true && effects.last?.committedText == nil)
        #expect(effects.last?.symbolPanel == nil)
        #expect(EquivalenceKey(engine: engine) == before)
        #expect(engine.handle(.space).committedText == "下")

        var focused = try played("n o DOWN SYMBOLS DOWN ESC").engine
        #expect(focused.state == .selectingCandidate && focused.selectedCandidateIndex == 1)
        #expect(focused.handle(.space).committedText == "欠")
    }

    @Test("Caps Lock 燈號真的變了就先關面板再照原本的流程送出緩衝；燈號沒變就吃掉")
    func capsLockClosesPanel() throws {
        var engine = try played("m y SYMBOLS DOWN").engine
        let same = engine.handle(.capsLock(false))
        #expect(same.handled && same.committedText == nil && same.symbolPanel?.focusedRow == 1)
        let lit = engine.handle(.capsLock(true))
        #expect(lit.handled && lit.committedText == "my" && lit.symbolPanel == nil)
        #expect(engine.layer == nil && engine.capsLockEnabled && engine.documentText == "my")
    }

    @Test("面板開著時其他按鍵一律吃掉、不動，也不交還宿主", arguments: [
        "a", "Z", "0", "BKSP", "COMMA", "PERIOD", "BACKTICK", "SHIFT_SPACE", "LOOKUP", "CTRL_COMMA",
        "CTRL_LBRACKET", "CTRL_SHIFT_RBRACKET", "OPT_.", "DBL_SHIFT", "SHIFT_2", "ACCEPT_CONTINUATION"
    ])
    func otherKeysAreSwallowed(token: String) throws {
        var engine = try played("i d TAB m y SYMBOLS DOWN").engine
        let before = EquivalenceKey(engine: engine)
        let panelBefore = engine.currentSymbolPanelContent
        let effect = engine.handle(try #require(KeyInput.parse(token: token)))
        #expect(effect.handled)
        #expect(effect.committedText == nil && effect.commitKind == .none && effect.deletedBackwardCount == 0)
        #expect(effect.symbolPanel == panelBefore)
        #expect(EquivalenceKey(engine: engine) == before)
    }

    @Test("焦點不同的面板是不同的狀態，檢查器不得合併")
    func panelStateIsPartOfEquivalenceKey() throws {
        let top = try played("SYMBOLS").engine
        let moved = try played("SYMBOLS DOWN").engine
        let otherTab = try played("SYMBOLS TAB").engine
        let thirdTab = try played("SYMBOLS TAB TAB").engine
        #expect(EquivalenceKey(engine: top) != EquivalenceKey(engine: moved))
        #expect(EquivalenceKey(engine: top) != EquivalenceKey(engine: otherTab))
        #expect(EquivalenceKey(engine: otherTab) != EquivalenceKey(engine: thirdTab))
        #expect(EquivalenceKey(engine: top) == EquivalenceKey(engine: try played("SYMBOLS TAB TAB TAB").engine))
        #expect(EquivalenceKey(engine: top, ignoringLayer: true) == EquivalenceKey(engine: moved, ignoringLayer: true))
    }

    @Test("每一步的 JSON 只在面板開著時多出 symbolPanel 欄位")
    func effectEncoding() throws {
        let effects = try played("SYMBOLS TAB TAB ESC").effects
        func object(_ effect: StepEffect) throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(effect)) as? [String: Any])
        }
        let open = try #require(try object(effects[0])["symbolPanel"] as? [String: Any])
        #expect(open["tab"] as? String == "recent")
        #expect((open["rows"] as? [[String: Any]])?.first?["symbol"] as? String == "——")
        #expect((try object(effects[1])["symbolPanel"] as? [String: Any])?["tab"] as? String == "punctuation")
        #expect((try object(effects[2])["symbolPanel"] as? [String: Any])?["tab"] as? String == "symbols")
        #expect(try object(effects[3])["symbolPanel"] == nil)
    }
}

@Suite("符號面板：選取後的送出")
struct SymbolPanelCommitTests {
    /// 每一列是：底下的組字、是否混打、預期在符號之前送出的文字、這個狀態的說明。
    /// 預期值寫死是為了讓規則本身錯了也會失敗；與逗號鍵的對照另外逐欄比。
    @Test("選取時底下的組字怎麼結束，與同一個狀態按逗號鍵完全相同", arguments: [
        ("m y", true, "下", "混打有精確候選"),
        ("o j", true, "午", "混打有重碼"),
        ("y r h", true, "yrh", "混打只有前綴"),
        ("m y y", true, "myy", "混打只剩英文軌"),
        ("n o DOWN", true, "欠", "已聚焦候選"),
        ("BACKTICK m y", true, "my", "片段語境英文優先"),
        ("BACKTICK m y SHIFT_SPACE SPACE m y", true, "my", "片段語境黏中"),
        ("BACKTICK n o DOWN", true, "欠", "片段語境已聚焦候選"),
        ("m y", false, "下", "純中文模式有精確候選"),
        ("y r h", false, "yrh", "純中文模式只有前綴"),
        ("n o DOWN", false, "欠", "純中文模式已聚焦候選")
    ])
    func compositionSettlesLikeCommaKey(script: String, mixed: Bool, prefix: String, label: String) throws {
        let configuration = EngineConfiguration(mixedModeEnabled: mixed)
        let base = try played(script, configuration: configuration).engine
        #expect(!base.buffer.isEmpty, "\(label)")

        var comma = base
        let commaEffect = comma.handle(.character(","))
        let commaText = try #require(commaEffect.committedText, "\(label)")
        #expect(commaText.last == "，" || commaText.last == ",", "\(label)")
        let settled = String(commaText.dropLast())
        #expect(settled == prefix, "\(label)")

        // 「最近使用」第一頁的第八列是乘號；【 改從「符號」分頁選。兩條路的結果都要對得上逗號鍵。
        for (pick, symbol) in [("SYMBOLS 8", "×"), ("SYMBOLS TAB TAB 1", "【")] {
            let label = "\(label)，\(pick)"
            var picked = base
            let effects = try play(pick, on: &picked)
            #expect(effects.last?.committedText == settled + symbol, "\(label)")
            #expect(effects.last?.committedCore == symbol, "\(label)")
            #expect(effects.last?.commitKind == .punctuation && effects.last?.deletedBackwardCount == 0, "\(label)")
            #expect(picked.documentText == String(comma.documentText.dropLast()) + symbol, "\(label)")
            #expect(picked.state == .idle && picked.buffer.isEmpty && picked.layer == nil, "\(label)")
            #expect(picked.state == comma.state && picked.pendingAutoSpace == comma.pendingAutoSpace, "\(label)")
            #expect(picked.snippet == comma.snippet, "\(label)")
            // 學習紀錄照同一條路徑記：除了最近使用的符號，其餘與按逗號鍵相同。
            #expect(picked.usageHistory.cangjie == comma.usageHistory.cangjie, "\(label)")
            #expect(picked.usageHistory.english == comma.usageHistory.english, "\(label)")
            #expect(picked.usageHistory.reading == comma.usageHistory.reading, "\(label)")
            #expect(picked.usageHistory.symbols == [symbol], "\(label)")
        }
    }

    @Test("送出首選字時照逗號鍵記倉頡重碼紀錄；關閉倉頡學習就不記")
    func settlingRecordsCangjieChoiceLikeCommaKey() throws {
        let learned = try played("o j SYMBOLS TAB TAB 1").engine
        #expect(learned.documentText == "午【")
        #expect(learned.usageHistory.cangjie.map(\.code) == ["oj"])
        #expect(learned.usageHistory.cangjie.first?.choices.map(\.character) == ["午"])
        #expect(learned.usageHistory.cangjie == (try played("o j COMMA").engine.usageHistory.cangjie))

        let off = try played("o j SYMBOLS TAB TAB 1", configuration: EngineConfiguration(learnsCangjieOrder: false)).engine
        #expect(off.documentText == "午【" && off.usageHistory.cangjie.isEmpty)
    }

    @Test("英文後接著打的組字，選取時首選字前照樣補中英之間那一格")
    func settledCandidateKeepsAutoSpace() throws {
        let (engine, effects) = try played("m y SYMBOLS TAB TAB 1", context: "abc")
        #expect(effects.last?.committedText == " 下【")
        #expect(engine.documentText == "abc 下【")
        #expect(engine.documentText == String(try played("m y COMMA", context: "abc").engine.documentText.dropLast()) + "【")
    }

    @Test("符號本身不補中英之間的空格", arguments: [
        ("i d ENTER SYMBOLS TAB TAB 1", "", "id【"),
        ("SYMBOLS TAB TAB 1", "abc", "abc【"),
        ("SYMBOLS TAB TAB 1", "中文", "中文【"),
        ("SYMBOLS TAB TAB 1", "v2", "v2【"),
        // 初始的最近使用裡的符號也一樣：英文、中文、數字後面都不補。
        ("i d ENTER SYMBOLS 8", "", "id×"),
        ("SYMBOLS 7", "abc", "abc→"),
        ("SYMBOLS 6", "中文", "中文※"),
        ("SYMBOLS 9", "v2", "v2±")
    ])
    func noSpacingAroundSymbol(script: String, context: String, expected: String) throws {
        let (engine, effects) = try played(script, context: context)
        #expect(effects.last?.committedCore == String(expected.suffix(1)))
        #expect(engine.documentText == expected)
    }

    @Test("收尾標點收合英文後自動補上的那一格，其他符號不收合", arguments: [
        ("，", true), ("。", true), ("；", true), ("：", true), ("？", true), ("！", true),
        ("）", true), ("」", true), ("』", true),
        (",", true), (".", true), (";", true), (":", true), ("?", true), ("!", true), (")", true),
        ("(", false), ("\"", false), ("「", false), ("（", false), ("《", false), ("》", false), ("→", false), ("％", false), ("……", false)
    ])
    func closingPunctuationCollapsesPendingSpace(symbol: String, collapses: Bool) throws {
        let entry = try #require(SymbolTable.shared.entry(for: symbol))
        var engine = try played(entry.tab == .punctuation ? "i d TAB SYMBOLS TAB" : "i d TAB SYMBOLS TAB TAB").engine
        #expect(engine.documentText == "id " && engine.pendingAutoSpace)
        #expect(engine.symbolPanel?.tab == entry.tab)
        let index = try #require(SymbolTable.shared.entries(in: entry.tab).firstIndex { $0.symbol == symbol })
        for _ in 0..<index { engine.handle(.arrowDown) }
        let effect = engine.handle(.enter)
        #expect(effect.committedText == symbol)
        #expect(effect.deletedBackwardCount == (collapses ? 1 : 0))
        #expect(engine.documentText == (collapses ? "id" : "id ") + symbol)
        #expect(!engine.pendingAutoSpace)
        #expect(PunctuationMapper.collapsesPendingAutoSpace(emitting: symbol) == collapses)
    }

    @Test("頓號沿用既有規則：打出它的反斜線鍵不收合，所以從面板選也不收合")
    func enumerationCommaFollowsKeyRule() throws {
        let picked = try played("i d TAB SYMBOLS TAB 6").engine
        let typed = try played("i d TAB CTRL_BACKSLASH").engine
        #expect(picked.documentText == "id 、")
        #expect(picked.documentText == typed.documentText)
    }

    @Test("半形標點從面板選出來原樣送出，不因中文語境改成全形，也不開關片段語境", arguments: [
        ("SYMBOLS TAB 5", ","), ("SYMBOLS TAB 3", "."), ("SYMBOLS TAB PGDN PGDN 1", "\""),
        ("SYMBOLS TAB PGDN PGDN 5", "("), ("SYMBOLS TAB PGDN PGDN 8", "?")
    ])
    func halfwidthPunctuationIsCommittedAsIs(script: String, symbol: String) throws {
        let (engine, effects) = try played(script, context: "中文")
        #expect(effects.last?.committedText == symbol && effects.last?.committedCore == symbol)
        #expect(engine.documentText == "中文" + symbol)
        #expect(!engine.snippet.isInside && engine.revertRecord == nil)
        // 同一個位置直接按鍵會照中文語境出全形，面板選的不會。
        if let key = symbol.first, let fullwidth = PunctuationMapper.fullwidthForm(for: key) {
            var typed = InputEngine(initialDocumentText: "中文")
            #expect(typed.handle(.character(key)).committedCore == fullwidth)
        }
    }

    @Test("半形的收尾標點從面板選出來，收合與直接按那個鍵相同", arguments: [
        ("SYMBOLS TAB 5", "OPT_,", "id,"), ("SYMBOLS TAB 3", "PERIOD", "id."),
        ("SYMBOLS TAB PGDN PGDN 6", "OPT_)", "id)")
    ])
    func halfwidthClosersCollapseLikeTheirKey(pick: String, typedKey: String, expected: String) throws {
        let (engine, effects) = try played("i d TAB " + pick)
        #expect(effects.last?.deletedBackwardCount == 1)
        #expect(engine.documentText == expected)
        #expect(engine.documentText == (try played("i d TAB " + typedKey).engine.documentText))
    }

    @Test("使用說明的教學照順序做：先按 4、5 打〔註〕，接著箭頭還在第 7 列")
    func tutorialSequenceFromFreshHistory() throws {
        var (engine, effects) = try played("SYMBOLS 4 y r y g SPACE SYMBOLS")
        // 剛選過的〔排到第 1 列，〕還在第 5 列。
        #expect(symbols(effects.last?.symbolPanel) == "〔——……‧〕※→×±")
        effects = try play("5 SYMBOLS", on: &engine)
        #expect(engine.documentText == "〔註〕")
        #expect(symbols(effects.last?.symbolPanel) == "〕〔——……‧※→×±")
        try play("7", on: &engine)
        #expect(engine.documentText == "〔註〕→")
    }

    @Test("使用者自己打的空格不收合")
    func manualSpaceIsKept() throws {
        let (engine, effects) = try played("i d ENTER SPACE SYMBOLS TAB 4")
        #expect(effects.last?.deletedBackwardCount == 0)
        #expect(engine.documentText == "id ，")
    }

    @Test("選取不留反悔紀錄：緊接的 Shift+空白 是一般空白，不對調寬度")
    func pickIsNotRevertible() throws {
        var (engine, effects) = try played("SYMBOLS TAB 4")
        #expect(effects.last?.committedText == "，")
        #expect(effects.last?.revertible == false && effects.last?.revertPreview == nil)
        #expect(engine.revertRecord == nil)
        let after = engine.handle(.shiftSpace)
        #expect(after.committedText == " " && after.commitKind == .space && after.deletedBackwardCount == 0)
        #expect(engine.documentText == "， ")

        // 組字中直接選符號也不留紀錄。
        // 對照：直接按逗號鍵得到的「下，」可以對調寬度，從面板選的同一段文字不行。
        var composed = try played("m y SYMBOLS TAB 4").engine
        #expect(composed.documentText == "下，" && composed.revertRecord == nil)
        #expect(composed.handle(.shiftSpace).committedText == " ")
        #expect(composed.documentText == "下， ")
        var typed = try played("m y COMMA").engine
        #expect(typed.documentText == "下，" && typed.revertRecord != nil)
        typed.handle(.shiftSpace)
        #expect(typed.documentText == "下,")

        // 對照：用空白送出的「下」本來可以反悔，隔了一次面板選取就不行，不會被對調成 my。
        var revertible = try played("m y SPACE").engine
        #expect(revertible.revertRecord != nil)
        try play("SYMBOLS TAB TAB 1", on: &revertible)
        #expect(revertible.revertRecord == nil)
        #expect(revertible.handle(.shiftSpace).committedText == " ")
        #expect(revertible.documentText == "下【 ")
    }

    @Test("片段語境裡照樣送出選到的符號，不改半形、不補空格，片段語境不變")
    func snippetKeepsChosenSymbol() throws {
        let (engine, effects) = try played("BACKTICK i d SYMBOLS TAB TAB 1")
        #expect(effects.last?.committedText == "id【")
        #expect(engine.documentText == "`id【")
        #expect(engine.snippet.isInside)

        let comma = try played("BACKTICK SYMBOLS TAB 4").engine
        #expect(comma.documentText == "`，" && comma.snippet.isInside)
    }

    @Test("片段裡選符號會解除黏中，之後空白回到英文優先")
    func snippetPickClearsStickyChinese() throws {
        var engine = try played("BACKTICK m y SHIFT_SPACE SPACE").engine
        #expect(engine.snippet.stickyChinese)
        try play("SYMBOLS TAB TAB 1", on: &engine)
        #expect(engine.snippet.isInside && !engine.snippet.stickyChinese)
        let effects = try play("m y SPACE", on: &engine)
        #expect(effects.last?.committedText == "my ")
        #expect(engine.documentText == "`下【my ")
    }

    @Test("選完面板關閉回到閒置，之後的標點照文件最後一個字元判斷寬度")
    func punctuationContextAfterPick() throws {
        var (engine, effects) = try played("SYMBOLS TAB 1")
        #expect(effects.last?.symbolPanel == nil && effects.last?.state == .idle)
        #expect(engine.layer == nil)
        #expect(engine.handle(.character(",")).committedCore == "，")
        #expect(engine.documentText == "。，")

        var afterArrow = try played("SYMBOLS TAB TAB 1", context: "abc").engine
        #expect(afterArrow.handle(.character(".")).committedCore == "。")

        // 選出半形字元之後，下一個標點的寬度與文件本來就以那個字元結尾時相同。
        for (script, symbol) in [("SYMBOLS TAB PGDN PGDN 5", "("), ("SYMBOLS TAB PGDN PGDN 1", "\""),
                                 ("SYMBOLS TAB PGDN PGDN 6", ")"), ("SYMBOLS TAB 5", ",")] {
            var picked = try played(script, context: "中文").engine
            var typed = InputEngine(initialDocumentText: "中文" + symbol)
            #expect(picked.documentText == typed.documentText, "\(symbol)")
            #expect(picked.handle(.character(",")).committedCore == typed.handle(.character(",")).committedCore, "\(symbol)")
            #expect(picked.handle(.character(".")).committedCore == typed.handle(.character(".")).committedCore, "\(symbol)")
        }
    }

    @Test("選取不觸發接詞提示")
    func pickDoesNotOfferContinuation() throws {
        var configuration = EngineConfiguration()
        configuration.chineseContinuationEnabled = true
        let engine = try played("SYMBOLS TAB TAB 1", configuration: configuration, context: "SQL 資").engine
        #expect(engine.chineseContinuation == nil)
    }

    @Test("宿主結束組字時先丟掉面板，只送出原字母，不送出焦點符號")
    func hostEndingCompositionDropsPanel() throws {
        var engine = try played("m y SYMBOLS DOWN").engine
        #expect(engine.finishHostComposition() == "my")
        #expect(engine.layer == nil && engine.documentText == "my" && engine.buffer.isEmpty)
        #expect(engine.usageHistory.symbols.isEmpty)

        // 底下已聚焦候選「欠」：沒有面板時宿主結束組字會採用焦點字，有面板時只送原字母。
        var withoutPanel = try played("n o DOWN").engine
        #expect(withoutPanel.state == .selectingCandidate)
        #expect(withoutPanel.finishHostComposition() == "欠")
        var focused = try played("n o DOWN SYMBOLS DOWN").engine
        #expect(focused.finishHostComposition() == "no")
        #expect(focused.layer == nil && focused.documentText == "no" && focused.buffer.isEmpty)

        var idle = try played("SYMBOLS DOWN").engine
        #expect(idle.finishHostComposition() == nil)
        #expect(idle.layer == nil && idle.documentText.isEmpty)
    }

    @Test("切換欄位與選單收起都丟掉面板，不送出任何字")
    func focusChangeDropsPanel() throws {
        var reset = try played("m y SYMBOLS DOWN").engine
        reset.resetContext()
        #expect(reset.layer == nil && reset.buffer.isEmpty && reset.documentText.isEmpty)
        #expect(reset.currentSymbolPanelContent == nil)

        var dismissed = try played("m y SYMBOLS DOWN").engine
        dismissed.dismissLayer()
        #expect(dismissed.layer == nil && dismissed.buffer == "my" && dismissed.state == .composingDual)

        var lookup = try played("m y LOOKUP").engine
        lookup.dismissLayer()
        #expect(lookup.readingLookup == nil && lookup.buffer == "my")
    }
}

@Suite("符號面板：最近使用")
struct SymbolPanelRecentTests {
    @Test("選過的符號下次排到最近使用的第一個，同一個符號只留一份")
    func pickedSymbolsMoveToFront() throws {
        var (engine, effects) = try played("SYMBOLS 8 SYMBOLS")
        #expect(engine.usageHistory.symbols == ["×"])
        #expect(symbols(effects.last?.symbolPanel) == "×——……‧〔〕※→±")
        var again = try play("9 SYMBOLS", on: &engine)
        #expect(engine.usageHistory.symbols == ["±", "×"])
        #expect(symbols(again.last?.symbolPanel) == "±×——……‧〔〕※→")
        again = try play("2 SYMBOLS", on: &engine)
        #expect(engine.usageHistory.symbols == ["×", "±"])
        #expect(symbols(again.last?.symbolPanel) == "×±——……‧〔〕※→")
        #expect(engine.documentText == "×±×")
    }

    @Test("從標點與符號分頁選的也進最近使用；不在初始清單的符號讓最近使用多出一列")
    func picksFromOtherTabsAreRecorded() throws {
        var (engine, effects) = try played("SYMBOLS TAB 4 SYMBOLS")
        #expect(engine.usageHistory.symbols == ["，"])
        var content = try #require(effects.last?.symbolPanel)
        #expect(content.tab == .recent && content.pageCount == 2)
        #expect(symbols(content) == "，——……‧〔〕※→×")

        effects = try play("TAB TAB 1 SYMBOLS", on: &engine)
        #expect(engine.usageHistory.symbols == ["【", "，"])
        content = try #require(effects.last?.symbolPanel)
        #expect(content.tab == .recent && symbols(content) == "【，——……‧〔〕※→")
        // 半形標點也記，下次開啟排在第一列。
        effects = try play("TAB 5 SYMBOLS", on: &engine)
        #expect(engine.usageHistory.symbols == [",", "【", "，"])
        #expect(effects.last?.symbolPanel?.rows.first?.name == "半形逗號")
    }

    @Test("最近使用至多十八個，最久沒選的被擠掉")
    func recentsAreCapped() throws {
        let pool = SymbolTable.shared.entries.filter { !$0.isInitialRecent }.prefix(20).map(\.symbol)
        var history = UsageHistory()
        for symbol in pool { history.recordSymbol(symbol) }
        #expect(history.symbols == Array(pool.reversed().prefix(18)))
        #expect(UsageHistory.symbolCapacity == 18)
        history.recordSymbol("")
        #expect(history.symbols.count == 18)

        var engine = InputEngine(usageHistory: history)
        let first = try #require(engine.handle(.toggleSymbolPanel).symbolPanel)
        #expect(first.pageCount == 2 && first.rows.map(\.symbol) == Array(pool.reversed().prefix(9)))
        let second = try #require(engine.handle(.pageDown).symbolPanel)
        #expect(second.page == 2 && second.rows.map(\.symbol) == Array(pool.reversed().dropFirst(9).prefix(9)))
        // 滿了之後初始符號沒有位置，再翻頁也不動。
        #expect(engine.handle(.pageDown).symbolPanel == second)
    }

    @Test("最近使用不受三個學習開關管")
    func recentsIgnoreLearningSwitches() throws {
        let configuration = EngineConfiguration(
            learnsEnglishPredictions: false, learnsCangjieOrder: false, learnsReadingLookupOrder: false
        )
        let (engine, effects) = try played("SYMBOLS 8 SYMBOLS", configuration: configuration)
        #expect(engine.usageHistory.symbols == ["×"])
        #expect(effects.last?.symbolPanel?.rows.first?.symbol == "×")
        #expect(engine.usageHistory.english.isEmpty && engine.usageHistory.cangjie.isEmpty)
    }

    @Test("面板開著時外層換了一份較短的紀錄，焦點不會留在清單外")
    func externalHistoryChangeClampsFocus() throws {
        let pool = SymbolTable.shared.entries.filter { !$0.isInitialRecent }.prefix(9).map(\.symbol)
        var engine = InputEngine(usageHistory: UsageHistory(recentSymbols: Array(pool)))
        try play("SYMBOLS PGDN DOWN DOWN", on: &engine)
        #expect(engine.symbolPanel?.focusIndex == 11)
        engine.usageHistory = UsageHistory()
        let content = try #require(engine.currentSymbolPanelContent)
        #expect(content.page == 1 && content.pageCount == 1 && content.focusedRow == 8)
        #expect(engine.handle(.enter).committedText == "±")
    }

    @Test("沒有 symbols 欄位的舊存檔照樣解碼，新欄位編碼後讀得回來")
    func legacyDecoding() throws {
        let legacy = #"{"english":[{"word":"functions","count":2}],"cangjie":[],"reading":[{"character":"波","count":1}]}"#
        let decoded = try JSONDecoder().decode(UsageHistory.self, from: Data(legacy.utf8))
        #expect(decoded.symbols.isEmpty)
        #expect(decoded.english.map(\.word) == ["functions"] && decoded.english.first?.count == 2)
        #expect(decoded.reading.map(\.character) == ["波"])

        var history = decoded
        history.recordSymbol("【")
        history.recordSymbol("，")
        let data = try JSONEncoder().encode(history)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["symbols"] as? [String] == ["，", "【"])
        #expect(try JSONDecoder().decode(UsageHistory.self, from: data) == history)
    }

    @Test("被手動改壞的 symbols 欄位在解碼時收乾淨：去掉重複與空字串，不超過上限")
    func decodingNormalizesSymbols() throws {
        let many = (0..<30).map { "符\($0)" }
        let data = try JSONEncoder().encode(["symbols": ["，", "", "，", "【"] + many])
        let decoded = try JSONDecoder().decode(UsageHistory.self, from: data)
        #expect(decoded.symbols == Array((["，", "【"] + many).prefix(18)))
    }

    @Test("只有最近使用的符號時紀錄不算空；便利建構子的順序是最近的在前")
    func emptinessAndInitializer() {
        #expect(UsageHistory().isEmpty)
        let history = UsageHistory(recentSymbols: ["，", "【", "，"])
        #expect(!history.isEmpty)
        #expect(history.symbols == ["，", "【"])
    }

    @Test("讀取失敗後恢復的合併：這段期間選的符號排在原檔的前面，不重複、不超過上限")
    func sessionMerge() {
        var original = UsageHistory(englishWords: ["idea"], recentSymbols: ["【", "】", "，"])
        original.recordSession(UsageHistory(recentSymbols: ["。", "】"]))
        #expect(original.symbols == ["。", "】", "【", "，"])
        #expect(original.english.map(\.word) == ["idea"])

        let pool = (0..<18).map { "符\($0)" }
        var full = UsageHistory(recentSymbols: pool)
        full.recordSession(UsageHistory(recentSymbols: ["新"]))
        #expect(full.symbols == ["新"] + pool.prefix(17))
    }
}
