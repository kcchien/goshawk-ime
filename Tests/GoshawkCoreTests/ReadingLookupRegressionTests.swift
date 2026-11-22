import GoshawkCore
@testable import GoshawkVerifier
import Testing

@Suite("讀音反查回歸")
struct ReadingLookupRegressionTests {
    @Test("關閉面板後，不同讀音方案在下一鍵產生不同結果，形式檢查須保留兩條路徑")
    func schemeDistinguishesVisitedStates() throws {
        var dachen = InputEngine()
        var pinyin = dachen
        for key in [KeyInput.toggleReadingLookup, .tab, .escape] {
            pinyin.handle(key)
        }
        #expect(EquivalenceKey(engine: dachen) != EquivalenceKey(engine: pinyin))
        dachen.handle(.toggleReadingLookup)
        pinyin.handle(.toggleReadingLookup)
        let dachenPanel = try #require(dachen.handle(.character("a")).readingLookupPanel)
        let pinyinPanel = try #require(pinyin.handle(.character("a")).readingLookupPanel)
        #expect(dachenPanel.inputDisplay == "ㄇ" && dachenPanel.rows.isEmpty)
        #expect(pinyinPanel.inputDisplay == "a" && pinyinPanel.rows.first?.character == "啊")
    }

    @Test("三、五代的匕可從反查直接選，顯示的原生碼會標明正查是否可用",
          arguments: [CangjieVersion.v3, .v5])
    func nativeCodeAvailability(version: CangjieVersion) throws {
        let config = EngineConfiguration(cangjieVersion: version, readingScheme: .pinyin)
        var engine = InputEngine(configuration: config)
        engine.handle(.toggleReadingLookup)
        for ch in "bi3" { engine.handle(.character(ch)) }
        let row = try #require(engine.currentReadingLookupPanel?.rows.first { $0.character == "匕" })
        #expect(row.code == "uh" && row.directInputAvailable == false)
        #expect(engine.handle(.panelPick(row.number)).committedCore == "匕")
        var forward = InputEngine(configuration: config)
        for ch in "uh" { forward.handle(.character(ch)) }
        #expect(forward.handle(.space).committedCore == "uh")
    }

    @Test("同字有多個原生碼時優先提示可以正查的碼；沒有原生碼另行表示")
    func displayUsableNativeCode() throws {
        let readings = ReadingIndex(readingsTSV: "ㄒㄧㄚ\txia\t4\t下彞",
                                    nativeCodesTSV: "下\tuh,my\tuh,my")
        var engine = InputEngine(configuration: EngineConfiguration(readingScheme: .pinyin), readings: readings)
        engine.handle(.toggleReadingLookup)
        for ch in "xia4" { engine.handle(.character(ch)) }
        let rows = try #require(engine.currentReadingLookupPanel).rows
        try #require(rows.count == 2)
        #expect(rows[0].code == "my" && rows[0].directInputAvailable == true)
        #expect(rows[1].code == nil && rows[1].directInputAvailable == nil)
    }

    /// 這個字在打包的讀音索引那一列排第幾名（1 起算），那一列沒有這個字時是 nil。
    private func bundledRank(_ character: String, _ bopomofo: String, _ tone: Tone) -> Int? {
        ReadingIndex.shared
            .characters(for: ReadingQuery(bopomofo: bopomofo, tone: tone))
            .firstIndex(of: character)
            .map { $0 + 1 }
    }

    @Test("台灣讀音與主要讀音只差聲調的常用字，在台灣讀音那一列排進第一頁",
          arguments: [("期", "ㄑㄧ", Tone.second), ("質", "ㄓ", .second), ("微", "ㄨㄟ", .second)])
    func taiwanToneVariantsReachFirstPage(character: String, bopomofo: String, tone: Tone) throws {
        let rank = try #require(bundledRank(character, bopomofo, tone))
        #expect(rank <= ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo)\(tone.bopomofoMark) 排第 \(rank) 名")
    }

