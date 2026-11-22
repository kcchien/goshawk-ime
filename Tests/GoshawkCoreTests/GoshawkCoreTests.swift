import Foundation
import Testing
@testable import GoshawkCore

private func replay(_ tokens: [String], configuration: EngineConfiguration = EngineConfiguration()) -> InputEngine {
    var engine = InputEngine(configuration: configuration)
    for token in tokens {
        guard let key = KeyInput.parse(token: token) else {
            Issue.record("Unknown token in test: \(token)")
            return engine
        }
        engine.handle(key)
    }
    return engine
}

@Suite("GoshawkCore PRD Acceptance Tests")
struct GoshawkCoreTests {
    @Test("Full bundled lexicons load authentic Cangjie5, Cangjie3, and English tables")
    func fullLexiconsLoaded() {
        #expect(CangjieDictionary.sharedV5.codeCount > 13_000)
        #expect(CangjieDictionary.sharedV3.codeCount > 14_000)
        #expect(EnglishPredictor.shared.wordCount > 9_000)

        #expect(CangjieDictionary.sharedV5.candidates(for: "ihs").first == "成")
        #expect(CangjieDictionary.sharedV5.candidates(for: "doo").first == "來")
        #expect(CangjieDictionary.sharedV5.candidates(for: "oog").first == "坐")
        #expect(CangjieDictionary.sharedV5.candidates(for: "is").isEmpty)
        // une 是碼表裡唯一一個只有一代收錄的完整英文詞，兩代差異看這個碼：
        // 「函」的五代原生碼是 une、三代是 nue，而 une 是完整英文詞，不補進三代。
        #expect(CangjieDictionary.sharedV5.candidates(for: "une").first == "函")
        #expect(CangjieDictionary.sharedV3.candidates(for: "une").isEmpty)
        #expect(CangjieDictionary.sharedV3.candidates(for: "nue").first == "函")
    }

    @Test("Option A: authentic colliding Cangjie codes commit Chinese on Space and English on Tab/Enter")
    func collidingKeyDisambiguation() {
        #expect(replay(["m", "y", "SPACE"]).documentText == "下")
        #expect(replay(["m", "y", "TAB"]).documentText == "my ")
        #expect(replay(["m", "y", "ENTER"]).documentText == "my")

        #expect(replay(["h", "e", "SPACE"]).documentText == "反")
        #expect(replay(["h", "e", "TAB"]).documentText == "he ")

        #expect(replay(["a", "n", "SPACE"]).documentText == "門")
        #expect(replay(["a", "n", "TAB"]).documentText == "an ")

        #expect(replay(["o", "k", "SPACE"]).documentText == "矢")
        #expect(replay(["o", "k", "TAB"]).documentText == "ok ")

        #expect(replay(["i", "h", "s", "SPACE"]).documentText == "成")
        #expect(replay(["d", "o", "o", "SPACE"]).documentText == "來")
        #expect(replay(["o", "o", "g", "SPACE"]).documentText == "坐")

        #expect(replay(["g", "i", "t", "TAB"]).documentText == "git ")
        #expect(replay(["i", "d", "TAB"]).documentText == "id ")
        #expect(replay(["a", "s", "TAB"]).documentText == "as ")
    }

    @Test("Codes without single-char Cangjie match and long English words commit English on Space")
    func nonCangjieAndLongEnglish() {
        #expect(replay(["i", "s", "SPACE"]).documentText == "is ")
        #expect(replay(["d", "o", "SPACE"]).documentText == "do ")
        #expect(replay(["g", "o", "SPACE"]).documentText == "go ")

        let theSpace = replay(["t", "h", "e", "SPACE"])
        #expect(theSpace.documentText == "the ")
        #expect(theSpace.state == .idle)

        let dockerSpace = replay(["d", "o", "c", "k", "e", "r", "SPACE"])
        #expect(dockerSpace.documentText == "docker ")
        #expect(dockerSpace.state == .idle)

        #expect(replay(["d", "o", "c", "TAB"]).documentText == "doc ")
        #expect(replay(["d", "o", "c", "k", "TAB"]).documentText == "dock ")
        #expect(replay(["d", "o", "c", "k", "e", "TAB"]).documentText == "docker ")
    }

    @Test("Backspace from ComposingEnglishOnly restores ComposingDual when prefix becomes valid")
    func backspaceRestoresDualTrack() {
        var engine = InputEngine()
        _ = engine.handle(.character("n"))
        _ = engine.handle(.character("o"))
        #expect(engine.state == .composingDual)
        #expect(engine.currentOverlay?.cangjieTrack != nil)

        _ = engine.handle(.character("t"))
        #expect(engine.state == .composingEnglishOnly)
        #expect(engine.currentOverlay?.cangjieTrack == nil)

        _ = engine.handle(.backspace)
        #expect(engine.state == .composingDual)
        #expect(engine.buffer == "no")
        #expect(engine.currentOverlay?.cangjieTrack != nil)
    }

    @Test("Auto-space and punctuation collapse on Chinese-English mixed text")
    func autoSpaceAndPunctuation() {
        let mixed = replay([
            "o", "n", "f", "SPACE",
            "v", "n", "d", "SPACE",
            "h", "e", "l", "l", "o", "TAB",
            "p", "t", "SPACE",
            "w", "o", "l", "l", "SPACE"
        ])
        #expect(mixed.documentText == "你好 hello 世界")

        let collapsed = replay([
            "o", "n", "f", "SPACE",
            "v", "n", "d", "SPACE",
            "h", "e", "l", "l", "o", "TAB",
            "COMMA", "SPACE",
            "w", "o", "r", "l", "d", "TAB",
            "BANG"
        ])
        #expect(collapsed.documentText == "你好 hello, world!")
    }

    @Test("Opening symbols and prefixes do not insert extra leading spaces")
    func prefixSymbolsNoExtraSpace() {
        let paren = replay(["LPAREN", "o", "n", "f", "SPACE", "RPAREN"])
        #expect(paren.documentText == "（你）")

        let hashTag = replay(["HASH", "o", "n", "f", "SPACE"])
        #expect(hashTag.documentText == "#你")

        let englishParen = replay(["h", "e", "l", "l", "o", "TAB", "LPAREN", "o", "n", "f", "SPACE", "RPAREN"])
        #expect(englishParen.documentText == "hello (你)")
    }

    @Test("Double Shift toggles PureEnglish mode and ShiftTapDetector honors timing window")
    func doubleShiftPureEnglish() {
        let pure = replay(["DBL_SHIFT", "m", "y", "SPACE", "DBL_SHIFT", "m", "y", "SPACE"])
        #expect(pure.documentText == "my 下")
        #expect(pure.state == .idle)

        var detector = ShiftTapDetector(thresholdSeconds: 0.30)
        #expect(detector.handleShiftChanged(isDown: true, timestamp: 1.00) == false)
        #expect(detector.handleShiftChanged(isDown: false, timestamp: 1.05) == false)
        #expect(detector.handleShiftChanged(isDown: true, timestamp: 1.20) == false)
        #expect(detector.handleShiftChanged(isDown: false, timestamp: 1.25) == true)

        // Cancelled when another key is pressed while Shift is held
        #expect(detector.handleShiftChanged(isDown: true, timestamp: 2.00) == false)
        detector.noteNonModifierKeyPressed()
        #expect(detector.handleShiftChanged(isDown: false, timestamp: 2.05) == false)
        #expect(detector.handleShiftChanged(isDown: true, timestamp: 2.15) == false)
        #expect(detector.handleShiftChanged(isDown: false, timestamp: 2.20) == false)

        // Cancelled when gap exceeds threshold
        #expect(detector.handleShiftChanged(isDown: false, timestamp: 2.65) == false)
    }

    @Test("Candidate selection, Shift+N English prediction, Cangjie3 switch, and external context sync")
    func candidateSelectionShiftPredictAndContextSync() {
        let digitSelect = replay(["n", "o", "SHIFT_SPACE", "DIGIT2"])
        #expect(digitSelect.documentText == "欠")

        let arrowSelect = replay(["n", "o", "DOWN", "SPACE"])
        #expect(arrowSelect.documentText == "欠")

        let shiftSecond = replay(["m", "y", "SHIFT_2"])
        let secondForMy = EnglishPredictor.shared.predictions(for: "my", limit: 2)[1]
        #expect(shiftSecond.documentText == "\(secondForMy) ")

        let k8s = replay(["k", "8", "TAB"])
        #expect(k8s.documentText == "k8s ")

        // une 只有五代收錄，預設的三代這個碼只有英文軌。
        let v5 = replay(["u", "n", "e", "SPACE"], configuration: EngineConfiguration(cangjieVersion: .v5))
        #expect(v5.documentText == "函")
        #expect(replay(["u", "n", "e", "SPACE"]).documentText == "une ")
        #expect(EngineConfiguration().cangjieVersion == .v3)

        var ctxEngine = InputEngine()
        ctxEngine.syncExternalContext("pasted")
        _ = ctxEngine.handle(.character("m"))
        _ = ctxEngine.handle(.character("y"))
        let effect = ctxEngine.handle(.space)
        #expect(effect.committedText == " 下")
    }
}

@Suite("Cangjie 3 / 5 compatible decompositions")
struct CompatibleDecompositionTests {
    @Test("Default table accepts both the Cangjie 5 code and the macOS Cangjie 3 code")
    func bothGenerationsCommitTheSameCharacter() {
        #expect(replay(["h", "s", "p", "SPACE"]).documentText == "怎")
        #expect(replay(["o", "s", "p", "SPACE"]).documentText == "怎")
        #expect(replay(["a", "h", "s", "SPACE"]).documentText == "昨")
        #expect(replay(["h", "s", "SHIFT_SPACE", "DIGIT2"]).documentText == "乍")
    }

    @Test("Primary table keeps first rank and `is` stays English in Cangjie 5")
    func primaryRankAndEnglishShortWordsSurvive() {
        #expect(CangjieDictionary.sharedV5.candidates(for: "hs").first == "戶")
        #expect(CangjieDictionary.sharedV5.candidates(for: "no") == ["久", "欠"])
        #expect(CangjieDictionary.sharedV5.candidates(for: "is").isEmpty)
        for word in [["i", "s"], ["d", "o"], ["g", "o"], ["t", "h", "e"]] {
            #expect(replay(word + ["SPACE"]).documentText == word.joined() + " ")
        }
    }

    @Test("三代可用兩種拆碼送出「怎」")
    func cangjie3AcceptsCangjie5Codes() {
        let v3 = EngineConfiguration(cangjieVersion: .v3)
        #expect(replay(["h", "s", "p", "SPACE"], configuration: v3).documentText == "怎")
        #expect(replay(["o", "s", "p", "SPACE"], configuration: v3).documentText == "怎")
        #expect(CangjieDictionary.sharedV3.candidates(for: "osp") == ["怎"])
    }

    @Test("只有原生倉頡碼能與完整英文詞共用空白鍵")
    func englishWordsAndNativeCodesKeepTheirSpaceKey() {
        for (version, words): (CangjieVersion, [String]) in [
            (.v5, ["is", "if", "the", "hu", "like", "risk", "bike", "horse", "tune"]),
            (.v3, ["is", "if", "the", "hu", "like", "risk", "bike", "horse", "tune", "une"])
        ] {
            let configuration = EngineConfiguration(cangjieVersion: version)
            for word in words {
                let engine = replay(word.map(String.init) + ["SPACE"], configuration: configuration)
                #expect(engine.documentText == word + " ")
            }
        }
        // 候選有常用字的完整英文詞碼仍是倉頡優先，兩代都一樣。
        #expect(replay(["a", "n", "d", "SPACE"]).documentText == "閑")
        #expect(replay(["d", "a", "m", "SPACE"]).documentText == "查")
        let v3 = EngineConfiguration(cangjieVersion: .v3)
        #expect(replay(["a", "n", "d", "SPACE"], configuration: v3).documentText == "閑")
        // une 只有五代有候選，所以五代送出「函」、三代送出英文。
        let v5 = EngineConfiguration(cangjieVersion: .v5)
        #expect(replay(["u", "n", "e", "SPACE"], configuration: v5).documentText == "函")
        #expect(replay(["u", "n", "e", "SPACE"], configuration: v3).documentText == "une ")
    }

    @Test("Fallback seed table also knows both codes")
    func seedTableKnowsBothCodes() {
        let seed = CangjieDictionary()
        #expect(seed.candidates(for: "hsp") == ["怎"])
        #expect(seed.candidates(for: "osp") == ["怎"])
    }
}

@Suite("Engine never forwards keys while composing")
struct ComposingKeyOwnershipTests {
    @Test("Arrow keys with nothing to pick are swallowed and keep the buffer")
    func arrowsAreSwallowed() {
        var engine = InputEngine()
        _ = engine.handle(.character("m"))
        _ = engine.handle(.character("y"))
        let down = engine.handle(.arrowDown)
        #expect(down.handled)
        #expect(down.buffer == "my")
        #expect(down.state == .composingDual)
        let up = engine.handle(.arrowUp)
        #expect(up.handled)
        #expect(up.buffer == "my")
    }

    @Test("Shift+N and double Shift do nothing while the candidate list is focused")
    func selectingCandidateIgnoresEnglishShortcuts() {
        var engine = replay(["n", "o", "DOWN"])
        let shift = engine.handle(.selectEnglishPrediction(2))
        #expect(shift.handled)
        #expect(shift.state == .selectingCandidate)
        let toggle = engine.handle(.doubleShift)
        #expect(toggle.handled)
        #expect(toggle.state == .selectingCandidate)
        #expect(engine.handle(.space).committedText == "欠")
    }

