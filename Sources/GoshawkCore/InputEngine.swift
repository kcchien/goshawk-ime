import Foundation

public struct InputEngine: Sendable {
    public private(set) var state: EngineStateKind = .idle
    public private(set) var buffer: String = ""
    public private(set) var selectedCandidateIndex: Int = 0
    public private(set) var selectedEnglishIndex: Int = 0
    public private(set) var documentText: String = ""
    public private(set) var pendingAutoSpace: Bool = false
    /// Caps Lock 亮燈。與 `state` 各自獨立，熄燈後回到原本的混打、純中文或純英文。
    public private(set) var capsLockEnabled: Bool = false
    /// 單字讀音反查。不是 nil 時所有按鍵都交給反查處理，上面那些欄位一律不動，
    /// 所以取消只要把它設回 nil。
    public private(set) var readingLookup: ReadingLookup?
    /// 上一個按鍵是一次可反悔的送出時才有值。下一個按鍵不論是什麼都先清掉它，
    /// 只有 Shift+空白 會拿它來對調。
    public private(set) var revertRecord: RevertRecord?
    /// 行內程式片段語境。只在混打模式作用，跟著前文鏡像一起失效。
    public private(set) var snippet: SnippetContext = .none
    /// 採用過的英文預測詞，影響之後的預測順序。外層負責載入、儲存與清除。
    public var usageHistory: UsageHistory {
        didSet {
            // 外層換了一份不同的紀錄（清除、其他宿主學到新的）：反悔會把舊紀錄寫回去，所以作廢。
            // 引擎自己記錄時紀錄還沒產生，這裡不會誤清。
            if usageHistory != oldValue {
                revertRecord = nil
            }
        }
    }

    public var configuration: EngineConfiguration {
        didSet {
            if oldValue != configuration {
                revertRecord = nil
            }
            if !configuration.mixedModeEnabled {
                // 純中文模式沒有片段語境；切回混打時要重新打一個反引號才算。
                snippet = .none
            }
            if oldValue.cangjieVersion != configuration.cangjieVersion, !usesCustomCangjie {
                cangjie = CangjieDictionary.shared(version: configuration.cangjieVersion)
            }
            // A settings change mid-composition can invalidate the current state
            // (e.g. the buffer is no longer a prefix in the newly selected table).
            // 排版與標點設定只影響之後送出的文字，保留現有候選、緩衝與焦點。
            var typographyNeutral = oldValue
            typographyNeutral.autoSpaceEnabled = configuration.autoSpaceEnabled
            typographyNeutral.autoPunctuationEnabled = configuration.autoPunctuationEnabled
            typographyNeutral.ctrlBracketsQuotesEnabled = configuration.ctrlBracketsQuotesEnabled
            // 反查方案與反查學習不影響組字：開著面板換方案時不能重算候選，否則會毀掉被暫停的焦點。
            typographyNeutral.readingScheme = configuration.readingScheme
            typographyNeutral.learnsReadingLookupOrder = configuration.learnsReadingLookupOrder
            // 反悔只管送出之後的那一個按鍵，不影響組字。
            typographyNeutral.revertEnabled = configuration.revertEnabled
            if typographyNeutral != configuration, !buffer.isEmpty {
                resetSelectionIndices()
                recomputeComposingState()
            }
        }
    }

    /// Caps Lock 亮燈或雙擊 Shift 純英文時，按鍵直接輸出鍵面字元。
    public var isLiteralLayer: Bool {
        capsLockEnabled || state == .pureEnglish
    }

    public private(set) var cangjie: CangjieDictionary
    public let english: EnglishPredictor
    private let usesCustomCangjie: Bool
    /// 讀音索引保持延遲載入：平常打字不碰 `ReadingIndex.shared`，記憶體就不會上升。
    private let readingsOverride: ReadingIndex?
    private var readings: ReadingIndex { readingsOverride ?? .shared }

    public init(
        configuration: EngineConfiguration = EngineConfiguration(),
        cangjie: CangjieDictionary? = nil,
        english: EnglishPredictor = .shared,
        initialDocumentText: String = "",
        usageHistory: UsageHistory = UsageHistory(),
        readings: ReadingIndex? = nil
    ) {
        self.configuration = configuration
        self.usageHistory = usageHistory
        if let custom = cangjie {
            self.cangjie = custom
            self.usesCustomCangjie = true
        } else {
            self.cangjie = CangjieDictionary.shared(version: configuration.cangjieVersion)
            self.usesCustomCangjie = false
        }
        self.english = english
        self.readingsOverride = readings
        self.documentText = initialDocumentText
    }

    /// Number of characters before the cursor worth asking the client for.
    public static let contextWindowLength = 32

    /// Reconciles the internal mirror with the text the client reports before the cursor.
    /// When they disagree (cursor moved, paste, foreign edit) the client wins.
    public mutating func syncExternalContext(_ leadingContext: String?) {
        guard buffer.isEmpty, let ext = leadingContext else {
            return
        }
        let clipped = String(ext.suffix(Self.contextWindowLength))
        let agrees = clipped.isEmpty ? documentText.isEmpty : documentText.hasSuffix(clipped)
        if agrees {
            return
        }
        documentText = clipped
        pendingAutoSpace = false
        // 游標前已經不是剛送出的那段文字，沒有東西可以對調。
        revertRecord = nil
        // 前文鏡像一失效，片段語境就跟著結束：那個反引號可能已經不在游標前了。
        snippet = .none
    }

    /// Call when a key the engine never saw may have moved the cursor or edited the document
    /// (arrows, shortcuts, function keys). Drops the fallback mirror so stale text cannot
    /// trigger a wrong auto-space or punctuation width.
    public mutating func noteExternalCursorMovement() {
        revertRecord = nil
        guard buffer.isEmpty else { return }
        resetContext()
    }

    /// 外層無法確認剛送出的文字還在游標前，或宿主結束了組字時呼叫。之後的 Shift+空白 不再反悔。
    public mutating func discardRevertRecord() {
        revertRecord = nil
    }

    /// 宿主結束組字時呼叫。之後游標可能已經不在那個反引號後面，片段語境到此結束。
    public mutating func endSnippetContext() {
        snippet = .none
    }

    public mutating func resetContext() {
        revertRecord = nil
        readingLookup = nil
        snippet = .none
        clearComposingToIdleKeepingMode()
        documentText = ""
        pendingAutoSpace = false
    }

    /// 宿主或選單要結束組字時先呼叫它，原組字才不會被反查的選字取代。
    public mutating func dismissReadingLookup() {
        readingLookup = nil
    }

    public var currentOverlay: OverlayState? {
        guard !buffer.isEmpty else { return nil }
        let engTrack = EnglishTrack(
            typed: buffer,
            predictions: visiblePredictions(),
            selectedIndex: selectedEnglishIndex
        )
        switch state {
        case .composingDual, .selectingCandidate:
            let cjTrack = CangjieTrack(
                radicals: cangjie.radicals(for: buffer),
                candidates: visibleCandidates(),
                selectedIndex: selectedCandidateIndex,
                digitsSelect: digitsSelectCandidates
            )
            return OverlayState(
                englishTrack: engTrack,
                cangjieTrack: cjTrack,
                inCodeSnippet: inSnippet,
                spaceCommits: spaceCommitTrack
            )
        case .composingEnglishOnly:
            return OverlayState(
                englishTrack: engTrack,
                cangjieTrack: nil,
                inCodeSnippet: inSnippet,
                spaceCommits: .english
            )
        case .idle, .pureEnglish:
            return nil
        }
    }

