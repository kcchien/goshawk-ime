import GoshawkCore
import Testing

private func engine(
    _ keys: String,
    context: String = "",
    configuration: EngineConfiguration = EngineConfiguration()
) -> InputEngine {
    var engine = InputEngine(configuration: configuration, initialDocumentText: context)
    for token in keys.split(separator: " ").map(String.init) {
        guard let key = KeyInput.parse(token: token) else {
            Issue.record("Unknown token in test: \(token)")
            return engine
        }
        engine.handle(key)
    }
    return engine
}

private func document(
    _ keys: String,
    context: String = "",
    configuration: EngineConfiguration = EngineConfiguration()
) -> String {
    engine(keys, context: context, configuration: configuration).documentText
}

@Suite("成對符號的種類與掃描")
struct PairStyleTests {
    @Test("八種的開頭與結尾，順序就是編號")
    func openersAndClosers() {
        #expect(PairStyle.allCases.map { "\($0.opener)\($0.closer)" }
            == ["「」", "[]", "『』", "《》", "〈〉", "【】", "“”", "‘’"])
        for style in PairStyle.allCases {
            #expect(PairStyle.style(opening: style.opener) == style)
            #expect(PairStyle.style(closing: style.closer) == style)
            #expect(PairStyle.style(opening: style.closer) == nil)
            #expect(PairStyle.style(closing: style.opener) == nil)
        }
        // 直引號、圓括號、花括號不在清單裡。
        for ch in "\"'(){}<>〔〕" {
            #expect(PairStyle.style(opening: ch) == nil)
            #expect(PairStyle.style(closing: ch) == nil)
        }
    }

    @Test("循環順序：半形方括號起點第一下先到角引號，其餘從自己的位置往後走")
    func cycleOrder() {
        #expect(PairStyle.cycle(from: .square)
            == [.square, .corner, .doubleCorner, .doubleAngle, .singleAngle, .lenticular, .curlyDouble, .curlySingle])
        #expect(PairStyle.cycle(from: .corner) == PairStyle.allCases)
        #expect(PairStyle.cycle(from: .doubleCorner)
            == [.doubleCorner, .doubleAngle, .singleAngle, .lenticular, .curlyDouble, .curlySingle, .corner, .square])
        for origin in PairStyle.allCases {
            let cycle = PairStyle.cycle(from: origin)
            #expect(cycle.first == origin)
            #expect(Set(cycle).count == PairStyle.allCases.count)
        }
    }

    private func unclosed(_ text: String, stopAtBacktick: Bool = false) -> PairStyle? {
        PunctuationMapper.unclosedPairOpener(in: text, stopAtBacktick: stopAtBacktick)?.style
    }

    @Test("八種各自配對")
    func eachStyleIsRecognised() {
        for style in PairStyle.allCases {
            #expect(unclosed("\(style.opener)內容") == style)
            #expect(unclosed("\(style.opener)內容\(style.closer)") == nil)
        }
    }

    @Test("巢狀、相鄰、交錯、落單結尾與空字串")
    func nestingAndStrayClosers() {
        #expect(unclosed("") == nil)
        #expect(unclosed("沒有括號") == nil)
        #expect(unclosed("「『日』") == .corner)
        #expect(unclosed("「『日") == .doubleCorner)
        #expect(unclosed("「日」「月」") == nil)
        #expect(unclosed("「日」《月") == .doubleAngle)
        // 交錯：角引號已經被自己的結尾關上，剩下書名號。
        #expect(unclosed("「《」") == .doubleAngle)
        // 落單的結尾只抵銷同一種的開頭。
        #expect(unclosed("「a》b") == .corner)
        #expect(unclosed("」") == nil)
        #expect(unclosed("(0, 1") == nil)
    }

    @Test("回傳的位置就是那個開頭")
    func reportsTheOpenerIndex() {
        let text = "前文「『日』月"
        let found = PunctuationMapper.unclosedPairOpener(in: text, stopAtBacktick: false)
        #expect(found.map { String(text[$0.index...]) } == "「『日』月")
    }

    @Test("片段裡只看反引號之後")
    func stopsAtTheBacktick() {
        #expect(unclosed("「`x", stopAtBacktick: true) == nil)
        #expect(unclosed("「`x", stopAtBacktick: false) == .corner)
        #expect(unclosed("`「x", stopAtBacktick: true) == .corner)
    }
}

@Suite("右方括號跟隨未關閉的開頭")
struct BracketFollowTests {
    @Test("跟最近一個未關閉的開頭，八種都認")
    func followsTheNearestUnclosedOpener() {
        #expect(document("LBRACKET m y SPACE RBRACKET") == "「下」")
        #expect(document("CTRL_SHIFT_LBRACKET m y SPACE RBRACKET") == "『下』")
        #expect(document("LBRACE a SPACE RBRACKET") == "『日』")
        #expect(document("RBRACKET", context: "《書") == "《書》")
        #expect(document("LBRACKET a SPACE RBRACKET", context: "abc") == "abc[日]")
        for style in PairStyle.allCases {
            #expect(document("a SPACE RBRACKET", context: String(style.opener)) == "\(style.opener)日\(style.closer)")
        }
    }

    @Test("巢狀由內而外，各層可以是不同種類")
    func closesNestedPairsInsideOut() {
        #expect(document("LBRACKET LBRACKET a SPACE RBRACKET RBRACKET") == "「「日」」")
        #expect(document("LBRACKET LBRACE a SPACE RBRACKET RBRACKET") == "「『日』」")
        #expect(document("RBRACKET RBRACKET", context: "《〈日") == "《〈日〉》")
    }

    @Test("沒有開頭時照語境，寬度照樣可以對調")
    func withoutAnOpenerItFollowsContext() {
        #expect(document("RBRACKET") == "」")
        #expect(document("RBRACKET SHIFT_SPACE") == "]")
        #expect(document("RBRACKET SHIFT_SPACE SHIFT_SPACE") == "」")
        #expect(document("RBRACKET", context: "(0, 1") == "(0, 1]")
        // 開頭已經關上就不再跟它。
        #expect(document("RBRACKET", context: "abc《書》") == "abc《書》」")
    }

    @Test("優先於片段的半形與半形標點設定")
    func winsOverSnippetAndHalfwidthSetting() {
        #expect(document("BACKTICK LBRACKET SHIFT_SPACE x RBRACKET", context: "中") == "中`「x」")
        // 片段裡沒有全形開頭時仍是半形。
        #expect(document("BACKTICK LBRACKET x RBRACKET", context: "中") == "中`[x]")
        let halfwidth = EngineConfiguration(autoPunctuationEnabled: false)
        #expect(document("LBRACKET SHIFT_SPACE RBRACKET", context: "中", configuration: halfwidth) == "中「」")
        #expect(document("LBRACKET RBRACKET", context: "中", configuration: halfwidth) == "中[]")
        #expect(document("RBRACKET", context: "中", configuration: halfwidth) == "中]")
    }

    @Test("片段裡只看片段內的開頭")
    func insideASnippetOnlyTheSnippetCounts() {
        #expect(document("BACKTICK x RBRACKET", context: "「") == "「`x]")
        // 片段裡自己的開頭關上之後，不會再去關片段外的那一個。
        #expect(document("BACKTICK LBRACKET SHIFT_SPACE x RBRACKET RBRACKET", context: "「") == "「`「x」]")
        // 片段關上之後又看得到整份前文。
        #expect(document("BACKTICK x BACKTICK RBRACKET", context: "「") == "「`x`」")
    }

    @Test("Option 與 Ctrl 加右方括號照字面，不留紀錄")
    func explicitKeysStayLiteral() {
        let option = engine("LBRACKET a SPACE OPT_]")
        #expect(option.documentText == "「日]")
        #expect(option.revertRecord == nil)
        let optionAfterDouble = engine("CTRL_SHIFT_LBRACKET a SPACE OPT_]")
        #expect(optionAfterDouble.documentText == "『日]")
        #expect(optionAfterDouble.revertRecord == nil)
        let ctrl = engine("CTRL_SHIFT_LBRACKET a SPACE CTRL_RBRACKET")
        #expect(ctrl.documentText == "『日」")
        #expect(ctrl.revertRecord == nil)
    }