    @Test("Candidate focus wraps; a digit that selects nothing types the letters and the digit")
    func candidateFocusStaysInRange() {
        #expect(replay(["n", "o", "DOWN", "DOWN", "SPACE"]).documentText == "久")
        #expect(replay(["n", "o", "DOWN", "UP"]).state == .composingDual)
        #expect(replay(["n", "o", "DOWN", "UP", "ENTER"]).documentText == "no")

        // `m4`、`v2`、`a0` 這類代號：數字選不到候選也接不上英文詞時，連同原字母送出。
        let code = replay(["m", "4"])
        #expect(code.documentText == "m4")
        #expect(code.state == .idle)
        #expect(replay(["n", "o", "9"]).documentText == "no9")
        #expect(replay(["a", "0"]).documentText == "a0")
        #expect(replay(["m", "y", "SPACE", "m", "4"]).documentText == "下 m4")

        // 混打時數字不搶著選字，`m120` 才能一路打完。接得上英文詞的仍然續打。
        #expect(replay(["m", "1"]).documentText == "m1")
        #expect(replay(["m", "1", "2", "0"]).documentText == "m120")
        #expect(replay(["m", "y", "SPACE", "m", "1", "2", "0"]).documentText == "下 m120")
        #expect(replay(["k", "8", "TAB"]).documentText == "k8s ")

        // 兩個字母以上且有兩個以上候選時，數字直接選字，不必先聚焦。
        #expect(replay(["o", "j", "1"]).documentText == "午")
        #expect(replay(["o", "j", "2"]).documentText == "什")
        #expect(replay(["o", "j", "3"]).documentText == "oj3")
        #expect(replay(["o", "j"]).currentOverlay?.cangjieTrack?.digitsSelect == true)
        // 單一字母或只有一個候選時沒有東西可選，數字是打字用的，浮窗不顯示編號。
        #expect(replay(["a", "1"]).documentText == "a1")
        #expect(replay(["m", "y", "1"]).documentText == "my1")
        #expect(replay(["a"]).currentOverlay?.cangjieTrack?.digitsSelect == false)
        #expect(replay(["m", "y"]).currentOverlay?.cangjieTrack?.digitsSelect == false)
        // 接得上英文詞的數字優先續打。
        #expect(replay(["m", "p", "3", "TAB"]).documentText == "mp3 ")

        // 聚焦候選後任何情況數字都選字，↓ 與 Shift+Space 都可以聚焦。
        #expect(replay(["n", "o", "DOWN", "1"]).documentText == "久")
        #expect(replay(["n", "o", "SHIFT_SPACE", "2"]).documentText == "欠")
        // 純中文模式沒有英文軌，數字照舊直接選字。
        #expect(replay(["n", "o", "2"], configuration: EngineConfiguration(mixedModeEnabled: false)).documentText == "欠")

        // 已聚焦候選清單或純中文模式時，選不到的數字不動作，緩衝保留。
        let focused = replay(["n", "o", "DOWN", "9"])
        #expect(focused.buffer == "no")
        #expect(focused.documentText.isEmpty)
        let chineseOnly = replay(["n", "o", "9"], configuration: EngineConfiguration(mixedModeEnabled: false))
        #expect(chineseOnly.buffer == "no")
        #expect(chineseOnly.documentText.isEmpty)
    }

    @Test("Disabled Ctrl+[ cancels a composition like Esc and passes through when idle")
    func disabledCtrlBracket() {
        var engine = InputEngine(configuration: EngineConfiguration(ctrlBracketsQuotesEnabled: false))
        #expect(engine.handle(.ctrlLeftBracket).handled == false)
        _ = engine.handle(.character("m"))
        let cancelled = engine.handle(.ctrlLeftBracket)
        #expect(cancelled.handled)
        #expect(cancelled.state == .idle)
        #expect(cancelled.committedText == nil)
    }

    @Test("Pure English mode forwards Ctrl+, and Option literals untouched")
    func pureEnglishForwardsShortcuts() {
        var engine = replay(["DBL_SHIFT"])
        #expect(engine.handle(.ctrlFullwidth(",")).handled == false)
        #expect(engine.handle(.optionLiteral("1")).handled == false)
        #expect(engine.documentText.isEmpty)
    }
}

@Suite("Settings changes and Chinese-only mode")
struct ConfigurationTests {
    @Test("Switching the Cangjie table mid-composition re-validates state and focus")
    func tableSwitchRevalidates() {
        // une 只有五代收錄。切到三代後這個碼沒有候選也不是合法前綴，
        // 焦點必須放掉並落到僅英文軌。
        var engine = replay(["u", "n", "e", "SHIFT_SPACE"], configuration: EngineConfiguration(cangjieVersion: .v5))
        #expect(engine.state == .selectingCandidate)
        #expect(engine.selectedCandidateIndex == 0)
        engine.configuration.cangjieVersion = .v3
        #expect(engine.state == .composingEnglishOnly)
        #expect(engine.selectedCandidateIndex == 0)
        #expect(engine.handle(.tab).committedText == "une ")
    }

    @Test("Chinese-only mode rejects keys that cannot extend a code instead of losing input")
    func chineseOnlyMode() {
        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)

        let rejected = replay(["n", "o", "t"], configuration: chineseOnly)
        #expect(rejected.buffer == "no")
        #expect(rejected.state == .composingDual)

        let incomplete = replay(["i", "s", "SPACE"], configuration: chineseOnly)
        #expect(incomplete.buffer == "is")
        #expect(incomplete.documentText.isEmpty)

        let tab = replay(["m", "y", "TAB"], configuration: chineseOnly)
        #expect(tab.buffer == "my")
        #expect(replay(["m", "y", "TAB", "SPACE"], configuration: chineseOnly).documentText == "下")

        #expect(replay(["k", "8"], configuration: chineseOnly).buffer == "k")
        #expect(replay(["z"], configuration: chineseOnly).documentText == "z")
        #expect(replay(["o", "n", "f", "SPACE", "A"], configuration: chineseOnly).documentText == "你 A")
        #expect(replay(["m", "y", "ENTER"], configuration: chineseOnly).documentText == "my")
    }
}

@Suite("English prediction casing")
struct EnglishCasingTests {
    @Test("Letters the user capitalised are never rewritten")
    func typedCapitalsArePreserved() {
        let predictor = EnglishPredictor.shared
        #expect(predictor.predictions(for: "HTT", limit: 1) == ["HTTP"])
        #expect(predictor.predictions(for: "Hell", limit: 5).contains("Hello"))
        #expect(predictor.predictions(for: "UseSt", limit: 1) == ["UseState"])
        #expect(replay(["H", "T", "T", "P", "TAB"]).documentText == "HTTP ")
        #expect(replay(["M", "y", "TAB"]).documentText == "My ")
    }

    @Test("All-lowercase input takes the lexicon casing of developer terms")
    func lexiconCasingForLowercaseInput() {
        #expect(EnglishPredictor.shared.predictions(for: "usest", limit: 1) == ["useState"])
        #expect(replay(["u", "s", "e", "S", "t", "TAB"]).documentText == "useState ")
    }

    @Test("Equal-frequency predictions come back in one stable order")
    func deterministicOrder() {
        let predictor = EnglishPredictor(entries: [
            EnglishEntry(word: "abcd", frequency: 10),
            EnglishEntry(word: "abcf", frequency: 10),
            EnglishEntry(word: "abce", frequency: 10)
        ])
        #expect(predictor.predictions(for: "abc", limit: 5) == ["abcd", "abce", "abcf"])
    }
}

@Suite("Quote pairing, spacing and context mirror")
struct TypographyTests {
    @Test("直引號在任何語境都是半形")
    func straightQuotesStayHalfwidth() {
        #expect(replay(["DQUOTE", "h", "e", "l", "l", "o", "DQUOTE"]).documentText == "\"hello\"")
        #expect(replay(["o", "n", "f", "SPACE", "DQUOTE", "SQUOTE"]).documentText == "你\"'")
        var engine = InputEngine(initialDocumentText: "他說「你好")
        #expect(engine.handle(.character("\"")).committedText == "\"")
    }

    @Test("方括號與大括號在中文或空前文出角引號，英數前文維持半形")
    func bracketKeysTypeCornerQuotes() {
        for (key, expected) in [("LBRACKET", "「"), ("RBRACKET", "」"), ("LBRACE", "『"), ("RBRACE", "』")] {
            #expect(replay([key]).documentText == expected)
        }
        #expect(replay(["LBRACKET", "o", "n", "f", "SPACE", "RBRACKET"]).documentText == "「你」")
        #expect(replay(["a", "r", "r", "ENTER", "LBRACKET", "0", "RBRACKET"]).documentText == "arr[0]")
        #expect(replay(["f", "n", "ENTER", "LPAREN", "RPAREN", "SPACE", "LBRACE", "RBRACE"]).documentText == "fn() {}")
        #expect(replay(["CTRL_LBRACKET", "CTRL_RBRACKET", "CTRL_SHIFT_LBRACKET", "CTRL_SHIFT_RBRACKET"]).documentText == "「」『』")
    }

    @Test("混打組字未聚焦候選時，句點連同原字母一次送出")
    func periodKeepsTypedLetters() {
        for name in ["my.file", "os.path", "go.mod", "id.name", ".gitignore", "./build.sh"] {
            #expect(replay(name.map(String.init) + ["ENTER"]).documentText == name)
        }
        var engine = replay(["m", "y"])
        let period = engine.handle(.character("."))
        #expect(period.committedText == "my.")
        #expect(period.deletedBackwardCount == 0)
        #expect(period.state == .idle)
        #expect(!period.pendingAutoSpace)
    }

    @Test("無緩衝的句點只在漢字或中文標點後出「。」")
    func periodFollowsTrustedContext() {
        #expect(replay(["m", "y", "SPACE", "."]).documentText == "下。")
        #expect(replay(["m", "y", "SPACE", ".", "."]).documentText == "下。。")
        #expect(replay(["m", "y", "SHIFT_SPACE", "."]).documentText == "下。")
        #expect(replay(["n", "o", "DOWN", "."]).documentText == "欠。")
        #expect(replay(["."]).documentText == ".")
        #expect(replay(["c", "d", "ENTER", "SPACE", ".", "."]).documentText == "cd ..")
        #expect(replay(["m", "y", "SPACE", "SPACE", "."]).documentText == "下 .")
        #expect(replay(["3", ".", "1"]).documentText == "3.1")

        // 游標移動後沒有可信前文。
        var moved = replay(["m", "y", "SPACE"])
        moved.noteExternalCursorMovement()
        #expect(moved.handle(.character(".")).committedText == ".")
    }

    @Test("Option 加標點當次輸出半形，選單的半形標點只改寬度")
    func optionLiteralAndHalfwidthSetting() {
        #expect(replay(["m", "y", "OPT_."]).documentText == "my.")
        #expect(replay(["m", "y", "SPACE", "OPT_."]).documentText == "下.")
        #expect(replay(["n", "o", "DOWN", "OPT_."]).documentText == "欠.")
        #expect(replay(["a", "OPT_1"]).documentText == "a1")
        #expect(replay(["m", "y", "SPACE", "OPT_.", "."]).documentText == "下..")

        let halfwidth = EngineConfiguration(autoPunctuationEnabled: false)
        #expect(replay(["m", "y", "SPACE", "."], configuration: halfwidth).documentText == "下.")
        #expect(replay(["m", "y", "COMMA"], configuration: halfwidth).documentText == "下,")
        #expect(replay(["m", "y", "."], configuration: halfwidth).documentText == "my.")
        #expect(replay(["LBRACKET"], configuration: halfwidth).documentText == "[")
        #expect(replay(["CTRL_COMMA", "CTRL_LBRACKET"], configuration: halfwidth).documentText == "，「")

        // Ctrl+. 不看語境，行首、英數後與半形設定下都出「。」。
        #expect(replay(["CTRL_PERIOD"]).documentText == "。")
        #expect(replay(["CTRL_PERIOD"], configuration: halfwidth).documentText == "。")
        #expect(replay(["m", "y", "CTRL_PERIOD"]).documentText == "下。")
        #expect(replay(["i", "s", "ENTER", "CTRL_PERIOD"]).documentText == "is。")
        var literal = replay(["CAPS_ON"])
        #expect(literal.handle(.ctrlFullwidth(".")).handled == false)

        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)
        #expect(replay(["m", "y", "."], configuration: chineseOnly).documentText == "下。")
        #expect(replay(["m", "y", "OPT_."], configuration: chineseOnly).documentText == "下.")
        let incomplete = replay(["i", "s", "."], configuration: chineseOnly)
        #expect(incomplete.buffer == "is")
        #expect(incomplete.documentText.isEmpty)
    }

    @Test("半形收尾標點只收合自動補上的空格，手動空格保留")
    func onlyAutoSpaceCollapses() {
        var auto = replay(["h", "e", "l", "l", "o", "TAB"])
        #expect(auto.handle(.character(".")).deletedBackwardCount == 1)
        #expect(auto.documentText == "hello.")

        var manual = replay(["h", "e", "l", "l", "o", "ENTER", "SPACE"])
        #expect(manual.handle(.character(".")).deletedBackwardCount == 0)
        #expect(manual.documentText == "hello .")

        #expect(replay(["h", "e", "l", "l", "o", "TAB", "OPT_,"]).documentText == "hello,")
        let halfwidth = EngineConfiguration(autoPunctuationEnabled: false)
        #expect(replay(["h", "e", "l", "l", "o", "TAB", "COMMA"], configuration: halfwidth).documentText == "hello,")
    }

    @Test("標點設定在組字中切換時保留候選焦點")
    func punctuationSettingKeepsCandidateFocus() {
        var engine = replay(["n", "o", "DOWN"])
        engine.configuration.autoPunctuationEnabled = false
        #expect(engine.state == .selectingCandidate)
        #expect(engine.selectedCandidateIndex == 1)
        #expect(engine.handle(.space).committedText == "欠")
    }

    @Test("A matching client context keeps the pending trailing space collapsible")
    func matchingContextKeepsPendingSpace() {
        var engine = replay(["h", "e", "l", "l", "o", "TAB"])
        engine.syncExternalContext("hello ")
        let comma = engine.handle(.character(","))
        #expect(comma.deletedBackwardCount == 1)
        #expect(engine.documentText == "hello,")

        var moved = replay(["h", "e", "l", "l", "o", "TAB"])
        moved.syncExternalContext("elsewhere ")
        #expect(moved.handle(.character(",")).deletedBackwardCount == 0)
    }

    @Test("`>` keeps the space after an English word; listed closers still collapse it")
    func greaterThanDoesNotCollapse() {
        #expect(replay(["a", "b", "c", "TAB", "GT"]).documentText == "abc >")
        for closer in ",.!?;:)]}%" {
            let engine = replay(["a", "b", "c", "TAB", String(closer)])
            #expect(engine.documentText == "abc" + String(closer))
        }
    }

    @Test("Enter, Tab and arrows drop the mirrored context so a new line starts clean")
    func cursorKeysInvalidateMirror() {
        for key in ["ENTER", "TAB", "UP", "DOWN"] {
            let engine = replay(["o", "n", "f", "SPACE", key, "h", "e", "l", "l", "o", "TAB"])
            #expect(engine.documentText == "hello ", "after \(key)")
        }

        var engine = replay(["o", "n", "f", "SPACE"])
        engine.noteExternalCursorMovement()
        #expect(engine.handle(.character("1")).committedText == "1")

        var composing = replay(["m", "y"])
        composing.noteExternalCursorMovement()
        #expect(composing.buffer == "my")
    }

    @Test("Auto-space recognises Han extensions, fullwidth symbols and CRLF")
    func autoSpacerCharacterClasses() {
        #expect(AutoSpacer.isChinese("\u{2A700}"))
        #expect(AutoSpacer.isChinese("\u{30000}"))
        #expect(AutoSpacer.isChinese("\u{845B}\u{E0100}"))
        #expect(!AutoSpacer.isChinese("a"))
        #expect(AutoSpacer.leadingSpace(before: "\u{2A700}", for: .englishOrNumber, enabled: true) == " ")
        #expect(AutoSpacer.leadingSpace(before: "～", for: .chinese, enabled: true).isEmpty)
        #expect(AutoSpacer.leadingSpace(before: "\r\n", for: .chinese, enabled: true).isEmpty)
        #expect(AutoSpacer.leadingSpace(before: "１", for: .chinese, enabled: true).isEmpty)
        #expect(AutoSpacer.leadingSpace(before: "a", for: .chinese, enabled: true) == " ")
    }
}

