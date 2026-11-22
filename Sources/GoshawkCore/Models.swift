import Foundation

public enum EngineStateKind: String, Sendable, Hashable, Codable {
    case idle
    case composingDual
    case composingEnglishOnly
    case selectingCandidate
    case pureEnglish
}

public enum CangjieVersion: String, Sendable, Hashable, Codable {
    case v5
    case v3
}

public enum KeyInput: Sendable, Hashable {
    case character(Character)
    case space
    case shiftSpace
    case acceptChineseContinuation
    /// Caps Lock 燈號的新狀態。亮燈期間引擎直接輸出鍵面半形字元。
    case capsLock(Bool)
    case tab
    case enter
    case backspace
    case escape
    case arrowDown
    case arrowUp
    /// `Ctrl` 加一個鍵面標點，強制送出對應的全形標點。帶的是鍵面字元（`Ctrl+Shift+1` 是 `!`）。
    case ctrlFullwidth(Character)
    case ctrlLeftBracket
    case ctrlRightBracket
    case ctrlShiftLeftBracket
    case ctrlShiftRightBracket
    case optionLiteral(Character)
    case selectEnglishPrediction(Int)
    case doubleShift
    /// `Ctrl+Shift+;` 或選單的「單字讀音反查」。開著反查時再按一次就關閉。
    case toggleReadingLookup
    case pageUp
    case pageDown
    /// 點選面板本頁的第 n 列，1 起算。讀音反查與符號面板共用，反查不論是否已進入候選選取都直接選字。
    case panelPick(Int)
    /// `Option+Shift+B` 或選單的「符號面板」。開著面板時再按一次就關閉。
    case toggleSymbolPanel

    public var tokenName: String {
        switch self {
        case .character(let ch):
            return String(ch)
        case .space:
            return "SPACE"
        case .shiftSpace:
            return "SHIFT_SPACE"
        case .acceptChineseContinuation:
            return "ACCEPT_CONTINUATION"
        case .capsLock(let isOn):
            return isOn ? "CAPS_ON" : "CAPS_OFF"
        case .tab:
            return "TAB"
        case .enter:
            return "ENTER"
        case .backspace:
            return "BKSP"
        case .escape:
            return "ESC"
        case .arrowDown:
            return "DOWN"
        case .arrowUp:
            return "UP"
        case .ctrlFullwidth(let ch):
            return Self.ctrlFullwidthTokens.first { $0.value == ch }?.key ?? "CTRL_\(ch)"
        case .ctrlLeftBracket:
            return "CTRL_LBRACKET"
        case .ctrlRightBracket:
            return "CTRL_RBRACKET"
        case .ctrlShiftLeftBracket:
            return "CTRL_SHIFT_LBRACKET"
        case .ctrlShiftRightBracket:
            return "CTRL_SHIFT_RBRACKET"
        case .optionLiteral(let ch):
            return "OPT_\(ch)"
        case .selectEnglishPrediction(let rank):
            return "SHIFT_\(rank)"
        case .doubleShift:
            return "DBL_SHIFT"
        case .toggleReadingLookup:
            return "LOOKUP"
        case .pageUp:
            return "PGUP"
        case .pageDown:
            return "PGDN"
        case .panelPick(let row):
            return "PICK_\(row)"
        case .toggleSymbolPanel:
            return "SYMBOLS"
        }
    }

    /// `Ctrl` 全形標點的記號與鍵面字元。`tokenName` 與 `parse` 共用這一張表，
    /// 每個鍵面字元在 `PunctuationMapper` 的全形對照表裡都查得到。
    public static let ctrlFullwidthTokens: [String: Character] = [
        "CTRL_COMMA": ",",
        "CTRL_PERIOD": ".",
        "CTRL_BACKSLASH": "\\",
        "CTRL_SEMICOLON": ";",
        "CTRL_BANG": "!",
        "CTRL_QUESTION": "?",
        "CTRL_LPAREN": "(",
        "CTRL_RPAREN": ")"
    ]

