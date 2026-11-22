import AppKit
import Carbon.HIToolbox
import Foundation
import InputMethodKit
import GoshawkCore

protocol IMKTextClientProtocol: AnyObject {
    func insertText(_ string: String, replacementRange: NSRange)
    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange)
    func selectedRange() -> NSRange
    func attributedSubstring(from range: NSRange) -> NSAttributedString?
    func cursorLineRect() -> NSRect
    /// 宿主是否宣告支援文件存取（讀回文字與 `replacementRange`）。只當成額外訊號：
    /// 說不支援就一定不靠回讀，說支援仍要實際讀回確認。
    func supportsDocumentAccess() -> Bool
}

final class IMKClientAdapter: IMKTextClientProtocol {
    private let input: IMKTextInput

    init(input: IMKTextInput) {
        self.input = input
    }

    func supportsDocumentAccess() -> Bool {
        input.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
    }

    func insertText(_ string: String, replacementRange: NSRange) {
        input.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange) {
        // Clients draw marked text only as the attributes say; a plain string leaves the
        // composing letters indistinguishable from committed text in many apps.
        let marked = NSAttributedString(string: string, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .markedClauseSegment: 0
        ])
        input.setMarkedText(marked, selectionRange: selectionRange, replacementRange: replacementRange)
    }

    func selectedRange() -> NSRange {
        input.selectedRange()
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        input.attributedSubstring(from: range)
    }

    func cursorLineRect() -> NSRect {
        // 索引 0 是組字首碼，浮窗不會隨每次新增的字母向右移。實測 Herdr、Chrome、Notes
        // 都由這個查詢回報正確位置。
        var rect = NSRect.zero
        _ = input.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        if CandidateOverlayPanel.isUsableCursorRect(rect) { return rect }
        // `firstRect` 在上述程式回傳未初始化的數值（約 1e-314 或負的高度），只當備援，
        // 而且要先確認數值合理。
        let marked = input.markedRange()
        let index = marked.location == NSNotFound ? input.selectedRange().location : marked.location
        guard index != NSNotFound else { return .zero }
        var actual = NSRange(location: NSNotFound, length: 0)
        let first = input.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: &actual)
        return CandidateOverlayPanel.isUsableCursorRect(first) ? first : .zero
    }
}

/// 疊加層要畫的面板內容。引擎同一時間最多開一個疊加層，所以這裡也只表示得出一個。
enum LayerPanelContent: Equatable {
    case reading(ReadingLookupPanel)
    case symbols(SymbolPanelContent)

    init?(_ effect: StepEffect) {
        if let panel = effect.readingLookupPanel {
            self = .reading(panel)
        } else if let panel = effect.symbolPanel {
            self = .symbols(panel)
        } else {
            return nil
        }
    }

    /// 從閒置開啟時放進宿主的暫時標記文字：反查放讀音，符號面板放焦點列的符號。
    var placeholderText: String {
        let text: String
        switch self {
        case .reading(let panel):
            text = panel.inputDisplay
        case .symbols(let panel):
            text = panel.focusedRow.flatMap { panel.rows.indices.contains($0) ? panel.rows[$0].symbol : nil } ?? ""
        }
        return text.isEmpty ? "？" : text
    }
}

/// 畫面更新回呼：雙軌內容、疊加層的面板內容與定位用的游標矩形。
/// 面板內容不是 nil 時，顯示端以它取代雙軌內容。
typealias OverlayUpdate = (OverlayState?, LayerPanelContent?, NSRect) -> Void

final class InputSessionCoordinator {
    var engine: InputEngine
    var translator = EventTranslator()
    private let preferences: PreferencesStore?
    private let usageStore: UsageHistoryStore?
    private let statistics: StatisticsSession?
    private enum HostReadback {
        /// 這個欄位還沒有任何一次送出，讀不讀得回文字還不知道。
        case unverified
        case mayReplace
        case lastCommitUnreadable
        case revertRefused
        case cursorStaysAtZero

        /// 送出後可以靠讀回來取代。還沒送出過也算，由送出前的游標位置把關。
        var allowsReplacing: Bool {
            self == .mayReplace || self == .unverified
        }

        mutating func didCommit(cursorLocation: Int, textMatches: () -> Bool) {
            if cursorLocation == 0 {
                self = .cursorStaysAtZero
                return
            }
            switch self {
            case .unverified, .mayReplace, .lastCommitUnreadable:
                self = textMatches() ? .mayReplace : .lastCommitUnreadable
            case .revertRefused, .cursorStaysAtZero:
                // 這兩種欄位即使後來有一次送字讀得回來，仍須暫存到換欄位為止。
                break
            }
        }

        mutating func didRefuseRevert() {
            // 游標已確認不可信時，連前文也要繼續用引擎的。
            if self != .cursorStaysAtZero { self = .revertRefused }
        }
    }
    private var readback = HostReadback.unverified
    /// 從閒置開啟疊加層時，宿主的標記文字是暫時放上去的讀音或焦點符號。
    private var lookupPlaceholderShown = false
    /// 剛做完一次字數不變的取代（空格換成逗號、半形標點換成全形）時記下的東西。
    /// 這種取代不移動游標，Chromium 系的宿主（VS Code）就不更新回報給輸入法的前文，
    /// 要到下一次送出才跟上；在那之前同一個位置讀回來的還是 `old`。
    /// 讀回的內容正好是 `old` 時，那是宿主還沒更新，照 `new` 看待；讀到別的就代表文件真的變了。
    private struct StaleEcho {
        let range: NSRange
        let old: String
        let new: String
    }
    private var staleEcho: StaleEcho?
    /// 宿主讀不回文字時，可反悔的送出先以標記文字暫存在宿主，等下一個按鍵：
    /// Shift+空白 就整段換成另一邊，其他任何事件都先把它正式送出。
    /// 宿主同一時間只有一段標記文字：有暫存就沒有組字緩衝，也沒有反查的暫時讀音。
    private(set) var stagedCommit: String?
    /// 可反悔的送出之後浮窗要提示的字詞（對調後會變成什麼）。下一個按鍵就清掉。
    private(set) var revertHint: String?
    /// 成對符號切換之後浮窗要顯示的選項列。壽命與 `revertHint` 相同，下一個不是切換的按鍵就清掉。
    private(set) var pairChoice: PairChoice?
    /// 成對切換被擋下時浮窗要閃一行的原因：引擎說整段換不了，或是這裡自己放棄。
    /// 壽命與 `revertHint` 相同，下一個按鍵就清掉；浮窗另外有計時器會自己先收。
    private(set) var pairSwitchNotice: PairSwitchNotice?