@Suite("Caps Lock 半形層與 Shift+Space")
struct LiteralLayerTests {
    @Test("組字中開燈先送出原字母，亮燈期間出鍵面半形，熄燈後恢復混打")
    func capsLockLayer() {
        var engine = replay(["m", "y", "CAPS_ON", ".", "f", "i", "l", "e"])
        #expect(engine.documentText == "my.file")
        #expect(engine.state == .idle)
        #expect(engine.currentOverlay == nil)
        #expect(engine.handle(.tab).handled == false)
        #expect(engine.handle(.enter).handled == false)
        _ = engine.handle(.capsLock(false))
        _ = engine.handle(.character("m"))
        _ = engine.handle(.character("y"))
        #expect(engine.handle(.space).committedText == "下")
    }

    @Test("亮燈期間不補空格、不轉全形、不收合空格")
    func capsLockTypesKeyFaces() {
        let tokens = ["o", "n", "f", "SPACE", "CAPS_ON", "a", "1", "COMMA", "DQUOTE", "LBRACKET", "SPACE", "SHIFT_SPACE", "A"]
        #expect(replay(tokens).documentText == "你a1,\"[  A")
        #expect(replay(["h", "e", "l", "l", "o", "TAB", "CAPS_ON", "COMMA"]).documentText == "hello ,")
        #expect(replay(["n", "o", "DOWN", "CAPS_ON"]).documentText == "no")

        var engine = replay(["CAPS_ON"])
        #expect(engine.handle(.optionLiteral(".")).handled == false)
        #expect(engine.handle(.ctrlFullwidth(",")).handled == false)
    }

    @Test("Caps Lock 與雙擊 Shift 的純英文各自獨立")
    func capsLockKeepsUnderlyingMode() {
        #expect(replay(["DBL_SHIFT", "CAPS_ON", "CAPS_OFF"]).state == .pureEnglish)
        #expect(replay(["CAPS_ON", "CAPS_OFF", "m", "y", "SPACE"]).documentText == "下")
        #expect(replay(["CAPS_ON", "CAPS_ON", "CAPS_OFF", "CAPS_OFF"]).capsLockEnabled == false)
    }

    @Test("Shift+Space 有候選時聚焦清單，沒有候選時與空白鍵相同")
    func shiftSpaceFocusesCandidates() {
        var engine = replay(["m", "y", "SHIFT_SPACE"])
        #expect(engine.state == .selectingCandidate)
        #expect(engine.buffer == "my")
        #expect(engine.documentText.isEmpty)
        #expect(engine.handle(.shiftSpace).state == .selectingCandidate)
        #expect(engine.handle(.escape).state == .composingDual)
        #expect(engine.handle(.space).committedText == "下")

        #expect(replay(["i", "s", "SHIFT_SPACE"]).documentText == "is ")
        #expect(replay(["SHIFT_SPACE"]).documentText == " ")
        #expect(replay(["n", "o", "SHIFT_SPACE", "DOWN", "SPACE"]).documentText == "欠")
    }
}

@Suite("Cangjie table loading")
struct CangjieTableTests {
    @Test("Malformed codes are dropped instead of trapping")
    func malformedCodesAreIgnored() {
        let dictionary = CangjieDictionary(entries: ["": ["空"], "abcdef": ["長"], "a1": ["數"], "z": ["無"], "ab": ["明"]])
        #expect(dictionary.codeCount == 1)
        #expect(dictionary.candidates(for: "ab") == ["明"])
        #expect(dictionary.hasCandidatesOrPrefix(for: "a"))
        #expect(!dictionary.hasCandidatesOrPrefix(for: "z"))
    }

    @Test("A code listed twice merges its candidates without duplicates")
    func duplicateCodesMerge() {
        let parsed = CangjieDictionary.parseTableTSV("# comment\na\t日\nA\t曰,日\nbad line\nb\t\n")
        #expect(parsed == ["a": ["日", "曰"]])
    }

    @Test("No bundled code has more candidates than the selection keys can reach")
    func everyCandidateIsReachable() {
        let limit = EngineConfiguration().maxVisibleCandidates
        for version in [CangjieVersion.v5, .v3] {
            let dictionary = CangjieDictionary.shared(version: version)
            #expect(dictionary.maxCandidateCount <= limit, "\(version.rawValue)")
        }
    }
}

@Suite("English choice learning")
struct UsageHistoryTests {
    private func firstPredictions(_ engine: InputEngine) -> [String] {
        engine.currentOverlay?.englishTrack.predictions ?? []
    }

    @Test("A prediction adopted with Shift+digit or Tab ranks first for the same prefix")
    func adoptedPredictionRanksFirst() {
        #expect(firstPredictions(replay(["f", "u", "n", "c"])).first == "function")

        let learned = replay(["f", "u", "n", "c", "SHIFT_2", "f", "u", "n", "c"])
        #expect(learned.documentText == "functions ")
        #expect(firstPredictions(learned).prefix(2) == ["functions", "function"])

        var tabbed = learned
        tabbed.handle(.tab)
        #expect(tabbed.documentText == "functions functions ")
        #expect(tabbed.usageHistory.english == [UsageHistory.Entry(word: "functions", count: 2)])
    }

    @Test("More adoptions win, and the most recent wins a tie")
    func countThenRecency() {
        var history = UsageHistory()
        for word in ["functional", "function", "functional", "functions"] {
            history.recordEnglish(word)
        }
        let predictions = EnglishPredictor.shared.predictions(for: "func", limit: 3, usage: history)
        #expect(predictions == ["functional", "functions", "function"])
    }

    @Test("Learning never displaces a locked short word or the Cangjie first candidate")
    func shortWordAndCangjieStayFixed() {
        let learned = replay(["i", "d", "e", "a", "TAB", "i", "d"])
        #expect(firstPredictions(learned).prefix(2) == ["id", "idea"])

        var tab = learned
        tab.handle(.tab)
        #expect(tab.documentText == "idea id ")

        var history = UsageHistory()
        history.recordEnglish("myself")
        var engine = InputEngine(usageHistory: history)
        engine.handle(.character("m"))
        engine.handle(.character("y"))
        #expect(firstPredictions(engine).prefix(2) == ["my", "myself"])
        engine.handle(.space)
        #expect(engine.documentText == "下")
    }

    @Test("Raw letters, developer-term filtering and the capacity limit")
    func recordingBoundaries() {
        // Enter 與沒有預測時的 Tab 送出原字母，不算採用。
        #expect(replay(["f", "u", "n", "c", "ENTER"]).usageHistory.isEmpty)
        #expect(replay(["z", "z", "z", "z", "TAB"]).usageHistory.isEmpty)

        var history = UsageHistory()
        history.recordEnglish("Docker")
        #expect(history.english.first?.word == "docker")
        let withoutDev = EnglishPredictor.shared.predictions(for: "dock", limit: 5, includeDeveloperTerms: false, usage: history)
        #expect(!withoutDev.contains("docker"))

        for index in 0..<(UsageHistory.capacity + 10) {
            history.recordEnglish("word\(index)")
        }
        #expect(history.english.count == UsageHistory.capacity)
        #expect(!history.english.contains { $0.word == "docker" })
    }
}

/// 倉頡重碼與讀音反查的順序學習。全部以使用者看得到的結果斷言。
@Suite("候選順序學習")
struct CandidateLearningTests {
    /// 兩代碼表對 `oj` 都收「午、什」，撿第二個字來看順序有沒有被學起來。
    private let code = "oj"
    private let tableOrder = ["午", "什"]

    private func type(_ letters: String, into engine: inout InputEngine) {
        for ch in letters {
            engine.handle(.character(ch))
        }
    }

    private func candidates(_ engine: InputEngine) -> [String] {
        engine.currentOverlay?.cangjieTrack?.candidates ?? []
    }

    /// 打 `oj`、按 ↓ 選第二個候選、按空白鍵送出，然後回到閒置。
    private func pickSecondCandidate(_ engine: inout InputEngine) -> String {
        type(code, into: &engine)
        engine.handle(.arrowDown)
        return engine.handle(.space).committedCore ?? ""
    }

    @Test("預設順序來自碼表，送出一次不改順序，兩次才讓那個字變首選")
    func promotionNeedsTwoCommits() {
        var engine = InputEngine()
        type(code, into: &engine)
        #expect(candidates(engine) == tableOrder)
        engine.handle(.escape)

        #expect(pickSecondCandidate(&engine) == "什")
        type(code, into: &engine)
        #expect(candidates(engine) == tableOrder)
        engine.handle(.escape)

        #expect(pickSecondCandidate(&engine) == "什")
        type(code, into: &engine)
        #expect(candidates(engine) == ["什", "午"])
        // 浮窗的第一個字就是空白鍵送出的字。
        #expect(engine.handle(.space).committedCore == "什")

        // 之後持續用空白鍵送首選，次數只會往上，首選更穩。
        for _ in 0..<3 {
            type(code, into: &engine)
            #expect(engine.handle(.space).committedCore == "什")
        }
        type(code, into: &engine)
        #expect(candidates(engine) == ["什", "午"])
    }

    @Test("數字選字與方向鍵選字都算一次")
    func digitAndArrowCommitsBothCount() {
        for secondPick in ["digit", "arrow"] {
            var engine = InputEngine()
            for _ in 0..<2 {
                type(code, into: &engine)
                if secondPick == "digit" {
                    // `oj` 是兩個字母、兩個候選，數字直接選字。
                    engine.handle(.character("2"))
                } else {
                    engine.handle(.arrowDown)
                    engine.handle(.space)
                }
            }
            type(code, into: &engine)
            #expect(candidates(engine) == ["什", "午"], "\(secondPick)")
        }
    }

    @Test("關閉倉頡學習後回到碼表順序且不再記錄，重新開啟時先前的紀錄仍在")
    func togglingKeepsStoredRecords() {
        var engine = InputEngine()
        for _ in 0..<2 {
            _ = pickSecondCandidate(&engine)
        }
        let learned = engine.usageHistory

        engine.configuration.learnsCangjieOrder = false
        type(code, into: &engine)
        #expect(candidates(engine) == tableOrder)
        #expect(engine.handle(.space).committedCore == "午")
        // 關閉時不記錄：紀錄一個字都沒多。
        #expect(engine.usageHistory == learned)

        engine.configuration.learnsCangjieOrder = true
        type(code, into: &engine)
        #expect(candidates(engine) == ["什", "午"])
    }

    @Test("單一候選的碼不產生紀錄")
    func singleCandidateCodeIsNotRecorded() {
        var engine = InputEngine()
        // `my` 只有「下」一個候選，沒有順序可學。
        type("my", into: &engine)
        #expect(candidates(engine) == ["下"])
        #expect(engine.handle(.space).committedCore == "下")
        #expect(engine.usageHistory.cangjie.isEmpty)
    }

    @Test("紀錄裡不屬於目前代別候選的字被忽略")
    func recordsOutsideTheTableAreIgnored() {
        // 「日」不是 `oj` 的候選，兩代都不是。
        let history = UsageHistory(cangjieChoices: [(code, "日"), (code, "日"), (code, "什")])
        for version in [CangjieVersion.v5, .v3] {
            var engine = InputEngine(
                configuration: EngineConfiguration(cangjieVersion: version),
                usageHistory: history
            )
            type(code, into: &engine)
            #expect(candidates(engine) == tableOrder, "\(version.rawValue)")
        }
    }

