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

/// 畫面更新回呼：雙軌內容、反查面板內容與定位用的游標矩形。
/// 反查面板不是 nil 時，顯示端以它取代雙軌內容。
typealias OverlayUpdate = (OverlayState?, ReadingLookupPanel?, NSRect) -> Void

final class InputSessionCoordinator {
    var engine: InputEngine
    var translator = EventTranslator()
    private let preferences: PreferencesStore?
    private let usageStore: UsageHistoryStore?
    /// 有些終端機不論游標在哪都回報位置 0。剛送出文字後仍在 0 就代表回報不可信，
    /// 之後改用引擎自己記住的前文，直到換欄位為止。
    private var clientReportsCursor = true
    /// 從閒置開啟反查時，宿主的標記文字是暫時放上去的讀音。
    private var lookupPlaceholderShown = false
    /// 這個欄位最近一次送出文字後，宿主讀不讀得回那段文字。還沒送出過是 nil。
    /// 讀不回（終端機、拒絕回讀的編輯器）就刪不掉已送出的字，可反悔的送出改用暫存。
    private var clientReadsBackCommits: Bool?
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

    init(
        configuration: EngineConfiguration,
        preferences: PreferencesStore? = nil,
        usageStore: UsageHistoryStore? = nil
    ) {
        self.engine = InputEngine(configuration: configuration)
        self.preferences = preferences
        self.usageStore = usageStore
    }

    func clearUsageHistory() {
        usageStore?.clear()
        engine.usageHistory = UsageHistory()
    }

    var englishActionsAvailable: Bool {
        engine.configuration.mixedModeEnabled && (engine.state == .composingDual || engine.state == .composingEnglishOnly)
    }