    init(
        configuration: EngineConfiguration,
        preferences: PreferencesStore? = nil,
        usageStore: UsageHistoryStore? = nil,
        statistics: StatisticsSession? = nil
    ) {
        self.engine = InputEngine(configuration: configuration)
        self.preferences = preferences
        self.usageStore = usageStore
        self.statistics = statistics
    }

    func clearUsageHistory() throws {
        try usageStore?.clear()
        engine.usageHistory = UsageHistory()
    }

    var englishActionsAvailable: Bool {
        engine.configuration.mixedModeEnabled && (engine.state == .composingDual || engine.state == .composingEnglishOnly)
    }

    func handlePayload(
        _ payload: KeyEventPayload,
        client: IMKTextClientProtocol,
        received: UInt64 = DispatchTime.now().uptimeNanoseconds,
        onOverlayUpdate: OverlayUpdate? = nil
    ) -> Bool {
        // 系統若把 Caps Lock 攔為輸入來源切換鍵，旗標不會亮，這裡就不會進入半形層。
        syncCapsLock(
            isOn: payload.modifierFlags.contains(.capsLock),
            client: client,
            onOverlayUpdate: onOverlayUpdate
        )

        // 選取範圍不為空時，接詞會取代宿主文字，必須把快捷鍵交還宿主。
        if engine.chineseContinuation != nil, client.selectedRange().length > 0 {
            engine.dismissChineseContinuation()
        }
        let event = translator.translate(payload, layer: engine.layer,
                                         hasChineseContinuation: engine.chineseContinuation != nil) {
            englishActionsAvailable && engine.currentOverlay?.englishTrack.predictions.isEmpty == false
        }
        switch event {
        case .key(let key):
            return handleInput(key, client: client, received: received, onOverlayUpdate: onOverlayUpdate)
        case .toggleHalfwidthPunctuation where !engine.isLiteralLayer:
            dismissCommitHints(onOverlayUpdate: onOverlayUpdate)
            toggleHalfwidthPunctuation()
            return true
        case .toggleHalfwidthPunctuation, nil:
            if payload.isKeyDown {
                releaseKeyToClient(client, onOverlayUpdate: onOverlayUpdate)
            }
            return false
        }
    }

    /// 鍵盤與反查面板的點選共用學習紀錄、前文、送字與偏好存檔。
    @discardableResult
    private func handleInput(
        _ keyInput: KeyInput,
        client: IMKTextClientProtocol,
        received: UInt64 = DispatchTime.now().uptimeNanoseconds,
        onOverlayUpdate: OverlayUpdate?
    ) -> Bool {
        let observation = statistics?.begin(engine: engine, start: received)
        var observedEffect: StepEffect?
        var isRevert = false
        var refused = false
        defer {
            if let observation {
                statistics?.finish(observation, key: keyInput, effect: observedEffect, engine: engine,
                                   isRevert: isRevert, staged: stagedCommit != nil, refused: refused,
                                   updatesOverlay: onOverlayUpdate != nil)
            }
        }
        if let usageStore {
            engine.usageHistory = usageStore.history
        }
        defer { usageStore?.update(engine.usageHistory) }
        let wasComposing = !engine.buffer.isEmpty
        let configurationBefore = engine.configuration

        // 反悔要把剛送出的文字換掉。暫存中的文字直接換；已經正式送出的，先讀回確認它還在
        // 游標前才取代，讀不到或不符就放棄這次反悔，什麼都不送，絕不盲目回刪。
        isRevert = engine.isRevertInput(keyInput)
        var revertRange: NSRange?
        if isRevert, let record = engine.revertRecord, record.spansEarlierCommits,
           stagedCommit != nil || !readback.allowsReplacing {
            // 這筆紀錄要換掉的文字比剛送出的長，前半段早就落地了：暫存的標記文字裡沒有它，
            // 帶取代範圍的標記文字在部分宿主又沒有作用。只走「讀回相符後立即取代」，
            // 走不了就放棄。暫存的文字留著，下一個按鍵照常落地一次；欄位也不因此降級。
            refused = true
            abandonRevert(of: record, client: client, onOverlayUpdate: onOverlayUpdate)
            return true
        }
        if isRevert, stagedCommit == nil, let record = engine.revertRecord {
            guard let range = rangeBeforeCursor(of: record.committedText, client: client) else {
                // 整段讀回不符多半是中間的內容被改了，剛送出的結尾本身才剛確認讀得回，
                // 所以不把欄位降級成暫存；其餘紀錄照舊降級。
                if !record.spansEarlierCommits {
                    readback.didRefuseRevert()
                }
                refused = true
                abandonRevert(of: record, client: client, onOverlayUpdate: onOverlayUpdate)
                return true
            }
            revertRange = range
        }

        // 暫存中的文字宿主還沒收下，前文以引擎記住的為準；反悔沿用送出時的前文。
        // 疊加層的暫時標記佔用宿主標記，不能把它當成已送出的前文。
        if !wasComposing, engine.layer == nil, stagedCommit == nil, !isRevert {
            let leading = readLeadingContext(from: client)
            engine.syncExternalContext(leading?.text, isClipped: leading?.isClipped ?? false)
        }

        let symbolPanelWasOpen = engine.symbolPanel != nil
        let effect = engine.handle(keyInput)
        if observation != nil { observedEffect = effect }
        // 引擎自己判定整段換不了（太長、跨行、夾著附件）時吃掉按鍵，統計上同樣是一次被拒的對調。
        if isRevert, effect.handled, effect.committedText == nil {
            refused = true
        }
        guard effect.handled else {
            // The engine only forwards keys while idle; commit anyway rather than leave a
            // live buffer behind a key the client is about to act on.
            // 放行不代表組字結束，片段語境留給引擎判定：閒置的退格還在片段裡。
            settleComposition(client: client, onOverlayUpdate: onOverlayUpdate)
            return false
        }

        if isRevert, effect.revertible, let swapped = effect.committedText {
            if let revertRange, readback.allowsReplacing {
                insert(swapped, replacementRange: revertRange, into: client)
            } else {
                // 上次送出後沒能立即讀回時，即使現在確認了舊文字，也不再直接送出對調結果。
                stage(swapped, replacing: revertRange ?? NSRange(location: NSNotFound, length: 0), in: client)
            }
            revertHint = effect.revertPreview
            pairChoice = effect.pairChoice
            pairSwitchNotice = nil
            // 中英對調的提示沿用剛才組字的位置。閒置時打出的括號沒有組字過，浮窗沒有位置可沿用，
            // 給零矩形會落到滑鼠那裡，所以選項列自己問宿主游標在哪。
            onOverlayUpdate?(nil, nil, pairChoice == nil ? .zero : client.cursorLineRect())
        } else {
            apply(effect, to: client, wasComposing: wasComposing, symbolPanelWasOpen: symbolPanelWasOpen,
                  onOverlayUpdate: onOverlayUpdate)
        }
        // 面板裡按 Tab 換讀音方案時，引擎自己改了設定，這裡把偏好存下來。
        if engine.configuration != configurationBefore {
            savePreferences()
        }
        return true
    }

