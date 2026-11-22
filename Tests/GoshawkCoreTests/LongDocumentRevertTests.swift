import GoshawkCore
import Testing

@Suite("長文件的反悔")
struct LongDocumentRevertTests {
    @Test("中英與標點反悔只改尾端，保留整段前文的原始 Unicode 編碼")
    func preservesPrefix() {
        // 同一個字素可能包含多個純量。逐位元組核對可攔下截斷前文或正規化前文的改動。
        let prefix = String(repeating: "e\u{301}🇹🇼👩🏽‍💻𠮷\u{E0100}。", count: 512)
        var engine = InputEngine(initialDocumentText: prefix)
        engine.handle(.character("m"))
        engine.handle(.character("y"))
        engine.handle(.space)
        let english = engine.handle(.shiftSpace)
        #expect(english.deletedBackwardCount == 1)
        #expect(english.committedText == "my ")
        #expect(english.documentText.utf8.elementsEqual((prefix + "my ").utf8))

        engine.handle(.character(","))
        let punctuation = engine.handle(.shiftSpace)
        #expect(punctuation.deletedBackwardCount == 1)
        #expect(punctuation.committedText == "，")
        #expect(punctuation.documentText.utf8.elementsEqual((prefix + "my，").utf8))
        #expect(engine.handle(.shiftSpace).documentText.utf8.elementsEqual((prefix + "my,").utf8))
    }
}

@Suite("前文鏡像的長度上限")
struct DocumentMirrorLimitTests {
    static let limit = InputEngine.documentMirrorLimit

    /// 每個字素都由多個純量組成，最後一個是全形句號，所以結尾是中文語境。
    static let unit = "e\u{301}🇹🇼👩🏽‍💻𠮷\u{E0100}。"

    /// 正好 `count` 個字素、以全形句號結尾的前文。
    static func prefix(count: Int) -> String {
        let repeats = count / unit.count + 1
        return String(String(repeating: unit, count: repeats).suffix(count))
    }

    /// 按一個鍵，並核對鏡像只是「回刪後接上送出文字」再留下尾端：
    /// 逐位元組比對，截破字素或正規化都會在這裡失敗。
    @discardableResult
    static func press(
        _ engine: inout InputEngine,
        _ input: KeyInput,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> StepEffect {
        let before = engine.documentText
        let effect = engine.handle(input)
        if effect.handled {
            let whole = String(before.dropLast(effect.deletedBackwardCount)) + (effect.committedText ?? "")
            let expected = String(whole.suffix(limit))
            // 先算成布林值：失敗訊息才不會印出整份八千多字的文件。
            let mirrorIsTail = engine.documentText.utf8.elementsEqual(expected.utf8)
            #expect(mirrorIsTail, sourceLocation: sourceLocation)
        }
        let effectMatchesEngine = effect.documentText.utf8.elementsEqual(engine.documentText.utf8)
        #expect(effectMatchesEngine, sourceLocation: sourceLocation)
        #expect(engine.documentText.count <= limit, sourceLocation: sourceLocation)
        if let record = engine.revertRecord {
            #expect(record.snapshot.documentText.count <= limit, sourceLocation: sourceLocation)
        }
        return effect
    }

    @Test("上限遠大於前文視窗、成對切換的整段與既有的長文件案例")
    func limitLeavesRoomForExistingContracts() {
        #expect(Self.limit == 8192)
        #expect(Self.limit > InputEngine.contextWindowLength)
        #expect(Self.limit > InputEngine.pairSwitchSpanLimit)
    }

    @Test("起始前文超過上限時只留尾端，沒超過就原樣保留")
    func initialDocumentIsTrimmed() {
        let long = Self.prefix(count: Self.limit + 500)
        let engine = InputEngine(initialDocumentText: long)
        #expect(engine.documentText.count == Self.limit)
        #expect(engine.documentText.utf8.elementsEqual(String(long.suffix(Self.limit)).utf8))

        let exact = Self.prefix(count: Self.limit)
        #expect(InputEngine(initialDocumentText: exact).documentText.utf8.elementsEqual(exact.utf8))
    }

    @Test("跨過上限那一步的中英反悔只回刪剛送出的字元")
    func trackRevertAcrossLimit() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        Self.press(&engine, .character("m"))
        Self.press(&engine, .character("y"))
        let chinese = Self.press(&engine, .space)
        #expect(chinese.committedText == "下")
        #expect(chinese.deletedBackwardCount == 0)
        #expect(engine.documentText.count == Self.limit)

        let english = Self.press(&engine, .shiftSpace)
        #expect(english.deletedBackwardCount == 1)
        #expect(english.committedText == "my ")
        #expect(engine.documentText.hasSuffix("。my "))

        let back = Self.press(&engine, .shiftSpace)
        #expect(back.deletedBackwardCount == 3)
        #expect(back.committedText == "下")
        #expect(engine.documentText.hasSuffix("。下"))
    }