    @Test("收合只看鍵：跟隨哪一種都收合英文後自動補上的那一格")
    func collapsesTheAutoSpaceWhateverTheStyle() {
        var square = engine("i d TAB LBRACKET i d TAB")
        #expect(square.documentText == "id [id ")
        let closed = square.handle(.character("]"))
        #expect(closed.deletedBackwardCount == 1)
        #expect(closed.committedText == "]")
        #expect(square.documentText == "id [id]")

        var double = engine("i d TAB", context: "『")
        let doubleClosed = double.handle(.character("]"))
        #expect(doubleClosed.deletedBackwardCount == 1)
        #expect(doubleClosed.committedText == "』")
        #expect(double.documentText == "『id』")
        // 手動空白不是待收合的那一格。
        #expect(document("i d ENTER SPACE RBRACKET", context: "《") == "《id 》")
    }

    @Test("帶著緩衝按右方括號：先照原本的規則結束組字，再跟隨開頭")
    func settlesTheBufferFirst() {
        var composing = engine("CTRL_SHIFT_LBRACKET a")
        let effect = composing.handle(.character("]"))
        #expect(effect.committedText == "日』")
        #expect(effect.committedCore == "』")
        #expect(effect.commitKind == .punctuation)
        #expect(composing.documentText == "『日』")
    }

    @Test("其他來源的開頭靠掃描認到：半形層、符號面板")
    func openersFromOtherSourcesAreFound() {
        #expect(document("CAPS_ON LBRACKET CAPS_OFF a SPACE RBRACKET") == "[日]")
        // 符號面板「符號」分頁第一頁的第一列是【。
        let picked = engine("SYMBOLS TAB TAB 1")
        #expect(picked.documentText == "【")
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET") == "【日】")
        // 「標點」分頁第二頁的第二、第四列是「與『。
        #expect(document("SYMBOLS TAB PGDN 2 a SPACE RBRACKET") == "「日」")
        #expect(document("SYMBOLS TAB PGDN 4 a SPACE RBRACKET") == "『日』")
    }

    /// 開頭不在「最近使用」的初始清單裡，要多按幾個鍵才選得到，模型檢查在深度 5 只走到
    /// 「選出開頭再關上」那一步。關上之後的切換、直選，以及其他設定下的結果在這裡補。
    @Test("從符號面板選出的開頭關上之後，整對切換與數字直選照常；各設定下結尾都跟隨")
    func pairFromPanelOpenerSwitchesLikeTypedOne() {
        for (pick, typed) in [("SYMBOLS TAB TAB 1", "LBRACKET SHIFT_SPACE SHIFT_SPACE SHIFT_SPACE SHIFT_SPACE SHIFT_SPACE"),
                              ("SYMBOLS TAB PGDN 2", "LBRACKET"),
                              ("SYMBOLS TAB PGDN 4", "LBRACKET SHIFT_SPACE SHIFT_SPACE")] {
            for tail in ["a SPACE RBRACKET", "a SPACE RBRACKET SHIFT_SPACE", "a SPACE RBRACKET SHIFT_SPACE 4",
                         "a SPACE RBRACKET SHIFT_SPACE SHIFT_SPACE", "RBRACKET SHIFT_SPACE 1 1"] {
                let fromPanel = engine("\(pick) \(tail)")
                let fromKey = engine("\(typed) \(tail)")
                #expect(fromPanel.documentText == fromKey.documentText, "\(pick) \(tail)")
                #expect(fromPanel.revertRecord?.kind == fromKey.revertRecord?.kind, "\(pick) \(tail)")
            }
        }
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET SHIFT_SPACE") == "“日”")
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET SHIFT_SPACE 4") == "《日》")
        #expect(document("SYMBOLS TAB PGDN 2 RBRACKET SHIFT_SPACE 1 1") == "「」1")

        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET", configuration: chineseOnly) == "【日】")
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET SHIFT_SPACE", configuration: chineseOnly) == "“日”")
        // 關閉一鍵反悔後沒有切換，結尾照樣跟隨，Shift+空白 是一般空白。
        let revertOff = EngineConfiguration(revertEnabled: false)
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET", configuration: revertOff) == "【日】")
        #expect(document("SYMBOLS TAB TAB 1 a SPACE RBRACKET SHIFT_SPACE", configuration: revertOff) == "【日】 ")
        let v5 = EngineConfiguration(cangjieVersion: .v5)
        #expect(document("SYMBOLS TAB PGDN 4 a SPACE RBRACKET SHIFT_SPACE", configuration: v5) == "《日》")
        // 面板選出的結尾也配得到開頭，選取不留紀錄，所以緊接的 Shift+空白 不切換。
        let closedByPanel = engine("LBRACKET a SPACE SYMBOLS TAB PGDN 3")
        #expect(closedByPanel.documentText == "「日」" && closedByPanel.revertRecord == nil)
    }

    @Test("前文鏡像沒有開頭時照沒有開頭處理")
    func invalidatedMirrorHasNoOpener() {
        // 閒置的 Enter 放行給宿主，鏡像清空。
        #expect(document("LBRACKET a SPACE ENTER RBRACKET") == "」")
        // 閒置退格刪掉開頭本身。
        #expect(document("LBRACKET BKSP RBRACKET", context: "abc") == "abc]")
        var resynced = engine("CTRL_SHIFT_LBRACKET a SPACE")
        resynced.syncExternalContext("別的內容")
        resynced.handle(.character("]"))
        #expect(resynced.documentText == "別的內容」")
    }

    @Test("純中文模式、Caps Lock 與純英文層")
    func otherModesAndLayers() {
        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)
        #expect(document("CTRL_SHIFT_LBRACKET m y SPACE RBRACKET", configuration: chineseOnly) == "『下』")
        #expect(document("RBRACKET", context: "《書", configuration: chineseOnly) == "《書》")
        // 半形層直出鍵面字元，不跟隨也不留紀錄。
        let caps = engine("CAPS_ON RBRACKET", context: "『日")
        #expect(caps.documentText == "『日]")
        #expect(caps.revertRecord == nil)
        let pureEnglish = engine("DBL_SHIFT RBRACKET", context: "『日")
        #expect(pureEnglish.documentText == "『日]")
        #expect(pureEnglish.revertRecord == nil)
    }

    @Test("關閉一鍵反悔後照樣跟隨，只是沒有紀錄")
    func followsWithRevertDisabled() {
        let off = EngineConfiguration(revertEnabled: false)
        let closed = engine("CTRL_SHIFT_LBRACKET m y SPACE RBRACKET", configuration: off)
        #expect(closed.documentText == "『下』")
        #expect(closed.revertRecord == nil)
    }
}

@Suite("配到開頭的右方括號留下的紀錄")
struct BracketPairRecordTests {
    @Test("紀錄是結尾側的成對紀錄，文字是鏡像上從開頭到結尾的整段")
    func recordsTheWholeSpan() {
        var typed = engine("CTRL_SHIFT_LBRACKET m y SPACE")
        let effect = typed.handle(.character("]"))
        #expect(effect.committedText == "』")
        #expect(effect.revertible)
        #expect(effect.revertPreview == nil)
        let record = typed.revertRecord
        #expect(record?.kind == .pair(PairSwitch(side: .closer, origin: .doubleCorner, current: .doubleCorner, step: .typed)))
        #expect(record?.committedText == "『下』")
        #expect(record?.committedCore == "』")
        #expect(record?.alternativeCore == "》")

        // 連帶送出的緩衝與收合掉的空格都算在整段裡。
        #expect(engine("LBRACKET a RBRACKET").revertRecord?.committedText == "「日」")
        #expect(engine("i d TAB LBRACKET i d TAB RBRACKET").revertRecord?.committedText == "[id]")
        // 巢狀時只算最內層剛關上的那一對。
        #expect(engine("LBRACKET LBRACE a SPACE RBRACKET").revertRecord?.committedText == "『日』")
        // 內容含 BMP 以外的漢字。
        #expect(engine("RBRACKET", context: "《𠮷").revertRecord?.committedText == "《𠮷》")
    }