    @Test("候選清單永遠是碼表該碼候選的一個排列")
    func candidatesStayAPermutation() {
        let history = UsageHistory(cangjieChoices: [
            ("no", "欠"), ("no", "欠"), ("a", "曰"), ("a", "曰"), ("a", "曰"), ("oj", "什"), ("oj", "什")
        ])
        var engine = InputEngine(usageHistory: history)
        for probe in ["no", "a", "oj", "he", "i"] {
            engine.handle(.escape)
            type(probe, into: &engine)
            let shown = candidates(engine)
            let table = CangjieDictionary.sharedV5.candidates(for: probe)
            #expect(shown.sorted() == table.sorted(), "\(probe)")
        }
    }

    @Test("學習開啟且有紀錄時，既有的分流行為全部不變")
    func learningDoesNotChangeOtherBehaviour() {
        let history = UsageHistory(
            englishWords: ["myself", "idea"],
            cangjieChoices: [("oj", "什"), ("oj", "什"), ("no", "欠"), ("no", "欠")],
            readingChoices: ["波", "波"]
        )
        func fresh() -> InputEngine { InputEngine(usageHistory: history) }

        var space = fresh()
        type("my", into: &space)
        #expect(space.handle(.space).committedCore == "下")

        var shortWord = fresh()
        type("id", into: &shortWord)
        #expect(shortWord.currentOverlay?.englishTrack.predictions.first == "id")
        shortWord.handle(.tab)
        #expect(shortWord.documentText == "id ")

        var identifier = fresh()
        type("m", into: &identifier)
        identifier.handle(.character("1"))
        identifier.handle(.character("2"))
        identifier.handle(.character("0"))
        #expect(identifier.documentText == "m120")
    }

    @Test("反查選過的字下次排第一，在它的其他讀音列也往前")
    func readingLookupPromotesOnFirstPick() {
        // ㄅㄛ 一聲是「玻波剝…」，ㄆㄛ 一聲是「坡潑波…」，「波」在兩列都不是第一個。
        var engine = InputEngine()
        #expect(firstReadingRows(&engine, dachenKeys: "1i ") == ["玻", "波", "剝"])

        engine.handle(.toggleReadingLookup)
        for ch in "1i" { engine.handle(.character(ch)) }
        engine.handle(.space)
        engine.handle(.arrowDown)
        // 選取中按 2 選本頁第二列。
        #expect(engine.handle(.character("2")).committedCore == "波")

        #expect(firstReadingRows(&engine, dachenKeys: "1i ").first == "波")
        #expect(firstReadingRows(&engine, dachenKeys: "qi ").first == "波")

        engine.configuration.learnsReadingLookupOrder = false
        #expect(firstReadingRows(&engine, dachenKeys: "1i ").first == "玻")
        #expect(firstReadingRows(&engine, dachenKeys: "qi ").first == "坡")
    }

    /// 開反查、打一段大千鍵序、讀出本頁前三個字，然後按 Esc 還原。
    private func firstReadingRows(_ engine: inout InputEngine, dachenKeys: String) -> [String] {
        engine.handle(.toggleReadingLookup)
        for ch in dachenKeys {
            if ch == " " {
                engine.handle(.space)
            } else {
                engine.handle(.character(ch))
            }
        }
        let rows = engine.currentReadingLookupPanel?.rows.prefix(3).map(\.character) ?? []
        engine.handle(.escape)
        return Array(rows)
    }

    @Test("三個學習設定互不影響")
    func thethreeSettingsAreIndependent() {
        let history = UsageHistory(
            englishWords: ["functions"],
            cangjieChoices: [("oj", "什"), ("oj", "什")],
            readingChoices: ["波", "波"]
        )
        var engine = InputEngine(
            configuration: EngineConfiguration(
                learnsEnglishPredictions: false,
                learnsCangjieOrder: true,
                learnsReadingLookupOrder: false
            ),
            usageHistory: history
        )
        // 關閉英文學習：`func` 的首選回到詞頻順序的 function。
        type("func", into: &engine)
        #expect(engine.currentOverlay?.englishTrack.predictions.first == "function")
        engine.handle(.escape)
        type(code, into: &engine)
        #expect(candidates(engine) == ["什", "午"])
        engine.handle(.escape)
        #expect(firstReadingRows(&engine, dachenKeys: "1i ").first == "玻")

        // 關閉英文學習時也不記錄。
        var english = engine
        english.handle(.escape)
        type("func", into: &english)
        english.handle(.tab)
        #expect(english.usageHistory.english == history.english)
    }

    @Test("舊版存檔只有英文紀錄也能解碼，各類容量上限獨立")
    func legacyDecodingAndCapacity() throws {
        let legacy = #"{"english":[{"word":"functions","count":2}]}"#
        let decoded = try JSONDecoder().decode(UsageHistory.self, from: Data(legacy.utf8))
        #expect(decoded.english == [UsageHistory.Entry(word: "functions", count: 2)])
        #expect(decoded.cangjie.isEmpty)
        #expect(decoded.reading.isEmpty)

        var history = UsageHistory()
        history.recordCangjie(code: "oj", character: "什")
        history.recordReading("波")
        for index in 0..<(UsageHistory.cangjieCapacity + 5) {
            history.recordCangjie(code: "a\(index)", character: "日")
        }
        for index in 0..<(UsageHistory.readingCapacity + 5) {
            history.recordReading("字\(index)")
        }
        #expect(history.cangjie.count == UsageHistory.cangjieCapacity)
        #expect(history.reading.count == UsageHistory.readingCapacity)
        #expect(!history.cangjie.contains { $0.code == "oj" })
        #expect(!history.reading.contains { $0.character == "波" })
        #expect(history.english.isEmpty)

        // 編碼後再解碼，三類紀錄都回得來。
        let roundTrip = try JSONDecoder().decode(
            UsageHistory.self,
            from: try JSONEncoder().encode(history)
        )
        #expect(roundTrip == history)
    }
}

@Suite("單字讀音反查索引")
struct ReadingIndexTests {
    private let index = ReadingIndex.shared

    private func query(_ keys: String, _ scheme: PhoneticScheme) -> ReadingQuery? {
        guard case .syllable(let parsed) = index.interpret(keys, scheme: scheme) else { return nil }
        return parsed
    }

    @Test("打字的人用兩種鍵盤查 ㄘㄨㄛˋ，得到同一個讀音與同一串候選")
    func acceptanceCuo() {
        let fromDachen = query("hji4", .dachen)
        let fromPinyin = query("cuo4", .pinyin)
        #expect(fromDachen == ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: .fourth))
        #expect(fromDachen == fromPinyin)

        guard let reading = fromDachen else { return }
        #expect(index.display(reading, scheme: .dachen) == "ㄘㄨㄛˋ")
        #expect(index.display(reading, scheme: .pinyin) == "cuo4")

        let v5 = index.candidates(for: reading, version: .v5)
        #expect(v5.map(\.character).contains("厝"))
        #expect(v5.first?.character == "錯")
        #expect(index.candidates(for: reading, version: .v3).map(\.character) == v5.map(\.character))

        // 反查面板的候選格式例：厝 在兩代都拆成 mta 一廿日。
        #expect(index.nativeCodes(for: "厝", version: .v5) == ["mta"])
        #expect(index.nativeCodes(for: "厝", version: .v3) == ["mta"])
        #expect(CangjieDictionary.sharedV5.radicals(for: "mta") == "一廿日")
    }

    @Test("怎 在兩代拆法不同，而且兩個讀音都查得到")
    func acceptanceZen() {
        let v5 = index.nativeCodes(for: "怎", version: .v5)
        let v3 = index.nativeCodes(for: "怎", version: .v3)
        #expect(v5.first == "osp")
        #expect(v3.first == "hsp")
        #expect(!v5.contains("hsp"))
        // 碼表把 osp 同時列為三代拆碼，三代仍以 hsp 為首。
        #expect(v3 == ["hsp", "osp"])
        #expect(CangjieDictionary.sharedV5.radicals(for: "osp") == "人尸心")
        #expect(CangjieDictionary.sharedV3.radicals(for: "hsp") == "竹尸心")

        // 多音字：ㄗㄜˇ 與 ㄗㄣˇ 都要列出「怎」。
        for (dachen, pinyin) in [("yk3", "ze3"), ("yp3", "zen3")] {
            guard let reading = query(dachen, .dachen) else {
                Issue.record("\(dachen) 應解讀為完整音節")
                continue
            }
            #expect(query(pinyin, .pinyin) == reading)
            #expect(index.characters(for: reading).contains("怎"))
        }
    }

    @Test("全表每個音節不指定聲調時，候選都是各聲調候選的無重複聯集")
    func tonelessIsUnionOfTones() {
        var failures: [String] = []
        for bopomofo in Set(index.tonedQueries.map(\.bopomofo)) {
            let merged = index.characters(for: ReadingQuery(bopomofo: bopomofo, tone: nil))
            let union = Set(Tone.allCases.flatMap {
                index.characters(for: ReadingQuery(bopomofo: bopomofo, tone: $0))
            })
            if Set(merged) != union || merged.count != union.count {
                failures.append(bopomofo)
            }
        }
        #expect(failures.isEmpty, "不是無重複聯集的音節：\(failures.sorted().prefix(5))")
    }

    @Test("讀音表沒有不指定聲調的列時依一到輕聲串接，有就照那一列，而且那一列不算帶調音節")
    func tonelessRowIsOptional() {
        let toned = "ㄇㄚ\tma\t1\t媽摩\nㄇㄚ\tma\t3\t馬嗎\nㄇㄚ\tma\t5\t嗎麼"
        let anyTone = ReadingQuery(bopomofo: "ㄇㄚ", tone: nil)

        let concatenated = ReadingIndex(readingsTSV: toned, nativeCodesTSV: "")
        #expect(concatenated.characters(for: anyTone) == ["媽", "摩", "馬", "嗎", "麼"])

        let ordered = ReadingIndex(readingsTSV: "ㄇㄚ\tma\t0\t馬嗎媽麼摩\n" + toned, nativeCodesTSV: "")
        #expect(ordered.characters(for: anyTone) == ["馬", "嗎", "媽", "麼", "摩"])
        #expect(ordered.characters(for: ReadingQuery(bopomofo: "ㄇㄚ", tone: .first)) == ["媽", "摩"])
        #expect(ordered.tonedSyllableCount == 3)
        #expect(ordered.tonedQueries.allSatisfy { $0.tone != nil })
        #expect(ordered.characterCount == concatenated.characterCount)
        #expect(ordered.interpret("ma", scheme: .pinyin) == .syllable(anyTone))
    }

    @Test("五種聲調各自成列，不指定聲調時跨聲調依常用度排序並依字去重")
    func tonesAndDeduplication() {
        for tone in Tone.allCases {
            let reading = ReadingQuery(bopomofo: "ㄇㄚ", tone: tone)
            #expect(!index.characters(for: reading).isEmpty)
        }
        // 「摩」讀 ㄇㄛˊ、「麼」讀 ˙ㄇㄜ，這兩個讀音不是它們的主要讀音，各自排在後面。
        #expect(index.characters(for: ReadingQuery(bopomofo: "ㄇㄚ", tone: .first)) == ["媽", "嬤", "摩", "螞"])
        #expect(index.characters(for: ReadingQuery(bopomofo: "ㄇㄚ", tone: .neutral)) == ["嗎", "麼", "蟆", "嘛"])

        // 嗎 在三聲與輕聲都有，整份結果只出現一次。各聲調的常用字一起排在前面，
        // 不是一聲的字全部排完才輪到其他聲調。
        let all = index.characters(for: ReadingQuery(bopomofo: "ㄇㄚ", tone: nil))
        #expect(all.prefix(4) == ["馬", "嗎", "麻", "媽"])
        #expect(all.filter { $0 == "嗎" }.count == 1)
        #expect(Set(all).count == all.count)

        // 全字庫只把「兒」標成 ㄦˊ，ㄦ 沒有一聲列，不指定聲調時照樣查得到其他聲調。
        #expect(index.characters(for: ReadingQuery(bopomofo: "ㄦ", tone: .first)).isEmpty)
        let er = index.characters(for: ReadingQuery(bopomofo: "ㄦ", tone: nil))
        #expect(er.prefix(3) == ["二", "耳", "兒"])
        #expect(er.filter { $0 == "兒" }.count == 1)

        // 收錄的音節缺某個聲調時仍是完整讀音，只是沒有候選。
        #expect(query("hji7", .dachen) == ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: .neutral))
        #expect(index.characters(for: ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: .neutral)).isEmpty)
    }