    public static func parse(token: String) -> KeyInput? {
        if let ch = ctrlFullwidthTokens[token] {
            return .ctrlFullwidth(ch)
        }
        switch token {
        case "SPACE":
            return .space
        case "SHIFT_SPACE":
            return .shiftSpace
        case "ACCEPT_CONTINUATION":
            return .acceptChineseContinuation
        case "CAPS_ON":
            return .capsLock(true)
        case "CAPS_OFF":
            return .capsLock(false)
        case "BACKTICK":
            return .character("`")
        case "BACKSLASH":
            return .character("\\")
        case "LBRACE":
            return .character("{")
        case "RBRACE":
            return .character("}")
        case "TAB":
            return .tab
        case "ENTER":
            return .enter
        case "BKSP", "BACKSPACE":
            return .backspace
        case "ESC", "ESCAPE":
            return .escape
        case "DOWN":
            return .arrowDown
        case "UP":
            return .arrowUp
        case "CTRL_LBRACKET":
            return .ctrlLeftBracket
        case "CTRL_RBRACKET":
            return .ctrlRightBracket
        case "CTRL_SHIFT_LBRACKET":
            return .ctrlShiftLeftBracket
        case "CTRL_SHIFT_RBRACKET":
            return .ctrlShiftRightBracket
        case "LBRACKET":
            return .character("[")
        case "RBRACKET":
            return .character("]")
        case "GT":
            return .character(">")
        case "SQUOTE":
            return .character("'")
        case "DBL_SHIFT":
            return .doubleShift
        case "LOOKUP":
            return .toggleReadingLookup
        case "SYMBOLS":
            return .toggleSymbolPanel
        case "PGUP":
            return .pageUp
        case "PGDN":
            return .pageDown
        case "COMMA":
            return .character(",")
        case "BANG":
            return .character("!")
        case "PERIOD":
            return .character(".")
        case "QUESTION":
            return .character("?")
        case "LPAREN":
            return .character("(")
        case "RPAREN":
            return .character(")")
        case "HASH":
            return .character("#")
        case "AT":
            return .character("@")
        case "DQUOTE":
            return .character("\"")
        case "DIGIT1":
            return .character("1")
        case "DIGIT2":
            return .character("2")
        default:
            if token.hasPrefix("SHIFT_"), token.count == 7, let digit = token.last?.wholeNumberValue, (1...9).contains(digit) {
                return .selectEnglishPrediction(digit)
            }
            if token.hasPrefix("PICK_"), token.count == 6, let row = token.last?.wholeNumberValue, (1...9).contains(row) {
                return .panelPick(row)
            }
            if token.hasPrefix("OPT_"), token.count == 5, let ch = token.last {
                return .optionLiteral(ch)
            }
            if token.count == 1, let ch = token.first {
                return .character(ch)
            }
            return nil
        }
    }
}

public struct ShiftTapDetector: Sendable, Equatable {
    public let thresholdSeconds: TimeInterval
    private var shiftIsDown: Bool = false
    private var currentPressHadOtherKey: Bool = false
    private var lastCleanTapReleaseTime: TimeInterval?

    public init(thresholdSeconds: TimeInterval = 0.30) {
        self.thresholdSeconds = thresholdSeconds
    }

    public mutating func noteNonModifierKeyPressed() {
        if shiftIsDown {
            currentPressHadOtherKey = true
        }
        lastCleanTapReleaseTime = nil
    }

    public mutating func handleShiftChanged(isDown: Bool, timestamp: TimeInterval) -> Bool {
        if isDown {
            if !shiftIsDown {
                shiftIsDown = true
                currentPressHadOtherKey = false
            }
            return false
        }

        guard shiftIsDown else { return false }
        shiftIsDown = false

        if currentPressHadOtherKey {
            currentPressHadOtherKey = false
            lastCleanTapReleaseTime = nil
            return false
        }

        if let prev = lastCleanTapReleaseTime,
           timestamp >= prev,
           timestamp - prev <= thresholdSeconds {
            lastCleanTapReleaseTime = nil
            return true
        }

        lastCleanTapReleaseTime = timestamp
        return false
    }
}