    @Test("跨過上限的反悔等同直接按另一個鍵")
    func revertAcrossLimitEqualsAlternative() {
        let start = Self.prefix(count: Self.limit)
        var reverted = InputEngine(initialDocumentText: start)
        reverted.handle(.character("m"))
        reverted.handle(.character("y"))
        reverted.handle(.space)
        reverted.handle(.shiftSpace)

        var direct = InputEngine(initialDocumentText: start)
        direct.handle(.character("m"))
        direct.handle(.character("y"))
        direct.handle(.tab)

        #expect(reverted.documentText.utf8.elementsEqual(direct.documentText.utf8))
        #expect(reverted.pendingAutoSpace == direct.pendingAutoSpace)
        #expect(reverted.usageHistory == direct.usageHistory)
        #expect(reverted.revertRecord?.snapshot == direct.revertRecord?.snapshot)
    }

    @Test("跨過上限那一步的標點寬度對調只換那一個標點")
    func punctuationWidthAcrossLimit() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        let comma = Self.press(&engine, .character(","))
        #expect(comma.committedText == "，")
        #expect(engine.documentText.count == Self.limit)

        let half = Self.press(&engine, .shiftSpace)
        #expect(half.deletedBackwardCount == 1)
        #expect(half.committedText == ",")

        let full = Self.press(&engine, .shiftSpace)
        #expect(full.deletedBackwardCount == 1)
        #expect(full.committedText == "，")
        #expect(engine.documentText.hasSuffix("。，"))
    }

    @Test("跨過上限那一步的成對符號切換整對一起換")
    func pairSwitchAcrossLimit() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        let opener = Self.press(&engine, .character("["))
        #expect(opener.committedText == "「")
        let halfOpener = Self.press(&engine, .shiftSpace)
        #expect(halfOpener.deletedBackwardCount == 1)
        #expect(halfOpener.committedText == "[")
        // 轉滿一圈回到「，八種各經過一次。
        for _ in 0..<7 {
            #expect(Self.press(&engine, .shiftSpace).deletedBackwardCount == 1)
        }
        #expect(engine.documentText.hasSuffix("。「"))

        Self.press(&engine, .character("m"))
        Self.press(&engine, .character("y"))
        Self.press(&engine, .space)
        let closer = Self.press(&engine, .character("]"))
        #expect(closer.committedText == "」")
        #expect(engine.documentText.hasSuffix("。「下」"))

        let switched = Self.press(&engine, .shiftSpace)
        #expect(switched.deletedBackwardCount == 3)
        #expect(switched.committedText == "[下]")

        let picked = Self.press(&engine, .character("4"))
        #expect(picked.deletedBackwardCount == 3)
        #expect(picked.committedText == "《下》")
        #expect(engine.documentText.hasSuffix("。《下》"))
        #expect(engine.documentText.count == Self.limit)
    }

    @Test("開頭在上限之前打出、結尾跨過上限時仍然整對切換")
    func pairClosedOnTheCrossingStep() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit - 2))
        Self.press(&engine, .character("["))
        Self.press(&engine, .character("m"))
        Self.press(&engine, .character("y"))
        Self.press(&engine, .space)
        #expect(engine.documentText.count == Self.limit)
        let closer = Self.press(&engine, .character("]"))
        #expect(closer.committedText == "」")
        let switched = Self.press(&engine, .shiftSpace)
        #expect(switched.deletedBackwardCount == 3)
        #expect(switched.committedText == "[下]")
        #expect(engine.documentText.count == Self.limit)
    }

    @Test("到達上限後的退格只拿掉最後一個字元，加一碼再退格完全還原")
    func backspaceAtLimit() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        Self.press(&engine, .character("m"))
        Self.press(&engine, .character("y"))
        Self.press(&engine, .space)

        let idle = engine
        Self.press(&engine, .character("m"))
        Self.press(&engine, .backspace)
        #expect(engine.state == idle.state)
        #expect(engine.buffer == idle.buffer)
        #expect(engine.pendingAutoSpace == idle.pendingAutoSpace)
        #expect(engine.documentText.utf8.elementsEqual(idle.documentText.utf8))

        let deleted = Self.press(&engine, .backspace)
        #expect(deleted.handled == false)
        #expect(engine.documentText.utf8.elementsEqual(String(idle.documentText.dropLast()).utf8))
        #expect(engine.documentText.count == Self.limit - 1)
    }

    @Test("從空白文件連續輸入超過上限，鏡像始終不超過上限")
    func continuousTypingStaysBounded() {
        var engine = InputEngine()
        // 中文、補了空格的英文與收合空格的標點交錯，一輪至少送出「下 id,」五個字元。
        let round: [KeyInput] = [
            .character("m"), .character("y"), .space,
            .character("i"), .character("d"), .tab, .character(","),
        ]
        let rounds = (Self.limit + 500) / 5 + 1
        for index in 0..<rounds {
            // 最後幾輪逐鍵核對鏡像的內容，其餘只看長度，測試才不會慢。
            if index >= rounds - 20 {
                for input in round { Self.press(&engine, input) }
            } else {
                for input in round { engine.handle(input) }
                #expect(engine.documentText.count <= Self.limit)
            }
        }
        #expect(engine.documentText.count == Self.limit)
        #expect(engine.documentText.hasSuffix("下 id, 下 id,"))
    }

    @Test("超過上限的前文與只給尾端的前文，按鍵結果完全相同")
    func longMirrorBehavesLikeItsTail() {
        let long = Self.prefix(count: Self.limit + 500)
        let scripts: [[KeyInput]] = [
            // 自動空格與收合。
            [.character("i"), .character("d"), .tab, .character("m"), .character("y"), .space, .character(".")],
            // 片段：英文優先、片段裡半形、關上後第一個標點看開啟時的語境。
            [.character("`"), .character("i"), .character("d"), .space, .character(","), .character("`"), .character(".")],
            // 片段裡黏中與反悔。
            [.character("`"), .character("m"), .character("y"), .shiftSpace, .space, .character("m"), .character("y"),
             .space, .shiftSpace, .character("`")],
            // 成對符號跟隨與片段裡的跟隨。
            [.character("["), .shiftSpace, .shiftSpace, .character("1"), .character("]"), .shiftSpace, .character("6")],
            [.character("`"), .character("["), .character("m"), .character("y"), .space, .character("]"), .shiftSpace],
        ]
        for script in scripts {
            var bounded = InputEngine(initialDocumentText: long)
            var tail = InputEngine(initialDocumentText: String(long.suffix(64)))
            for input in script {
                let boundedEffect = Self.press(&bounded, input)
                let tailEffect = tail.handle(input)
                #expect(boundedEffect.committedText == tailEffect.committedText)
                #expect(boundedEffect.deletedBackwardCount == tailEffect.deletedBackwardCount)
                #expect(boundedEffect.commitKind == tailEffect.commitKind)
                #expect(boundedEffect.handled == tailEffect.handled)
                #expect(boundedEffect.revertible == tailEffect.revertible)
                #expect(boundedEffect.pairChoice == tailEffect.pairChoice)
                #expect(bounded.state == tail.state)
                #expect(bounded.buffer == tail.buffer)
                #expect(bounded.pendingAutoSpace == tail.pendingAutoSpace)
                #expect(bounded.snippet == tail.snippet)
                #expect(bounded.documentText.hasSuffix(tail.documentText.suffix(64)))
            }
        }
    }

    @Test("在上限邊界接受中文接詞，鏡像照樣裁到上限以內")
    func acceptedContinuationIsTrimmed() {
        var configuration = EngineConfiguration()
        configuration.chineseContinuationEnabled = true
        let start = String(repeating: "甲", count: Self.limit - 2) + "資"
        var engine = InputEngine(configuration: configuration, initialDocumentText: start)
        for key in "fdyj" { Self.press(&engine, .character(key)) }
        #expect(Self.press(&engine, .space).committedText == "料")
        #expect(engine.documentText.count == Self.limit)
        let offered = engine.chineseContinuation
        #expect(offered != nil)

        let accepted = Self.press(&engine, .acceptChineseContinuation)
        #expect(accepted.committedText == offered)
        #expect(accepted.deletedBackwardCount == 0)
        #expect(engine.documentText.count == Self.limit)
        #expect(engine.documentText.hasSuffix("資料" + (offered ?? "")))
    }

    @Test("宿主結束組字送出原字母之後，鏡像照樣裁到上限以內")
    func finishedHostCompositionIsTrimmed() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        engine.handle(.character("m"))
        engine.handle(.character("y"))
        #expect(engine.finishHostComposition() == "my")
        #expect(engine.documentText.count == Self.limit)
        #expect(engine.documentText.hasSuffix("。my"))

        // 疊加層開著時走另一條送出路徑，同樣要裁。
        var layered = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        layered.handle(.character("m"))
        layered.handle(.character("y"))
        layered.handle(.toggleReadingLookup)
        #expect(layered.finishHostComposition() == "my")
        #expect(layered.documentText.count == Self.limit)
        #expect(layered.documentText.hasSuffix("。my"))
    }

    @Test("宿主回報的前文與裁過的鏡像尾端相符時，鏡像與反悔紀錄都不動")
    func externalContextStillAgreesAfterTrim() {
        var engine = InputEngine(initialDocumentText: Self.prefix(count: Self.limit))
        engine.handle(.character("m"))
        engine.handle(.character("y"))
        engine.handle(.space)
        let trimmed = engine.documentText
        // 文件比視窗長，外層讀到的前文沒到文件開頭，所以會說它被裁過。
        engine.syncExternalContext(String(trimmed.suffix(InputEngine.contextWindowLength)), isClipped: true)
        #expect(engine.documentText.utf8.elementsEqual(trimmed.utf8))
        #expect(engine.revertRecord != nil)
        #expect(engine.handle(.shiftSpace).deletedBackwardCount == 1)
    }
}