    @Test("大千用空白指定一聲，不打聲調鍵就是不指定")
    func toneKeys() {
        #expect(query("hji ", .dachen) == ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: .first))
        #expect(query("hji", .dachen) == ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: nil))
        #expect(query("hji6", .dachen)?.tone == .second)
        #expect(query("hji3", .dachen)?.tone == .third)
        #expect(query("cuo", .pinyin) == ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: nil))

        // 不指定聲調時不顯示調號或數字；一聲在拼音顯示 1。
        let unspecified = ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: nil)
        #expect(index.display(unspecified, scheme: .dachen) == "ㄘㄨㄛ")
        #expect(index.display(unspecified, scheme: .pinyin) == "cuo")
        let first = ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: .first)
        #expect(index.display(first, scheme: .dachen) == "ㄘㄨㄛ")
        #expect(index.display(first, scheme: .pinyin) == "cuo1")
    }

    @Test("拼音接受 ü 與鍵盤替代寫法 v")
    func pinyinUmlaut() {
        #expect(query("lü4", .pinyin) == ReadingQuery(bopomofo: "ㄌㄩ", tone: .fourth))
        #expect(query("lv4", .pinyin) == query("lü4", .pinyin))
        #expect(query("lv4", .pinyin) == query("xm4", .dachen))
        #expect(query("nv3", .pinyin) == ReadingQuery(bopomofo: "ㄋㄩ", tone: .third))
        #expect(query("lve4", .pinyin) == ReadingQuery(bopomofo: "ㄌㄩㄝ", tone: .fourth))
        #expect(index.display(ReadingQuery(bopomofo: "ㄌㄩ", tone: .fourth), scheme: .pinyin) == "lü4")
        #expect(index.characters(for: ReadingQuery(bopomofo: "ㄌㄩ", tone: .fourth)).first == "綠")
    }

    @Test("空白、未成音與查無此讀音各自可辨")
    func partialAndUnknown() {
        #expect(index.interpret("", scheme: .dachen) == .empty)
        #expect(index.interpret("", scheme: .pinyin) == .empty)
        // ㄅ 不單獨成音節，但是 ㄅㄚ 等音節的開頭。
        #expect(index.interpret("1", scheme: .dachen) == .partial)
        #expect(index.interpret("ㄅ", scheme: .dachen) == .partial)
        #expect(index.interpret("zh", scheme: .pinyin) == .partial)
        // ㄅㄆ 不是任何收錄音節的開頭。
        #expect(index.interpret("1q", scheme: .dachen) == .unknown)
        #expect(index.interpret("zzz", scheme: .pinyin) == .unknown)
        #expect(index.interpret("cuo9", scheme: .pinyin) == .unknown)
        // ㄘ 單獨成音節，一按就有候選。
        #expect(query("h", .dachen) == ReadingQuery(bopomofo: "ㄘ", tone: nil))
    }

    @Test("缺碼的字回報空陣列，查詢與候選仍然可用")
    func missingNativeCodes() {
        // 碼表為每個收錄的字在兩代各給一份拆碼，匚 兩代同碼。
        #expect(index.nativeCodes(for: "匚", version: .v5) == ["mv"])
        #expect(index.nativeCodes(for: "匚", version: .v3) == ["mv"])

        // 讀音索引只收有倉頡碼的字，所以打包的資料裡沒有缺碼的字；查沒收的字回報空陣列。
        #expect(index.nativeCodes(for: "彞", version: .v5).isEmpty)
        #expect(index.nativeCodes(for: "彞", version: .v3).isEmpty)
        #expect(!index.characters(for: ReadingQuery(bopomofo: "ㄧ", tone: .second)).contains("彞"))

        // 原生碼欄留空的字仍然列得進候選，面板那一列不顯示碼與字根。
        let sparse = ReadingIndex(
            readingsTSV: "ㄧ\tyi\t2\t夷彞",
            nativeCodesTSV: "夷\tkn\tkn"
        )
        let yi = ReadingQuery(bopomofo: "ㄧ", tone: .second)
        #expect(sparse.characters(for: yi) == ["夷", "彞"])
        #expect(sparse.candidates(for: yi, version: .v5)
            .contains { $0.character == "彞" && $0.nativeCodes.isEmpty })
    }

    @Test("同音同調在兩種鍵盤得到相同候選與順序")
    func schemesAgree() {
        for (dachen, pinyin) in [("a8", "ma"), ("-3", "er3"), ("j4", "wu4"), ("xm,4", "lve4")] {
            guard let a = query(dachen, .dachen), let b = query(pinyin, .pinyin) else {
                Issue.record("\(dachen) 與 \(pinyin) 都應解讀為完整音節")
                continue
            }
            #expect(a == b)
            #expect(index.candidates(for: a, version: .v5) == index.candidates(for: b, version: .v5))
        }
    }

    @Test("全表每個帶調音節顯示後都能解讀回同一讀音")
    func displayRoundTrip() {
        let readings = index.tonedQueries
        #expect(readings.count == 1_353)

        var dachenFailures: [String] = []
        var pinyinFailures: [String] = []
        for reading in readings {
            let shown = index.display(reading, scheme: .pinyin)
            if index.interpret(shown, scheme: .pinyin) != .syllable(reading) {
                pinyinFailures.append(shown)
            }
            // 注音一聲不加調號，顯示後與「不指定聲調」同形，這是大千記法本身的歧義。
            let expected = reading.tone == .first
                ? ReadingQuery(bopomofo: reading.bopomofo, tone: nil)
                : reading
            let bopomofo = index.display(reading, scheme: .dachen)
            if index.interpret(bopomofo, scheme: .dachen) != .syllable(expected) {
                dachenFailures.append(bopomofo)
            }
        }
        #expect(pinyinFailures.isEmpty, "拼音往返失敗：\(pinyinFailures.prefix(5))")
        #expect(dachenFailures.isEmpty, "注音往返失敗：\(dachenFailures.prefix(5))")
    }

    @Test("大千鍵位表覆蓋資料裡出現的每個注音符號")
    func dachenKeyMapCoversTable() {
        #expect(ReadingIndex.dachenKeyMap.count == 37)
        let mapped = Set(ReadingIndex.dachenKeyMap.values)
        let used = Set(index.tonedQueries.flatMap { Array($0.bopomofo) })
        #expect(used.subtracting(mapped).isEmpty)
        #expect(mapped.subtracting(used).isEmpty)
    }

    @Test("索引只依資料建立，餵小表就只查得到小表的內容")
    func buildsFromSuppliedTables() {
        let small = ReadingIndex(
            readingsTSV: """
            # 測試用
            ㄘㄨㄛ\tcuo\t4\t厝錯
            ㄇㄚ\tma\t1\t媽
            """,
            nativeCodesTSV: """
            # 測試用
            厝\tmta\tmta
            錯\t\tcta
            """
        )
        #expect(small.syllableCount == 2)
        #expect(small.characterCount == 3)
        let reading = ReadingQuery(bopomofo: "ㄘㄨㄛ", tone: .fourth)
        #expect(small.characters(for: reading) == ["厝", "錯"])
        #expect(small.candidates(for: reading, version: .v5) == [
            ReadingCandidate(character: "厝", nativeCodes: ["mta"]),
            ReadingCandidate(character: "錯", nativeCodes: [])
        ])
        #expect(small.candidates(for: reading, version: .v3).last?.nativeCodes == ["cta"])
        #expect(small.interpret("yk3", scheme: .dachen) == .unknown)
        #expect(small.interpret("hj", scheme: .dachen) == .partial)
    }
}

@Suite("單字讀音反查面板")
struct ReadingLookupTests {
    /// 以按鍵序列驅動引擎。`LOOKUP` 是 `Ctrl+Shift+;`，其餘沿用既有代號。
    private func engine(_ keys: String, configuration: EngineConfiguration = EngineConfiguration()) -> InputEngine {
        replay(keys.split(separator: " ").map(String.init), configuration: configuration)
    }

    @Test("查完按 Esc，原地還是 my，空白鍵照樣送出「下」")
    func escapeRestoresComposition() throws {
        var engine = self.engine("m y LOOKUP h j i 4")
        #expect(engine.buffer == "my")
        #expect(engine.state == .composingDual)
        // 查詢期間文件與待收合空格都沒有被碰過。
        #expect(engine.documentText.isEmpty)
        #expect(!engine.pendingAutoSpace)
        let panel = try #require(engine.currentReadingLookupPanel)
        #expect(panel.inputDisplay == "ㄘㄨㄛˋ")
        #expect(panel.rows.first?.character == "錯")

        engine.handle(.escape)
        #expect(engine.readingLookup == nil)
        #expect(engine.currentReadingLookupPanel == nil)
        #expect(engine.buffer == "my")
        #expect(engine.handle(.space).committedCore == "下")
        #expect(engine.documentText == "下")
    }

    @Test("已移動過焦點時，取消反查仍指向原本的候選")
    func escapeKeepsCandidateFocus() {
        var engine = self.engine("n o DOWN LOOKUP h j i")
        #expect(engine.state == .selectingCandidate)
        #expect(engine.selectedCandidateIndex == 1)

        engine.handle(.escape)
        #expect(engine.state == .selectingCandidate)
        #expect(engine.selectedCandidateIndex == 1)
        #expect(engine.handle(.space).committedCore == "欠")
    }

    @Test("換讀音方案不會毀掉被暫停的候選焦點")
    func switchingSchemeKeepsSuspendedFocus() {
        var engine = self.engine("n o DOWN LOOKUP TAB")
        #expect(engine.configuration.readingScheme == .pinyin)
        #expect(engine.state == .selectingCandidate)
        #expect(engine.selectedCandidateIndex == 1)

        engine.handle(.escape)
        #expect(engine.handle(.space).committedCore == "欠")
    }

    @Test("選「厝」只送出一次，下一個 my 回到雙軌")
    func pickingReplacesTheComposition() throws {
        var engine = self.engine("m y LOOKUP h j i 4 DOWN DOWN DOWN DOWN DOWN")
        let panel = try #require(engine.currentReadingLookupPanel)
        #expect(panel.isSelecting)
        #expect(panel.focusedRow == 4)
        #expect(panel.rows[4].character == "厝")
        #expect(panel.rows[4].code == "mta")
        #expect(panel.rows[4].radicals == "一廿日")

        let effect = engine.handle(.enter)
        #expect(effect.commitKind == .chinese)
        #expect(effect.committedCore == "厝")
        #expect(effect.committedText == "厝")
        #expect(engine.readingLookup == nil)
        #expect(engine.state == .idle)
        #expect(engine.buffer.isEmpty)
        #expect(engine.documentText == "厝")

        engine.handle(.character("m"))
        engine.handle(.character("y"))
        #expect(engine.handle(.space).committedCore == "下")
        #expect(engine.documentText == "厝下")
    }

    @Test("兩種方案查「厝」得到同一串候選與同樣的頁數")
    func bothSchemesAgree() throws {
        let dachen = try #require(engine("LOOKUP h j i 4").currentReadingLookupPanel)
        let pinyin = try #require(engine("LOOKUP TAB c u o 4").currentReadingLookupPanel)
        #expect(dachen.rows == pinyin.rows)
        #expect(dachen.pageCount == pinyin.pageCount)
        #expect(dachen.inputDisplay == "ㄘㄨㄛˋ")
        #expect(pinyin.inputDisplay == "cuo4")
    }

    @Test("Tab 把鍵序改寫成同一讀音，未成音時清空")
    func tabRewritesTheKeys() throws {
        var fourth = engine("LOOKUP h j i 4")
        fourth.handle(.tab)
        #expect(fourth.readingLookup?.scheme == .pinyin)
        #expect(fourth.readingLookup?.keys == "cuo4")
        fourth.handle(.tab)
        #expect(fourth.readingLookup?.keys == "hji4")

        // 一聲：大千是結尾空白，拼音是 1。
        var first = engine("LOOKUP h j i SPACE")
        #expect(first.readingLookup?.keys == "hji ")
        #expect(try #require(first.currentReadingLookupPanel).inputDisplay == "ㄘㄨㄛˉ")
        first.handle(.tab)
        #expect(first.readingLookup?.keys == "cuo1")
        first.handle(.tab)
        #expect(first.readingLookup?.keys == "hji ")

        // 不指定聲調：兩邊都不加聲調鍵。
        var noTone = engine("LOOKUP h j i")
        noTone.handle(.tab)
        #expect(noTone.readingLookup?.keys == "cuo")

        // 未成音：只清除面板查詢。
        var partial = engine("LOOKUP 1")
        #expect(try #require(partial.currentReadingLookupPanel).status == .partial)
        partial.handle(.tab)
        #expect(partial.readingLookup?.keys == "")
        #expect(try #require(partial.currentReadingLookupPanel).status == .empty)
    }

    @Test("方案偏好記在設定裡，下次開啟沿用")
    func schemePreferenceIsRemembered() {
        var engine = self.engine("LOOKUP TAB ESC")
        #expect(engine.configuration.readingScheme == .pinyin)
        engine.handle(.toggleReadingLookup)
        #expect(engine.readingLookup?.scheme == .pinyin)

        let started = self.engine("LOOKUP", configuration: EngineConfiguration(readingScheme: .pinyin))
        #expect(started.readingLookup?.scheme == .pinyin)
    }

    @Test("五種聲調各自成列，不指定聲調時候選最多")
    func tonesInThePanel() throws {
        var pageCounts: [Int] = []
        for (toneKey, mark) in [("SPACE", "ˉ"), ("6", "ˊ"), ("3", "ˇ"), ("4", "ˋ"), ("7", "˙")] {
            let panel = try #require(engine("LOOKUP a 8 \(toneKey)").currentReadingLookupPanel)
            #expect(panel.status == .results)
            #expect(panel.inputDisplay == "ㄇㄚ\(mark)")
            #expect(!panel.rows.isEmpty)
            pageCounts.append(panel.pageCount)
        }
        let anyTone = try #require(engine("LOOKUP a 8").currentReadingLookupPanel)
        #expect(anyTone.inputDisplay == "ㄇㄚ")
        #expect(anyTone.pageCount >= pageCounts.max() ?? 1)
    }

    @Test("末頁不足九項，翻頁在首末頁都不循環")
    func pagingStopsAtBothEnds() throws {
        var engine = self.engine("LOOKUP h j i 4")
        let firstPage = try #require(engine.currentReadingLookupPanel)
        #expect(firstPage.page == 1)
        #expect(firstPage.pageCount == 2)
        #expect(firstPage.rows.count == 9)

        engine.handle(.pageUp)
        #expect(try #require(engine.currentReadingLookupPanel).page == 1)

        engine.handle(.pageDown)
        let lastPage = try #require(engine.currentReadingLookupPanel)
        #expect(lastPage.page == 2)
        #expect(lastPage.rows.count < 9)
        #expect(!lastPage.rows.isEmpty)
        #expect(lastPage.focusedRow == 0)

        engine.handle(.pageDown)
        #expect(try #require(engine.currentReadingLookupPanel).page == 2)
    }