    @Test("沒配到開頭的右方括號仍是寬度對調的紀錄，左方括號是開頭側的成對紀錄")
    func unpairedCloserKeepsTheWidthRecord() {
        #expect(engine("RBRACKET").revertRecord?.kind == .punctuationWidth(key: "]", swapToFullwidth: false))
        #expect(engine("LBRACKET").revertRecord?.kind
            == .pair(PairSwitch(side: .opener, origin: .corner, current: .corner, step: .typed)))
    }

    @Test("配到開頭的結尾不單獨換寬度：開頭一定跟著換")
    func closerNeverSwapsAlone() {
        #expect(document("LBRACKET RBRACKET SHIFT_SPACE") == "[]")
        #expect(document("BACKTICK LBRACKET SHIFT_SPACE RBRACKET SHIFT_SPACE") == "`[]")
    }

    @Test("紀錄只活一個按鍵")
    func recordLivesForOneKey() {
        #expect(document("LBRACKET m y SPACE RBRACKET SPACE SHIFT_SPACE") == "「下」  ")
        // 切換之後隔了一個按鍵也一樣。
        #expect(document("LBRACKET m y SPACE RBRACKET SHIFT_SPACE SPACE SHIFT_SPACE") == "[下]  ")
    }

    @Test("涵蓋更早送出的只有結尾側的成對紀錄")
    func onlyCloserRecordsSpanEarlierCommits() {
        #expect(engine("LBRACKET m y SPACE RBRACKET").revertRecord?.spansEarlierCommits == true)
        #expect(engine("LBRACKET m y SPACE RBRACKET SHIFT_SPACE").revertRecord?.spansEarlierCommits == true)
        #expect(engine("LBRACKET").revertRecord?.spansEarlierCommits == false)
        #expect(engine("RBRACKET").revertRecord?.spansEarlierCommits == false)
        #expect(engine("m y SPACE").revertRecord?.spansEarlierCommits == false)
    }

    @Test("反悔的按鍵：有紀錄時的 Shift+空白")
    func revertInput() {
        let closed = engine("LBRACKET m y SPACE RBRACKET")
        #expect(closed.isRevertInput(.shiftSpace))
        #expect(!closed.isRevertInput(.space))
        #expect(!closed.isRevertInput(.character("4")))
        #expect(!engine("LBRACKET m y SPACE RBRACKET SPACE").isRevertInput(.shiftSpace))
        #expect(!engine("m y").isRevertInput(.shiftSpace))
    }
}