    /// 選單與 `Ctrl+Shift+;` 共用的反查開關。
    func toggleReadingLookup(client: IMKTextClientProtocol?, onOverlayUpdate: OverlayUpdate? = nil) {
        sendToReadingLookup(.toggleReadingLookup, client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 點選面板上本頁的第 `row` 列（1 起算）。
    func pickReadingLookupRow(_ row: Int, client: IMKTextClientProtocol?, onOverlayUpdate: OverlayUpdate? = nil) {
        sendToReadingLookup(.panelPick(row), client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 點選面板上的「注音｜拼音」分段按鈕，與面板裡按 Tab 同一條路。
    func toggleReadingScheme(client: IMKTextClientProtocol?, onOverlayUpdate: OverlayUpdate? = nil) {
        guard engine.readingLookup != nil else { return }
        sendToReadingLookup(.tab, client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 選單與 `Option+Shift+B` 共用的符號面板開關。
    func toggleSymbolPanel(client: IMKTextClientProtocol?, onOverlayUpdate: OverlayUpdate? = nil) {
        sendToReadingLookup(.toggleSymbolPanel, client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 點選符號面板上本頁的第 `row` 列（1 起算）。面板已經關掉時，遲到的點選不作用。
    func pickSymbolPanelRow(_ row: Int, client: IMKTextClientProtocol?, onOverlayUpdate: OverlayUpdate? = nil) {
        guard engine.symbolPanel != nil else { return }
        sendToReadingLookup(.panelPick(row), client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 點選符號面板的分段按鈕，與面板裡按 Tab 同一條路：三個分頁輪流，
    /// 所以按到點的那個分頁為止，最多兩下。點的是目前這個分頁就不動。
    /// 要按兩下時，中間那個分頁只推進引擎，不碰宿主的標記文字也不更新浮窗：
    /// 否則宿主的暫時標記會先換成中間分頁的符號，VoiceOver 也會先念錯的分頁。
    func selectSymbolPanelTab(
        _ tab: SymbolPanel.Tab,
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil
    ) {
        guard var current = engine.symbolPanel?.tab, current != tab else { return }
        if client != nil {
            while current.next != tab {
                _ = engine.handle(.tab)
                current = current.next
            }
        }
        sendToReadingLookup(.tab, client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 選單與兩張面板的滑鼠動作都從這裡進引擎，和鍵盤走同一條路。
    private func sendToReadingLookup(
        _ key: KeyInput,
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate?
    ) {
        guard let client else {
            redrawWithoutClient(onOverlayUpdate: onOverlayUpdate)
            return
        }
        handleInput(key, client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 選單動作拿不到宿主時只重畫浮窗。被擋下的提示先清掉：浮窗的計時器到期只收畫面，
    /// 這裡的值還留著，照舊重畫會把過期的提示再叫出來，而且沒有游標位置可放。
    private func redrawWithoutClient(onOverlayUpdate: OverlayUpdate?) {
        pairSwitchNotice = nil
        onOverlayUpdate?(nil, nil, .zero)
    }

    /// Toggles pure English mode from the menu, delivering any buffer the engine commits.
    func togglePureEnglish(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil
    ) {
        statistics?.hostEndedComposition(engine: engine, deliversText: client != nil)
        engine.dismissLayer()
        let wasComposing = !engine.buffer.isEmpty
        let effect = engine.handle(.doubleShift)
        if let client {
            apply(effect, to: client, wasComposing: wasComposing, onOverlayUpdate: onOverlayUpdate)
        } else {
            redrawWithoutClient(onOverlayUpdate: onOverlayUpdate)
        }
    }

    /// 依實際的修飾鍵旗標同步 Caps Lock 燈號。亮燈時引擎會先原樣送出進行中的緩衝。
    func syncCapsLock(
        isOn: Bool,
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil
    ) {
        guard engine.capsLockEnabled != isOn else {
            return
        }
        statistics?.hostEndedComposition(engine: engine, deliversText: client != nil)
        let wasComposing = !engine.buffer.isEmpty
        let effect = engine.handle(.capsLock(isOn))
        if let client {
            apply(effect, to: client, wasComposing: wasComposing, onOverlayUpdate: onOverlayUpdate)
        } else {
            redrawWithoutClient(onOverlayUpdate: onOverlayUpdate)
        }
    }

    /// 「使用半形標點符號」只改之後的標點寬度，不結束組字，候選與焦點都保留。
    func toggleHalfwidthPunctuation() {
        engine.configuration.autoPunctuationEnabled.toggle()
        savePreferences()
    }

    /// 設定視窗改完偏好後重新載入。沿用選單改設定的流程：先結束組字並關閉反查。
    func reloadConfiguration(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil
    ) {
        guard let preferences else { return }
        updateConfiguration(client: client, onOverlayUpdate: onOverlayUpdate) {
            $0 = preferences.loadConfiguration()
        }
    }

    /// Changes a setting from the menu. An active composition is committed first because
    /// the buffer may not be valid under the new setting (other table, no English track).
    func updateConfiguration(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil,
        _ change: (inout EngineConfiguration) -> Void
    ) {
        commitComposition(client: client, onOverlayUpdate: onOverlayUpdate)
        change(&engine.configuration)
        savePreferences()
    }

    private func apply(
        _ effect: StepEffect,
        to client: IMKTextClientProtocol,
        wasComposing: Bool,
        symbolPanelWasOpen: Bool = false,
        onOverlayUpdate: OverlayUpdate?
    ) {
        let notFound = NSRange(location: NSNotFound, length: 0)
        revertHint = nil
        pairChoice = nil
        // 引擎擋下成對切換時效果帶著原因；其餘按鍵是 nil，上一則提示就在這裡收掉。
        pairSwitchNotice = effect.pairSwitchNotice

        // 暫存中的文字在這個按鍵落地，而且只送這一次。這個按鍵要收合的尾端空格
        // 就是暫存字串的尾端空格，直接在字串上收掉，不必向宿主回刪。
        var deleteCount = effect.deletedBackwardCount
        // 符號面板沒有送出文字的按鍵（開啟、瀏覽、關閉）不讓暫存落地：宿主讀不回文字，
        // 落地後就收不掉它尾端的空格，之後從面板選收尾標點會比引擎記的多一格。
        // 讀音反查的選字不收合空格，維持開啟時落地。
        let keepsStaged = effect.committedText == nil && (symbolPanelWasOpen || effect.symbolPanel != nil)
        if var staged = stagedCommit, !keepsStaged {
            stagedCommit = nil
            if deleteCount > 0, staged.hasSuffix(String(repeating: " ", count: deleteCount)) {
                staged.removeLast(deleteCount)
                deleteCount = 0
            }
            insert(staged, replacementRange: notFound, into: client)
        }

        if lookupPlaceholderShown, deleteCount > 0, effect.committedText != nil {
            // 要收合的空格在暫時標記的前面。先把標記清掉，游標回到空格後面，
            // 下面才讀得到那一格並把它取代掉。
            lookupPlaceholderShown = false
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
        }

        if let committed = effect.committedText {
            if effect.revertible, !canReplaceCommittedText(in: client, hadMarkedText: wasComposing) {
                // 宿主讀不回文字，之後就刪不掉它：先放成標記文字，等下一個按鍵決定。
                // 這個按鍵要收合的尾端空格由標記文字的取代範圍一起吃掉。
                stage(committed, replacing: backwardReplacementRange(count: deleteCount, client: client), in: client)
            } else {
                insert(
                    committed,
                    replacementRange: backwardReplacementRange(count: deleteCount, client: client),
                    into: client
                )
            }
        }

        if let layerPanel = LayerPanelContent(effect) {
            // 有原字母時它留在宿主的標記文字裡，這裡不碰。從閒置開啟時宿主沒有標記文字，
            // 終端機會把 Enter 直接交給裡面的程式而不經過輸入法，所以用讀音或焦點符號
            // 當暫時的標記文字。有選取範圍時不放，否則取消後選取的文字就被吃掉了。
            // 暫存的文字還是宿主的標記文字時也不放，宿主同一時間只有一段標記。
            if effect.buffer.isEmpty, stagedCommit == nil,
               lookupPlaceholderShown || client.selectedRange().length == 0 {
                let text = layerPanel.placeholderText
                let selRange = NSRange(location: text.utf16.count, length: 0)
                client.setMarkedText(text, selectionRange: selRange, replacementRange: notFound)
                lookupPlaceholderShown = true
            }
            onOverlayUpdate?(effect.overlay, layerPanel, client.cursorLineRect())
            return
        }
        let hadLookupPlaceholder = lookupPlaceholderShown
        lookupPlaceholderShown = false

        if !effect.buffer.isEmpty {
            let selRange = NSRange(location: effect.buffer.utf16.count, length: 0)
            client.setMarkedText(effect.buffer, selectionRange: selRange, replacementRange: notFound)
            onOverlayUpdate?(effect.overlay, nil, client.cursorLineRect())
        } else {
            // Clear marked text only if this key ended a composition. With none active,
            // an empty setMarkedText would replace (delete) the user's selection.
            if wasComposing || hadLookupPlaceholder, effect.committedText == nil {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
            }
            // 可反悔的送出之後留一行提示。游標矩形給零，浮窗就留在剛才組字的位置。
            revertHint = effect.revertible ? effect.revertPreview : nil
            // 被擋下的提示與選項列一樣自己問游標位置：閒置時打出的結尾沒有組字位置可沿用。
            onOverlayUpdate?(nil, nil, pairSwitchNotice == nil ? .zero : client.cursorLineRect())
        }
    }

    /// 送出文字，並記下宿主事後讀不讀得回它。
    private func insert(_ text: String, replacementRange: NSRange, into client: IMKTextClientProtocol) {
        // 字數不變的取代先記下宿主現在回報的內容，之後讀回時用來認出還沒更新的回報。
        // 其他送出都會移動游標，宿主會跟上，舊的紀錄到此作廢。
        if replacementRange.location != NSNotFound, replacementRange.length > 0,
           replacementRange.length == text.utf16.count,
           let old = client.attributedSubstring(from: replacementRange)?.string, old != text {
            staleEcho = StaleEcho(range: replacementRange, old: old, new: text)
        } else {
            staleEcho = nil
        }
        client.insertText(text, replacementRange: replacementRange)
        guard !text.isEmpty else { return }
        readback.didCommit(cursorLocation: client.selectedRange().location) {
            rangeBeforeCursor(of: text, client: client) != nil
        }
    }

    /// 把可反悔的送出放成標記文字。組字中的原字母就是宿主現有的那段標記，直接被它取代。
    /// `replacementRange` 不是 NSNotFound 時，連游標前那一段（要收合的尾端空格）一起取代。
    private func stage(
        _ text: String,
        replacing replacementRange: NSRange = NSRange(location: NSNotFound, length: 0),
        in client: IMKTextClientProtocol
    ) {
        stagedCommit = text
        client.setMarkedText(
            text,
            selectionRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: replacementRange
        )
    }

    /// 可反悔的送出能不能照常立即送出、事後再取代。在送出前呼叫，這時原字母還是宿主的標記文字。
    /// 組字時游標應在標記文字之後，位置 0 代表回報不可信。從閒置送出標點時，
    /// 位置 0 可能真的是文件開頭，也可能是不回報游標的終端機，送出前分不出來：
    /// 這個欄位已經確認讀得回就立即送出，還沒送出過就先暫存一個按鍵，落地時再觀察。
    private func canReplaceCommittedText(in client: IMKTextClientProtocol, hadMarkedText: Bool) -> Bool {
        guard readback.allowsReplacing, client.supportsDocumentAccess() else {
            return false
        }
        let sel = client.selectedRange()
        guard sel.location != NSNotFound else {
            return false
        }
        return sel.location > 0 || (!hadMarkedText && readback == .mayReplace)
    }

    /// 讀宿主的一段文字。範圍碰到剛做過的等長取代、而宿主回報的還是取代前的內容時，
    /// 補上取代後的內容；宿主回報的是別的內容就照實回傳，並且不再補。
    private func hostString(in range: NSRange, client: IMKTextClientProtocol) -> String? {
        guard let echo = staleEcho, NSIntersectionRange(range, echo.range).length > 0 else {
            return client.attributedSubstring(from: range)?.string
        }
        let union = NSUnionRange(range, echo.range)
        guard let raw = client.attributedSubstring(from: union)?.string,
              (raw as NSString).length == union.length else {
            staleEcho = nil
            return client.attributedSubstring(from: range)?.string
        }
        let echoInUnion = NSRange(location: echo.range.location - union.location, length: echo.range.length)
        let rangeInUnion = NSRange(location: range.location - union.location, length: range.length)
        guard (raw as NSString).substring(with: echoInUnion) == echo.old else {
            staleEcho = nil
            return (raw as NSString).substring(with: rangeInUnion)
        }
        let patched = (raw as NSString).replacingCharacters(in: echoInUnion, with: echo.new)
        return (patched as NSString).substring(with: rangeInUnion)
    }

    /// 游標前如果正好是 `text`，回傳它的範圍。宿主不回報游標、有選取範圍、讀不到或內容不符都回傳 nil。
    private func rangeBeforeCursor(of text: String, client: IMKTextClientProtocol) -> NSRange? {
        let length = text.utf16.count
        let sel = client.selectedRange()
        guard length > 0, sel.location != NSNotFound, sel.length == 0, sel.location >= length else {
            return nil
        }
        let range = NSRange(location: sel.location - length, length: length)
        guard hostString(in: range, client: client) == text else {
            return nil
        }
        return range
    }

    private func dismissCommitHints(onOverlayUpdate: OverlayUpdate?) {
        guard revertHint != nil || pairChoice != nil || pairSwitchNotice != nil
                || engine.chineseContinuation != nil else { return }
        engine.dismissChineseContinuation()
        revertHint = nil
        pairChoice = nil
        pairSwitchNotice = nil
        onOverlayUpdate?(nil, nil, .zero)
    }

    /// 外層放棄一次反悔：丟掉紀錄、吃掉按鍵，文件與暫存都不動。
    /// 放棄的是涵蓋更早送出的紀錄（成對切換）時，換上一行提示說明原因，否則使用者只看到按了沒反應；
    /// 其餘紀錄照舊只收掉提示。
    private func abandonRevert(
        of record: RevertRecord,
        client: IMKTextClientProtocol,
        onOverlayUpdate: OverlayUpdate?
    ) {
        engine.discardRevertRecord()
        guard record.spansEarlierCommits else {
            dismissCommitHints(onOverlayUpdate: onOverlayUpdate)
            return
        }
        engine.dismissChineseContinuation()
        revertHint = nil
        pairChoice = nil
        pairSwitchNotice = .hostReadbackUnavailable
        onOverlayUpdate?(nil, nil, client.cursorLineRect())
    }

    /// Range of the auto-inserted trailing space to replace, or NSNotFound to insert at the
    /// cursor when the client cannot confirm that the space is really there.
    private func backwardReplacementRange(count: Int, client: IMKTextClientProtocol) -> NSRange {
        let notFound = NSRange(location: NSNotFound, length: 0)
        guard count > 0 else {
            return notFound
        }
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.length == 0, sel.location >= count else {
            return notFound
        }
        let range = NSRange(location: sel.location - count, length: count)
        guard hostString(in: range, client: client) == String(repeating: " ", count: count) else {
            return notFound
        }
        return range
    }

    /// A key the IME does not interpret (shortcut, arrow, function key) goes to the client.
    /// Commit first so the client does not act on marked text the engine still owns, then
    /// forget the mirrored context since the key may move the cursor or edit the document.
    private func releaseKeyToClient(
        _ client: IMKTextClientProtocol,
        onOverlayUpdate: OverlayUpdate?
    ) {
        statistics?.hostEndedComposition(engine: engine, deliversText: true)
        settleComposition(client: client, onOverlayUpdate: onOverlayUpdate)
        // 游標可能已經移動，片段語境跟著前文鏡像一起結束。
        engine.noteExternalCursorMovement()
    }

    /// 宿主或使用者主動結束組字：除了把組字落地，片段語境也到此結束，
    /// 因為游標之後可能已經不在那個反引號後面。
    func commitComposition(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil
    ) {
        statistics?.hostEndedComposition(engine: engine, deliversText: client != nil)
        settleComposition(client: client, onOverlayUpdate: onOverlayUpdate)
        engine.endSnippetContext()
    }

    /// 只把進行中的組字落地，不碰片段語境。引擎放行的按鍵走這條：閒置的退格仍在片段裡，
    /// 真的要結束語境的按鍵（Enter、Tab、方向鍵）由引擎自己判定。
    private func settleComposition(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate?
    ) {
        engine.dismissChineseContinuation()
        revertHint = nil
        pairChoice = nil
        pairSwitchNotice = nil
        // 按鍵交還宿主或組字被結束之後，文件可能已經變了，不再替宿主補上取代後的內容。
        staleEcho = nil
        if lookupPlaceholderShown {
            // 暫時的讀音或符號標記不是使用者要的文字，結束組字前先清掉，宿主才不會把它寫進文件。
            lookupPlaceholderShown = false
            client?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        if let staged = stagedCommit {
            // 暫存的文字是使用者已經送出的，這裡正式交給宿主，只送這一次。
            stagedCommit = nil
            if let client {
                insert(staged, replacementRange: NSRange(location: NSNotFound, length: 0), into: client)
            }
        }
        // 宿主結束一般選字也會採用焦點候選，此時可能沒有對應的按鍵事件。
        if !engine.buffer.isEmpty, let usageStore {
            engine.usageHistory = usageStore.history
        }
        if let committed = engine.finishHostComposition() {
            usageStore?.update(engine.usageHistory)
            client?.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        onOverlayUpdate?(nil, nil, .zero)
    }

    func resetForFocusChange(onOverlayUpdate: OverlayUpdate? = nil) {
        statistics?.reset()
        engine.resetContext()
        translator = EventTranslator()
        readback = .unverified
        staleEcho = nil
        lookupPlaceholderShown = false
        // 失焦時宿主已經透過 `commitComposition` 收下暫存的文字。走到這裡還有的話
        // 也不能帶進新欄位。
        stagedCommit = nil
        revertHint = nil
        pairChoice = nil
        pairSwitchNotice = nil
        onOverlayUpdate?(nil, nil, .zero)
    }

    func savePreferences() {
        preferences?.save(engine.configuration)
    }

    /// 游標前的文字，以及它是不是沒讀到文件開頭。引擎靠後者分辨「確定沒有開頭」與「看不到」。
    private func readLeadingContext(from client: IMKTextClientProtocol) -> (text: String, isClipped: Bool)? {
        let sel = client.selectedRange()
        guard readback != .cursorStaysAtZero, sel.location != NSNotFound else {
            return nil
        }
        if sel.location == 0 {
            return ("", false)
        }
        let len = min(InputEngine.contextWindowLength + 1, sel.location)
        let range = NSRange(location: sel.location - len, length: len)
        guard let text = hostString(in: range, client: client), !text.isEmpty else {
            return nil
        }
        // A window that does not reach the start of the document may begin in the middle of
        // a surrogate pair (Han characters beyond the BMP). The orphaned half bridges to
        // U+FFFD and would never match the engine's mirror, so the first character of a
        // clipped window is read only to be discarded.
        return len < sel.location ? (String(text.dropFirst()), true) : (text, false)
    }
}

@objc(GoshawkInputController)
final class GoshawkInputController: IMKInputController {
    private let preferences = PreferencesStore()
    private var statisticsProtection = StatisticsInputProtection()
    private var preferencesObserver: NSObjectProtocol?
    private lazy var overlayFontSizeFollower = OverlayFontSizeFollower(preferences: preferences)
    private lazy var coordinator = InputSessionCoordinator(
        configuration: preferences.loadConfiguration(),
        preferences: preferences,
        usageStore: .shared,
        statistics: StatisticsSession(store: .shared) { [weak self] in
            self?.statisticsProtection.suspended(secureEventInput: IsSecureEventInputEnabled()) ?? true
        }
    )

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        statisticsProtection.set(value, forTag: tag)
        super.setValue(value, forTag: tag, client: sender)
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.union(.flagsChanged).rawValue)
    }

    deinit {
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        observePreferenceChangesIfNeeded()
        coordinator.engine.configuration = preferences.loadConfiguration()
        overlayFontSizeFollower.apply()
        coordinator.resetForFocusChange(onOverlayUpdate: overlayUpdater())
        // 燈號可能在其他輸入來源或欄位裡切換過，取得焦點時以實際旗標為準。
        coordinator.syncCapsLock(isOn: NSEvent.modifierFlags.contains(.capsLock), client: nil)
        MainActor.assumeIsolated { UpdateChecker.shared.checkIfDue() }
    }

    override func deactivateServer(_ sender: Any!) {
        let adapter = (sender as? IMKTextInput).map(IMKClientAdapter.init)
        coordinator.commitComposition(client: adapter, onOverlayUpdate: overlayUpdater())
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        let adapter = (sender as? IMKTextInput).map(IMKClientAdapter.init)
        coordinator.commitComposition(client: adapter, onOverlayUpdate: overlayUpdater())
    }

    /// 系統要輸入法收起所有看得見的介面（切換輸入來源、宿主失去焦點）。
    /// 只收浮窗與疊加層的面板，不動組字：下一個按鍵會照引擎的狀態重新顯示。
    override func hidePalettes() {
        super.hidePalettes()
        MainActor.assumeIsolated {
            CandidateOverlayPanel.shared.update(
                overlay: nil,
                layerPanel: nil,
                cursorRect: .zero,
                showsEnglishActions: false
            )
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        let received = DispatchTime.now().uptimeNanoseconds
        guard let event,
              let payload = KeyEventPayload(event: event),
              let input = sender as? IMKTextInput else {
            return false
        }
        let adapter = IMKClientAdapter(input: input)
        return coordinator.handlePayload(payload, client: adapter, received: received, onOverlayUpdate: overlayUpdater())
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: UIText.productName.text)

        if let version = MainActor.assumeIsolated({ UpdateChecker.shared.availableVersion }) {
            let updateItem = NSMenuItem(
                title: UIText.menuUpdateAvailable.text(version.description),
                action: #selector(openReleasePage(_:)),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let pureEnglishItem = NSMenuItem(
            title: UIText.menuPureEnglish.text,
            action: #selector(togglePureEnglish(_:)),
            keyEquivalent: ""
        )
        pureEnglishItem.state = coordinator.engine.state == .pureEnglish ? .on : .off
        pureEnglishItem.target = self
        menu.addItem(pureEnglishItem)

        let mixedModeItem = NSMenuItem(
            title: UIText.menuMixedMode.text,
            action: #selector(toggleMixedMode(_:)),
            keyEquivalent: ""
        )
        mixedModeItem.state = coordinator.engine.configuration.mixedModeEnabled ? .on : .off
        mixedModeItem.target = self
        menu.addItem(mixedModeItem)

        menu.addItem(.separator())

        let autoSpaceItem = NSMenuItem(
            title: UIText.menuAutoSpace.text,
            action: #selector(toggleAutoSpace(_:)),
            keyEquivalent: ""
        )
        autoSpaceItem.state = coordinator.engine.configuration.autoSpaceEnabled ? .on : .off
        autoSpaceItem.target = self
        menu.addItem(autoSpaceItem)

        // 與 `goshawk.autoPunctuationEnabled` 共用同一個偏好，勾選狀態取反。
        let halfwidthPunctItem = NSMenuItem(
            title: UIText.menuHalfwidthPunctuation.text,
            action: #selector(toggleHalfwidthPunctuation(_:)),
            keyEquivalent: "H"
        )
        halfwidthPunctItem.keyEquivalentModifierMask = [.option, .shift]
        halfwidthPunctItem.state = coordinator.engine.configuration.autoPunctuationEnabled ? .off : .on
        halfwidthPunctItem.target = self
        menu.addItem(halfwidthPunctItem)

        let devVocabItem = NSMenuItem(
            title: UIText.menuDeveloperVocabulary.text,
            action: #selector(toggleDeveloperVocab(_:)),
            keyEquivalent: ""
        )
        devVocabItem.state = coordinator.engine.configuration.developerVocabularyEnabled ? .on : .off
        devVocabItem.target = self
        menu.addItem(devVocabItem)

        let ctrlBracketsItem = NSMenuItem(
            title: UIText.menuCtrlBrackets.text,
            action: #selector(toggleCtrlBrackets(_:)),
            keyEquivalent: ""
        )
        ctrlBracketsItem.state = coordinator.engine.configuration.ctrlBracketsQuotesEnabled ? .on : .off
        ctrlBracketsItem.target = self
        menu.addItem(ctrlBracketsItem)

        menu.addItem(.separator())

        // 快捷鍵與這一項走同一條路。重新指定快捷鍵這一版還沒做。
        let readingLookupItem = NSMenuItem(
            title: UIText.readingLookup.text,
            action: #selector(toggleReadingLookup(_:)),
            keyEquivalent: ";"
        )
        readingLookupItem.keyEquivalentModifierMask = [.control, .shift]
        readingLookupItem.state = coordinator.engine.readingLookup == nil ? .off : .on
        readingLookupItem.target = self
        menu.addItem(readingLookupItem)

        let symbolPanelItem = NSMenuItem(
            title: UIText.symbolPanel.text,
            action: #selector(toggleSymbolPanel(_:)),
            keyEquivalent: "B"
        )
        symbolPanelItem.keyEquivalentModifierMask = [.option, .shift]
        symbolPanelItem.state = coordinator.engine.symbolPanel == nil ? .off : .on
        symbolPanelItem.target = self
        menu.addItem(symbolPanelItem)

        menu.addItem(.separator())

        let cj5Item = NSMenuItem(
            title: UIText.cangjieV5.text,
            action: #selector(selectCangjieV5(_:)),
            keyEquivalent: ""
        )
        cj5Item.state = coordinator.engine.configuration.cangjieVersion == .v5 ? .on : .off
        cj5Item.target = self

        let cj3Item = NSMenuItem(
            title: UIText.cangjieV3.text,
            action: #selector(selectCangjieV3(_:)),
            keyEquivalent: ""
        )
        cj3Item.state = coordinator.engine.configuration.cangjieVersion == .v3 ? .on : .off
        cj3Item.target = self
        // 預設的三代排前面。
        menu.addItem(cj3Item)
        menu.addItem(cj5Item)

        menu.addItem(.separator())

        let clearHistoryItem = NSMenuItem(
            title: UIText.menuClearHistory.text,
            action: #selector(clearUsageHistory(_:)),
            keyEquivalent: ""
        )
        clearHistoryItem.target = self
        menu.addItem(clearHistoryItem)

        menu.addItem(.separator())

        let guideItem = NSMenuItem(
            title: UIText.menuGuide.text,
            action: #selector(openGuide(_:)),
            keyEquivalent: ""
        )
        guideItem.target = self
        menu.addItem(guideItem)

        let settingsItem = NSMenuItem(
            title: UIText.menuSettings.text,
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        return menu
    }

    @objc private func togglePureEnglish(_ sender: Any?) {
        coordinator.togglePureEnglish(client: currentClientAdapter(), onOverlayUpdate: overlayUpdater())
    }

    @objc private func toggleReadingLookup(_ sender: Any?) {
        coordinator.toggleReadingLookup(client: currentClientAdapter(), onOverlayUpdate: overlayUpdater())
    }

    @objc private func toggleSymbolPanel(_ sender: Any?) {
        coordinator.toggleSymbolPanel(client: currentClientAdapter(), onOverlayUpdate: overlayUpdater())
    }

    @objc private func toggleMixedMode(_ sender: Any?) {
        updateConfiguration { $0.mixedModeEnabled.toggle() }
    }

    @objc private func toggleAutoSpace(_ sender: Any?) {
        updateConfiguration { $0.autoSpaceEnabled.toggle() }
    }

    @objc private func toggleHalfwidthPunctuation(_ sender: Any?) {
        coordinator.toggleHalfwidthPunctuation()
    }

    @objc private func toggleDeveloperVocab(_ sender: Any?) {
        updateConfiguration { $0.developerVocabularyEnabled.toggle() }
    }

    @objc private func toggleCtrlBrackets(_ sender: Any?) {
        updateConfiguration { $0.ctrlBracketsQuotesEnabled.toggle() }
    }

    @objc private func selectCangjieV5(_ sender: Any?) {
        updateConfiguration { $0.cangjieVersion = .v5 }
    }

    @objc private func selectCangjieV3(_ sender: Any?) {
        updateConfiguration { $0.cangjieVersion = .v3 }
    }

    @objc private func clearUsageHistory(_ sender: Any?) {
        do {
            try coordinator.clearUsageHistory()
        } catch {
            MainActor.assumeIsolated { _ = NSAlert(error: error).runModal() }
        }
    }

    @objc private func openReleasePage(_ sender: Any?) {
        NSWorkspace.shared.open(UpdateChecker.releasePage)
    }

    @objc private func openGuide(_ sender: Any?) {
        coordinator.commitComposition(client: currentClientAdapter(), onOverlayUpdate: overlayUpdater())
        MainActor.assumeIsolated {
            GuideLauncher.open()
        }
    }

    /// 開設定視窗前先結束組字並關閉反查，使用者回來時才不會接到半截的緩衝。
    @objc private func openSettings(_ sender: Any?) {
        coordinator.commitComposition(client: currentClientAdapter(), onOverlayUpdate: overlayUpdater())
        MainActor.assumeIsolated {
            SettingsWindowController.shared.show()
        }
    }

    /// 設定視窗改完偏好後，作用中的控制器在這裡跟上。
    private func observePreferenceChangesIfNeeded() {
        guard preferencesObserver == nil else { return }
        let box = ControllerBox(controller: self)
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .goshawkPreferencesDidChange,
            object: nil,
            queue: .main
        ) { _ in
            guard let controller = box.controller else { return }
            controller.coordinator.reloadConfiguration(
                client: controller.currentClientAdapter(),
                onOverlayUpdate: controller.overlayUpdater()
            )
        }
    }

    private func currentClientAdapter() -> IMKClientAdapter? {
        (client() as IMKTextInput?).map(IMKClientAdapter.init)
    }

    private func updateConfiguration(_ change: (inout EngineConfiguration) -> Void) {
        coordinator.updateConfiguration(
            client: currentClientAdapter(),
            onOverlayUpdate: overlayUpdater(),
            change
        )
    }

    private func overlayUpdater() -> OverlayUpdate {
        { [weak self] overlay, layerPanel, rect in
            self?.updateOverlay(overlay, layerPanel: layerPanel, rect: rect)
        }
    }

    private func updateOverlay(_ overlay: OverlayState?, layerPanel: LayerPanelContent?, rect: NSRect) {
        let showsEnglishActions = coordinator.englishActionsAvailable
        let continuation = coordinator.engine.chineseContinuation
        let revertHint = coordinator.revertHint
        let pairChoice = coordinator.pairChoice
        let pairSwitchNotice = coordinator.pairSwitchNotice
        if layerPanel != nil { bindReadingPanelToCurrentClient() }
        MainActor.assumeIsolated {
            CandidateOverlayPanel.shared.update(
                overlay: overlay,
                layerPanel: layerPanel,
                cursorRect: rect,
                showsEnglishActions: showsEnglishActions,
                revertHint: revertHint,
                pairChoice: pairChoice,
                pairSwitchNotice: pairSwitchNotice,
                continuation: continuation
            )
        }
    }

    /// 反查面板的點選入口。IMK 的按鍵回呼與面板的滑鼠事件都在主執行緒，
    /// 控制器只會在主執行緒被碰到，所以用 Sendable 的弱參照盒子交給 @MainActor 的面板。
    private struct ControllerBox: @unchecked Sendable {
        weak var controller: GoshawkInputController?
    }

    private func bindReadingPanelToCurrentClient() {
        let box = ControllerBox(controller: self)
        MainActor.assumeIsolated {
            let panel = CandidateOverlayPanel.shared
            panel.onReadingRowClick = { row in
                guard let controller = box.controller else { return }
                controller.coordinator.pickReadingLookupRow(
                    row,
                    client: controller.currentClientAdapter(),
                    onOverlayUpdate: controller.overlayUpdater()
                )
            }
            panel.onReadingSchemeClick = {
                guard let controller = box.controller else { return }
                controller.coordinator.toggleReadingScheme(
                    client: controller.currentClientAdapter(),
                    onOverlayUpdate: controller.overlayUpdater()
                )
            }
            panel.onSymbolRowClick = { row in
                guard let controller = box.controller else { return }
                controller.coordinator.pickSymbolPanelRow(
                    row,
                    client: controller.currentClientAdapter(),
                    onOverlayUpdate: controller.overlayUpdater()
                )
            }
            panel.onSymbolTabClick = { tab in
                guard let controller = box.controller else { return }
                controller.coordinator.selectSymbolPanelTab(
                    tab,
                    client: controller.currentClientAdapter(),
                    onOverlayUpdate: controller.overlayUpdater()
                )
            }
        }
    }
}