    func handlePayload(
        _ payload: KeyEventPayload,
        client: IMKTextClientProtocol,
        onOverlayUpdate: OverlayUpdate? = nil
    ) -> Bool {
        // 系統若把 Caps Lock 攔為輸入來源切換鍵，旗標不會亮，這裡就不會進入半形層。
        syncCapsLock(
            isOn: payload.modifierFlags.contains(.capsLock),
            client: client,
            onOverlayUpdate: onOverlayUpdate
        )

        // 其他宿主程式裡學到或清除的紀錄，在這裡跟上。
        if let usageStore {
            engine.usageHistory = usageStore.history
        }
        defer { usageStore?.update(engine.usageHistory) }

        let wasComposing = !engine.buffer.isEmpty
        let configurationBefore = engine.configuration
        let event = translator.translate(payload, readingLookupActive: engine.readingLookup != nil) {
            englishActionsAvailable && engine.currentOverlay?.englishTrack.predictions.isEmpty == false
        }
        let keyInput: KeyInput
        switch event {
        case .key(let key):
            keyInput = key
        case .toggleHalfwidthPunctuation where !engine.isLiteralLayer:
            toggleHalfwidthPunctuation()
            // 改設定讓反悔紀錄作廢，提示跟著收掉。暫存中的文字等下一個按鍵照常送出。
            dismissRevertHint(onOverlayUpdate: onOverlayUpdate)
            return true
        case .toggleHalfwidthPunctuation, nil:
            if payload.isKeyDown {
                releaseKeyToClient(client, onOverlayUpdate: onOverlayUpdate)
            }
            return false
        }

        // 反悔要把剛送出的文字換掉。暫存中的文字直接換；已經正式送出的，先讀回確認它還在
        // 游標前才取代，讀不到或不符就放棄這次反悔，什麼都不送，絕不盲目回刪。
        let isRevert = keyInput == .shiftSpace && engine.revertRecord != nil
        var revertRange: NSRange?
        if isRevert, stagedCommit == nil, let record = engine.revertRecord {
            guard let range = rangeBeforeCursor(of: record.committedText, client: client) else {
                // 這個欄位之後的可反悔送出改用暫存，下一次就換得了。
                clientReadsBackCommits = false
                engine.discardRevertRecord()
                dismissRevertHint(onOverlayUpdate: onOverlayUpdate)
                return true
            }
            revertRange = range
        }

        // 暫存中的文字宿主還沒收下，前文以引擎記住的為準；反悔沿用送出時的前文。
        if !wasComposing, stagedCommit == nil, !isRevert {
            engine.syncExternalContext(readLeadingContext(from: client))
        }

        let effect = engine.handle(keyInput)
        guard effect.handled else {
            // The engine only forwards keys while idle; commit anyway rather than leave a
            // live buffer behind a key the client is about to act on.
            // 放行不代表組字結束，片段語境留給引擎判定：閒置的退格還在片段裡。
            settleComposition(client: client, onOverlayUpdate: onOverlayUpdate)
            return false
        }

        if isRevert, effect.revertible, let swapped = effect.committedText {
            if let revertRange {
                insert(swapped, replacementRange: revertRange, into: client)
            } else {
                stage(swapped, in: client)
            }
            revertHint = effect.revertPreview
            onOverlayUpdate?(nil, nil, .zero)
        } else {
            apply(effect, to: client, wasComposing: wasComposing, onOverlayUpdate: onOverlayUpdate)
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
        sendToReadingLookup(.readingLookupPick(row), client: client, onOverlayUpdate: onOverlayUpdate)
    }

    /// 點選面板上的「注音｜拼音」分段按鈕，與面板裡按 Tab 同一條路。
    func toggleReadingScheme(client: IMKTextClientProtocol?, onOverlayUpdate: OverlayUpdate? = nil) {
        guard engine.readingLookup != nil else { return }
        sendToReadingLookup(.tab, client: client, onOverlayUpdate: onOverlayUpdate)
    }

    private func sendToReadingLookup(
        _ key: KeyInput,
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate?
    ) {
        let wasComposing = !engine.buffer.isEmpty
        let configurationBefore = engine.configuration
        let effect = engine.handle(key)
        if let client {
            apply(effect, to: client, wasComposing: wasComposing, onOverlayUpdate: onOverlayUpdate)
        } else {
            onOverlayUpdate?(nil, nil, .zero)
        }
        if engine.configuration != configurationBefore {
            savePreferences()
        }
    }

    /// Toggles pure English mode from the menu, delivering any buffer the engine commits.
    func togglePureEnglish(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate? = nil
    ) {
        engine.dismissReadingLookup()
        let wasComposing = !engine.buffer.isEmpty
        let effect = engine.handle(.doubleShift)
        if let client {
            apply(effect, to: client, wasComposing: wasComposing, onOverlayUpdate: onOverlayUpdate)
        } else {
            onOverlayUpdate?(nil, nil, .zero)
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
        let wasComposing = !engine.buffer.isEmpty
        let effect = engine.handle(.capsLock(isOn))
        if let client {
            apply(effect, to: client, wasComposing: wasComposing, onOverlayUpdate: onOverlayUpdate)
        } else {
            onOverlayUpdate?(nil, nil, .zero)
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
        onOverlayUpdate: OverlayUpdate?
    ) {
        let notFound = NSRange(location: NSNotFound, length: 0)
        revertHint = nil

        // 暫存中的文字在這個按鍵落地，而且只送這一次。這個按鍵要收合的尾端空格
        // 就是暫存字串的尾端空格，直接在字串上收掉，不必向宿主回刪。
        var deleteCount = effect.deletedBackwardCount
        if var staged = stagedCommit {
            stagedCommit = nil
            if deleteCount > 0, staged.hasSuffix(String(repeating: " ", count: deleteCount)) {
                staged.removeLast(deleteCount)
                deleteCount = 0
            }
            insert(staged, replacementRange: notFound, into: client)
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

        if let readingPanel = effect.readingLookupPanel {
            // 有原字母時它留在宿主的標記文字裡，這裡不碰。從閒置開啟時宿主沒有標記文字，
            // 終端機會把 Enter 直接交給裡面的程式而不經過輸入法，所以用讀音當暫時的標記文字。
            // 有選取範圍時不放，否則取消後選取的文字就被吃掉了。
            if effect.buffer.isEmpty, lookupPlaceholderShown || client.selectedRange().length == 0 {
                let text = readingPanel.inputDisplay.isEmpty ? "？" : readingPanel.inputDisplay
                let selRange = NSRange(location: text.utf16.count, length: 0)
                client.setMarkedText(text, selectionRange: selRange, replacementRange: notFound)
                lookupPlaceholderShown = true
            }
            onOverlayUpdate?(effect.overlay, readingPanel, client.cursorLineRect())
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
            onOverlayUpdate?(nil, nil, .zero)
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
        if client.selectedRange().location == 0 {
            clientReportsCursor = false
        }
        clientReadsBackCommits = clientReportsCursor && rangeBeforeCursor(of: text, client: client) != nil
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
    /// 每個訊號都要過，拿不準就用暫存（它在所有宿主都正確，只是字會多留一個按鍵的底線）：
    /// 宿主沒有明說不支援文件存取；送出後游標沒有停在 0 過；上一次送出讀得回來，或還沒送出過；
    /// 而且現在游標不在 0。`hadMarkedText` 為真時游標在標記文字後面，誠實的宿主不可能回報 0，
    /// 終端機則不論何時都回報 0；沒有標記文字時（標點自己送出）文件開頭的 0 是真的，
    /// 不能拿它當訊號，這種宿主會在第一次送出之後就被認出來。
    private func canReplaceCommittedText(in client: IMKTextClientProtocol, hadMarkedText: Bool) -> Bool {
        guard clientReportsCursor, clientReadsBackCommits != false, client.supportsDocumentAccess() else {
            return false
        }
        let sel = client.selectedRange()
        guard sel.location != NSNotFound else {
            return false
        }
        return hadMarkedText ? sel.location > 0 : true
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

    private func dismissRevertHint(onOverlayUpdate: OverlayUpdate?) {
        guard revertHint != nil else { return }
        revertHint = nil
        onOverlayUpdate?(nil, nil, .zero)
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
        settleComposition(client: client, onOverlayUpdate: onOverlayUpdate)
        engine.endSnippetContext()
    }

    /// 只把進行中的組字落地，不碰片段語境。引擎放行的按鍵走這條：閒置的退格仍在片段裡，
    /// 真的要結束語境的按鍵（Enter、Tab、方向鍵）由引擎自己判定。
    private func settleComposition(
        client: IMKTextClientProtocol?,
        onOverlayUpdate: OverlayUpdate?
    ) {
        // 先丟掉反查，否則下面的 Enter 會變成選字，宿主就收到了反查的候選字。
        engine.dismissReadingLookup()
        // 組字到此結束，之後游標可能已經不在剛送出的文字後面，不再反悔。
        engine.discardRevertRecord()
        revertHint = nil
        // 按鍵交還宿主或組字被結束之後，文件可能已經變了，不再替宿主補上取代後的內容。
        staleEcho = nil
        if lookupPlaceholderShown {
            // 暫時的讀音標記不是使用者要的文字，結束組字前先清掉，宿主才不會把它寫進文件。
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
        guard !engine.buffer.isEmpty else {
            onOverlayUpdate?(nil, nil, .zero)
            return
        }
        let effect = engine.handle(.enter)
        if let committed = effect.committedText {
            client?.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        onOverlayUpdate?(nil, nil, .zero)
    }

    func resetForFocusChange(onOverlayUpdate: OverlayUpdate? = nil) {
        engine.resetContext()
        translator = EventTranslator()
        clientReportsCursor = true
        clientReadsBackCommits = nil
        staleEcho = nil
        lookupPlaceholderShown = false
        // 失焦時宿主已經透過 `commitComposition` 收下暫存的文字。走到這裡還有的話
        // 也不能帶進新欄位。
        stagedCommit = nil
        revertHint = nil
        onOverlayUpdate?(nil, nil, .zero)
    }

    func savePreferences() {
        preferences?.save(engine.configuration)
    }

    private func readLeadingContext(from client: IMKTextClientProtocol) -> String? {
        let sel = client.selectedRange()
        guard clientReportsCursor, sel.location != NSNotFound else {
            return nil
        }
        if sel.location == 0 {
            return ""
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
        return len < sel.location ? String(text.dropFirst()) : text
    }
}

@objc(GoshawkInputController)
final class GoshawkInputController: IMKInputController {
    private let preferences = PreferencesStore()
    private var didInstallPanelCallbacks = false
    private var preferencesObserver: NSObjectProtocol?
    private lazy var coordinator = InputSessionCoordinator(
        configuration: preferences.loadConfiguration(),
        preferences: preferences,
        usageStore: .shared
    )

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
        coordinator.resetForFocusChange(onOverlayUpdate: overlayUpdater())
        // 燈號可能在其他輸入來源或欄位裡切換過，取得焦點時以實際旗標為準。
        coordinator.syncCapsLock(isOn: NSEvent.modifierFlags.contains(.capsLock), client: nil)
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
    /// 只收浮窗與反查面板，不動組字：下一個按鍵會照引擎的狀態重新顯示。
    override func hidePalettes() {
        super.hidePalettes()
        MainActor.assumeIsolated {
            CandidateOverlayPanel.shared.update(
                overlay: nil,
                readingPanel: nil,
                cursorRect: .zero,
                showsEnglishActions: false
            )
        }
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event,
              let payload = KeyEventPayload(event: event),
              let input = sender as? IMKTextInput else {
            return false
        }
        let adapter = IMKClientAdapter(input: input)
        return coordinator.handlePayload(payload, client: adapter, onOverlayUpdate: overlayUpdater())
    }

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: UIText.productName.text)

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
        coordinator.clearUsageHistory()
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
        { [weak self] overlay, readingPanel, rect in
            self?.updateOverlay(overlay, readingPanel: readingPanel, rect: rect)
        }
    }

    private func updateOverlay(_ overlay: OverlayState?, readingPanel: ReadingLookupPanel?, rect: NSRect) {
        let showsEnglishActions = coordinator.englishActionsAvailable
        let revertHint = coordinator.revertHint
        installPanelCallbacksIfNeeded()
        MainActor.assumeIsolated {
            CandidateOverlayPanel.shared.update(
                overlay: overlay,
                readingPanel: readingPanel,
                cursorRect: rect,
                showsEnglishActions: showsEnglishActions,
                revertHint: revertHint
            )
        }
    }

    /// 反查面板的點選入口。IMK 的按鍵回呼與面板的滑鼠事件都在主執行緒，
    /// 控制器只會在主執行緒被碰到，所以用 Sendable 的弱參照盒子交給 @MainActor 的面板。
    private struct ControllerBox: @unchecked Sendable {
        weak var controller: GoshawkInputController?
    }

    private func installPanelCallbacksIfNeeded() {
        guard !didInstallPanelCallbacks else { return }
        didInstallPanelCallbacks = true
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
        }
    }
}
