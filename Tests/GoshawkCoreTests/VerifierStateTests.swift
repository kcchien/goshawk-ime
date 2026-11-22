import GoshawkCore
@testable import GoshawkVerifier
import Testing

@Suite("模型檢查器的狀態去重")
struct VerifierStateTests {
    /// 每組設定各有自己的已訪狀態集合，詞庫與這些偏好在同一輪探索中固定。
    /// 讀音方案可由面板內的 Tab 切換，因此必須進入去重鍵。
    private let fixedResources: Set<String> = ["cangjie", "english", "usesCustomCangjie", "readingsOverride"]
    private let fixedPreferences: Set<String> = [
        "mixedModeEnabled", "cangjieVersion", "autoSpaceEnabled", "autoPunctuationEnabled",
        "ctrlBracketsQuotesEnabled", "developerVocabularyEnabled", "chineseContinuationEnabled",
        "personalTermsEnabled", "personalTerms", "learnsEnglishPredictions", "learnsCangjieOrder",
        "learnsReadingLookupOrder", "revertEnabled", "maxVisibleCandidates", "maxVisibleEnglishPredictions"
    ]

    private func storedFields(of value: Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: Mirror(reflecting: value).children.compactMap { child in
            child.label.map { ($0, child.value) }
        })
    }

    // 從引擎本身取得欄位，新欄位即使是 nil 或 0 也能查到漏列。只在測試反射。
    private func expectCompleteKey(for engine: InputEngine) throws {
        let state = storedFields(of: engine).filter { !fixedResources.contains($0.key) && $0.key != "configuration" }
        let preferences = storedFields(of: engine.configuration).filter { !fixedPreferences.contains($0.key) }
        let key = storedFields(of: EquivalenceKey(engine: engine))
        #expect(Set(state.keys).isDisjoint(with: preferences.keys))
        #expect(Set(state.keys).union(preferences.keys) == Set(key.keys))
        for (name, field) in Array(state) + Array(preferences) {
            let expected = try #require(field as? AnyHashable, "引擎欄位 \(name)")
            let keyField = try #require(key[name], "去重鍵缺少 \(name)")
            let actual = try #require(keyField as? AnyHashable)
            #expect(expected == actual, "去重鍵的 \(name) 取錯值")
        }
    }

    @Test("探索中的每個可變欄位都能在去重鍵找到同名且相等的值", arguments: [
        "o j DOWN DOWN SPACE SHIFT_SPACE", "n o t DOWN TAB", "i d TAB COMMA SHIFT_SPACE",
        "BACKTICK CAPS_ON CAPS_OFF", "LOOKUP TAB a ESC", "f d y j SPACE ACCEPT_CONTINUATION",
        "m y SYMBOLS DOWN TAB PGDN TAB DOWN DIGIT2 SYMBOLS TAB TAB TAB ESC"
    ])
    func capturesEngineState(trace: String) throws {
        var config = EngineConfiguration()
        config.chineseContinuationEnabled = true
        var engine = InputEngine(configuration: config, initialDocumentText: "SQL 資")
        try expectCompleteKey(for: engine)
        for token in trace.split(separator: " ") {
            engine.handle(try #require(KeyInput.parse(token: String(token))))
            try expectCompleteKey(for: engine)
            var fixed = engine.configuration
            fixed.readingScheme = config.readingScheme
            #expect(fixed == config, "代表按鍵改變了視為固定的設定")
        }
    }

    // 探索從空白文件出發，走不到「鏡像之前還有看不到的前文」，所以去重鍵有沒有收它在這裡驗。
    @Test("同一份鏡像，看不看得到更早的前文是兩個狀態")
    func clippedMirrorDistinguishesVisitedStates() throws {
        var visible = InputEngine(configuration: EngineConfiguration())
        visible.syncExternalContext(String(repeating: "字", count: 32))
        var clipped = InputEngine(configuration: EngineConfiguration())
        clipped.syncExternalContext(String(repeating: "字", count: 32), isClipped: true)
        try expectCompleteKey(for: clipped)
        #expect(visible.documentText == clipped.documentText)
        #expect(EquivalenceKey(engine: visible) != EquivalenceKey(engine: clipped))
        // 下一個右方括號的結果不同：一邊可以對調寬度，一邊被擋下。
        visible.handle(.character("]"))
        clipped.handle(.character("]"))
        try expectCompleteKey(for: clipped)
        #expect(visible.documentText == clipped.documentText)
        #expect(visible.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(clipped.handle(.shiftSpace).pairSwitchNotice == .spanUnsupported)
    }

    @Test("同一份已送出文字，取消提示後不能和仍可採用的路徑合併")
    func pendingContinuationDistinguishesVisitedStates() {
        var config = EngineConfiguration()
        config.chineseContinuationEnabled = true
        var offered = InputEngine(configuration: config, initialDocumentText: "SQL 資")
        for ch in "fdyj" { offered.handle(.character(ch)) }
        offered.handle(.space)
        var dismissed = offered
        dismissed.dismissChineseContinuation()
        #expect(offered.documentText == dismissed.documentText)
        #expect(EquivalenceKey(engine: offered) != EquivalenceKey(engine: dismissed))
        #expect(offered.handle(.acceptChineseContinuation).documentText == "SQL 資料庫")
        #expect(!dismissed.handle(.acceptChineseContinuation).handled)
    }
}