    @Test("台灣常用的第二讀音排進那一列的第一頁，不論與主要讀音只差聲調還是不同音節",
          arguments: [("為", "ㄨㄟ", Tone.second), ("樂", "ㄩㄝ", .fourth), ("彈", "ㄊㄢ", .second), ("和", "ㄏㄢ", .fourth)])
    func taiwanSecondReadingsReachFirstPage(character: String, bopomofo: String, tone: Tone) throws {
        let rank = try #require(bundledRank(character, bopomofo, tone))
        #expect(rank <= ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo)\(tone.bopomofoMark) 排第 \(rank) 名")
        let toneless = try #require(
            ReadingIndex.shared
                .characters(for: ReadingQuery(bopomofo: bopomofo, tone: nil))
                .firstIndex(of: character)
        ) + 1
        #expect(toneless <= ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo) 排第 \(toneless) 名")
    }

    @Test("教育部辭典列為又音、讀音或不收的聲調，不當主要讀音排進第一頁",
          arguments: [("誼", "ㄧ", Tone.second), ("俄", "ㄜ", .fourth), ("誣", "ㄨ", .second)])
    func dictionaryAlternateTonesStayOffFirstPage(character: String, bopomofo: String, tone: Tone) throws {
        let rank = try #require(bundledRank(character, bopomofo, tone))
        #expect(rank > ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo)\(tone.bopomofoMark) 排第 \(rank) 名")
    }

    @Test("台灣讀音排進第一頁，不能擠掉那一列原本常用的字",
          arguments: [("裡", "ㄌㄧ", Tone.third), ("製", "ㄓ", .fourth), ("視", "ㄕ", .fourth), ("峰", "ㄈㄥ", .first),
                      ("月", "ㄩㄝ", .fourth), ("汗", "ㄏㄢ", .fourth), ("漢", "ㄏㄢ", .fourth), ("談", "ㄊㄢ", .second),
                      ("圍", "ㄨㄟ", .second)])
    func commonCharactersStayOnFirstPage(character: String, bopomofo: String, tone: Tone) throws {
        let rank = try #require(bundledRank(character, bopomofo, tone))
        #expect(rank <= ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo)\(tone.bopomofoMark) 排第 \(rank) 名")
    }

    @Test("只差聲調的又讀不會排到那一列的第一名",
          arguments: [("現", "ㄒㄧㄢ", Tone.fourth), ("科", "ㄎㄜ", .first), ("師", "ㄕ", .first), ("胰", "ㄧ", .second)])
    func firstCandidateIsNotAnAlternateReading(character: String, bopomofo: String, tone: Tone) {
        #expect(bundledRank(character, bopomofo, tone) == 1)
    }

    @Test("常用字的罕用讀音仍排在第一頁之後，不論它與主要讀音是不同音節還是只差聲調",
          arguments: [("紅", "ㄍㄨㄥ", Tone.first), ("雨", "ㄩ", .fourth), ("先", "ㄒㄧㄢ", .fourth), ("使", "ㄕ", .fourth)])
    func rareReadingsStayOffFirstPage(character: String, bopomofo: String, tone: Tone) throws {
        let rank = try #require(bundledRank(character, bopomofo, tone))
        #expect(rank > ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo)\(tone.bopomofoMark) 排第 \(rank) 名")
    }

    @Test("ㄘㄨㄛˋ 的第一個仍是「錯」，「厝」仍在第一頁")
    func cuoFirstPageKeepsCuoAndCuo() throws {
        #expect(bundledRank("錯", "ㄘㄨㄛ", .fourth) == 1)
        let rank = try #require(bundledRank("厝", "ㄘㄨㄛ", .fourth))
        #expect(rank <= ReadingLookup.rowsPerPage, "厝 排第 \(rank) 名")
    }

    @Test("不指定聲調時，各聲調的常用字不必翻完一聲的罕用字就在第一頁",
          arguments: [("錯", "ㄘㄨㄛ"), ("期", "ㄑㄧ"), ("氣", "ㄑㄧ"), ("起", "ㄑㄧ"), ("是", "ㄕ"), ("位", "ㄨㄟ")])
    func commonCharactersOfAnyToneReachFirstPage(character: String, bopomofo: String) throws {
        let rank = try #require(
            ReadingIndex.shared
                .characters(for: ReadingQuery(bopomofo: bopomofo, tone: nil))
                .firstIndex(of: character)
        ) + 1
        #expect(rank <= ReadingLookup.rowsPerPage, "\(character) 在 \(bopomofo) 排第 \(rank) 名")
    }

    @Test("面板只打聲母韻母時第一頁就有「錯」，選過的字照樣往前排")
    func tonelessPanelShowsCommonCharactersAndLearns() throws {
        var engine = InputEngine()
        engine.handle(.toggleReadingLookup)
        for ch in "hj" { engine.handle(.character(ch)) }
        let panel = try #require(engine.handle(.character("i")).readingLookupPanel)
        #expect(panel.inputDisplay == "ㄘㄨㄛ")
        #expect(panel.rows.first?.character == "錯")

        let third = panel.rows[2].character
        #expect(engine.handle(.panelPick(3)).committedCore == third)
        engine.handle(.toggleReadingLookup)
        for ch in "hj" { engine.handle(.character(ch)) }
        let learned = try #require(engine.handle(.character("i")).readingLookupPanel)
        #expect(learned.rows.prefix(2).map(\.character) == [third, "錯"])
    }

    @Test("滿額紀錄下的候選次數、同次數順序與跨頁實際選字一致")
    func fullHistoryOrderAndPaging() throws {
        var engine = InputEngine(configuration: EngineConfiguration(readingScheme: .pinyin))
        engine.handle(.toggleReadingLookup)
        for ch in "yi" { engine.handle(.character(ch)) }
        let original = engine.readingLookupCandidates().map(\.character)
        try #require(original.count > 18)
        var history = UsageHistory(readingChoices: (0..<(UsageHistory.readingCapacity - 3)).map { "測試\($0)" })
        for choice in [original[18], original[18], original[15], original[16]] {
            history.recordReading(choice)
        }
        #expect(history.reading.count == UsageHistory.readingCapacity)
        engine.usageHistory = history
        let promoted = [original[18], original[16], original[15]]
        let expected = promoted + original.filter { !promoted.contains($0) }
        #expect(engine.readingLookupCandidates().map(\.character) == expected)
        let first = try #require(engine.handle(.arrowDown).readingLookupPanel)
        #expect(first.rows.map(\.character) == Array(expected.prefix(9)))
        let second = try #require(engine.handle(.pageDown).readingLookupPanel)
        #expect(second.rows.map(\.character) == Array(expected[9..<18]))
        #expect(engine.handle(.panelPick(1)).committedCore == expected[9])
    }
}