    /// 游標在行內程式片段裡。片段語境只在混打模式作用。
    private var inSnippet: Bool {
        configuration.mixedModeEnabled && snippet.isInside
    }

    /// 片段裡已經送出過中文字，空白鍵暫時回到中文優先。
    private var snippetStickyChinese: Bool {
        configuration.mixedModeEnabled && snippet.stickyChinese
    }

    /// 空白鍵現在會送出哪一軌。浮窗的焦點與可反悔送出的兩邊都看它。
    private var spaceCommitTrack: SpaceCommitTrack {
        guard state == .composingDual || state == .selectingCandidate, !visibleCandidates().isEmpty else {
            return .english
        }
        if state == .selectingCandidate {
            return .chinese
        }
        return inSnippet && !snippetStickyChinese ? .english : .chinese
    }

    /// 送出一個半形反引號之後的語境切換。只數引擎自己送出的反引號。
    /// 呼叫前文件的最後一個字元必須就是這個反引號。
    private mutating func noteSnippetBacktick() {
        guard configuration.mixedModeEnabled else {
            snippet = .none
            return
        }
        switch snippet {
        case .inside(let inside):
            snippet = .justClosed(characterBefore: inside.characterBefore)
        case .none, .justClosed:
            let before = documentText.dropLast()
            snippet = .inside(SnippetContext.Inside(
                characterBefore: before.last(where: { $0 != " " && $0 != "`" })
            ))
        }
    }

    /// 退格刪掉的就是切換語境的那個反引號時，語境跟著倒回去一步。
    /// 呼叫前已經從鏡像拿掉那個反引號。
    private mutating func undoSnippetBacktick() {
        guard configuration.mixedModeEnabled else { return }
        switch snippet {
        case .inside:
            // 片段裡鏡像尾端的反引號只會是開啟片段的那一個：片段裡再送一個就關上了。
            snippet = .none
        case .justClosed(let characterBefore):
            // 刪掉結尾的反引號就回到片段裡，沿用開啟時記下的語境字元，黏中不延續。
            snippet = .inside(SnippetContext.Inside(characterBefore: characterBefore))
        case .none:
            break
        }
    }

    /// 片段裡送出中文字就進入黏中，從緩衝送出原字母、按下符號或離開片段就解除。
    private mutating func setSnippetStickyChinese(_ sticky: Bool) {
        guard case .inside(var inside) = snippet, inside.stickyChinese != sticky else { return }
        inside.stickyChinese = sticky
        snippet = .inside(inside)
    }

    /// 反查面板要畫的內容。未開啟時為 nil。候選與分頁都在這裡算完，外層不再查索引。
    public var currentReadingLookupPanel: ReadingLookupPanel? {
        guard let lookup = readingLookup else { return nil }

        let status: ReadingLookupPanel.Status
        // 候選只從 `readingLookupCandidates()` 來，面板與選字才會是同一份順序。
        let candidates = readingLookupCandidates()
        switch readings.interpret(lookup.keys, scheme: lookup.scheme) {
        case .empty:
            status = .empty
        case .partial:
            status = .partial
        case .unknown:
            status = .noResults
        case .syllable:
            status = candidates.isEmpty ? .noResults : .results
        }

        let perPage = ReadingLookup.rowsPerPage
        let pageCount = max(1, (candidates.count + perPage - 1) / perPage)
        let pageIndex = min(lookup.pageIndex, pageCount - 1)
        let rows = candidates.dropFirst(pageIndex * perPage).prefix(perPage).enumerated().map { offset, candidate in
            let code = candidate.nativeCodes.first
            return ReadingLookupPanel.Row(
                number: offset + 1,
                character: candidate.character,
                code: code,
                radicals: code.map { cangjie.radicals(for: $0) }
            )
        }
        let focusedRow = rows.isEmpty ? nil : lookup.focusIndex - pageIndex * perPage

        return ReadingLookupPanel(
            scheme: lookup.scheme,
            inputDisplay: ReadingIndex.displayKeys(lookup.keys, scheme: lookup.scheme),
            cangjieVersion: configuration.cangjieVersion,
            status: status,
            rows: Array(rows),
            focusedRow: focusedRow,
            isSelecting: lookup.isSelecting,
            page: pageIndex + 1,
            pageCount: pageCount
        )
    }

    @discardableResult
    public mutating func handle(_ input: KeyInput) -> StepEffect {
        // 反悔紀錄只活一個按鍵：不論這個按鍵是什麼，舊紀錄都到此為止。
        let record = revertRecord
        revertRecord = nil
        let snippetBefore = snippet
        if input == .shiftSpace, let record, let reverted = revert(record) {
            // 反悔會把片段語境一起倒回去，失效的判斷已經在 revert 裡用送出前的語境做過。
            return reverted
        }
        let effect = commitTrackRevertibly(input) ?? commitPunctuationRevertibly(input) ?? dispatch(input)
        expireJustClosedSnippet(before: snippetBefore, committedText: effect.committedText)
        return effect
    }

    /// 送出這個按鍵之前的引擎狀態，反悔要倒回去的就是這些。
    private var revertSnapshot: RevertRecord.Snapshot {
        RevertRecord.Snapshot(
            state: state,
            buffer: buffer,
            selectedCandidateIndex: selectedCandidateIndex,
            selectedEnglishIndex: selectedEnglishIndex,
            documentText: documentText,
            pendingAutoSpace: pendingAutoSpace,
            usageHistory: usageHistory,
            snippet: snippet
        )
    }

    private mutating func restore(_ snapshot: RevertRecord.Snapshot) {
        state = snapshot.state
        buffer = snapshot.buffer
        selectedCandidateIndex = snapshot.selectedCandidateIndex
        selectedEnglishIndex = snapshot.selectedEnglishIndex
        documentText = snapshot.documentText
        pendingAutoSpace = snapshot.pendingAutoSpace
        usageHistory = snapshot.usageHistory
        snippet = snapshot.snippet
    }

    /// 反悔對宿主的效果：回刪上一次送出的完整文字，再接上這一段。
    /// 由新舊文件的差異算出來，不假設兩次送出只差幾個字元。回刪範圍以外的文件必須一樣，
    /// 否則這次反悔就不只是換掉剛送出的那一段，放棄。
    private static func replacementText(
        oldDocument: String,
        newDocument: String,
        deletedBackwardCount: Int
    ) -> String? {
        let keptCount = oldDocument.count - deletedBackwardCount
        guard keptCount >= 0 else { return nil }
        let kept = oldDocument.prefix(keptCount)
        guard newDocument.hasPrefix(kept) else { return nil }
        return String(newDocument.dropFirst(keptCount))
    }