    @Test("查無此讀音時不送字，退格就回到有候選的狀態")
    func noResultsIsRecoverable() throws {
        var engine = self.engine("LOOKUP h j i 4 z")
        let panel = try #require(engine.currentReadingLookupPanel)
        #expect(panel.status == .noResults)
        #expect(panel.rows.isEmpty)
        #expect(panel.focusedRow == nil)
        #expect(panel.pageCount == 1)

        #expect(engine.handle(.enter).commitKind == .none)
        #expect(engine.handle(.space).commitKind == .none)
        #expect(engine.readingLookup != nil)

        engine.handle(.backspace)
        #expect(try #require(engine.currentReadingLookupPanel).status == .results)
    }

    @Test("數字在讀音輸入中是讀音鍵，按過 ↓ 之後才選字")
    func digitsAreReadingKeysUntilSelecting() throws {
        var engine = self.engine("LOOKUP a 8 3")
        #expect(engine.readingLookup?.keys == "a83")
        #expect(try #require(engine.currentReadingLookupPanel).inputDisplay == "ㄇㄚˇ")
        #expect(engine.readingLookup?.isSelecting == false)

        engine.handle(.arrowDown)
        #expect(engine.readingLookup?.isSelecting == true)
        let rows = try #require(engine.currentReadingLookupPanel).rows
        let effect = engine.handle(.character("2"))
        #expect(effect.committedCore == rows[1].character)
        #expect(engine.readingLookup == nil)
    }

    @Test("沒有對應列時不送字")
    func pickingAnEmptyRowDoesNothing() throws {
        var engine = self.engine("LOOKUP y k 3")
        #expect(try #require(engine.currentReadingLookupPanel).rows.count == 1)
        #expect(engine.handle(.panelPick(9)).commitKind == .none)
        #expect(engine.readingLookup != nil)
        #expect(engine.handle(.panelPick(1)).committedCore == "怎")
    }

    @Test("面板顯示目前代別的原生碼，缺碼的字仍選得到")
    func nativeCodesFollowTheVersion() throws {
        let v5Engine = engine("LOOKUP y k 3", configuration: EngineConfiguration(cangjieVersion: .v5))
        let v5 = try #require(v5Engine.currentReadingLookupPanel)
        #expect(v5.cangjieVersion == .v5)
        #expect(v5.rows.first?.character == "怎")
        #expect(v5.rows.first?.code == "osp")
        #expect(v5.rows.first?.radicals == "人尸心")

        let v3Engine = engine("LOOKUP y p 3", configuration: EngineConfiguration(cangjieVersion: .v3))
        let v3 = try #require(v3Engine.currentReadingLookupPanel)
        #expect(v3.cangjieVersion == .v3)
        #expect(v3.rows.contains { $0.character == "怎" && $0.code == "hsp" && $0.radicals == "竹尸心" })

        // 打包的讀音索引只收有倉頡碼的字，缺碼那條路徑改用小表驗：
        // 原生碼欄留空時，面板那一列沒有碼與字根，但照樣選得到。
        var engine = InputEngine(readings: ReadingIndex(
            readingsTSV: "ㄧ\tyi\t2\t夷彞",
            nativeCodesTSV: "夷\tkn\tkn"
        ))
        engine.handle(.toggleReadingLookup)
        engine.handle(.character("u"))
        engine.handle(.character("6"))
        let row = try #require(engine.currentReadingLookupPanel?.rows.first { $0.character == "彞" })
        #expect(row.code == nil)
        #expect(row.radicals == nil)
        #expect(engine.handle(.panelPick(row.number)).committedCore == "彞")
    }

    @Test("Caps Lock 亮燈與純英文時，反查快捷鍵交還宿主")
    func literalLayerKeepsTheShortcut() {
        var caps = engine("CAPS_ON")
        #expect(!caps.handle(.toggleReadingLookup).handled)
        #expect(caps.readingLookup == nil)

        var pure = engine("DBL_SHIFT")
        #expect(pure.state == .pureEnglish)
        #expect(!pure.handle(.toggleReadingLookup).handled)
        #expect(pure.readingLookup == nil)
    }

    @Test("反查開啟時 Caps Lock 亮燈會關閉反查，並原樣送出緩衝")
    func capsLockClosesTheLookup() {
        var engine = self.engine("m y LOOKUP h j i 4")
        let effect = engine.handle(.capsLock(true))
        #expect(engine.readingLookup == nil)
        #expect(engine.capsLockEnabled)
        #expect(effect.commitKind == .rawEnglish)
        #expect(effect.committedCore == "my")
        #expect(engine.documentText == "my")
    }

    @Test("選字依既有規則補空格，不補第二個")
    func autoSpaceAroundThePick() {
        // 英文原樣送出後沒有尾端空格：選字時補一格。
        var afterEnglish = engine("m y ENTER LOOKUP y k 3")
        #expect(afterEnglish.documentText == "my")
        #expect(afterEnglish.handle(.enter).committedText == " 怎")
        #expect(afterEnglish.documentText == "my 怎")

        // Tab 已經補過空格：不再補第二個。
        var afterTab = engine("i s TAB LOOKUP y k 3")
        #expect(afterTab.documentText == "is ")
        #expect(afterTab.handle(.enter).committedText == "怎")
        #expect(afterTab.documentText == "is 怎")
    }
}

@Suite("一鍵反悔")
struct RevertTests {
    private func engine(_ keys: String, configuration: EngineConfiguration = EngineConfiguration()) -> InputEngine {
        replay(keys.split(separator: " ").map(String.init), configuration: configuration)
    }

    private func document(_ keys: String) -> String {
        engine(keys).documentText
    }

    /// 反悔後的引擎必須與直接按另一個鍵的引擎一模一樣，只差反悔紀錄。
    private func expectSameOutcome(_ reverted: InputEngine, _ direct: InputEngine, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(reverted.state == direct.state, sourceLocation: sourceLocation)
        #expect(reverted.buffer == direct.buffer, sourceLocation: sourceLocation)
        #expect(reverted.documentText == direct.documentText, sourceLocation: sourceLocation)
        #expect(reverted.pendingAutoSpace == direct.pendingAutoSpace, sourceLocation: sourceLocation)
        #expect(reverted.selectedCandidateIndex == direct.selectedCandidateIndex, sourceLocation: sourceLocation)
        #expect(reverted.selectedEnglishIndex == direct.selectedEnglishIndex, sourceLocation: sourceLocation)
        #expect(reverted.usageHistory == direct.usageHistory, sourceLocation: sourceLocation)
    }

    @Test("空白送出中文後按 Shift+空白 換成英文，再按一次換回來；Tab 送出英文後換成中文")
    func swapsBetweenChineseAndEnglish() {
        #expect(document("m y SPACE") == "下")
        #expect(document("m y SPACE SHIFT_SPACE") == "my ")
        #expect(document("m y SPACE SHIFT_SPACE SHIFT_SPACE") == "下")
        #expect(document("m y TAB SHIFT_SPACE") == "下")
        #expect(document("m y TAB SHIFT_SPACE SHIFT_SPACE") == "my ")
    }

    @Test("外層拿到的是回刪上一次送出的完整文字，再接上對調後的完整文字")
    func effectReplacesTheWholeCommit() {
        var engine = self.engine("m y SPACE m y")
        let committed = engine.handle(.space)
        #expect(committed.committedText == "下")
        #expect(committed.revertible)
        #expect(committed.revertPreview == "my")
        #expect(committed.deletedBackwardCount == 0)

        let reverted = engine.handle(.shiftSpace)
        // 中文後面接英文要補一格，英文後面再留一格。
        #expect(reverted.committedText == " my ")
        #expect(reverted.committedCore == "my")
        #expect(reverted.commitKind == .english)
        #expect(reverted.deletedBackwardCount == 1)
        #expect(reverted.revertible)
        #expect(reverted.revertPreview == "下")
        #expect(reverted.documentText == "下 my ")

        let back = engine.handle(.shiftSpace)
        #expect(back.committedText == "下")
        #expect(back.deletedBackwardCount == 4)
        #expect(back.commitKind == .chinese)
        #expect(back.documentText == "下下")
    }

    @Test("中英交界的空格照對調後的文字重算")
    func spacingFollowsTheSwappedText() {
        #expect(document("m y SPACE m y SPACE SHIFT_SPACE") == "下 my ")
        #expect(document("h e l l o TAB m y SPACE SHIFT_SPACE") == "hello my ")
        #expect(document("h e l l o TAB m y TAB SHIFT_SPACE") == "hello 下")
        #expect(document("m y SPACE m y TAB SHIFT_SPACE") == "下下")
    }

    @Test("反悔成英文後接逗號，尾端空格照常收合")
    func trailingSpaceStillCollapses() {
        var engine = self.engine("m y SPACE SHIFT_SPACE")
        #expect(engine.pendingAutoSpace)
        let comma = engine.handle(.character(","))
        #expect(comma.deletedBackwardCount == 1)
        #expect(engine.documentText == "my,")
        // 反悔成中文後接逗號出全形，與直接按空白鍵相同。
        #expect(document("m y TAB SHIFT_SPACE COMMA") == document("m y SPACE COMMA"))
    }

    @Test("高頻撞碼詞一鍵換回英文")
    func commonCollidingWords() {
        for word in ["of", "and", "a", "i", "id", "he", "an", "ok"] {
            let keys = word.map(String.init).joined(separator: " ")
            let chinese = document("\(keys) SPACE")
            #expect(chinese != "\(word) ", "\(word) 應該先送出中文字")
            #expect(document("\(keys) SPACE SHIFT_SPACE") == "\(word) ")
            #expect(document("\(keys) TAB SHIFT_SPACE") == chinese)
        }
    }

    @Test("候選聚焦在第二個字時送出、反悔、再反悔，回到第二個字")
    func focusedCandidateSurvivesTheRoundTrip() {
        #expect(document("o j DOWN SPACE") == "什")
        #expect(document("o j DOWN SPACE SHIFT_SPACE") == "oj ")
        #expect(document("o j DOWN SPACE SHIFT_SPACE SHIFT_SPACE") == "什")
        // 選字中的 Tab 與空白鍵一樣送出聚焦的字，也一樣能反悔。
        #expect(document("o j DOWN TAB SHIFT_SPACE") == "oj ")
        #expect(document("o j DOWN TAB SHIFT_SPACE SHIFT_SPACE") == "什")
    }

    @Test("送出後按了別的鍵，Shift+空白 就只是空白")
    func recordLivesForOneKey() {
        // 句點自己留下的是標點寬度的紀錄，所以用不會留紀錄的按鍵才看得出中英紀錄已經失效。
        #expect(document("m y SPACE a BKSP SHIFT_SPACE") == "下 ")
        #expect(document("m y TAB a BKSP SHIFT_SPACE") == "my  ")
        #expect(document("m y SPACE SPACE SHIFT_SPACE") == "下  ")
        #expect(engine("m y SPACE ESC").revertRecord == nil)
        #expect(engine("m y SPACE CAPS_ON CAPS_OFF").revertRecord == nil)
        #expect(engine("m y SPACE DBL_SHIFT DBL_SHIFT").revertRecord == nil)
        #expect(engine("m y SPACE LOOKUP ESC").revertRecord == nil)
    }

    @Test("Enter、數字選字、Option 半形與 Shift+數字選詞都不可對調中英")
    func otherCommitsAreNotRevertible() {
        // 標點連帶送出的前綴同樣換不回來（`m y COMMA` 之後的 Shift+空白 只換標點的寬度，
        // 「下」不會變回 `my`），那條路由標點寬度對調的測試涵蓋。
        for keys in ["m y ENTER", "o j 2", "m y OPT_.", "m y SHIFT_2", "o j DOWN ENTER", "o j DOWN m"] {
            var engine = self.engine(keys)
            #expect(engine.revertRecord == nil, "\(keys) 不該留下反悔紀錄")
            let before = engine.documentText
            let effect = engine.handle(.shiftSpace)
            #expect(!effect.revertible)
            #expect(effect.deletedBackwardCount == 0)
            #expect(engine.documentText.hasPrefix(before), "\(keys) 之後的 Shift+空白 不得回刪")
        }
    }

    @Test("只有英文軌的詞、只有倉頡前綴的字母不產生紀錄")
    func needsBothSides() {
        #expect(engine("t h e SPACE").revertRecord == nil)
        #expect(engine("t h e TAB").revertRecord == nil)
        #expect(document("t h e SPACE SHIFT_SPACE") == "the  ")
        #expect(engine("f u n c TAB").revertRecord == nil)
        // `mym` 只是前綴，空白鍵送出原字母，兩邊沒有不同的東西可換。
        var prefixOnly = engine("y m y")
        if prefixOnly.currentOverlay?.cangjieTrack?.candidates.isEmpty == true {
            prefixOnly.handle(.space)
            #expect(prefixOnly.revertRecord == nil)
        }
    }

    @Test("反悔後的學習紀錄等同直接按另一個鍵")
    func learningMatchesTheOtherKey() {
        // 倉頡重碼：先記了一次「什」，反悔成英文後那一次不留紀錄，改記英文。
        let pickedSecond = engine("o j DOWN SPACE")
        #expect(pickedSecond.usageHistory.cangjie.first?.code == "oj")
        let revertedToEnglish = engine("o j DOWN SPACE SHIFT_SPACE")
        #expect(revertedToEnglish.usageHistory.cangjie.isEmpty)
        expectSameOutcome(revertedToEnglish, engine("o j TAB"))
        expectSameOutcome(engine("o j DOWN SPACE SHIFT_SPACE SHIFT_SPACE"), pickedSecond)

        // 英文學習：Tab 記了一次 my，反悔成中文後英文紀錄消失。
        #expect(engine("m y TAB").usageHistory.english.first?.word == "my")
        let revertedToChinese = engine("m y TAB SHIFT_SPACE")
        #expect(revertedToChinese.usageHistory.english.isEmpty)
        expectSameOutcome(revertedToChinese, engine("m y SPACE"))
        expectSameOutcome(engine("m y SPACE SHIFT_SPACE"), engine("m y TAB"))

        // 反悔兩次不會把次數記成兩次：仍然要第二次真的送出才越過碼表順序。
        var twice = engine("o j DOWN SPACE SHIFT_SPACE SHIFT_SPACE o j")
        #expect(twice.currentOverlay?.cangjieTrack?.candidates == ["午", "什"])
        twice.handle(.escape)
    }