@Suite("配到開頭的右方括號之後成對切換")
struct BracketPairSwitchTests {
    @Test("整段一起換，八下回原樣")
    func switchesTheWholePair() {
        #expect(cycled("LBRACKET m y SPACE RBRACKET")
            == ["[下]", "『下』", "《下》", "〈下〉", "【下】", "“下”", "‘下’", "「下」"])
        // 半形方括號起點：第一下先到角引號。
        #expect(cycled("LBRACKET a SPACE RBRACKET", context: "abc")
            == ["abc「日」", "abc『日』", "abc《日》", "abc〈日〉", "abc【日】", "abc“日”", "abc‘日’", "abc[日]"])
        // 再走一圈仍是同一個順序。
        #expect(cycled("LBRACKET a SPACE RBRACKET", context: "abc", count: 10).suffix(2) == ["abc「日」", "abc『日』"])
    }

    @Test("從配到的種類往後走")
    func continuesFromTheMatchedStyle() {
        #expect(cycled("CTRL_SHIFT_LBRACKET m y SPACE RBRACKET", count: 1) == ["《下》"])
        #expect(cycled("RBRACKET", context: "‘好", count: 2) == ["「好」", "[好]"])
    }

    @Test("效果與紀錄：回刪整段、送出整段，紀錄留在結尾側並帶選項列")
    func effectAndRecord() {
        var subject = engine("LBRACKET m y SPACE RBRACKET")
        let first = subject.handle(.shiftSpace)
        #expect(first.handled)
        #expect(first.committedText == "[下]")
        #expect(first.committedCore == "]")
        #expect(first.commitKind == .punctuation)
        #expect(first.deletedBackwardCount == 3)
        #expect(first.revertible)
        #expect(first.revertPreview == nil)
        #expect(first.pairChoice?.current == .square)
        let record = subject.revertRecord
        #expect(record?.kind == .pair(PairSwitch(side: .closer, origin: .corner, current: .square, step: .cycled)))
        #expect(record?.committedText == "[下]")
        #expect(record?.committedCore == "]")
        #expect(record?.alternativeCore == "』")

        let second = subject.handle(.shiftSpace)
        #expect(second.committedText == "『下』")
        #expect(second.deletedBackwardCount == 3)
        #expect(second.pairChoice?.current == .doubleCorner)
        // 選項列只活到下一個不是切換的按鍵。
        #expect(subject.handle(.character("a")).pairChoice == nil)
        #expect(subject.revertRecord == nil)
    }

    @Test("結尾帶著緩衝：連帶送出的字留在整段裡，學習紀錄等同直接送出")
    func closerWithBuffer() {
        var switched = engine("LBRACKET a RBRACKET")
        let effect = switched.handle(.shiftSpace)
        #expect(effect.committedText == "[日]")
        #expect(effect.deletedBackwardCount == 3)
        #expect(switched.documentText == "[日]")
        let direct = engine("LBRACKET a RBRACKET")
        #expect(switched.usageHistory == direct.usageHistory)
        #expect(switched.state == .idle)
        #expect(switched.buffer.isEmpty)
    }

    @Test("空格數不變：收合掉的那一格不會回來，開頭前的那一格不動")
    func keepsSpaces() {
        var subject = engine("i d TAB LBRACKET i d TAB RBRACKET")
        let effect = subject.handle(.shiftSpace)
        #expect(subject.documentText == "id 「id」")
        #expect(effect.committedText == "「id」")
        #expect(effect.deletedBackwardCount == 4)
        #expect(!subject.pendingAutoSpace)
    }

    @Test("只換最內層剛關上的那一對")
    func onlyTheInnermostPair() {
        var subject = engine("LBRACKET LBRACKET a SPACE RBRACKET")
        #expect(subject.documentText == "「「日」")
        subject.handle(.shiftSpace)
        #expect(subject.documentText == "「[日]")
        subject.handle(.shiftSpace)
        #expect(subject.documentText == "「『日』")
        subject.handle(.character("]"))
        #expect(subject.documentText == "「『日』」")
        let outer = subject.handle(.shiftSpace)
        #expect(subject.documentText == "[『日』]")
        #expect(outer.deletedBackwardCount == 5)
    }

    @Test("內容逐字不變，含 BMP 以外的漢字與別種的落單結尾")
    func contentIsUntouched() {
        #expect(cycled("LBRACKET i d TAB RBRACKET", context: "abc", count: 1) == ["abc「id」"])
        var astral = engine("RBRACKET", context: "《𠮷")
        let effect = astral.handle(.shiftSpace)
        #expect(astral.documentText == "〈𠮷〉")
        #expect(effect.deletedBackwardCount == 3)
        #expect(effect.committedText == "〈𠮷〉")
        // 每次都從送出前的鏡像重找開頭：內容裡新種類的落單結尾不會被拿去配新的開頭。
        #expect(cycled("RBRACKET", context: "「a》b", count: 3) == ["[a》b]", "『a》b』", "《a》b》"])
    }

    @Test("片段裡也適用，片段語境不變")
    func worksInsideASnippet() {
        var subject = engine("BACKTICK LBRACKET x RBRACKET", context: "中")
        #expect(subject.documentText == "中`[x]")
        let before = subject.snippet
        subject.handle(.shiftSpace)
        #expect(subject.documentText == "中`「x」")
        #expect(subject.snippet == before)
    }

    @Test("半形層送的開頭也算；純中文模式也適用")
    func openersFromOtherLayers() {
        #expect(cycled("CAPS_ON LBRACKET CAPS_OFF a SPACE RBRACKET", count: 1) == ["「日」"])
        #expect(cycled("LBRACKET m y SPACE RBRACKET", count: 2,
                       configuration: EngineConfiguration(mixedModeEnabled: false)) == ["[下]", "『下』"])
        #expect(cycled("LBRACKET SHIFT_SPACE RBRACKET", context: "中", count: 1,
                       configuration: EngineConfiguration(autoPunctuationEnabled: false)) == ["中[]"])
    }

    @Test("切換前後待收合空格、片段語境、學習紀錄與狀態都相同")
    func nothingElseChanges() {
        let typed = engine("m y SPACE LBRACKET i d TAB RBRACKET")
        var switched = typed
        switched.handle(.shiftSpace)
        #expect(typed.documentText == "下「id」")
        #expect(switched.documentText == "下[id]")
        #expect(switched.pendingAutoSpace == typed.pendingAutoSpace)
        #expect(switched.snippet == typed.snippet)
        #expect(switched.usageHistory == typed.usageHistory)
        #expect(switched.state == typed.state)
        #expect(switched.buffer == typed.buffer)
    }

    private func refused(_ subject: InputEngine) -> Bool {
        var engine = subject
        let document = engine.documentText
        let effect = engine.handle(.shiftSpace)
        return effect.handled && effect.committedText == nil && effect.deletedBackwardCount == 0
            && !effect.revertible && effect.pairChoice == nil
            && engine.documentText == document && engine.revertRecord == nil
    }

    @Test("整段正好三十二個字換得了，三十三個字換不了")
    func spanLimit() {
        #expect(InputEngine.pairSwitchSpanLimit == 32)
        // 開頭加三十個字加結尾是三十二個字。
        var fits = engine("RBRACKET", context: "「" + String(repeating: "字", count: 30))
        #expect(fits.revertRecord?.committedText.count == 32)
        fits.handle(.shiftSpace)
        #expect(fits.documentText == "[" + String(repeating: "字", count: 30) + "]")

        let tooLong = engine("RBRACKET", context: "「" + String(repeating: "字", count: 31))
        #expect(tooLong.documentText.hasSuffix("字」"))
        #expect(tooLong.revertRecord?.committedText.count == 33)
        #expect(refused(tooLong))
    }

    @Test("整段跨行或含附件占位字元時換不了，結尾照樣配對")
    func multilineAndAttachments() {
        let multiline = engine("RBRACKET", context: "「日\n月")
        #expect(multiline.documentText == "「日\n月」")
        #expect(refused(multiline))
        #expect(refused(engine("RBRACKET", context: "「日\r月")))
        #expect(refused(engine("RBRACKET", context: "「日\u{2028}月")))
        let attachment = engine("RBRACKET", context: "「日\u{FFFC}月")
        #expect(attachment.documentText == "「日\u{FFFC}月」")
        #expect(refused(attachment))
    }

    @Test("換不了時第一下被吃掉，再按一次是一般空白")
    func secondPressIsASpace() {
        var subject = engine("RBRACKET", context: "「日\n月")
        subject.handle(.shiftSpace)
        #expect(subject.documentText == "「日\n月」")
        subject.handle(.shiftSpace)
        #expect(subject.documentText == "「日\n月」 ")
    }

    @Test("換不了時效果帶著原因，再按一次的一般空白不帶", arguments: [
        "「" + String(repeating: "字", count: 31),
        "「日\n月",
        "「日\u{FFFC}月",
    ])
    func refusalCarriesANotice(context: String) {
        var subject = engine("RBRACKET", context: context)
        let closed = subject.documentText
        let refusedEffect = subject.handle(.shiftSpace)
        #expect(refusedEffect.pairSwitchNotice == .spanUnsupported)
        #expect(refusedEffect.committedText == nil)
        #expect(refusedEffect.deletedBackwardCount == 0)
        #expect(refusedEffect.handled)
        #expect(subject.documentText == closed)
        let spaceEffect = subject.handle(.shiftSpace)
        #expect(spaceEffect.pairSwitchNotice == nil)
        #expect(spaceEffect.committedText == " ")
        #expect(subject.documentText == closed + " ")
    }

    @Test("換得了的切換、開頭側的切換、寬度與中英對調、過期的 Shift+空白 都不帶原因")
    func noNoticeElsewhere() {
        for keys in [
            "LBRACKET m y SPACE RBRACKET SHIFT_SPACE",
            "LBRACKET m y SPACE RBRACKET SHIFT_SPACE 4",
            "LBRACKET SHIFT_SPACE",
            "RBRACKET SHIFT_SPACE",
            "i d COMMA SHIFT_SPACE",
            "m y SPACE SHIFT_SPACE",
            "m y SPACE a SHIFT_SPACE",
            "SHIFT_SPACE",
        ] {
            var subject = InputEngine(configuration: EngineConfiguration())
            for token in keys.split(separator: " ") {
                guard let key = KeyInput.parse(token: String(token)) else {
                    Issue.record("Unknown token in test: \(token)")
                    return
                }
                #expect(subject.handle(key).pairSwitchNotice == nil, "\(keys) 的 \(token)")
            }
        }
        // 換不了的那一段隔了一個按鍵之後，Shift+空白 是過期的，不提示。
        var stale = engine("RBRACKET a BKSP", context: "「日\n月")
        #expect(stale.handle(.shiftSpace).pairSwitchNotice == nil)
        // 關閉一鍵反悔後沒有切換可擋。
        var off = engine("RBRACKET", context: "「日\n月", configuration: EngineConfiguration(revertEnabled: false))
        #expect(off.handle(.shiftSpace).pairSwitchNotice == nil)
    }

    @Test("鏡像裡沒有開頭時照沒有開頭處理：只換結尾的寬度")
    func withoutAnOpenerInTheMirror() {
        #expect(cycled("LBRACKET a SPACE ENTER RBRACKET", count: 1) == ["]"])
        #expect(cycled("LBRACKET BKSP RBRACKET", count: 2) == ["]", "」"])
    }

    /// 宿主回報的前文：外層每個按鍵讀回游標前的文字，引擎只留前文視窗那麼長。
    private func synced(_ context: String, isClipped: Bool = false, keys: String = "RBRACKET") -> InputEngine {
        var subject = InputEngine(configuration: EngineConfiguration())
        subject.syncExternalContext(context, isClipped: isClipped)
        for token in keys.split(separator: " ") {
            guard let key = KeyInput.parse(token: String(token)) else {
                Issue.record("Unknown token in test: \(token)")
                return subject
            }
            subject.handle(key)
        }
        return subject
    }

    @Test("開頭在前文視窗之外：全形結尾不單獨換寬度，Shift+空白 被擋下並帶原因", arguments: [32, 40, 200])
    func openerBeyondTheContextWindow(count: Int) {
        var subject = synced("「" + String(repeating: "字", count: count))
        let closed = subject.documentText
        #expect(closed.hasSuffix("字」"))
        #expect(!closed.contains("「"))
        #expect(subject.revertRecord?.kind == .unresolvedCloser)
        #expect(subject.revertRecord?.spansEarlierCommits == false)
        #expect(refused(subject))
        let refusedEffect = subject.handle(.shiftSpace)
        #expect(refusedEffect.pairSwitchNotice == .spanUnsupported)
        #expect(subject.documentText == closed)
        let spaceEffect = subject.handle(.shiftSpace)
        #expect(spaceEffect.pairSwitchNotice == nil)
        #expect(subject.documentText == closed + " ")
    }

    @Test("外層說前文被裁過時，不滿視窗的前文同樣算看不到開頭")
    func clippedContextShorterThanTheWindow() {
        // 視窗以 UTF-16 計長，補充平面的漢字一個占兩格，裁過的前文不到三十二個字元。
        let context = String(repeating: "𠀀", count: 16)
        #expect(refused(synced(context, isClipped: true)))
        #expect(synced(context, isClipped: true).documentText == context + "」")
        // 同一段前文沒被裁過就是整份文件，確定沒有開頭。
        #expect(synced(context, keys: "RBRACKET SHIFT_SPACE").documentText == context + "]")
    }

    @Test("掃到文件開頭都沒有開頭的落單結尾照舊換寬度", arguments: [0, 2, 31, 32])
    func loneCloserInAFullyVisibleDocument(count: Int) {
        let context = String(repeating: "字", count: count)
        var subject = synced(context)
        #expect(subject.revertRecord?.kind == .punctuationWidth(key: "]", swapToFullwidth: false))
        #expect(subject.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(subject.documentText == context + "]")
        subject.handle(.shiftSpace)
        #expect(subject.documentText == context + "」")
    }

    @Test("看不到開頭時，半形的落單結尾照舊兩種寬度互換")
    func halfwidthCloserBeyondTheWindowStillSwapsWidth() {
        let context = String(repeating: "a", count: 40)
        var subject = synced(context)
        #expect(subject.documentText.hasSuffix("a]"))
        #expect(subject.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(subject.documentText.hasSuffix("a」"))
        #expect(subject.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(subject.documentText.hasSuffix("a]"))
    }

    @Test("看不到更早的前文不影響視窗裡配得到的那一對")
    func pairInsideAClippedWindowStillSwitches() {
        let context = String(repeating: "字", count: 40)
        #expect(synced(context, keys: "LBRACKET m y SPACE RBRACKET SHIFT_SPACE").documentText.hasSuffix("字[下]"))
        // 那一對關上之後再按一個結尾，又是看不到開頭的全形結尾。
        #expect(refused(synced(context, keys: "LBRACKET m y SPACE RBRACKET RBRACKET")))
    }

    @Test("看不到開頭的狀態跟著鏡像走：接著打字仍然算，換欄位或前文變短就不算")
    func unseenTextFollowsTheMirror() {
        let context = String(repeating: "字", count: 40)
        #expect(refused(synced(context, keys: "m y SPACE RBRACKET")))
        // 宿主回報的前文與鏡像相符時鏡像不動，看不到的那一段也還在。
        var agreeing = synced(context, keys: "m y SPACE")
        agreeing.syncExternalContext(String(agreeing.documentText.suffix(InputEngine.contextWindowLength)), isClipped: true)
        agreeing.handle(.character("]"))
        #expect(refused(agreeing))

        var reset = synced(context, keys: "")
        reset.resetContext()
        reset.syncExternalContext("字")
        reset.handle(.character("]"))
        #expect(reset.revertRecord?.kind == .punctuationWidth(key: "]", swapToFullwidth: false))

        var shortened = synced(context, keys: "")
        shortened.syncExternalContext("好")
        shortened.handle(.character("]"))
        #expect(shortened.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(shortened.documentText == "好]")
    }

    @Test("宿主給的是整份游標前的文件時，比它長的鏡像是過期的：換成宿主的前文，落單結尾照舊換寬度")
    func unclippedShorterContextReplacesAStaleMirror() {
        // 不經過按鍵的編輯或游標移動之後，游標前只剩兩個字，剛好是舊鏡像的尾端。
        var clipped = synced(String(repeating: "字", count: 32), isClipped: true, keys: "")
        clipped.syncExternalContext("字字")
        #expect(clipped.documentText == "字字")
        #expect(!clipped.mirrorIsClipped)
        clipped.handle(.character("]"))
        #expect(clipped.revertRecord?.kind == .punctuationWidth(key: "]", swapToFullwidth: false))
        #expect(clipped.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(clipped.documentText == "字字]")

        // 舊鏡像裡的開頭已經不在游標前，結尾不能跟隨它。
        var opener = synced("「好字字", keys: "")
        opener.syncExternalContext("字字")
        opener.handle(.character("]"))
        #expect(opener.documentText == "字字」")
        #expect(opener.revertRecord?.kind == .punctuationWidth(key: "]", swapToFullwidth: false))

        // 宿主說前文被裁過時，相符的尾端不代表鏡像過期：多出來的是更早的文字。
        var kept = synced("「好字字", keys: "")
        kept.syncExternalContext("字字", isClipped: true)
        #expect(kept.documentText == "「好字字")
    }

    @Test("被擋下的落單結尾：數字是內容，隔一個按鍵就過期，關閉一鍵反悔後沒有紀錄")
    func unresolvedCloserRecordLifetime() {
        let context = String(repeating: "字", count: 40)
        var digit = synced(context)
        #expect(!digit.isRevertInput(.character("1")))
        #expect(digit.isRevertInput(.shiftSpace))
        digit.handle(.character("1"))
        #expect(digit.documentText.hasSuffix("字」1"))

        var stale = synced(context, keys: "RBRACKET a BKSP")
        #expect(stale.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(stale.documentText.hasSuffix("字」 "))

        var off = InputEngine(configuration: EngineConfiguration(revertEnabled: false))
        off.syncExternalContext(context)
        #expect(!off.handle(.character("]")).revertible)
        #expect(off.revertRecord == nil)
        #expect(off.handle(.shiftSpace).pairSwitchNotice == nil)
        #expect(off.documentText.hasSuffix("字」 "))
    }

    @Test("鏡像超過上限被裁掉開頭之後，也算看不到更早的前文")
    func trimmedMirrorCountsAsUnseen() {
        let long = "「" + String(repeating: "字", count: InputEngine.documentMirrorLimit)
        var subject = InputEngine(configuration: EngineConfiguration(), initialDocumentText: long)
        #expect(!subject.documentText.contains("「"))
        subject.handle(.character("]"))
        #expect(subject.documentText.hasSuffix("字」"))
        #expect(refused(subject))
    }

    @Test("關閉一鍵反悔後沒有成對切換")
    func disabledRevert() {
        let off = EngineConfiguration(revertEnabled: false)
        #expect(document("CTRL_SHIFT_LBRACKET m y SPACE RBRACKET SHIFT_SPACE", configuration: off) == "『下』 ")
        #expect(document("LBRACKET SHIFT_SPACE", configuration: off) == "「 ")
    }

    @Test("疊加層開著時紀錄已經清掉")
    func layersDropTheRecord() {
        #expect(engine("LBRACKET m y SPACE RBRACKET SYMBOLS").revertRecord == nil)
        #expect(engine("LBRACKET m y SPACE RBRACKET SHIFT_SPACE SYMBOLS").revertRecord == nil)
        #expect(engine("LBRACKET m y SPACE RBRACKET LOOKUP").revertRecord == nil)
        #expect(engine("LBRACKET m y SPACE RBRACKET SHIFT_SPACE LOOKUP").revertRecord == nil)
        // 反查關掉之後，Shift+空白 不會回頭去換更早的那一對。
        #expect(document("LBRACKET m y SPACE RBRACKET LOOKUP ESC SHIFT_SPACE") == "「下」 ")
    }

    @Test("Caps Lock 切換與純英文層：紀錄作廢，直出的方括號不留紀錄")
    func literalLayersDropTheRecord() {
        #expect(document("LBRACKET m y SPACE RBRACKET CAPS_ON CAPS_OFF SHIFT_SPACE") == "「下」 ")
        #expect(document("LBRACKET m y SPACE RBRACKET SHIFT_SPACE CAPS_ON CAPS_OFF 4") == "[下]4")
        #expect(document("LBRACKET CAPS_ON CAPS_OFF SHIFT_SPACE") == "「 ")
        let pureEnglish = engine("DBL_SHIFT LBRACKET")
        #expect(pureEnglish.documentText == "[")
        #expect(pureEnglish.revertRecord == nil)
        #expect(document("DBL_SHIFT LBRACKET SHIFT_SPACE") == "[ ")
    }

    @Test("外部事件讓成對紀錄作廢：游標移動、宿主結束組字、設定與學習紀錄被換掉")
    func externalEventsDropTheRecord() {
        let closed = "LBRACKET m y SPACE RBRACKET"
        // 另一個宿主學到新東西之後的學習紀錄，與這裡的不同才會讓紀錄作廢。
        let otherHistory = engine("o j 2").usageHistory
        let events: [(String, (inout InputEngine) -> Void)] = [
            ("游標移動", { $0.noteExternalCursorMovement() }),
            ("宿主結束組字", { _ = $0.finishHostComposition() }),
            ("設定被換掉", { $0.configuration.autoPunctuationEnabled.toggle() }),
            ("學習紀錄被換掉", { $0.usageHistory = otherHistory })
        ]
        for script in [closed, "\(closed) SHIFT_SPACE", "LBRACKET", "LBRACKET SHIFT_SPACE"] {
            for (name, event) in events {
                var subject = engine(script)
                #expect(subject.revertRecord != nil, "\(script)")
                event(&subject)
                #expect(subject.revertRecord == nil, "\(name)：\(script)")
                #expect(!subject.isRevertInput(.shiftSpace), "\(name)：\(script)")
                #expect(!subject.isRevertInput(.character("4")), "\(name)：\(script)")
                // 之後的 Shift+空白 只是一般空白，不換任何括號。
                let effect = subject.handle(.shiftSpace)
                #expect(effect.committedText == " ", "\(name)：\(script)")
                #expect(effect.deletedBackwardCount == 0, "\(name)：\(script)")
                #expect(effect.pairChoice == nil, "\(name)：\(script)")
            }
        }
    }
}