    /// 剛關上的片段只對緊接的那一個標點透明：這個按鍵又送出了別的文字就不算了。
    /// 關上片段的那個反引號本身不受影響，它進來時還在片段裡。
    private mutating func expireJustClosedSnippet(before: SnippetContext, committedText: String?) {
        guard case .justClosed = snippet, case .justClosed = before, committedText != nil else { return }
        snippet = .none
    }

    /// 送出目前組字的其中一邊，就像使用者按了那一邊的鍵。中文那邊是首選字或目前聚焦的候選；
    /// 英文那邊依 `englishStyle` 走 Tab 或片段裡空白鍵的原字母加空格。
    private mutating func commit(side: RevertSide, englishStyle: RevertEnglishStyle) -> StepEffect {
        if state == .selectingCandidate, side == .english {
            // 等同先按 Esc 離開候選選取。
            state = .composingDual
            selectedCandidateIndex = 0
        }
        switch side {
        case .chinese:
            let emitted = commitSelectedChineseCandidate()
            clearComposingToIdle()
            return makeEffect(
                committedText: emitted.full,
                committedCore: emitted.core,
                commitKind: .chinese,
                deletedBackwardCount: 0,
                handled: true
            )
        case .english:
            switch englishStyle {
            case .tab:
                return handleTab()
            case .rawWithSpace:
                let emitted = commitRawBuffer(appendTrailingSpace: true)
                clearComposingToIdle()
                return makeEffect(
                    committedText: emitted.full,
                    committedCore: emitted.core,
                    commitKind: .rawEnglish,
                    deletedBackwardCount: 0,
                    handled: true
                )
            }
        }
    }

    /// 這個按鍵若是一次可對調寬度的標點送出，就送出並記下紀錄；不是就回傳 nil，引擎完全沒動過。
    /// 條件：設定開啟、不在半形層或反查裡，按的是鍵面有兩種寬度的標點鍵。
    /// 有沒有緩衝、在不在片段裡、半形標點設定開不開都不影響。
    /// `Ctrl` 加標點與 `Option` 單次半形已經指定了寬度，不走這裡。
    private mutating func commitPunctuationRevertibly(_ input: KeyInput) -> StepEffect? {
        guard configuration.revertEnabled, readingLookup == nil, !isLiteralLayer,
              case .character(let ch) = input,
              let fullwidth = PunctuationMapper.fullwidthForm(for: ch) else {
            return nil
        }
        let snapshot = revertSnapshot
        var chosen = self
        let effect = chosen.handlePunctuation(ch)
        guard let text = effect.committedText, let core = effect.committedCore else {
            // 純中文模式只有前綴時句點不送出任何東西，沒有東西可對調。
            return nil
        }
        let wasFullwidth = core == fullwidth
        self = chosen
        revertRecord = RevertRecord(
            snapshot: snapshot,
            kind: .punctuationWidth(key: ch, swapToFullwidth: !wasFullwidth),
            committedText: text,
            committedCore: core,
            alternativeCore: wasFullwidth ? String(ch) : fullwidth
        )
        // 標點寬度對調不顯示提示：每個標點都跳一行太吵。
        return makeEffect(
            committedText: text,
            committedCore: core,
            commitKind: effect.commitKind,
            deletedBackwardCount: effect.deletedBackwardCount,
            handled: true,
            revertible: true
        )
    }

    /// 這個按鍵若是一次可對調中英的送出，就送出並記下紀錄；不是就回傳 nil，引擎完全沒動過。
    /// 條件：混打、雙軌或選字中按空白或 Tab，這串字母有倉頡候選，
    /// 而且另一邊會送出不同的文字。
    private mutating func commitTrackRevertibly(_ input: KeyInput) -> StepEffect? {
        guard configuration.revertEnabled, configuration.mixedModeEnabled,
              readingLookup == nil, !isLiteralLayer,
              input == .space || input == .tab,
              state == .composingDual || state == .selectingCandidate,
              !visibleCandidates().isEmpty else {
            return nil
        }
        // 選字中的 Tab 與空白鍵一樣送出聚焦的候選字。片段裡沒黏中時空白鍵送的是英文。
        let focused = state == .selectingCandidate
        let side: RevertSide = input == .tab && !focused ? .english
            : (focused ? .chinese : (spaceCommitTrack == .english ? .english : .chinese))
        // 片段裡按空白、又沒聚焦候選時，英文那一邊是原字母加一格空格。
        let englishStyle: RevertEnglishStyle = input == .tab || focused || !inSnippet ? .tab : .rawWithSpace

        var chosen = self
        let effect = chosen.commit(side: side, englishStyle: englishStyle)
        var alternative = self
        let alternativeEffect = alternative.commit(side: side.opposite, englishStyle: englishStyle)
        guard let text = effect.committedText, let core = effect.committedCore,
              let alternativeText = alternativeEffect.committedText,
              let alternativeCore = alternativeEffect.committedCore,
              text != alternativeText, core != alternativeCore else {
            return nil
        }

        let snapshot = revertSnapshot
        self = chosen
        revertRecord = RevertRecord(
            snapshot: snapshot,
            kind: .track(side: side, englishStyle: englishStyle),
            committedText: text,
            committedCore: core,
            alternativeCore: alternativeCore
        )
        return makeEffect(
            committedText: text,
            committedCore: core,
            commitKind: effect.commitKind,
            deletedBackwardCount: 0,
            handled: true,
            revertible: true,
            revertPreview: alternativeCore
        )
    }

    /// 反悔：回到送出前的狀態，再送出另一邊或另一個寬度。結果與當初直接那樣送出完全相同
    /// （空格、標點語境、學習紀錄都重算），只差紀錄仍在，再按一次會換回來。
    private mutating func revert(_ record: RevertRecord) -> StepEffect? {
        let oldDocument = documentText
        var restored = self
        restored.restore(record.snapshot)

        let effect: StepEffect
        let nextKind: RevertRecord.Kind
        switch record.kind {
        case .track(let side, let englishStyle):
            effect = restored.commit(side: side.opposite, englishStyle: englishStyle)
            nextKind = .track(side: side.opposite, englishStyle: englishStyle)
        case .punctuationWidth(let key, let swapToFullwidth):
            effect = restored.handlePunctuation(key, widthOverride: swapToFullwidth ? .fullwidth : .halfwidth)
            nextKind = .punctuationWidth(key: key, swapToFullwidth: !swapToFullwidth)
        }
        guard let core = effect.committedCore,
              let text = Self.replacementText(
                  oldDocument: oldDocument,
                  newDocument: restored.documentText,
                  deletedBackwardCount: record.committedText.count
              ) else {
            return nil
        }
        self = restored
        expireJustClosedSnippet(before: record.snapshot.snippet, committedText: text)
        revertRecord = RevertRecord(
            snapshot: record.snapshot,
            kind: nextKind,
            committedText: text,
            committedCore: core,
            alternativeCore: record.committedCore
        )
        // 中英對調才提示；標點寬度對調不提示，但同樣可以再對調回去。
        let showsHint: Bool
        if case .track = nextKind { showsHint = true } else { showsHint = false }
        return makeEffect(
            committedText: text,
            committedCore: core,
            commitKind: effect.commitKind,
            deletedBackwardCount: record.committedText.count,
            handled: true,
            revertible: true,
            revertPreview: showsHint ? record.committedCore : nil
        )
    }

