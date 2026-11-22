import Testing
@testable import GoshawkCore

@Suite("中文接詞與個人術語")
struct CompletionTests {
    private func afterLiao(_ context: String, enabled: Bool = true, terms: PersonalTerms = .empty) -> InputEngine {
        var config = EngineConfiguration()
        config.chineseContinuationEnabled = enabled
        config.personalTerms = terms
        config.personalTermsEnabled = !terms.words.isEmpty
        var engine = InputEngine(configuration: config, initialDocumentText: context)
        for ch in "fdyj" { engine.handle(.character(ch)) }
        engine.handle(.space)
        return engine
    }

    @Test("相同的兩字詞尾以技術語境排序，平手使用詞頻")
    func contextOrFrequency() {
        #expect(afterLiao("用 SQL 查詢資").chineseContinuation == "庫")
        #expect(afterLiao("存放檔案的資").chineseContinuation == "夾")
        #expect(afterLiao("宣告資").chineseContinuation == "型別")
        #expect(afterLiao("資").chineseContinuation == "夾")
        #expect(afterLiao("資", enabled: false).chineseContinuation == nil)
        #expect(afterLiao("原").chineseContinuation == nil)
    }

    @Test("兩種接詞排序共用詞表，語境線索平手或超出視窗時用詞頻")
    func rankingBaseline() {
        for (text, contextual, frequency) in [
            ("交易查詢和路徑資料", "庫", "夾"),
            ("交易和路徑資料", "夾", "夾"),
            ("查詢" + String(repeating: "甲", count: InputEngine.contextWindowLength) + "資料", "夾", "夾"),
            ("建立伺服", "器", "器"),
        ] {
            #expect(ChineseContinuation.suggestion(after: text) == contextual)
            #expect(ChineseContinuation.suggestion(after: text, ranking: .frequencyOnly) == frequency)
        }
        #expect(ChineseContinuation.suggestion(after: "原料", ranking: .frequencyOnly) == nil)
    }

    @Test("接受只加入提示的字，取消或直接打字維持已送出的文件")
    func acceptOrSkip() {
        let original = afterLiao("SQL 資")
        #expect(original.documentText == "SQL 資料")
        var accepted = original
        #expect(accepted.handle(.acceptChineseContinuation).committedText == "庫")
        #expect(accepted.documentText == "SQL 資料庫")
        #expect(!accepted.handle(.acceptChineseContinuation).handled)

        var cancelled = original
        #expect(cancelled.handle(.escape).handled)
        #expect(cancelled.chineseContinuation == nil)
        #expect(cancelled.documentText == original.documentText)

        for key in [KeyInput.character("m"), .space, .tab, .shiftSpace, .character(",")] {
            var plain = afterLiao("SQL 資", enabled: false)
            var assisted = original
            let baseline = plain.handle(key)
            let actual = assisted.handle(key)
            #expect(actual.documentText == baseline.documentText)
            #expect(actual.buffer == baseline.buffer)
            #expect(actual.handled == baseline.handled)
            #expect(actual.pendingAutoSpace == baseline.pendingAutoSpace)
            #expect(assisted.chineseContinuation == nil)
        }
    }

    @Test("游標、新欄位、切換設定與半形層會清掉待選接詞")
    func expiresAtBoundaries() {
        var engine = afterLiao("SQL 資")
        engine.syncExternalContext("別處")
        #expect(!engine.handle(.acceptChineseContinuation).handled)
        #expect(engine.documentText == "別處")
        engine = afterLiao("資")
        engine.resetContext()
        #expect(engine.chineseContinuation == nil)
        engine = afterLiao("資")
        engine.configuration.chineseContinuationEnabled = false
        #expect(engine.chineseContinuation == nil)
        engine = afterLiao("資")
        engine.handle(.capsLock(true))
        #expect(engine.chineseContinuation == nil)
    }

    @Test("從接詞與反悔同時可用的狀態，窮舉兩種前文接下來三個按鍵")
    func boundedContinuationTraces() {
        let keys: [KeyInput] = [.character("i"), .character("d"), .tab, .space,
                                .shiftSpace, .character(","), .escape, .acceptChineseContinuation]
        let terms = PersonalTerms(["idMaker"])
        var transitions = 0
        func explore(_ assisted: InputEngine, _ plain: InputEngine, path: [KeyInput]) {
            guard path.count < 3 else { return }
            for key in keys {
                let nextPath = path + [key]
                let trace = nextPath.map(\.tokenName).joined(separator: " ")
                var actual = assisted
                var baseline = plain
                let effect = actual.handle(key)
                let reference = baseline.handle(key)
                transitions += 1
                if let suffix = assisted.chineseContinuation, key == .acceptChineseContinuation {
                    #expect(effect.handled && effect.committedText == suffix, "\(trace)")
                    #expect(effect.documentText == assisted.documentText + suffix, "\(trace)")
                    #expect(effect.deletedBackwardCount == 0 && actual.chineseContinuation == nil, "\(trace)")
                    // 讓兩邊從相同的已採用文字繼續比較後續按鍵。
                    baseline = actual
                    baseline.configuration.chineseContinuationEnabled = false
                } else if assisted.chineseContinuation != nil, key == .escape {
                    #expect(effect.handled && effect.committedText == nil, "\(trace)")
                    #expect(actual.chineseContinuation == nil && actual.documentText == plain.documentText, "\(trace)")
                } else {
                    #expect(effect == reference, "\(trace)")
                }
                #expect(actual.usageHistory == baseline.usageHistory, "\(trace)")
                #expect(actual.revertRecord == baseline.revertRecord, "\(trace)")
                explore(actual, baseline, path: nextPath)
            }
        }
        for prefix in ["SQL 資", "存放檔案的資"] {
            let assisted = afterLiao(prefix, terms: terms)
            #expect(assisted.chineseContinuation != nil)
            explore(assisted, afterLiao(prefix, enabled: false, terms: terms), path: [])
        }
        #expect(transitions == 1_168)
    }

    @Test("英文術語保留大小寫、可停用與移除，也保留原本短詞首選")
    func personalEnglish() {
        let terms = PersonalTerms(["goshawkime", "GoshawkIME", "idMaker", "Foo2Bar", "x", "2foo", "中文"])
        #expect(terms.words == ["Foo2Bar", "GoshawkIME", "idMaker"])
        var config = EngineConfiguration()
        config.personalTerms = terms
        func tab(_ typed: String, _ config: EngineConfiguration) -> String {
            var engine = InputEngine(configuration: config)
            for ch in typed { engine.handle(.character(ch)) }
            return engine.handle(.tab).documentText
        }
        #expect(tab("goshaw", config) == "goshaw ")
        config.personalTermsEnabled = true
        #expect(tab("goshaw", config) == "GoshawkIME ")
        #expect(tab("foo2", config) == "Foo2Bar ")
        #expect(tab("id", config) == "id ")
        config.personalTerms = .empty
        #expect(tab("goshaw", config) == "goshaw ")
    }
}