/// 行內程式片段語境。引擎只數自己送出的反引號，不讀文件內容判斷。
/// 用三個情形表示，不合法的組合就表示不出來：黏中只存在於片段內，
/// 開啟時記下的語境字元只有片段內與剛關上時才有意義。
public enum SnippetContext: Sendable, Hashable {
    /// 不在片段裡，游標前也不是剛關上的片段。
    case none
    /// 在片段裡。
    case inside(Inside)
    /// 游標前就是剛關上的片段。下一個標點的寬度看 `characterBefore`。
    case justClosed(characterBefore: Character?)

    public struct Inside: Sendable, Hashable {
        /// 開啟片段時，反引號前面最後一個不是空格也不是反引號的字元。
        /// 行首或前文未知時為 nil，也就是語境字元為「無」。
        public let characterBefore: Character?
        /// 片段裡已經送出過中文字，空白鍵暫時回到中文優先。
        public var stickyChinese: Bool

        public init(characterBefore: Character?, stickyChinese: Bool = false) {
            self.characterBefore = characterBefore
            self.stickyChinese = stickyChinese
        }
    }

    public var isInside: Bool {
        if case .inside = self { return true }
        return false
    }

    public var stickyChinese: Bool {
        if case .inside(let inside) = self { return inside.stickyChinese }
        return false
    }
}

/// 浮窗要標成焦點的那一軌，也就是空白鍵現在會送出的那一邊。
public enum SpaceCommitTrack: String, Sendable, Equatable, Codable {
    case chinese
    case english
}

public struct CangjieTrack: Sendable, Equatable, Codable {
    public let radicals: String
    public let candidates: [String]
    public let selectedIndex: Int
    /// 數字鍵現在會選候選字。為假時數字是打字用的，浮窗不顯示編號。
    public let digitsSelect: Bool

    public init(radicals: String, candidates: [String], selectedIndex: Int, digitsSelect: Bool = true) {
        self.radicals = radicals
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        self.digitsSelect = digitsSelect
    }
}

public struct EnglishTrack: Sendable, Equatable, Codable {
    public let typed: String
    public let predictions: [String]
    public let selectedIndex: Int

    public init(typed: String, predictions: [String], selectedIndex: Int) {
        self.typed = typed
        self.predictions = predictions
        self.selectedIndex = selectedIndex
    }
}

public struct OverlayState: Sendable, Equatable, Codable {
    public let englishTrack: EnglishTrack
    public let cangjieTrack: CangjieTrack?
    /// 游標在行內程式片段裡。浮窗要標出「片段」。
    public let inCodeSnippet: Bool
    /// 空白鍵現在會送出哪一軌。外層只照這個標焦點，不得自己再判一次。
    public let spaceCommits: SpaceCommitTrack

    public init(
        englishTrack: EnglishTrack,
        cangjieTrack: CangjieTrack?,
        inCodeSnippet: Bool = false,
        spaceCommits: SpaceCommitTrack = .chinese
    ) {
        self.englishTrack = englishTrack
        self.cangjieTrack = cangjieTrack
        self.inCodeSnippet = inCodeSnippet
        self.spaceCommits = spaceCommits
    }
}

public enum CommitKind: String, Sendable, Equatable, Codable {
    case none
    case chinese
    case english
    case rawEnglish
    case punctuation
    case number
    case space
}

/// 一次可反悔的送出目前留在文件上的是哪一邊。
public enum RevertSide: String, Sendable, Hashable, Codable {
    /// 空白鍵送出的倉頡候選字。
    case chinese
    /// Tab 送出的英文（預測首選或原字母）。
    case english

    public var opposite: RevertSide {
        self == .chinese ? .english : .chinese
    }
}

/// 英文那一邊是哪一種送出。片段外一律是 Tab；片段裡的空白鍵送的是原字母加一格空格，
/// 所以得記下當初按的是哪一個，來回對調才回到同一段文字。
public enum RevertEnglishStyle: Sendable, Hashable {
    /// Tab 會送出的英文預測首選或原字母。片段外附一格尾端空格，片段裡不附。
    case tab
    /// 片段裡空白鍵會送出的原字母加一格空格。
    case rawWithSpace
}