    private mutating func dispatch(_ input: KeyInput) -> StepEffect {
        if readingLookup != nil {
            return handleReadingLookupKey(input)
        }

        switch input {
        case .toggleReadingLookup:
            return handleToggleReadingLookup()
        case .pageUp, .pageDown, .readingLookupPick:
            // 反查沒開啟時這些鍵不屬於輸入法。外層本來就只在開啟時才送它們。
            return passthroughOrSwallowEffect()
        case .capsLock(let isOn):
            return handleCapsLock(isOn)
        case .doubleShift:
            return handleDoubleShift()
        case .ctrlFullwidth(let ch):
            // 自動判斷猜不到語境時（行首、剛移動游標），用 Ctrl 明確指定全形。
            if isLiteralLayer {
                return passthroughEffect()
            }
            // 外層只送表內的鍵面字元，表外的字元沒有全形可出，交還宿主。
            guard let text = PunctuationMapper.fullwidthForm(for: ch) else {
                return passthroughOrSwallowEffect()
            }
            return commitImplicitComposingIfNeededAndEmit(
                coreText: text,
                outgoing: .punctuation,
                appendTrailingSpace: false,
                commitKind: .punctuation,
                collapsesPendingAutoSpace: PunctuationMapper.collapsesPendingAutoSpace(ch)
            )
        case .ctrlLeftBracket:
            return handleCtrlBracket(text: "「", opens: true)
        case .ctrlRightBracket:
            return handleCtrlBracket(text: "」", opens: false)
        case .ctrlShiftLeftBracket:
            return handleCtrlBracket(text: "『", opens: true)
        case .ctrlShiftRightBracket:
            return handleCtrlBracket(text: "』", opens: false)
        case .optionLiteral(let ch):
            if isLiteralLayer {
                return passthroughEffect()
            }
            return handleOptionLiteral(ch)
        case .selectEnglishPrediction(let rank):
            return handleSelectEnglishPrediction(rank: rank)
        default:
            break
        }

        if isLiteralLayer {
            return handleLiteralLayer(input)
        }

        switch input {
        case .character(let ch):
            return handleCharacter(ch)
        case .space:
            return handleSpace()
        case .shiftSpace:
            return handleShiftSpace()
        case .tab:
            return handleTab()
        case .enter:
            return handleEnter()
        case .backspace:
            return handleBackspace()
        case .escape:
            return handleEscape()
        case .arrowDown:
            return handleArrowDown()
        case .arrowUp:
            return handleArrowUp()
        case .capsLock, .doubleShift, .ctrlFullwidth, .ctrlLeftBracket, .ctrlRightBracket,
             .ctrlShiftLeftBracket, .ctrlShiftRightBracket, .optionLiteral, .selectEnglishPrediction,
             .toggleReadingLookup, .pageUp, .pageDown, .readingLookupPick:
            return passthroughOrSwallowEffect()
        }
    }

    /// 開啟反查。Caps Lock 亮燈或純英文直通時交還宿主的快捷鍵。
    private mutating func handleToggleReadingLookup() -> StepEffect {
        guard !isLiteralLayer else {
            return passthroughEffect()
        }
        readingLookup = ReadingLookup(scheme: configuration.readingScheme)
        return swallowEffect()
    }

    /// 反查開啟期間的全部按鍵。除了選字，一律不動主組字、文件與待收合空格，
    /// 也絕不回傳 `handled: false`，宿主才收不到查詢字元。
    private mutating func handleReadingLookupKey(_ input: KeyInput) -> StepEffect {
        guard var lookup = readingLookup else {
            return swallowEffect()
        }

        switch input {
        case .escape, .toggleReadingLookup:
            readingLookup = nil
            return swallowEffect()

        case .capsLock(let isOn):
            // 燈號真的改變時先關閉反查，再照原本的 Caps Lock 流程處理。
            guard isOn != capsLockEnabled else {
                return swallowEffect()
            }
            readingLookup = nil
            return handleCapsLock(isOn)

        case .character(let ch):
            if lookup.isSelecting, let row = ch.wholeNumberValue, (1...9).contains(row) {
                return pickReadingLookupRow(row)
            }
            lookup.keys.append(ch.lowercased().first ?? ch)
            return updateReadingLookupQuery(lookup)

        case .backspace:
            guard !lookup.keys.isEmpty else {
                return swallowEffect()
            }
            lookup.keys.removeLast()
            return updateReadingLookupQuery(lookup)

        case .space:
            // 大千的一聲要用空白鍵指定，面板必須記住使用者按過它。
            if lookup.scheme == .dachen, !lookup.isSelecting,
               case .syllable(let query) = readings.interpret(lookup.keys, scheme: .dachen),
               query.tone == nil {
                lookup.keys.append(" ")
                return updateReadingLookupQuery(lookup)
            }
            return pickFocusedReadingLookupRow()

        case .enter:
            return pickFocusedReadingLookupRow()

        case .readingLookupPick(let row):
            return pickReadingLookupRow(row)

        case .tab:
            let next: PhoneticScheme = lookup.scheme == .dachen ? .pinyin : .dachen
            if case .syllable(let query) = readings.interpret(lookup.keys, scheme: lookup.scheme) {
                lookup.keys = readings.keys(for: query, scheme: next)
            } else {
                lookup.keys = ""
            }
            lookup.scheme = next
            lookup.focusIndex = 0
            lookup.isSelecting = false
            readingLookup = lookup
            configuration.readingScheme = next
            return swallowEffect()

        case .arrowDown:
            let total = readingLookupCandidates().count
            guard total > 0 else {
                return swallowEffect()
            }
            if !lookup.isSelecting {
                lookup.isSelecting = true
            } else if lookup.focusIndex + 1 < total {
                lookup.focusIndex += 1
            }
            readingLookup = lookup
            return swallowEffect()

        case .arrowUp:
            guard lookup.isSelecting else {
                return swallowEffect()
            }
            if lookup.focusIndex == 0 {
                lookup.isSelecting = false
            } else {
                lookup.focusIndex -= 1
            }
            readingLookup = lookup
            return swallowEffect()

        case .pageDown:
            let perPage = ReadingLookup.rowsPerPage
            let nextPageStart = (lookup.pageIndex + 1) * perPage
            guard nextPageStart < readingLookupCandidates().count else {
                return swallowEffect()
            }
            lookup.focusIndex = nextPageStart
            readingLookup = lookup
            return swallowEffect()

        case .pageUp:
            guard lookup.pageIndex > 0 else {
                return swallowEffect()
            }
            lookup.focusIndex = (lookup.pageIndex - 1) * ReadingLookup.rowsPerPage
            readingLookup = lookup
            return swallowEffect()

        case .shiftSpace, .doubleShift, .ctrlFullwidth, .ctrlLeftBracket, .ctrlRightBracket,
             .ctrlShiftLeftBracket, .ctrlShiftRightBracket, .optionLiteral, .selectEnglishPrediction:
            return swallowEffect()
        }
    }