@Suite("成對切換之後用數字直選種類")
struct BracketPairDigitPickTests {
    private let switched = "LBRACKET m y SPACE RBRACKET SHIFT_SPACE"

    @Test("緊接一次切換的數字跳到那個編號的種類，與起點無關")
    func digitPicksTheNumberedStyle() {
        let expected = ["「下」", "[下]", "『下』", "《下》", "〈下〉", "【下】", "“下”", "‘下’"]
        for (index, text) in expected.enumerated() {
            #expect(document("\(switched) \(index + 1)") == text)
            // 起點是半形方括號時編號相同。
            #expect(document("LBRACKET a SPACE RBRACKET SHIFT_SPACE \(index + 1)", context: "abc")
                == "abc" + text.replacingOccurrences(of: "下", with: "日"))
        }
        // 切換過兩次再選也一樣。
        #expect(document("\(switched) SHIFT_SPACE 6") == "【下】")
    }

    @Test("效果與紀錄：回刪整段、送出整段，選項列留著但不再顯示編號")
    func effectAndRecord() {
        var subject = engine(switched)
        #expect(subject.isRevertInput(.character("4")))
        let effect = subject.handle(.character("4"))
        #expect(effect.handled)
        #expect(effect.committedText == "《下》")
        #expect(effect.committedCore == "》")
        #expect(effect.commitKind == .punctuation)
        #expect(effect.deletedBackwardCount == 3)
        #expect(effect.revertible)
        #expect(effect.revertPreview == nil)
        #expect(effect.pairChoice == PairChoice(current: .doubleAngle, digitsPick: false))
        let record = subject.revertRecord
        #expect(record?.kind == .pair(PairSwitch(side: .closer, origin: .corner, current: .doubleAngle, step: .picked)))
        #expect(record?.committedText == "《下》")
        #expect(record?.committedCore == "》")
        #expect(record?.alternativeCore == "〉")
        #expect(record?.spansEarlierCommits == true)
    }

    @Test("選項列只在數字會直選時顯示編號")
    func choiceShowsNumbersOnlyWhenDigitsPick() {
        var subject = engine("LBRACKET m y SPACE RBRACKET")
        #expect(subject.handle(.shiftSpace).pairChoice == PairChoice(current: .square, digitsPick: true))
        #expect(subject.handle(.shiftSpace).pairChoice == PairChoice(current: .doubleCorner, digitsPick: true))
        #expect(subject.handle(.character("1")).pairChoice == PairChoice(current: .corner, digitsPick: false))
        #expect(subject.handle(.shiftSpace).pairChoice == PairChoice(current: .square, digitsPick: true))
    }

    @Test("直選之後數字是內容，最多只吃掉一個")
    func digitAfterPickIsContent() {
        var subject = engine("\(switched) 4")
        #expect(!subject.isRevertInput(.character("4")))
        let effect = subject.handle(.character("4"))
        #expect(subject.documentText == "《下》4")
        #expect(effect.deletedBackwardCount == 0)
        #expect(effect.pairChoice == nil)
        #expect(subject.revertRecord == nil)
    }

    @Test("沒切換過不直選")
    func noPickWithoutASwitch() {
        let typed = engine("LBRACKET a SPACE RBRACKET")
        #expect(!typed.isRevertInput(.character("1")))
        #expect(document("LBRACKET a SPACE RBRACKET 1") == "「日」1")
    }

    @Test("直選後可以繼續循環，從選到的種類往後走；再切換一次數字又能直選")
    func cycleContinuesAfterPick() {
        #expect(document("\(switched) 4 SHIFT_SPACE") == "〈下〉")
        #expect(document("\(switched) 4 SHIFT_SPACE 1") == "「下」")
        // 半形方括號起點的循環順序照舊：選到「之後下一種是『。
        #expect(document("LBRACKET a SPACE RBRACKET SHIFT_SPACE 2 SHIFT_SPACE", context: "abc") == "abc「日」")
        #expect(document("LBRACKET a SPACE RBRACKET SHIFT_SPACE 1 SHIFT_SPACE", context: "abc") == "abc『日』")
    }

    @Test("9、0 與其他按鍵不直選")
    func otherKeysAreNotPicks() {
        let subject = engine(switched)
        #expect(!subject.isRevertInput(.character("9")))
        #expect(!subject.isRevertInput(.character("0")))
        #expect(!subject.isRevertInput(.character("a")))
        #expect(!subject.isRevertInput(.selectEnglishPrediction(4)))
        #expect(document("\(switched) 9") == "[下]9")
        #expect(document("\(switched) 0") == "[下]0")
    }

    @Test("開頭側永遠不直選")
    func openerSideNeverPicks() {
        var subject = engine("LBRACKET SHIFT_SPACE SHIFT_SPACE")
        #expect(!subject.isRevertInput(.character("4")))
        subject.handle(.character("4"))
        #expect(subject.documentText == "『4")
        // 寬度對調與中英對調的紀錄也不收數字。
        #expect(!engine("RBRACKET SHIFT_SPACE").isRevertInput(.character("1")))
        #expect(document("RBRACKET SHIFT_SPACE 1") == "]1")
    }

    @Test("選到目前這一種：文件不變，數字照樣被吃掉")
    func pickingTheCurrentStyle() {
        var subject = engine(switched)
        let effect = subject.handle(.character("2"))
        #expect(subject.documentText == "[下]")
        #expect(effect.committedText == "[下]")
        #expect(effect.deletedBackwardCount == 3)
        #expect(effect.pairChoice == PairChoice(current: .square, digitsPick: false))
    }

    @Test("直選等同循環到那一種：文件與紀錄以外的狀態相同，內容逐字不變")
    func pickEqualsCycling() {
        // 半形方括號起點，第一下已經到角引號，再兩下是書名號。
        var picked = engine("i d TAB LBRACKET i d TAB RBRACKET SHIFT_SPACE")
        var cycledTo = picked
        picked.handle(.character("4"))
        cycledTo.handle(.shiftSpace)
        cycledTo.handle(.shiftSpace)
        #expect(picked.documentText == "id 《id》")
        #expect(picked.documentText == cycledTo.documentText)
        #expect(picked.pendingAutoSpace == cycledTo.pendingAutoSpace)
        #expect(picked.usageHistory == cycledTo.usageHistory)
        #expect(picked.snippet == cycledTo.snippet)
        #expect(picked.state == cycledTo.state)
        // 內容裡有那個種類的落單結尾也不會配錯。
        #expect(document("RBRACKET SHIFT_SPACE 4", context: "「a》b") == "《a》b》")
    }

    @Test("片段裡與純中文模式都適用")
    func worksInSnippetsAndChineseOnlyMode() {
        #expect(document("BACKTICK LBRACKET x RBRACKET SHIFT_SPACE 3", context: "中") == "中`『x』")
        #expect(document("\(switched) 4", configuration: EngineConfiguration(mixedModeEnabled: false)) == "《下》")
    }

    @Test("換不了的整段與關閉一鍵反悔時沒有直選")
    func refusedSwitchAndDisabledRevert() {
        #expect(document("RBRACKET SHIFT_SPACE 4", context: "「日\n月") == "「日\n月」4")
        #expect(document("\(switched) 4", configuration: EngineConfiguration(revertEnabled: false)) == "「下」 4")
    }
}