/// 成對符號的種類。順序就是選項列的顯示順序與數字編號。
/// 只收開頭與結尾是不同字元的符號：直引號開關同形，從文字分不出哪個是開頭。
public enum PairStyle: String, CaseIterable, Sendable, Hashable, Codable {
    case corner, square, doubleCorner, doubleAngle, singleAngle,
         lenticular, curlyDouble, curlySingle

    public var opener: Character {
        switch self {
        case .corner: return "「"
        case .square: return "["
        case .doubleCorner: return "『"
        case .doubleAngle: return "《"
        case .singleAngle: return "〈"
        case .lenticular: return "【"
        case .curlyDouble: return "“"
        case .curlySingle: return "‘"
        }
    }

    public var closer: Character {
        switch self {
        case .corner: return "」"
        case .square: return "]"
        case .doubleCorner: return "』"
        case .doubleAngle: return "》"
        case .singleAngle: return "〉"
        case .lenticular: return "】"
        case .curlyDouble: return "”"
        case .curlySingle: return "’"
        }
    }

    public static func style(opening ch: Character) -> PairStyle? {
        allCases.first { $0.opener == ch }
    }

    public static func style(closing ch: Character) -> PairStyle? {
        allCases.first { $0.closer == ch }
    }

    /// 從 `origin` 出發的循環順序。半形方括號起點的第一下先到角引號，
    /// 「第一下換寬度」才不會因為清單變長而改變；其餘起點從自己的位置往後走，到底接回第一種。
    public static func cycle(from origin: PairStyle) -> [PairStyle] {
        if origin == .square {
            return [.square] + allCases.filter { $0 != .square }
        }
        let start = allCases.firstIndex(of: origin) ?? 0
        return Array(allCases[start...] + allCases[..<start])
    }
}

/// 成對符號紀錄的內容：哪一側、從哪一種開始、現在是哪一種、怎麼來的。
public struct PairSwitch: Sendable, Hashable {
    public enum Side: Sendable, Hashable { case opener, closer }
    /// 這筆紀錄怎麼來的：剛打出來、剛用 Shift+空白 換到、剛用數字選到。
    public enum Step: Sendable, Hashable { case typed, cycled, picked }

    public let side: Side
    /// 剛打出來時的種類，決定循環順序。
    public let origin: PairStyle
    /// 目前留在文件上的種類。
    public let current: PairStyle
    public let step: Step

    public init(side: Side, origin: PairStyle, current: PairStyle, step: Step) {
        self.side = side
        self.origin = origin
        self.current = current
        self.step = step
    }
}

/// 上一個按鍵是一次可反悔的送出時，引擎記住的東西。只活一個按鍵。
public struct RevertRecord: Sendable, Hashable {
    /// 送出那個按鍵之前的引擎狀態。反悔就是回到這裡再送一次。
    public struct Snapshot: Sendable, Hashable {
        public let state: EngineStateKind
        public let buffer: String
        public let selectedCandidateIndex: Int
        public let selectedEnglishIndex: Int
        /// 引擎裁掉前文鏡像的開頭時，這裡跟著裁掉同一段，兩邊才對得上。
        public internal(set) var documentText: String
        public let pendingAutoSpace: Bool
        public let usageHistory: UsageHistory
        public let snippet: SnippetContext
    }

    /// 這次能對調的是什麼。三種情形各自只帶自己要用的東西。
    public enum Kind: Sendable, Hashable {
        /// 中英對調：目前留在文件上的是哪一軌，以及英文那一軌要用哪一種送出。
        case track(side: RevertSide, englishStyle: RevertEnglishStyle)
        /// 標點寬度對調：按下的那個鍵面字元，以及對調後要出的寬度。
        case punctuationWidth(key: Character, swapToFullwidth: Bool)
        /// 成對符號：開頭與結尾要一起換，所以不能當成單一標點的寬度對調。
        case pair(PairSwitch)
        /// 右方括號送出了全形結尾，鏡像裡找不到開頭，但鏡像之前還有看不到的前文：
        /// 分不出它是落單的還是某一對的結尾，所以不換，Shift+空白 被擋下並提示。
        case unresolvedCloser
    }

