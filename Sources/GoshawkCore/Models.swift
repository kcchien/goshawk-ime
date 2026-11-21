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
    /// 點選反查面板本頁的第 n 列，1 起算。不論是否已進入候選選取都直接選字。
    case readingLookupPick(Int)

    public var tokenName: String {
        switch self {
        case .character(let ch):
            return String(ch)
        case .space:
            return "SPACE"
        case .shiftSpace:
            return "SHIFT_SPACE"
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
        case .readingLookupPick(let row):
            return "PICK_\(row)"
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
                return .readingLookupPick(row)
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

/// 上一個按鍵是一次可反悔的送出時，引擎記住的東西。只活一個按鍵。
public struct RevertRecord: Sendable, Hashable {
    /// 送出那個按鍵之前的引擎狀態。反悔就是回到這裡再送一次。
    public struct Snapshot: Sendable, Hashable {
        public let state: EngineStateKind
        public let buffer: String
        public let selectedCandidateIndex: Int
        public let selectedEnglishIndex: Int
        public let documentText: String
        public let pendingAutoSpace: Bool
        public let usageHistory: UsageHistory
        public let snippet: SnippetContext
    }

    /// 這次能對調的是什麼。兩種情形各自只帶自己要用的東西。
    public enum Kind: Sendable, Hashable {
        /// 中英對調：目前留在文件上的是哪一軌，以及英文那一軌要用哪一種送出。
        case track(side: RevertSide, englishStyle: RevertEnglishStyle)
        /// 標點寬度對調：按下的那個鍵面字元，以及對調後要出的寬度。
        case punctuationWidth(key: Character, swapToFullwidth: Bool)
    }

    public let snapshot: Snapshot
    public let kind: Kind
    /// 目前留在文件上的完整文字，含當時補的前導與尾端空格。反悔時整段換掉。
    public let committedText: String
    /// 目前留在文件上的字詞或標點本身，不含空格。
    public let committedCore: String
    /// 對調後會換成的字詞。中英對調拿它當浮窗提示；標點寬度對調不顯示提示，
    /// 這裡是另一個寬度的那個字元。
    public let alternativeCore: String
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
    public let handled: Bool
    public let documentText: String
    public let pendingAutoSpace: Bool
    /// 這次送出的文字可以用 Shift+空白 對調。外層據此決定要不要先暫存。反悔本身也是可反悔的送出：
    /// 那時 `deletedBackwardCount` 是上一次送出的完整字元數，`committedText` 是對調後的完整文字。
    public let revertible: Bool
    /// 浮窗要提示的「再按 Shift+空白 會換成什麼」，不含空格。
    /// 可反悔但不該顯示提示時為 nil（標點寬度對調），所以外層不得自己從 `revertible` 推。
    public let revertPreview: String?

    public init(
        state: EngineStateKind,
        buffer: String,
        committedText: String?,
        committedCore: String?,
        commitKind: CommitKind,
        deletedBackwardCount: Int,
        overlay: OverlayState?,
        readingLookupPanel: ReadingLookupPanel? = nil,
        handled: Bool,
        documentText: String,
        pendingAutoSpace: Bool,
        revertible: Bool = false,
        revertPreview: String? = nil
    ) {
        self.revertible = revertible
        self.revertPreview = revertPreview
        self.state = state
        self.buffer = buffer
        self.committedText = committedText
        self.committedCore = committedCore
        self.commitKind = commitKind
        self.deletedBackwardCount = deletedBackwardCount
        self.overlay = overlay
        self.readingLookupPanel = readingLookupPanel
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