    @Test("關閉設定後 Shift+空白 是原本的行為")
    func disabledSettingKeepsOldBehaviour() {
        let off = EngineConfiguration(revertEnabled: false)
        var engine = self.engine("m y", configuration: off)
        let effect = engine.handle(.space)
        #expect(!effect.revertible)
        #expect(effect.revertPreview == nil)
        #expect(engine.revertRecord == nil)
        let shiftSpace = engine.handle(.shiftSpace)
        #expect(shiftSpace.committedText == " ")
        #expect(shiftSpace.deletedBackwardCount == 0)
        #expect(engine.documentText == "下 ")
        #expect(self.engine("m y TAB SHIFT_SPACE", configuration: off).documentText == "my  ")
        // 組字中的 Shift+空白 不論設定都是聚焦候選。
        #expect(self.engine("m y SHIFT_SPACE", configuration: off).state == .selectingCandidate)
        #expect(self.engine("m y SHIFT_SPACE").state == .selectingCandidate)
    }

    @Test("Caps Lock、純英文與純中文模式不產生紀錄")
    func literalLayersNeverRecord() {
        #expect(engine("CAPS_ON m y SPACE").revertRecord == nil)
        #expect(document("CAPS_ON m y SPACE SHIFT_SPACE") == "my  ")
        #expect(engine("DBL_SHIFT m y SPACE").revertRecord == nil)
        #expect(document("DBL_SHIFT m y SPACE SHIFT_SPACE") == "my  ")
        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)
        #expect(engine("m y SPACE", configuration: chineseOnly).revertRecord == nil)
        #expect(engine("m y SPACE SHIFT_SPACE", configuration: chineseOnly).documentText == "下 ")
    }

    @Test("讀音反查選字後不可反悔，反查開著時 Shift+空白 不動任何東西")
    func readingLookupPickIsNotRevertible() {
        var picked = engine("m y LOOKUP h j i 4 ENTER")
        #expect(picked.documentText == "錯")
        #expect(picked.revertRecord == nil)
        picked.handle(.shiftSpace)
        #expect(picked.documentText == "錯 ")

        var open = engine("m y LOOKUP h j i 4")
        let effect = open.handle(.shiftSpace)
        #expect(effect.handled)
        #expect(effect.committedText == nil)
        #expect(open.buffer == "my")
    }

    @Test("游標移動、失焦、前文不符、改設定、換學習紀錄都讓紀錄消失")
    func externalChangesDropTheRecord() {
        let committed = engine("m y SPACE")
        #expect(committed.revertRecord != nil)

        var moved = committed
        moved.noteExternalCursorMovement()
        #expect(moved.revertRecord == nil)

        var blurred = committed
        blurred.resetContext()
        #expect(blurred.revertRecord == nil)

        var sameContext = committed
        sameContext.syncExternalContext("下")
        #expect(sameContext.revertRecord != nil)
        sameContext.syncExternalContext(nil)
        #expect(sameContext.revertRecord != nil)

        var edited = committed
        edited.syncExternalContext("上")
        #expect(edited.revertRecord == nil)
        edited.handle(.shiftSpace)
        #expect(edited.documentText == "上 ")

        var reconfigured = committed
        reconfigured.configuration.autoSpaceEnabled = false
        #expect(reconfigured.revertRecord == nil)

        var switchedOff = committed
        switchedOff.configuration.revertEnabled = false
        #expect(switchedOff.revertRecord == nil)

        var sameHistory = committed
        sameHistory.usageHistory = committed.usageHistory
        #expect(sameHistory.revertRecord != nil)

        var clearedHistory = engine("m y TAB")
        #expect(clearedHistory.revertRecord != nil)
        clearedHistory.usageHistory = UsageHistory()
        #expect(clearedHistory.revertRecord == nil)
        clearedHistory.handle(.shiftSpace)
        #expect(clearedHistory.usageHistory.isEmpty)

        var discarded = committed
        discarded.discardRevertRecord()
        discarded.handle(.shiftSpace)
        #expect(discarded.documentText == "下 ")
    }
}

/// 標點寬度對調。斷言都看使用者看得到的結果：文件、送出的文字與回刪數。
@Suite("標點寬度對調")
struct PunctuationWidthRevertTests {
    private func engine(_ keys: String, configuration: EngineConfiguration = EngineConfiguration()) -> InputEngine {
        replay(keys.split(separator: " ").map(String.init), configuration: configuration)
    }

    private func document(_ keys: String, configuration: EngineConfiguration = EngineConfiguration()) -> String {
        engine(keys, configuration: configuration).documentText
    }

    /// 對調後的引擎必須與直接打出那個寬度的引擎一模一樣，只差反悔紀錄。
    private func expectSameOutcome(
        _ swapped: InputEngine,
        _ direct: InputEngine,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(swapped.documentText == direct.documentText, sourceLocation: sourceLocation)
        #expect(swapped.state == direct.state, sourceLocation: sourceLocation)
        #expect(swapped.buffer == direct.buffer, sourceLocation: sourceLocation)
        #expect(swapped.pendingAutoSpace == direct.pendingAutoSpace, sourceLocation: sourceLocation)
        #expect(swapped.usageHistory == direct.usageHistory, sourceLocation: sourceLocation)
        #expect(swapped.snippet == direct.snippet, sourceLocation: sourceLocation)
    }

    @Test("英數後面的半形標點換成全形，再按一次換回來")
    func swapsHalfwidthToFullwidth() {
        #expect(document("i d TAB COMMA") == "id,")
        #expect(document("i d TAB COMMA SHIFT_SPACE") == "id，")
        #expect(document("i d TAB COMMA SHIFT_SPACE SHIFT_SPACE") == "id,")
        #expect(document("i d TAB COMMA SHIFT_SPACE SHIFT_SPACE SHIFT_SPACE") == "id，")
    }

    @Test("中文後面的全形標點換成半形")
    func swapsFullwidthToHalfwidth() {
        #expect(document("m y SPACE COMMA") == "下，")
        #expect(document("m y SPACE COMMA SHIFT_SPACE") == "下,")
        #expect(document("m y SPACE COMMA SHIFT_SPACE SHIFT_SPACE") == "下，")
        #expect(document("m y SPACE . SHIFT_SPACE") == "下.")
    }

    @Test("對調等同在同一個位置直接打出那個寬度")
    func swapEqualsTypingThatWidthDirectly() {
        // 全形那一邊：等同按 Ctrl 加同一個鍵，連英文後面待收合的那一格空格都一樣收掉。
        expectSameOutcome(engine("i d TAB COMMA SHIFT_SPACE"), engine("i d TAB CTRL_COMMA"))
        expectSameOutcome(engine("i d TAB . SHIFT_SPACE"), engine("i d TAB CTRL_PERIOD"))
        expectSameOutcome(engine("o n f SPACE i d TAB COMMA SHIFT_SPACE"), engine("o n f SPACE i d TAB CTRL_COMMA"))
        // 半形那一邊：等同按 Option 加同一個鍵。
        expectSameOutcome(engine("m y SPACE COMMA SHIFT_SPACE"), engine("m y SPACE OPT_,"))
        expectSameOutcome(engine("m y SPACE . SHIFT_SPACE"), engine("m y SPACE OPT_."))
    }

    @Test("只換標點本身，連帶送出的前綴不動")
    func keepsTheCommittedPrefix() {
        // 句點連同原字母一次送出，對調只換句點。
        var dotted = engine("m y PERIOD")
        #expect(dotted.documentText == "my.")
        let swapped = dotted.handle(.shiftSpace)
        #expect(swapped.committedText == "my。")
        #expect(swapped.deletedBackwardCount == 3)
        #expect(dotted.documentText == "my。")
        // 逗號先送出倉頡首選字，對調只換逗號。
        #expect(document("m y COMMA") == "下，")
        #expect(document("m y COMMA SHIFT_SPACE") == "下,")
        #expect(document("m y COMMA SHIFT_SPACE SHIFT_SPACE") == "下，")
    }

    @Test("外層拿到的是回刪上一次送出的文字再接上新寬度，而且不顯示提示")
    func effectReplacesTheWholeCommit() {
        var engine = self.engine("i d TAB")
        let comma = engine.handle(.character(","))
        #expect(comma.committedText == ",")
        #expect(comma.deletedBackwardCount == 1)
        #expect(comma.revertible)
        #expect(comma.revertPreview == nil)

        let swapped = engine.handle(.shiftSpace)
        #expect(swapped.committedText == "，")
        #expect(swapped.committedCore == "，")
        #expect(swapped.commitKind == .punctuation)
        #expect(swapped.deletedBackwardCount == 1)
        #expect(swapped.revertible)
        #expect(swapped.revertPreview == nil)
        #expect(swapped.documentText == "id，")
    }

    @Test("直引號、反引號與只有半形的符號不適用")
    func onlyKeysWithTwoWidthsSwap() {
        #expect(document("i d TAB DQUOTE SHIFT_SPACE") == "id \" ")
        #expect(document("m y SPACE DQUOTE SHIFT_SPACE") == "下\" ")
        #expect(document("i d TAB BACKTICK SHIFT_SPACE") == "id ` ")
        #expect(document("m y SPACE GT SHIFT_SPACE") == "下> ")
        #expect(engine("m y SPACE DQUOTE").revertRecord == nil)
        #expect(engine("m y SPACE BACKTICK").revertRecord == nil)
    }

    @Test("Ctrl 與 Option 已經指定寬度，不留紀錄")
    func explicitWidthKeysNeverRecord() {
        #expect(engine("i d TAB CTRL_COMMA").revertRecord == nil)
        #expect(engine("m y SPACE OPT_,").revertRecord == nil)
        #expect(document("i d TAB CTRL_COMMA SHIFT_SPACE") == "id， ")
        #expect(document("m y SPACE OPT_, SHIFT_SPACE") == "下, ")
    }

    @Test("Caps Lock、純英文層不產生紀錄，純中文模式照樣可以對調")
    func layersAndChineseOnlyMode() {
        #expect(engine("CAPS_ON COMMA").revertRecord == nil)
        #expect(document("CAPS_ON COMMA SHIFT_SPACE") == ", ")
        #expect(engine("DBL_SHIFT COMMA").revertRecord == nil)
        #expect(document("DBL_SHIFT COMMA SHIFT_SPACE") == ", ")

        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)
        #expect(document("m y SPACE COMMA", configuration: chineseOnly) == "下，")
        #expect(document("m y SPACE COMMA SHIFT_SPACE", configuration: chineseOnly) == "下,")
        #expect(document("m y SPACE COMMA SHIFT_SPACE SHIFT_SPACE", configuration: chineseOnly) == "下，")
    }

    @Test("半形標點設定開著也能對調")
    func worksWithHalfwidthPunctuationSetting() {
        let halfwidth = EngineConfiguration(autoPunctuationEnabled: false)
        #expect(document("m y SPACE COMMA", configuration: halfwidth) == "下,")
        #expect(document("m y SPACE COMMA SHIFT_SPACE", configuration: halfwidth) == "下，")
        #expect(document("m y SPACE COMMA SHIFT_SPACE SHIFT_SPACE", configuration: halfwidth) == "下,")
    }

    @Test("關閉一鍵反悔後 Shift+空白 是原本的行為")
    func disabledSettingKeepsOldBehaviour() {
        let off = EngineConfiguration(revertEnabled: false)
        var engine = self.engine("i d TAB", configuration: off)
        let comma = engine.handle(.character(","))
        #expect(!comma.revertible)
        #expect(engine.revertRecord == nil)
        #expect(document("i d TAB COMMA SHIFT_SPACE", configuration: off) == "id, ")
    }

    @Test("片段裡的半形標點可以換成全形，片段語境不受影響")
    func worksInsideCodeSnippet() {
        #expect(document("BACKTICK i d SPACE COMMA") == "`id ,")
        #expect(document("BACKTICK i d SPACE COMMA SHIFT_SPACE") == "`id ，")
        expectSameOutcome(
            engine("BACKTICK i d SPACE COMMA SHIFT_SPACE"),
            engine("BACKTICK i d SPACE CTRL_COMMA")
        )
        #expect(engine("BACKTICK i d SPACE COMMA SHIFT_SPACE").snippet.isInside)
        // 片段剛關上時由透明規則決定的寬度同樣可以對調。
        #expect(document("m y SPACE BACKTICK i d SPACE BACKTICK PERIOD") == "下`id `。")
        #expect(document("m y SPACE BACKTICK i d SPACE BACKTICK PERIOD SHIFT_SPACE") == "下`id `.")
    }

    @Test("對調左括號後，之後的右括號沿用新寬度")
    func pairedBracketsFollowTheSwappedOpener() {
        #expect(document("m y SPACE LPAREN") == "下（")
        #expect(document("m y SPACE LPAREN o n f SPACE RPAREN") == "下（你）")
        #expect(document("m y SPACE LPAREN SHIFT_SPACE") == "下(")
        #expect(document("m y SPACE LPAREN SHIFT_SPACE o n f SPACE RPAREN") == "下(你)")
    }

    @Test("收尾標點不論寬度都只收合輸入法補的那一格，手動空白不動")
    func collapsesOnlyTheAutoSpace() {
        var engine = self.engine("i d TAB")
        #expect(engine.pendingAutoSpace)
        #expect(engine.handle(.ctrlFullwidth(",")).deletedBackwardCount == 1)
        #expect(engine.documentText == "id，")
        // 手動打出來的空格不是待收合的那一格。
        #expect(document("i d ENTER SPACE CTRL_COMMA") == "id ，")
        #expect(document("i d ENTER SPACE COMMA SHIFT_SPACE") == "id ，")
        // 開啟的括號與引號不收合，英文與中文引言之間要留那一格。
        #expect(document("i d TAB LPAREN SHIFT_SPACE") == "id （")
    }
}