    public internal(set) var snapshot: Snapshot
    public let kind: Kind
    /// 反悔時整段換掉、外層要先讀回確認的文字，含當時補的前導與尾端空格。
    /// 成對紀錄的結尾側是鏡像上從開頭到結尾的整段，比那次按鍵送出的文字長。
    public let committedText: String
    /// 目前留在文件上的字詞或標點本身，不含空格。
    public let committedCore: String
    /// 對調後會換成的字詞。中英對調拿它當浮窗提示；標點寬度對調不顯示提示，
    /// 這裡是另一個寬度的那個字元。成對紀錄是循環上下一種的那個符號。
    public let alternativeCore: String

    /// 紀錄的文字比那次按鍵送出的長，含更早就落地的內容。外層只看這個性質，不必認得括號：
    /// 這種紀錄不能在暫存的標記文字裡換，只能讀回整段相符後一次取代。
    public var spansEarlierCommits: Bool {
        if case .pair(let pair) = kind { return pair.side == .closer }
        return false
    }
}

/// 成對符號切換之後浮窗選項列要畫的內容。八種的順序固定，所以只需要目前是哪一種。
public struct PairChoice: Sendable, Equatable, Codable {
    public let current: PairStyle
    /// 數字這時會不會直選種類。選項列只在會直選時顯示編號。
    public let digitsPick: Bool

    public init(current: PairStyle, digitsPick: Bool) {
        self.current = current
        self.digitsPick = digitsPick
    }
}

/// 成對符號的結尾按了 Shift+空白 卻沒換成時，浮窗要閃一行提示說明原因。
/// 只是一次性的輸出，不是引擎狀態。
public enum PairSwitchNotice: String, Sendable, Hashable, Codable {
    /// 整段超過字數上限、跨行或含附件占位字元，或是開頭在看得到的前文之外。由核心判定。
    case spanUnsupported
    /// 宿主讀不回文字或正在暫存，沒辦法回頭改開頭。由外層判定，核心不會給這個值。
    case hostReadbackUnavailable
}

public struct StepEffect: Sendable, Equatable, Codable {
    public let state: EngineStateKind
    public let buffer: String
    public let committedText: String?
    public let committedCore: String?
    public let commitKind: CommitKind
    public let deletedBackwardCount: Int
    public let overlay: OverlayState?
    /// 反查開啟時面板要畫的內容。外層看到它就顯示反查面板，取代雙軌內容。
    public let readingLookupPanel: ReadingLookupPanel?
    /// 符號面板開啟時要畫的內容。與 `readingLookupPanel` 不會同時有值。
    public let symbolPanel: SymbolPanelContent?
    public let handled: Bool
    /// 按鍵之後的前文鏡像。超過 `InputEngine.documentMirrorLimit` 時只有尾端那一段。
    public internal(set) var documentText: String
    public let pendingAutoSpace: Bool
    /// 這次送出的文字可以用 Shift+空白 對調。外層據此決定要不要先暫存。反悔本身也是可反悔的送出：
    /// 那時 `deletedBackwardCount` 是上一次送出的完整字元數，`committedText` 是對調後的完整文字。
    public let revertible: Bool
    /// 浮窗要提示的「再按 Shift+空白 會換成什麼」，不含空格。
    /// 可反悔但不該顯示提示時為 nil（標點寬度對調），所以外層不得自己從 `revertible` 推。
    public let revertPreview: String?
    /// 這個按鍵是一次成對符號切換時，浮窗要顯示的選項列。單純打出括號時為 nil。
    /// 與 `revertPreview` 是兩種提示，不會同時有值。
    public let pairChoice: PairChoice?
    /// 成對切換被擋下、按鍵被吃掉時要提示的原因。其餘按鍵一律為 nil，不會與 `pairChoice` 同時有值。
    public let pairSwitchNotice: PairSwitchNotice?