    /// 改過讀音鍵序後回第一頁、離開候選選取。
    private mutating func updateReadingLookupQuery(_ lookup: ReadingLookup) -> StepEffect {
        var next = lookup
        next.focusIndex = 0
        next.isSelecting = false
        readingLookup = next
        return swallowEffect()
    }

    /// 反查目前讀音的候選，已套用學習順序。面板、選字與翻頁都看這一份。
    public func readingLookupCandidates() -> [ReadingCandidate] {
        guard let lookup = readingLookup,
              case .syllable(let query) = readings.interpret(lookup.keys, scheme: lookup.scheme) else {
            return []
        }
        let candidates = readings.candidates(for: query, version: configuration.cangjieVersion)
        guard configuration.learnsReadingLookupOrder else {
            return candidates
        }
        return usageHistory.orderedByReadingChoices(candidates, character: \.character)
    }

    private mutating func pickFocusedReadingLookupRow() -> StepEffect {
        guard let lookup = readingLookup else {
            return swallowEffect()
        }
        return commitReadingLookupCandidate(at: lookup.focusIndex)
    }

    private mutating func pickReadingLookupRow(_ row: Int) -> StepEffect {
        guard let lookup = readingLookup, (1...ReadingLookup.rowsPerPage).contains(row) else {
            return swallowEffect()
        }
        return commitReadingLookupCandidate(at: lookup.pageIndex * ReadingLookup.rowsPerPage + row - 1)
    }