/// 行內程式片段語境的案例。斷言都看使用者看得到的結果：送出的文字、文件與回刪數。
@Suite("行內程式片段語境")
struct CodeSnippetContextTests {
    private func engine(_ keys: String, configuration: EngineConfiguration = EngineConfiguration()) -> InputEngine {
        replay(keys.split(separator: " ").map(String.init), configuration: configuration)
    }

    private func document(_ keys: String) -> String {
        engine(keys).documentText
    }

    @Test("一個反引號進入片段，再一個離開；連按兩個等於開了又關")
    func backtickTogglesTheContext() {
        // 片段外 `id` 加空白是倉頡字，片段裡是英文。
        #expect(document("i d SPACE") == "床")
        #expect(document("BACKTICK i d SPACE") == "`id ")
        #expect(document("BACKTICK i d SPACE BACKTICK") == "`id `")
        // 開了又關，之後回到中文優先。
        #expect(document("BACKTICK BACKTICK i d SPACE") == "``床")
        // 三個反引號等於開、關、開。
        #expect(document("BACKTICK BACKTICK BACKTICK i d SPACE") == "```id ")
        // 片段外緩衝有候選字時，反引號仍先送首選字；片段裡先送原字母。
        #expect(document("m y BACKTICK") == "下`")
        #expect(document("BACKTICK m y BACKTICK") == "`my`")
        // 關上之後下一個字詞回到中文優先。
        #expect(document("BACKTICK i d SPACE BACKTICK m y SPACE") == "`id `下")
    }

    @Test("片段裡的空白、Tab、Enter、數字、符號與 Shift+空白")
    func keysInsideTheSnippet() {
        // 空白鍵：有候選字送原字母加空格，沒有候選字與片段外相同。
        #expect(document("BACKTICK m y SPACE") == "`my ")
        #expect(document("BACKTICK t h e SPACE") == "`the ")
        // Tab 與 Shift+數字 送英文預測，不附尾端空格。
        #expect(document("BACKTICK i d TAB") == "`id")
        #expect(document("BACKTICK m y SHIFT_2") == "`myself")
        // Enter 送原字母，而且不離開片段。
        #expect(document("BACKTICK m y ENTER i d SPACE") == "`myid ")
        // 數字不選字：片段外 `oj` 按 2 得「什」。
        #expect(document("o j DIGIT2") == "什")
        #expect(document("BACKTICK o j DIGIT2") == "`oj2")
        // 符號鍵先送原字母，再送鍵面的半形字元。
        #expect(document("m y COMMA") == "下，")
        #expect(document("BACKTICK m y COMMA") == "`my,")
        #expect(document("BACKTICK m y PERIOD") == "`my.")
        // Ctrl 加標點照常送出全形標點，緩衝以原字母送出。
        #expect(document("BACKTICK m y CTRL_PERIOD") == "`my。")
        // Shift+空白 聚焦候選，之後空白鍵送中文字。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE") == "`下")
        #expect(document("BACKTICK m y SHIFT_SPACE ENTER") == "`下")
        #expect(document("BACKTICK o j SHIFT_SPACE DIGIT2") == "`什")
    }

    @Test("片段裡的空格是內容：不收合，也不補中英與中數之間的空格")
    func noAutoSpacingInsideTheSnippet() {
        // 片段外英文後的尾端空格遇到收尾標點會收合，片段裡不會。
        var outside = engine("i d TAB")
        #expect(outside.handle(.character(",")).deletedBackwardCount == 1)
        #expect(outside.documentText == "id,")
        var inside = engine("BACKTICK i d SPACE")
        #expect(inside.handle(.character(",")).deletedBackwardCount == 0)
        #expect(inside.documentText == "`id ,")
        // 中英、中數交界不補空格。
        #expect(document("m y SPACE h e l l o TAB") == "下 hello ")
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE h e l l o TAB") == "`下hello")
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE DIGIT1") == "`下1")
    }

    @Test("黏中：片段裡送出中文字之後空白鍵回到中文優先，送出原字母就解除")
    func stickyChineseInsideTheSnippet() {
        // 聚焦候選選字進入黏中，之後照平常的打法。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE i d SPACE") == "`下床")
        // 送出原字母解除黏中。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE t h e SPACE i d SPACE") == "`下the id ")
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE i d TAB m y SPACE") == "`下idmy ")
        // 聚焦候選後用 Enter 送出的中文字同樣進入黏中，Enter 本身不離開片段。
        #expect(document("BACKTICK m y SHIFT_SPACE ENTER i d SPACE") == "`下床")
        // Tab 與 Shift+數字 送出的英文詞也是從緩衝來的，同樣解除。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE i d TAB i d SPACE") == "`下idid ")
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE m y SHIFT_2 i d SPACE") == "`下myselfid ")
        // 閒置時單獨送出的數字不是從緩衝送出原字母，黏中留著：`答案是：12個` 這種片段才打得完。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE DIGIT1 DIGIT2 l v o k SPACE") == "`下12數")
        // 數字連同原字母送出就解除。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE o j DIGIT2 i d SPACE") == "`下oj2id ")
        // 符號也解除。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE COMMA i d SPACE") == "`下,id ")
        // 離開片段後回到原本的中文優先，不受黏中影響。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE BACKTICK i d SPACE") == "`下`床")
    }

    @Test("透明：片段後第一個標點看開啟片段時前面那個字元")
    func punctuationSeesThroughTheSnippet() {
        // 漢字後：句點出全形。
        #expect(document("m y SPACE BACKTICK i d SPACE BACKTICK PERIOD") == "下`id `。")
        #expect(document("m y SPACE BACKTICK i d SPACE BACKTICK COMMA") == "下`id `，")
        // 英數後：出半形。
        #expect(document("i d TAB BACKTICK m y BACKTICK PERIOD") == "id `my`.")
        // 行首（前面沒有字）：出全形。
        #expect(document("BACKTICK m y BACKTICK PERIOD") == "`my`。")
        #expect(document("BACKTICK m y BACKTICK COMMA") == "`my`，")
        // 有緩衝、或中間按過別的鍵就不適用。
        #expect(document("BACKTICK m y BACKTICK i d PERIOD") == "`my`id.")
        #expect(document("BACKTICK m y BACKTICK SPACE PERIOD") == "`my` .")
        // 片段裡的標點一律半形，不看語境。
        #expect(document("m y SPACE BACKTICK i d PERIOD") == "下`id.")
    }

    @Test("換行與前文鏡像失效都讓片段語境結束")
    func contextEndsWithTheMirror() {
        // 閒置時交給宿主的 Enter 換行：片段語境與文件鏡像一起重置。
        #expect(document("BACKTICK i d SPACE ENTER i d SPACE") == "床")
        // 放行的 Tab 與方向鍵同理。
        #expect(document("BACKTICK TAB i d SPACE") == "床")
        #expect(document("BACKTICK DOWN i d SPACE") == "床")

        var moved = engine("BACKTICK")
        moved.noteExternalCursorMovement()
        moved.handle(.character("i"))
        moved.handle(.character("d"))
        moved.handle(.space)
        #expect(moved.documentText == "床")

        var blurred = engine("BACKTICK")
        blurred.resetContext()
        blurred.handle(.character("i"))
        blurred.handle(.character("d"))
        blurred.handle(.space)
        #expect(blurred.documentText == "床")

        // 宿主回報的前文與鏡像不符：片段結束。相符時語境留著。
        var edited = engine("BACKTICK")
        edited.syncExternalContext("x")
        edited.handle(.character("i"))
        edited.handle(.character("d"))
        edited.handle(.space)
        // 回到一般語境，中英交界照常補空格。
        #expect(edited.documentText == "x 床")

        var agrees = engine("BACKTICK")
        agrees.syncExternalContext("`")
        agrees.handle(.character("i"))
        agrees.handle(.character("d"))
        agrees.handle(.space)
        #expect(agrees.documentText == "`id ")
    }

    @Test("退格刪掉反引號本身就把語境倒回去一步")
    func backspaceOverABacktickUndoesTheContext() {
        // 刪掉開啟片段的反引號：回到片段外，之後的字詞中文優先。
        #expect(document("BACKTICK BACKSPACE m y SPACE") == "下")
        // 刪掉結尾的反引號：回到片段裡，之後的字詞英文優先。
        #expect(document("BACKTICK i d SPACE BACKTICK BACKSPACE m y SPACE") == "`id my ")
        // 回到片段裡不延續黏中。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE BACKTICK BACKSPACE m y SPACE") == "`下my ")
        // 連按兩個反引號之後退格，剩下的那個仍是開啟片段的反引號。
        #expect(document("BACKTICK BACKTICK BACKSPACE i d SPACE") == "`id ")
        // 刪掉的不是反引號：語境不變。
        #expect(document("BACKTICK i d SPACE BACKSPACE m y SPACE") == "`idmy ")
        // 倒回去的語境字元仍是第一個反引號前面那個，所以之後的標點照它的寬度。
        #expect(document("BACKTICK a BACKTICK BACKSPACE BACKTICK PERIOD") == "`a`。")
        #expect(document("i d TAB BACKTICK a BACKTICK BACKSPACE BACKTICK PERIOD") == "id `a`.")
    }

    @Test("純中文模式與 Caps Lock 半形層的按鍵結果不變，送出的反引號照樣切換語境")
    func otherLayersKeepTheirResults() {
        let chineseOnly = EngineConfiguration(mixedModeEnabled: false)
        #expect(document("BACKTICK i d SPACE") == "`id ")
        #expect(engine("BACKTICK i d SPACE", configuration: chineseOnly).documentText == "`床")

        // Caps Lock 亮燈期間每個鍵都直出鍵面字元，熄燈後片段仍是開著的。
        #expect(document("CAPS_ON BACKTICK i d SPACE CAPS_OFF i d SPACE") == "`id id ")
        #expect(document("CAPS_ON i d SPACE CAPS_OFF i d SPACE") == "id 床")
        // 純英文層送出的反引號也算數。
        #expect(document("DBL_SHIFT BACKTICK DBL_SHIFT i d SPACE") == "`id ")
    }

    @Test("片段裡的一鍵反悔：來回對調，結果等同直接得到那一邊")
    func revertInsideTheSnippet() {
        // 空白送出英文後對調成中文，再按一次換回來。
        var engine = self.engine("BACKTICK m y")
        let committed = engine.handle(.space)
        #expect(committed.committedText == "my ")
        #expect(committed.revertible)
        #expect(committed.revertPreview == "下")
        let reverted = engine.handle(.shiftSpace)
        #expect(reverted.committedText == "下")
        #expect(reverted.deletedBackwardCount == 3)
        #expect(engine.documentText == "`下")
        let back = engine.handle(.shiftSpace)
        #expect(back.committedText == "my ")
        #expect(back.deletedBackwardCount == 1)
        #expect(engine.documentText == "`my ")

        // Tab 送出的英文沒有尾端空格，對調成中文只回刪那兩個字母。
        var tabbed = self.engine("BACKTICK m y TAB")
        let tabReverted = tabbed.handle(.shiftSpace)
        #expect(tabReverted.deletedBackwardCount == 2)
        #expect(tabbed.documentText == "`下")

        // 換到中文那一邊之後黏中生效，接下來的字詞照平常的打法。
        #expect(document("BACKTICK m y SPACE SHIFT_SPACE i d SPACE") == "`下床")
        // 換回英文那一邊黏中解除。
        #expect(document("BACKTICK m y SPACE SHIFT_SPACE SHIFT_SPACE i d SPACE") == "`my id ")

        // 黏中時空白鍵送的是中文，對調成英文是原字母加空格，之後黏中解除。
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE m y SPACE") == "`下下")
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE m y SPACE SHIFT_SPACE") == "`下my ")
        #expect(document("BACKTICK m y SHIFT_SPACE SPACE m y SPACE SHIFT_SPACE i d SPACE") == "`下my id ")

        // 反悔後的文件、黏中與學習紀錄都與直接得到那一邊相同。
        let direct = self.engine("BACKTICK o j SHIFT_SPACE SPACE")
        let viaRevert = self.engine("BACKTICK o j SPACE SHIFT_SPACE")
        #expect(viaRevert.documentText == direct.documentText)
        #expect(viaRevert.usageHistory == direct.usageHistory)
        #expect(viaRevert.state == direct.state)
        // 被反悔掉的英文詞不留學習紀錄。
        #expect(self.engine("BACKTICK i d TAB SHIFT_SPACE").usageHistory == self.engine("BACKTICK i d SHIFT_SPACE SPACE").usageHistory)
    }

    @Test("浮窗帶出片段標記與空白鍵會送出的那一軌")
    func overlayReportsTheSnippet() {
        let outside = engine("m y")
        #expect(outside.currentOverlay?.inCodeSnippet == false)
        #expect(outside.currentOverlay?.spaceCommits == .chinese)

        let inside = engine("BACKTICK m y")
        #expect(inside.currentOverlay?.inCodeSnippet == true)
        #expect(inside.currentOverlay?.spaceCommits == .english)
        // 片段裡數字不選字，浮窗就不顯示編號。
        #expect(inside.currentOverlay?.cangjieTrack?.digitsSelect == false)

        let focused = engine("BACKTICK m y SHIFT_SPACE")
        #expect(focused.currentOverlay?.spaceCommits == .chinese)

        let sticky = engine("BACKTICK m y SHIFT_SPACE SPACE m y")
        #expect(sticky.currentOverlay?.inCodeSnippet == true)
        #expect(sticky.currentOverlay?.spaceCommits == .chinese)

        // 只有英文軌時空白鍵送的是原字母。
        let englishOnly = engine("t h e")
        #expect(englishOnly.currentOverlay?.spaceCommits == .english)
    }
}