    public init(
        state: EngineStateKind,
        buffer: String,
        committedText: String?,
        committedCore: String?,
        commitKind: CommitKind,
        deletedBackwardCount: Int,
        overlay: OverlayState?,
        readingLookupPanel: ReadingLookupPanel? = nil,
        symbolPanel: SymbolPanelContent? = nil,
        handled: Bool,
        documentText: String,
        pendingAutoSpace: Bool,
        revertible: Bool = false,
        revertPreview: String? = nil,
        pairChoice: PairChoice? = nil,
        pairSwitchNotice: PairSwitchNotice? = nil
    ) {
        self.revertible = revertible
        self.revertPreview = revertPreview
        self.pairChoice = pairChoice
        self.pairSwitchNotice = pairSwitchNotice
        self.state = state
        self.buffer = buffer
        self.committedText = committedText
        self.committedCore = committedCore
        self.commitKind = commitKind
        self.deletedBackwardCount = deletedBackwardCount
        self.overlay = overlay
        self.readingLookupPanel = readingLookupPanel
        self.symbolPanel = symbolPanel
        self.handled = handled
        self.documentText = documentText
        self.pendingAutoSpace = pendingAutoSpace
    }
}

public struct EngineConfiguration: Sendable, Equatable {
    public var mixedModeEnabled: Bool
    public var cangjieVersion: CangjieVersion
    public var autoSpaceEnabled: Bool
    public var autoPunctuationEnabled: Bool
    public var ctrlBracketsQuotesEnabled: Bool
    public var developerVocabularyEnabled: Bool
    public var chineseContinuationEnabled = false
    public var personalTermsEnabled = false
    public var personalTerms: PersonalTerms = .empty
    /// 依使用習慣調整英文預測順序。關閉時既不套用也不記錄，已存的紀錄保留。
    public var learnsEnglishPredictions: Bool
    /// 依使用習慣調整倉頡重碼順序。關閉後同一組按鍵永遠送出同一個字。
    public var learnsCangjieOrder: Bool
    /// 依使用習慣調整讀音反查的候選順序。
    public var learnsReadingLookupOrder: Bool
    /// 讀音反查面板的鍵盤方案。只影響反查，不影響組字。
    public var readingScheme: PhoneticScheme
    /// 一鍵反悔：送出同時是倉頡碼與英文的字詞後，Shift+空白 把它在中英之間對調。
    /// 關閉時不產生反悔紀錄，Shift+空白 維持原本的行為。
    public var revertEnabled: Bool
    public var maxVisibleCandidates: Int
    public var maxVisibleEnglishPredictions: Int

    public init(
        mixedModeEnabled: Bool = true,
        cangjieVersion: CangjieVersion = .v3,
        autoSpaceEnabled: Bool = true,
        autoPunctuationEnabled: Bool = true,
        ctrlBracketsQuotesEnabled: Bool = true,
        developerVocabularyEnabled: Bool = true,
        learnsEnglishPredictions: Bool = true,
        learnsCangjieOrder: Bool = true,
        learnsReadingLookupOrder: Bool = true,
        readingScheme: PhoneticScheme = .dachen,
        revertEnabled: Bool = true,
        maxVisibleCandidates: Int = 9,
        maxVisibleEnglishPredictions: Int = 5
    ) {
        self.revertEnabled = revertEnabled
        self.mixedModeEnabled = mixedModeEnabled
        self.cangjieVersion = cangjieVersion
        self.autoSpaceEnabled = autoSpaceEnabled
        self.autoPunctuationEnabled = autoPunctuationEnabled
        self.ctrlBracketsQuotesEnabled = ctrlBracketsQuotesEnabled
        self.developerVocabularyEnabled = developerVocabularyEnabled
        self.learnsEnglishPredictions = learnsEnglishPredictions
        self.learnsCangjieOrder = learnsCangjieOrder
        self.learnsReadingLookupOrder = learnsReadingLookupOrder
        self.readingScheme = readingScheme
        self.maxVisibleCandidates = maxVisibleCandidates
        self.maxVisibleEnglishPredictions = maxVisibleEnglishPredictions
    }
}