/// 從 `keys` 之後連按 `count` 次 Shift+空白，回傳每一下之後的文件。
private func cycled(
    _ keys: String,
    context: String = "",
    count: Int = 8,
    configuration: EngineConfiguration = EngineConfiguration()
) -> [String] {
    var subject = engine(keys, context: context, configuration: configuration)
    return (0..<count).map { _ in
        subject.handle(.shiftSpace)
        return subject.documentText
    }
}

@Suite("左方括號的八種循環")
struct BracketOpenerCycleTests {
    @Test("單按左方括號的輸出不變，不帶選項列")
    func defaultOutputIsUnchanged() {
        #expect(document("LBRACKET") == "「")
        #expect(document("LBRACKET", context: "abc") == "abc[")
        #expect(document("BACKTICK LBRACKET", context: "中") == "中`[")
        #expect(document("LBRACKET", context: "中", configuration: EngineConfiguration(autoPunctuationEnabled: false)) == "中[")
        var typed = InputEngine()
        let effect = typed.handle(.character("["))
        #expect(effect.revertible)
        #expect(effect.revertPreview == nil)
        #expect(effect.pairChoice == nil)
    }

    @Test("循環八種，第一下換寬度，八下回原樣")
    func cyclesThroughEightStyles() {
        #expect(cycled("LBRACKET") == ["[", "『", "《", "〈", "【", "“", "‘", "「"])
        #expect(cycled("LBRACKET", context: "abc")
            == ["abc「", "abc『", "abc《", "abc〈", "abc【", "abc“", "abc‘", "abc["])
        // 再走一圈仍是同一個順序：循環看的是剛打出來時的種類，不是目前這一種。
        #expect(cycled("LBRACKET", context: "abc", count: 10).suffix(2) == ["abc「", "abc『"])
    }

    @Test("紀錄與選項列：每一下都留開頭側的成對紀錄，效果帶目前的種類，數字不直選")
    func recordAndChoiceFollowTheCycle() {
        var subject = engine("LBRACKET", context: "abc")
        #expect(subject.revertRecord?.kind
            == .pair(PairSwitch(side: .opener, origin: .square, current: .square, step: .typed)))
        #expect(subject.revertRecord?.committedText == "[")
        #expect(subject.revertRecord?.committedCore == "[")
        #expect(subject.revertRecord?.alternativeCore == "「")

        let first = subject.handle(.shiftSpace)
        #expect(first.committedText == "「")
        #expect(first.committedCore == "「")
        #expect(first.commitKind == .punctuation)
        #expect(first.deletedBackwardCount == 1)
        #expect(first.revertible)
        #expect(first.revertPreview == nil)
        #expect(first.pairChoice == PairChoice(current: .corner, digitsPick: false))
        #expect(subject.revertRecord?.kind
            == .pair(PairSwitch(side: .opener, origin: .square, current: .corner, step: .cycled)))
        #expect(subject.revertRecord?.alternativeCore == "『")

        let second = subject.handle(.shiftSpace)
        #expect(second.pairChoice == PairChoice(current: .doubleCorner, digitsPick: false))
        #expect(subject.revertRecord?.committedCore == "『")
        #expect(subject.revertRecord?.alternativeCore == "《")

        // 選項列只活到下一個不是切換的按鍵。
        let next = subject.handle(.character("a"))
        #expect(next.pairChoice == nil)
        #expect(subject.revertRecord == nil)
    }

    @Test("連帶送出的前綴整段換，前綴本身不動")
    func prefixIsReplacedTogether() {
        var subject = engine("a LBRACKET")
        #expect(subject.documentText == "日「")
        #expect(subject.revertRecord?.committedText == "日「")
        let first = subject.handle(.shiftSpace)
        #expect(first.committedText == "日[")
        #expect(first.deletedBackwardCount == 2)
        #expect(subject.documentText == "日[")
        let second = subject.handle(.shiftSpace)
        #expect(second.committedText == "日『")
        #expect(second.deletedBackwardCount == 2)
        #expect(subject.documentText == "日『")
        // 混打只有前綴時原字母照逗號鍵的規則留下。
        #expect(cycled("y r h LBRACKET", count: 2) == ["yrh「", "yrh『"])
    }

    @Test("開頭側的數字是內容，不拿來選種類")
    func digitsAfterTheOpenerAreContent() {
        #expect(document("LBRACKET SHIFT_SPACE 1 RBRACKET") == "[1]")
        var subject = engine("LBRACKET SHIFT_SPACE SHIFT_SPACE")
        let digit = subject.handle(.character("4"))
        #expect(digit.committedText == "4")
        #expect(digit.pairChoice == nil)
        #expect(subject.documentText == "『4")
        #expect(document("LBRACKET SHIFT_SPACE SHIFT_SPACE 4 RBRACKET") == "『4』")
    }

    @Test("不收合英文後自動補上的那一格")
    func keepsTheAutoSpace() {
        #expect(cycled("i d TAB LBRACKET", count: 3) == ["id 「", "id 『", "id 《"])
        var subject = engine("i d TAB LBRACKET SHIFT_SPACE SHIFT_SPACE")
        #expect(!subject.pendingAutoSpace)
        // 換過種類之後，結尾照樣收合它自己前面那一格並跟隨開頭。
        for token in ["i", "d", "TAB", "RBRACKET"] {
            subject.handle(KeyInput.parse(token: token)!)
        }
        #expect(subject.documentText == "id 『id』")
    }

    @Test("選好的開頭由結尾跟隨")
    func chosenOpenerIsFollowed() {
        #expect(document("LBRACKET SHIFT_SPACE SHIFT_SPACE m y SPACE RBRACKET") == "『下』")
        #expect(document("LBRACKET SHIFT_SPACE SHIFT_SPACE SHIFT_SPACE a SPACE RBRACKET") == "《日》")
    }

    @Test("換到角引號、雙角引號與半形方括號，等同直接按 Ctrl 或 Option 的那個鍵")
    func equalsTheDirectKeys() {
        let direct: [(presses: Int, token: String)] = [(2, "CTRL_SHIFT_LBRACKET"), (8, "CTRL_LBRACKET"), (1, "OPT_[")]
        for (presses, token) in direct {
            var switched = engine("m y SPACE LBRACKET")
            for _ in 0..<presses { switched.handle(.shiftSpace) }
            let typed = engine("m y SPACE \(token)")
            #expect(switched.documentText == typed.documentText)
            #expect(switched.pendingAutoSpace == typed.pendingAutoSpace)
            #expect(switched.usageHistory == typed.usageHistory)
            #expect(switched.snippet == typed.snippet)
        }
    }

    @Test("片段裡與純中文模式都適用，片段語境不變")
    func worksInSnippetsAndChineseOnlyMode() {
        var snippet = engine("BACKTICK LBRACKET", context: "中")
        let before = snippet.snippet
        snippet.handle(.shiftSpace)
        snippet.handle(.shiftSpace)
        #expect(snippet.documentText == "中`『")
        #expect(snippet.snippet == before)
        #expect(cycled("LBRACKET", count: 3, configuration: EngineConfiguration(mixedModeEnabled: false))
            == ["[", "『", "《"])
        #expect(cycled("LBRACKET", context: "中", count: 2,
                       configuration: EngineConfiguration(autoPunctuationEnabled: false)) == ["中「", "中『"])
    }

    @Test("紀錄只活一個按鍵；關閉一鍵反悔、半形層都沒有循環")
    func recordLifetimeAndLayers() {
        #expect(document("LBRACKET SHIFT_SPACE SPACE SHIFT_SPACE") == "[  ")
        #expect(document("LBRACKET SHIFT_SPACE", configuration: EngineConfiguration(revertEnabled: false)) == "「 ")
        let caps = engine("CAPS_ON LBRACKET")
        #expect(caps.documentText == "[")
        #expect(caps.revertRecord == nil)
        // 開啟符號面板的那個按鍵就清掉紀錄。
        #expect(engine("LBRACKET SHIFT_SPACE SYMBOLS").revertRecord == nil)
    }

    @Test("其他有兩種寬度的鍵仍是兩下回原樣，不帶選項列")
    func otherKeysStillSwapWidth() {
        #expect(cycled("LBRACE", count: 2) == ["{", "『"])
        #expect(cycled("(", count: 2) == ["(", "（"])
        var comma = engine("i d TAB COMMA")
        #expect(comma.handle(.shiftSpace).pairChoice == nil)
    }
}