    /// 選字：丟掉原緩衝不送出原字母，用既有的中文送出流程一次取代宿主的標記文字。
    private mutating func commitReadingLookupCandidate(at index: Int) -> StepEffect {
        let candidates = readingLookupCandidates()
        guard candidates.indices.contains(index) else {
            return swallowEffect()
        }
        readingLookup = nil
        clearComposingToIdle()
        let character = candidates[index].character
        if configuration.learnsReadingLookupOrder {
            usageHistory.recordReading(character)
        }
        let emitted = emitText(core: character, outgoing: .chinese, appendTrailingSpace: false)
        return makeEffect(
            committedText: emitted.full,
            committedCore: emitted.core,
            commitKind: .chinese,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    private mutating func handleCapsLock(_ isOn: Bool) -> StepEffect {
        guard isOn != capsLockEnabled else {
            return swallowEffect()
        }
        capsLockEnabled = isOn
        guard isOn else {
            return swallowEffect()
        }
        // 亮燈時原樣送出尚未確認的緩衝，不補尾端空格。半形層不收合先前自動補上的空格。
        var emitted: (full: String, core: String)?
        if !buffer.isEmpty {
            emitted = commitRawBuffer(appendTrailingSpace: false)
            clearComposingToIdleKeepingMode()
        }
        pendingAutoSpace = false
        return makeEffect(
            committedText: emitted?.full,
            committedCore: emitted?.core,
            commitKind: emitted == nil ? .none : .rawEnglish,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    /// 有倉頡候選時聚焦清單，保留緩衝且不選字。沒有候選時與空白鍵相同。
    private mutating func handleShiftSpace() -> StepEffect {
        switch state {
        case .composingDual where !visibleCandidates().isEmpty:
            state = .selectingCandidate
            selectedCandidateIndex = 0
            return swallowEffect()
        case .selectingCandidate:
            return swallowEffect()
        case .idle, .composingDual, .composingEnglishOnly, .pureEnglish:
            return handleSpace()
        }
    }

    private mutating func handleCtrlBracket(text: String, opens: Bool) -> StepEffect {
        guard configuration.ctrlBracketsQuotesEnabled, !isLiteralLayer else {
            // Shortcut disabled for Vim / terminal users, where Ctrl+[ means Esc: an active
            // composition is cancelled like Esc instead of leaking the key to the client.
            if !buffer.isEmpty, opens {
                return handleEscape()
            }
            return passthroughOrSwallowEffect()
        }
        return commitImplicitComposingIfNeededAndEmit(
            coreText: text,
            outgoing: .punctuation,
            appendTrailingSpace: false,
            commitKind: .punctuation,
            // 收尾的角引號與收尾標點同一條規則，收合英文後自動補上的那一格。
            collapsesPendingAutoSpace: !opens
        )
    }

    private mutating func handleSelectEnglishPrediction(rank: Int) -> StepEffect {
        guard configuration.mixedModeEnabled,
              state == .composingDual || state == .composingEnglishOnly,
              (1...9).contains(rank) else {
            return passthroughOrSwallowEffect()
        }
        let preds = visiblePredictions()
        guard preds.indices.contains(rank - 1) else {
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        }
        let emitted = emitText(core: preds[rank - 1], outgoing: .englishOrNumber, appendTrailingSpace: !inSnippet)
        // Shift+數字 送出的是緩衝的英文詞，黏中解除。
        setSnippetStickyChinese(false)
        if configuration.learnsEnglishPredictions {
            usageHistory.recordEnglish(preds[rank - 1])
        }
        clearComposingToIdle()
        return makeEffect(
            committedText: emitted.full,
            committedCore: emitted.core,
            commitKind: .english,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    private mutating func handleDoubleShift() -> StepEffect {
        if state == .pureEnglish {
            state = .idle
            resetSelectionIndices()
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        }

        if state == .selectingCandidate {
            // No mode switch while the candidate list is focused.
            return swallowEffect()
        }

        var committedText: String?
        var committedCore: String?
        var commitKind: CommitKind = .none

        if !buffer.isEmpty {
            let emitted = commitRawBuffer(appendTrailingSpace: false)
            committedText = emitted.full
            committedCore = emitted.core
            commitKind = .rawEnglish
        }

        state = .pureEnglish
        buffer = ""
        resetSelectionIndices()
        return makeEffect(
            committedText: committedText,
            committedCore: committedCore,
            commitKind: commitKind,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    private mutating func handleLiteralLayer(_ input: KeyInput) -> StepEffect {
        switch input {
        case .character(let ch):
            let s = String(ch)
            documentText += s
            pendingAutoSpace = false
            // 半形層送出的反引號照樣切換語境，熄燈後接著打字就在片段裡。
            if ch == "`" {
                noteSnippetBacktick()
            }
            return makeEffect(committedText: s, committedCore: s, commitKind: .rawEnglish, deletedBackwardCount: 0, handled: true)
        case .space, .shiftSpace:
            documentText += " "
            pendingAutoSpace = false
            return makeEffect(committedText: " ", committedCore: " ", commitKind: .space, deletedBackwardCount: 0, handled: true)
        case .backspace:
            return passthroughDeletingBackward()
        case .enter, .tab, .arrowDown, .arrowUp:
            return passthroughInvalidatingContext()
        default:
            return passthroughEffect()
        }
    }

    /// Option 加鍵面數字或標點：當次輸出半形。混打組字未聚焦候選時連同原字母送出。
    private mutating func handleOptionLiteral(_ ch: Character) -> StepEffect {
        guard AutoSpacer.isASCIIDigit(ch) else {
            return handlePunctuation(ch, optionHalfwidth: true)
        }
        let prefixText = settleComposition(keepingRawLetters: configuration.mixedModeEnabled)
        let emitted = emitText(core: String(ch), outgoing: .englishOrNumber, appendTrailingSpace: false)
        return makeEffect(
            committedText: prefixText + emitted.full,
            committedCore: emitted.core,
            commitKind: .number,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    private mutating func handleCharacter(_ ch: Character) -> StepEffect {
        if AutoSpacer.isASCIILetter(ch) {
            return handleLetter(ch)
        }
        if AutoSpacer.isASCIIDigit(ch) {
            return handleDigit(ch)
        }
        if PunctuationMapper.isPunctuationKey(ch) {
            return handlePunctuation(ch)
        }
        let s = String(ch)
        return commitImplicitComposingIfNeededAndEmit(
            coreText: s,
            outgoing: .punctuation,
            appendTrailingSpace: false,
            commitKind: .punctuation
        )
    }

    private mutating func handleLetter(_ ch: Character) -> StepEffect {
        if !configuration.mixedModeEnabled, state != .composingEnglishOnly {
            // Chinese-only mode has no English track: a key that cannot extend the Cangjie
            // code is rejected while composing, or typed literally when nothing is composing.
            let base = state == .selectingCandidate ? "" : buffer
            if !cangjie.hasCandidatesOrPrefix(for: base + String(ch)) {
                guard buffer.isEmpty else {
                    return swallowEffect()
                }
                let emitted = emitText(core: String(ch), outgoing: .englishOrNumber, appendTrailingSpace: false)
                return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .rawEnglish, deletedBackwardCount: 0, handled: true)
            }
        }

        var preCommitted: (full: String, core: String)?
        if state == .selectingCandidate {
            preCommitted = commitSelectedChineseCandidate()
            buffer = ""
        }

        buffer.append(ch)
        resetSelectionIndices()
        recomputeComposingState()

        return makeEffect(
            committedText: preCommitted?.full,
            committedCore: preCommitted?.core,
            commitKind: preCommitted == nil ? .none : .chinese,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    private mutating func handleDigit(_ ch: Character) -> StepEffect {
        switch state {
        case .idle:
            let s = String(ch)
            let emitted = emitText(core: s, outgoing: .englishOrNumber, appendTrailingSpace: false)
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .number, deletedBackwardCount: 0, handled: true)

        case .composingDual, .selectingCandidate:
            let cands = visibleCandidates()
            let picked = ch.wholeNumberValue.flatMap { cands.indices.contains($0 - 1) ? cands[$0 - 1] : nil }
            let extendsEnglish = state == .composingDual && configuration.mixedModeEnabled
            if digitsSelectCandidates, !extendsEnglish, let picked {
                return commitPickedCandidate(picked)
            }
            if extendsEnglish {
                let candidatePrefix = buffer + String(ch)
                let nextPreds = englishPredictions(for: candidatePrefix, limit: 1)
                if !nextPreds.isEmpty {
                    buffer = candidatePrefix
                    resetSelectionIndices()
                    recomputeComposingState()
                    return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
                }
                // 接不上英文詞（`k8s`、`mp3` 才會續打）。有得選就選字，否則當成代號連同原字母送出。
                if digitsSelectCandidates, let picked {
                    return commitPickedCandidate(picked)
                }
                return commitRawBufferFollowedByDigit(ch)
            }
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)

        case .composingEnglishOnly:
            let candidatePrefix = buffer + String(ch)
            let nextPreds = englishPredictions(for: candidatePrefix, limit: 1)
            if !nextPreds.isEmpty {
                buffer = candidatePrefix
                resetSelectionIndices()
                return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
            }
            return commitRawBufferFollowedByDigit(ch)

        case .pureEnglish:
            let s = String(ch)
            documentText += s
            pendingAutoSpace = false
            return makeEffect(committedText: s, committedCore: s, commitKind: .number, deletedBackwardCount: 0, handled: true)
        }
    }

    /// 數字鍵現在會不會選候選字，浮窗依此決定要不要顯示編號。
    /// 已聚焦候選與純中文模式一律會。混打未聚焦時，只有一個字母的緩衝後面接數字多半是代號
    /// （`m120`、`v2`、`a4`），只有一個候選時也沒有東西可選，這兩種情況數字都當字元。
    private var digitsSelectCandidates: Bool {
        if state == .selectingCandidate || !configuration.mixedModeEnabled {
            return true
        }
        // 片段裡數字只用來打字（`k8s`、`mp3`），不選字。
        return state == .composingDual && !inSnippet && buffer.count >= 2 && visibleCandidates().count >= 2
    }

    private mutating func commitPickedCandidate(_ chosen: String) -> StepEffect {
        let emitted = emitCangjieCandidate(chosen)
        clearComposingToIdle()
        return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .chinese, deletedBackwardCount: 0, handled: true)
    }

    private mutating func commitRawBufferFollowedByDigit(_ ch: Character) -> StepEffect {
        let rawEmitted = commitRawBuffer(appendTrailingSpace: false)
        let digitStr = String(ch)
        documentText += digitStr
        pendingAutoSpace = false
        clearComposingToIdle()
        return makeEffect(
            committedText: rawEmitted.full + digitStr,
            committedCore: rawEmitted.core + digitStr,
            commitKind: .rawEnglish,
            deletedBackwardCount: 0,
            handled: true
        )
    }

    /// 片段剛關上、游標前就是那個結尾反引號、而且這個標點前沒有緩衝時，
    /// 寬度改看開啟片段時記下的字元，也就是片段對標點語境透明。其餘情況回傳 nil，照原本的規則判。
    private func snippetTransparentContext(hadBuffer: Bool) -> PunctuationContextOverride? {
        guard configuration.mixedModeEnabled, !hadBuffer,
              case .justClosed(let characterBefore) = snippet,
              documentText.hasSuffix("`") else {
            return nil
        }
        return characterBefore.map(PunctuationContextOverride.character) ?? .unknown
    }

    /// `optionHalfwidth` 是 Option 單次半形：除了出半形，前面的組字也送原字母。
    /// `widthOverride` 是 Shift+空白 對調指定的寬度，只換標點本身，前綴照這個鍵原本的規則。
    private mutating func handlePunctuation(
        _ ch: Character,
        optionHalfwidth: Bool = false,
        widthOverride: PunctuationWidth? = nil
    ) -> StepEffect {
        let isPeriod = ch == "."
        if isPeriod, !optionHalfwidth, !configuration.mixedModeEnabled,
           state == .composingDual, visibleCandidates().isEmpty {
            // 純中文模式只有前綴：保留組字，讓使用者把碼打完。
            return swallowEffect()
        }

        // 混打時句點與單次半形代表英文名稱還沒結束（`my.file`、`os.path`），送出原字母。
        let hadBuffer = !buffer.isEmpty
        let wasInSnippet = inSnippet
        let prefixText = settleComposition(
            keepingRawLetters: configuration.mixedModeEnabled && (isPeriod || optionHalfwidth)
        )

        let mapped: PunctuationResult
        if let widthOverride {
            // 對調指定的寬度優先於語境、半形標點設定與片段規則；空格的收合只看鍵，兩個寬度相同。
            mapped = PunctuationMapper.map(
                character: ch,
                documentText: documentText,
                pendingAutoSpace: pendingAutoSpace,
                width: widthOverride
            )
        } else if wasInSnippet {
            // 片段裡的標點一律半形，也不收合前面的空格。
            mapped = PunctuationResult(text: String(ch), shouldCollapsePendingAutoSpace: false)
        } else {
            mapped = PunctuationMapper.map(
                character: ch,
                documentText: documentText,
                pendingAutoSpace: pendingAutoSpace,
                width: optionHalfwidth || !configuration.autoPunctuationEnabled ? .halfwidth : .automatic,
                contextOverride: snippetTransparentContext(hadBuffer: hadBuffer)
            )
        }

        var deletedCount = 0
        if mapped.shouldCollapsePendingAutoSpace, documentText.hasSuffix(" ") {
            documentText.removeLast()
            deletedCount = 1
        }

        documentText += mapped.text
        pendingAutoSpace = false
        if ch == "`" {
            noteSnippetBacktick()
        } else {
            setSnippetStickyChinese(false)
        }

        return makeEffect(
            committedText: prefixText + mapped.text,
            committedCore: mapped.text,
            commitKind: .punctuation,
            deletedBackwardCount: deletedCount,
            handled: true
        )
    }

    private mutating func handleSpace() -> StepEffect {
        switch state {
        case .idle:
            documentText += " "
            pendingAutoSpace = false
            return makeEffect(committedText: " ", committedCore: " ", commitKind: .space, deletedBackwardCount: 0, handled: true)

        case .composingDual:
            let cands = visibleCandidates()
            // 片段裡英文優先：有候選字也先送原字母加空格，黏中時才回到中文。
            if let first = cands.first, !(inSnippet && !snippetStickyChinese) {
                let emitted = emitCangjieCandidate(first)
                clearComposingToIdle()
                return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .chinese, deletedBackwardCount: 0, handled: true)
            }
            if !configuration.mixedModeEnabled {
                // Incomplete code in Chinese-only mode: keep the buffer so the user can
                // finish or correct it instead of silently losing the keystrokes.
                return swallowEffect()
            }
            let emitted = commitRawBuffer(appendTrailingSpace: true)
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .rawEnglish, deletedBackwardCount: 0, handled: true)

        case .selectingCandidate:
            let emitted = commitSelectedChineseCandidate()
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .chinese, deletedBackwardCount: 0, handled: true)

        case .composingEnglishOnly:
            let emitted = commitRawBuffer(appendTrailingSpace: true)
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .rawEnglish, deletedBackwardCount: 0, handled: true)

        case .pureEnglish:
            documentText += " "
            pendingAutoSpace = false
            return makeEffect(committedText: " ", committedCore: " ", commitKind: .space, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func handleTab() -> StepEffect {
        switch state {
        case .idle, .pureEnglish:
            return passthroughInvalidatingContext()

        case .selectingCandidate:
            let emitted = commitSelectedChineseCandidate()
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .chinese, deletedBackwardCount: 0, handled: true)

        case .composingDual, .composingEnglishOnly:
            if !configuration.mixedModeEnabled, state == .composingDual {
                return swallowEffect()
            }
            let preds = visiblePredictions()
            let chosen: String
            if preds.indices.contains(selectedEnglishIndex) {
                chosen = preds[selectedEnglishIndex]
                if configuration.learnsEnglishPredictions {
                    usageHistory.recordEnglish(chosen)
                }
            } else {
                chosen = buffer
            }
            // 片段裡的英文不附尾端空格：那一格在程式片段裡是內容。
            let emitted = emitText(core: chosen, outgoing: .englishOrNumber, appendTrailingSpace: !inSnippet)
            // Tab 送出的是緩衝的英文預測或原字母，黏中解除。
            setSnippetStickyChinese(false)
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .english, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func handleEnter() -> StepEffect {
        switch state {
        case .idle, .pureEnglish:
            return passthroughInvalidatingContext()

        case .selectingCandidate:
            let emitted = commitSelectedChineseCandidate()
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .chinese, deletedBackwardCount: 0, handled: true)

        case .composingDual, .composingEnglishOnly:
            let emitted = commitRawBuffer(appendTrailingSpace: false)
            clearComposingToIdle()
            return makeEffect(committedText: emitted.full, committedCore: emitted.core, commitKind: .rawEnglish, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func handleBackspace() -> StepEffect {
        switch state {
        case .idle, .pureEnglish:
            return passthroughDeletingBackward()

        case .composingDual, .composingEnglishOnly, .selectingCandidate:
            guard !buffer.isEmpty else {
                clearComposingToIdle()
                return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
            }
            buffer.removeLast()
            resetSelectionIndices()
            recomputeComposingState()
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func handleEscape() -> StepEffect {
        switch state {
        case .idle, .pureEnglish:
            return passthroughEffect()
        case .selectingCandidate:
            state = .composingDual
            selectedCandidateIndex = 0
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        case .composingDual, .composingEnglishOnly:
            clearComposingToIdle()
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func handleArrowDown() -> StepEffect {
        switch state {
        case .idle, .pureEnglish:
            return passthroughInvalidatingContext()
        case .composingDual:
            let cands = visibleCandidates()
            if cands.count > 1 {
                state = .selectingCandidate
                selectedCandidateIndex = 1
            }
            // With nothing to pick the key is swallowed: forwarding it would let the client
            // move the cursor and drop its marked text while this buffer stays alive.
            return swallowEffect()
        case .selectingCandidate:
            let cands = visibleCandidates()
            if !cands.isEmpty {
                selectedCandidateIndex = (selectedCandidateIndex + 1) % cands.count
            }
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        case .composingEnglishOnly:
            let preds = visiblePredictions()
            if preds.count > 1 {
                selectedEnglishIndex = (selectedEnglishIndex + 1) % preds.count
            }
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func handleArrowUp() -> StepEffect {
        switch state {
        case .idle, .pureEnglish:
            return passthroughInvalidatingContext()
        case .composingDual:
            return swallowEffect()
        case .selectingCandidate:
            if selectedCandidateIndex <= 1 {
                state = .composingDual
                selectedCandidateIndex = 0
            } else {
                selectedCandidateIndex -= 1
            }
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        case .composingEnglishOnly:
            let preds = visiblePredictions()
            if preds.count > 1 {
                selectedEnglishIndex = (selectedEnglishIndex - 1 + preds.count) % preds.count
            }
            return makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
        }
    }

    private mutating func recomputeComposingState() {
        if buffer.isEmpty {
            state = .idle
            return
        }
        if cangjie.hasCandidatesOrPrefix(for: buffer) {
            state = .composingDual
        } else {
            state = .composingEnglishOnly
        }
    }

    private mutating func clearComposingToIdle() {
        buffer = ""
        state = .idle
        resetSelectionIndices()
    }

    private mutating func clearComposingToIdleKeepingMode() {
        buffer = ""
        if state != .pureEnglish {
            state = .idle
        }
        resetSelectionIndices()
    }

    private mutating func resetSelectionIndices() {
        selectedCandidateIndex = 0
        selectedEnglishIndex = 0
    }

    /// 目前緩衝的倉頡候選，已套用學習順序。空白鍵送出的、浮窗顯示的與數字選到的都走這裡。
    private func visibleCandidates() -> [String] {
        let table = cangjie.candidates(for: buffer)
        let ordered = configuration.learnsCangjieOrder
            ? usageHistory.orderedCangjieCandidates(table, code: buffer)
            : table
        return Array(ordered.prefix(configuration.maxVisibleCandidates))
    }

    /// 英文預測的唯一入口。關閉英文學習時不帶紀錄進去。
    private func visiblePredictions() -> [String] {
        englishPredictions(for: buffer, limit: configuration.maxVisibleEnglishPredictions)
    }

    private func englishPredictions(for prefix: String, limit: Int) -> [String] {
        guard configuration.mixedModeEnabled else { return [] }
        return english.predictions(
            for: prefix,
            limit: limit,
            includeDeveloperTerms: configuration.developerVocabularyEnabled,
            usage: configuration.learnsEnglishPredictions ? usageHistory : UsageHistory()
        )
    }

    /// 送出一個倉頡候選字。只有重碼才記，單一候選沒有學習的意義。
    /// 必須在清掉緩衝之前呼叫，紀錄才對得上現在這個碼。
    private mutating func emitCangjieCandidate(_ character: String) -> (full: String, core: String) {
        if configuration.learnsCangjieOrder, visibleCandidates().count >= 2 {
            usageHistory.recordCangjie(code: buffer, character: character)
        }
        return emitText(core: character, outgoing: .chinese, appendTrailingSpace: false)
    }

    private mutating func commitSelectedChineseCandidate() -> (full: String, core: String) {
        let cands = visibleCandidates()
        if cands.indices.contains(selectedCandidateIndex) {
            return emitCangjieCandidate(cands[selectedCandidateIndex])
        }
        if let first = cands.first {
            return emitCangjieCandidate(first)
        }
        return commitRawBuffer(appendTrailingSpace: false)
    }

    /// 從組字緩衝送出原字母。空白鍵沒有候選、Enter、符號前的結束組字與數字連同原字母都走這裡，
    /// 片段裡的黏中跟著解除。
    private mutating func commitRawBuffer(appendTrailingSpace: Bool) -> (full: String, core: String) {
        let emitted = emitText(core: buffer, outgoing: .englishOrNumber, appendTrailingSpace: appendTrailingSpace)
        setSnippetStickyChinese(false)
        return emitted
    }

    /// 標點或符號接手前先結束組字，回傳這次送出的文字。已聚焦候選時送焦點字。
    /// 其餘情況送首選字，沒有候選或 `keepingRawLetters` 為真時送原字母。
    private mutating func settleComposition(keepingRawLetters: Bool) -> String {
        guard !buffer.isEmpty else {
            return ""
        }
        // 片段裡的符號、標點與 Ctrl 標點都先送原字母，黏中也一樣。
        let keepingRawLetters = keepingRawLetters || inSnippet
        let text: String
        if state == .selectingCandidate {
            text = commitSelectedChineseCandidate().full
        } else if state == .composingDual, !keepingRawLetters, let first = visibleCandidates().first {
            text = emitCangjieCandidate(first).full
        } else {
            text = commitRawBuffer(appendTrailingSpace: false).full
        }
        clearComposingToIdle()
        return text
    }

    private mutating func commitImplicitComposingIfNeededAndEmit(
        coreText: String,
        outgoing: OutgoingTokenKind,
        appendTrailingSpace: Bool,
        commitKind: CommitKind,
        collapsesPendingAutoSpace: Bool = false
    ) -> StepEffect {
        let prefixFull = settleComposition(keepingRawLetters: false)
        // 結束組字之後就不會再有待收合的空格，所以收合與前綴不會同時發生。
        var deletedCount = 0
        if collapsesPendingAutoSpace, pendingAutoSpace, documentText.hasSuffix(" ") {
            documentText.removeLast()
            deletedCount = 1
        }
        let emitted = emitText(core: coreText, outgoing: outgoing, appendTrailingSpace: appendTrailingSpace)
        return makeEffect(
            committedText: prefixFull + emitted.full,
            committedCore: emitted.core,
            commitKind: commitKind,
            deletedBackwardCount: deletedCount,
            handled: true
        )
    }

    private mutating func emitText(
        core: String,
        outgoing: OutgoingTokenKind,
        appendTrailingSpace: Bool
    ) -> (full: String, core: String) {
        // 片段裡不補中英、中數之間的空格；送出的尾端空格是內容的一部分，之後的標點不收合它。
        let leading = inSnippet ? "" : AutoSpacer.leadingSpace(
            before: documentText.last,
            for: outgoing,
            enabled: configuration.autoSpaceEnabled
        )
        let trailing = appendTrailingSpace ? " " : ""
        let full = leading + core + trailing
        documentText += full
        pendingAutoSpace = inSnippet ? false : appendTrailingSpace
        // 送出中文字就進入黏中。解除黏中由按鍵自己負責：只有從組字緩衝送出原字母或英文詞才算，
        // 閒置時單獨送出的數字不算，`答案是：12個` 這種片段才不會在數字後面掉回英文。
        if case .chinese = outgoing {
            setSnippetStickyChinese(true)
        }
        return (full, core)
    }

    /// A handled key with no visible effect.
    private func swallowEffect() -> StepEffect {
        makeEffect(committedText: nil, committedCore: nil, commitKind: .none, deletedBackwardCount: 0, handled: true)
    }

    /// Keys may only be forwarded to the client when nothing is composing. Otherwise the
    /// client would act on its marked text while the engine still holds the buffer.
    private func passthroughOrSwallowEffect() -> StepEffect {
        buffer.isEmpty ? passthroughEffect() : swallowEffect()
    }

    /// Forwards a key that moves the cursor or breaks the line (Enter, Tab, arrows). The
    /// fallback mirror no longer describes the text before the cursor, so it is dropped.
    private mutating func passthroughInvalidatingContext() -> StepEffect {
        noteExternalCursorMovement()
        return passthroughEffect()
    }

    private mutating func passthroughDeletingBackward() -> StepEffect {
        let deleted = documentText.popLast()
        pendingAutoSpace = false
        if deleted == "`" {
            undoSnippetBacktick()
        }
        return passthroughEffect()
    }

    private func passthroughEffect() -> StepEffect {
        makeEffect(
            committedText: nil,
            committedCore: nil,
            commitKind: .none,
            deletedBackwardCount: 0,
            handled: false
        )
    }

    /// `revertible` 與 `revertPreview` 分開給：標點寬度對調可以反悔卻不顯示提示。
    private func makeEffect(
        committedText: String?,
        committedCore: String?,
        commitKind: CommitKind,
        deletedBackwardCount: Int,
        handled: Bool,
        revertible: Bool = false,
        revertPreview: String? = nil
    ) -> StepEffect {
        StepEffect(
            state: state,
            buffer: buffer,
            committedText: committedText,
            committedCore: committedCore,
            commitKind: commitKind,
            deletedBackwardCount: deletedBackwardCount,
            overlay: currentOverlay,
            readingLookupPanel: currentReadingLookupPanel,
            handled: handled,
            documentText: documentText,
            pendingAutoSpace: pendingAutoSpace,
            revertible: revertible,
            revertPreview: revertPreview
        )
    }
}