@Suite("彎引號的標點語境與自動空格")
struct CurlyQuoteTests {
    @Test("整對彎引號前面有字時，標點看開頭彎引號前面那個字")
    func punctuationLooksBeforeOpeningCurlyQuote() {
        // 中文句子引英數詞：引號裡以英數結尾，標點仍是全形。
        #expect(document("PERIOD", context: "他說“AI”") == "他說“AI”。")
        #expect(document("COMMA", context: "所謂的“AI”") == "所謂的“AI”，")
        #expect(document("PERIOD", context: "他說 “AI”") == "他說 “AI”。")
        #expect(document("COMMA", context: "他說：“AI”") == "他說：“AI”，")
        #expect(document("PERIOD", context: "他說“AI’s”") == "他說“AI’s”。")
        #expect(document("PERIOD", context: "他說“他說‘AI’”") == "他說“他說‘AI’”。")
        #expect(document("A I TAB RBRACKET PERIOD", context: "他說“") == "他說“AIR”。")
        #expect(document("DBL_SHIFT DBL_SHIFT PERIOD", context: "他說“AI”") == "他說“AI”。")
        // 英文句子引中文：照外面的英文出半形。
        #expect(document("PERIOD", context: "He said “好”") == "He said “好”.")
        #expect(document("COMMA", context: "x “a” “b”") == "x “a” “b”,")
        // 引號後的手動空白照舊讓句點出半形。
        #expect(document("PERIOD", context: "他說“AI” ") == "他說“AI” .")
    }

    @Test("開頭彎引號只在同一行裡找，找不到就看引號裡的字")
    func openingCurlyQuoteIsSearchedOnTheSameLine() {
        #expect(document("COMMA", context: "He said\n“hello”") == "He said\n“hello”,")
        #expect(document("PERIOD", context: "好\n“hello\nworld”") == "好\n“hello\nworld”.")
    }

    @Test("開頭彎引號在行首時，句點看引號裡的字：中文出全形")
    func periodAfterCurlyQuoteAroundChinese() {
        #expect(document("PERIOD", context: "“好”") == "“好”。")
        #expect(document("PERIOD", context: "‘好’") == "‘好’。")
        #expect(document("PERIOD", context: "“好。”") == "“好。”。")
        #expect(document("PERIOD", context: "“‘好’”") == "“‘好’”。")
        #expect(document("PERIOD", context: "「好」") == "「好」。")
    }

    @Test("英文句子的結尾彎引號、撇號與行首的英文引號後面，句點出半形")
    func periodAfterCurlyQuoteAroundEnglish() {
        #expect(document("PERIOD", context: "He said “hello”") == "He said “hello”.")
        #expect(document("PERIOD", context: "the users’") == "the users’.")
        #expect(document("PERIOD", context: "3”") == "3”.")
        #expect(document("PERIOD", context: "“it’s ‘ok’”") == "“it’s ‘ok’”.")
        #expect(document("PERIOD", context: "“Wait!”") == "“Wait!”.")
    }

    @Test("結尾彎引號前是空白、換行或沒有字時，把彎引號當全形標點，句點與逗號寬度一致")
    func punctuationAfterClosingCurlyQuoteWithoutContent() {
        for context in ["”", "’”", "好 ”", "好\n”", "hello ”"] {
            #expect(document("PERIOD", context: context) == context + "。")
            #expect(document("COMMA", context: context) == context + "，")
        }
        #expect(document("PERIOD COMMA", context: "他說“好 ”") == "他說“好 ”。，")
    }

    @Test("其他依前文決定寬度的標點走同一條規則")
    func otherPunctuationAfterClosingCurlyQuote() {
        #expect(document("COMMA", context: "He said “hello”") == "He said “hello”,")
        #expect(document("QUESTION", context: "the users’") == "the users’?")
        #expect(document("COMMA", context: "“好”") == "“好”，")
        #expect(document("QUESTION", context: "‘好’") == "‘好’？")
        #expect(document("COMMA o n f SPACE", context: "“Hello”") == "“Hello”, 你")
        // 結尾彎引號後面隔著手動空格，逗號略過空格後照樣看整對引號外面。
        #expect(document("COMMA", context: "He said “hello” ") == "He said “hello” ,")
        #expect(document("COMMA", context: "他說“AI” ") == "他說“AI” ，")
    }

    @Test("沒有未關閉的開頭時，括號鍵與頓號鍵在英文結尾彎引號後也出半形")
    func bracketKeysAfterEnglishClosingCurlyQuote() {
        let context = "He said “hello”"
        #expect(document("LBRACKET", context: context) == context + "[")
        #expect(document("RBRACKET", context: context) == context + "]")
        #expect(document("LBRACE", context: context) == context + "{")
        #expect(document("RBRACE", context: context) == context + "}")
        #expect(document("LPAREN", context: context) == context + "(")
        #expect(document("RPAREN", context: context) == context + ")")
        #expect(document("BACKSLASH", context: context) == context + "\\")
        #expect(document("LBRACKET", context: "他說“AI”") == "他說“AI”「")
        #expect(document("RBRACKET", context: "他說“AI”") == "他說“AI”」")
    }

    @Test("開頭彎引號後面的標點不變")
    func punctuationAfterOpeningCurlyQuote() {
        #expect(document("PERIOD", context: "abc“") == "abc“。")
        #expect(document("PERIOD", context: "abc‘") == "abc‘。")
        #expect(document("COMMA", context: "abc“") == "abc“，")
    }

    @Test("片段前是結尾彎引號時，片段後的第一個標點照同一條規則")
    func punctuationAfterSnippetFollowingClosingCurlyQuote() {
        #expect(document("BACKTICK i d BACKTICK PERIOD", context: "他說“AI”") == "他說“AI”`id`。")
        #expect(document("BACKTICK i d BACKTICK PERIOD", context: "He said “hello”") == "He said “hello”`id`.")
        #expect(document("BACKTICK i d BACKTICK PERIOD", context: "“好”") == "“好”`id`。")
    }

    @Test("成對符號的跟隨與自動空格不受影響")
    func pairFollowAndAutoSpaceUnchanged() {
        #expect(document("RBRACKET", context: "“hello") == "“hello”")
        #expect(document("RBRACKET", context: "“it’s") == "“it’s”")
        #expect(document("m y SPACE", context: "abc”") == "abc”下")
    }

    @Test("彎引號後面接中文或英文都不補空格")
    func noAutoSpaceAfterCurlyQuote() {
        #expect(document("m y SPACE", context: "“") == "“下")
        #expect(document("i d TAB", context: "“") == "“id ")
        #expect(document("i d TAB", context: "abc”") == "abc”id ")
        for ch in "“”‘’" {
            #expect(AutoSpacer.isFullwidthPunctuation(ch))
        }
    }
}
