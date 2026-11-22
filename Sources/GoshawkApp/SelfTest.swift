import AppKit
import Foundation
import InputMethodKit
import GoshawkCore

final class FakeIMKClient: IMKTextClientProtocol {
    var text: String = ""
    var markedText: String = ""
    var allowsReadingText = true
    var lastOverlay: OverlayState?
    var cursorRect = NSRect(x: 100, y: 200, width: 2, height: 18)

    /// 宿主實際收下的每一段文字，用來確認暫存的文字只被送出一次。
    var insertedStrings: [String] = []
    /// 宿主對「是否支援文件存取」的回答。
    var declaresDocumentAccess = true

    func supportsDocumentAccess() -> Bool {
        declaresDocumentAccess
    }

    /// 模擬 VS Code：字數不變的取代之後，回報給輸入法的文字停在取代前，下一次一般送出才跟上。
    var keepsStaleTextAfterEqualLengthReplacement = false
    private var staleReportedText: String?

    /// 模擬收下下一次送出之後就讀不回文字的宿主：輸入法要到送出後才發現，
    /// 這時浮窗上可能還留著上一步的提示。
    var stopsReadingAfterNextInsert = false

    func insertText(_ string: String, replacementRange: NSRange) {
        insertedStrings.append(string)
        markedText = ""
        if stopsReadingAfterNextInsert {
            stopsReadingAfterNextInsert = false
            allowsReadingText = false
        }
        if keepsStaleTextAfterEqualLengthReplacement, replacementRange.location != NSNotFound,
           replacementRange.length > 0, replacementRange.length == (string as NSString).length {
            staleReportedText = staleReportedText ?? text
        } else {
            staleReportedText = nil
        }
        if replacementRange.location != NSNotFound {
            let ns = NSMutableString(string: text)
            let safeLoc = min(replacementRange.location, ns.length)
            let safeLen = min(replacementRange.length, ns.length - safeLoc)
            ns.replaceCharacters(in: NSRange(location: safeLoc, length: safeLen), with: string)
            text = String(ns)
        } else {
            text += string
        }
    }

    var setMarkedTextCallCount = 0

    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange) {
        setMarkedTextCallCount += 1
        markedText = string
    }

    /// 模擬不回報游標位置的終端機：永遠說游標在 0，也不提供前文。
    var reportsCursorAtZero = false

    /// 模擬使用者選取了游標前的這麼多個 UTF-16 單位。0 是沒有選取範圍。
    var selectedLength = 0

    /// 一般文字欄位的游標在標記文字後面（NSTextView 就是這樣），所以標記文字算進位置。
    func selectedRange() -> NSRange {
        if reportsCursorAtZero {
            return NSRange(location: 0, length: 0)
        }
        let end = (text as NSString).length + (markedText as NSString).length
        let length = min(selectedLength, end)
        return NSRange(location: end - length, length: length)
    }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        let ns = (staleReportedText ?? text) as NSString
        guard allowsReadingText, range.location != NSNotFound, range.location + range.length <= ns.length else {
            return nil
        }
        return NSAttributedString(string: ns.substring(with: range))
    }

    func cursorLineRect() -> NSRect {
        cursorRect
    }
}

@MainActor
private final class TextViewTestClient: @preconcurrency IMKTextClientProtocol {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
    var allowsReadingText = true

    func insertText(_ string: String, replacementRange: NSRange) {
        view.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange) {
        view.setMarkedText(string, selectedRange: selectionRange, replacementRange: replacementRange)
    }

    func selectedRange() -> NSRange { view.selectedRange() }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        allowsReadingText ? view.attributedSubstring(forProposedRange: range, actualRange: nil) : nil
    }

    func cursorLineRect() -> NSRect { .zero }

    func supportsDocumentAccess() -> Bool { true }
}

/// Drives the IMK shell through keys the engine never sees (shortcuts, arrows, editing
/// commands) and through client quirks. Returns the passed check count or a failure.
@MainActor
func runShellRegressionChecks() -> Result<Int, SelfTestFailure> {
    var passed = 0
    var coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
    var client = FakeIMKClient()

    func fresh(text: String = "") {
        coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
        client = FakeIMKClient()
        client.text = text
    }
    func send(_ payload: KeyEventPayload) -> Bool {
        coordinator.handlePayload(payload, client: client)
    }
    func type(_ letters: String) {
        for ch in letters {
            _ = send(KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)))
        }
    }
    func check(_ name: String, _ condition: Bool) -> SelfTestFailure? {
        if condition {
            passed += 1
            return nil
        }
        return SelfTestFailure(message: "\(name): text='\(client.text)' marked='\(client.markedText)' state=\(coordinator.engine.state.rawValue) buffer='\(coordinator.engine.buffer)'")
    }

    // Cmd shortcut while composing: commit the letters, then let the client have the key.
    fresh()
    type("my")
    let cmdHandled = send(KeyEventPayload(keyCode: 9, modifierFlags: .command, characters: "v", charactersIgnoringModifiers: "v"))
    if let failure = check("Cmd+V while composing", !cmdHandled && client.text == "my" && client.markedText.isEmpty && coordinator.engine.buffer.isEmpty) {
        return .failure(failure)
    }

    // Left arrow while composing: same rule, no orphaned buffer.
    fresh()
    type("the")
    let arrowHandled = send(KeyEventPayload(keyCode: 123, modifierFlags: [.function, .numericPad], characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}"))
    if let failure = check("Left arrow while composing", !arrowHandled && client.text == "the" && coordinator.engine.state == .idle) {
        return .failure(failure)
    }

    // Ctrl+A / Ctrl+E / Ctrl+K / Ctrl+U / Ctrl+C and F5 are never intercepted.
    fresh()
    var shortcutsForwarded = true
    for (code, ch) in [(0, "a"), (14, "e"), (40, "k"), (32, "u"), (8, "c")] as [(UInt16, String)] {
        if send(KeyEventPayload(keyCode: code, modifierFlags: .control, characters: ch, charactersIgnoringModifiers: ch)) {
            shortcutsForwarded = false
        }
    }
    if send(KeyEventPayload(keyCode: 96, modifierFlags: .function, characters: "\u{F708}", charactersIgnoringModifiers: "\u{F708}")) {
        shortcutsForwarded = false
    }
    if let failure = check("Ctrl shortcuts and function keys pass through", shortcutsForwarded && client.text.isEmpty) {
        return .failure(failure)
    }

    // Option+Delete deletes a word in the client; it must not insert a DEL character.
    fresh(text: "word")
    let optionDeleteHandled = send(KeyEventPayload(keyCode: 51, modifierFlags: .option, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}"))
    if let failure = check("Option+Delete passes through", !optionDeleteHandled && client.text == "word") {
        return .failure(failure)
    }

    // Shift+1 while picking a candidate is the "!" key: commit the focused character first.
    fresh()
    type("no")
    _ = send(KeyEventPayload(keyCode: 125, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}"))
    let bangHandled = send(KeyEventPayload(keyCode: 18, modifierFlags: .shift, characters: "!", charactersIgnoringModifiers: "!"))
    if let failure = check("Shift+1 while selecting a candidate", bangHandled && client.text == "欠！" && coordinator.engine.state == .idle) {
        return .failure(failure)
    }

    // Double Shift with nothing composing must not touch marked text (it would replace a selection).
    fresh(text: "abc")
    for (flags, time) in [(NSEvent.ModifierFlags.shift, 1.0), ([], 1.05), (.shift, 1.15), ([], 1.2)] as [(NSEvent.ModifierFlags, TimeInterval)] {
        _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: flags, timestamp: time))
    }
    if let failure = check("Idle double Shift leaves marked text alone", coordinator.engine.state == .pureEnglish && client.setMarkedTextCallCount == 0 && client.text == "abc") {
        return .failure(failure)
    }

    // Menu toggle while composing delivers the buffer instead of dropping it.
    fresh()
    type("my")
    coordinator.togglePureEnglish(client: client)
    if let failure = check("Menu pure-English toggle while composing", client.text == "my" && client.markedText.isEmpty && coordinator.engine.state == .pureEnglish) {
        return .failure(failure)
    }

    // Changing the Cangjie table mid-composition commits first and leaves a consistent engine.
    // une 是兩份碼表唯一的差異：「函」的五代原生碼是 une，三代沒有這個碼。
    fresh()
    coordinator.updateConfiguration(client: client) { $0.cangjieVersion = .v3 }
    type("une")
    coordinator.updateConfiguration(client: client) { $0.cangjieVersion = .v5 }
    type("une")
    _ = send(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "))
    if let failure = check("Table switch while composing", client.text == "une 函" && coordinator.engine.state == .idle) {
        return .failure(failure)
    }

    // The 32-unit context window starts inside a surrogate pair here; the trailing-space
    // collapse must still recognise its own "hello ".
    fresh(text: "𣊭" + String(repeating: "a", count: 24) + " ")
    type("hello")
    _ = send(KeyEventPayload(keyCode: 48, characters: "\t", charactersIgnoringModifiers: "\t"))
    _ = send(KeyEventPayload(keyCode: 43, characters: ",", charactersIgnoringModifiers: ","))
    if let failure = check("Context window split inside a surrogate pair", client.text.hasSuffix(" hello,")) {
        return .failure(failure)
    }

    // An editor may change the text and decline to share its context between keystrokes.
    fresh()
    type("hello")
    _ = send(KeyEventPayload(keyCode: 48))
    client.text = "elseX"
    client.allowsReadingText = false
    _ = send(KeyEventPayload(keyCode: 43, characters: ",", charactersIgnoringModifiers: ","))
    if let failure = check("Unreadable context preserves the preceding character", client.text == "elseX,") {
        return .failure(failure)
    }

    // A Shift tap in one field must not complete a gesture started in another field.
    fresh()
    for timestamp in [1.0, 1.15] {
        coordinator.resetForFocusChange()
        _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: .shift, timestamp: timestamp))
        _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, timestamp: timestamp + 0.05))
    }
    if let failure = check("Shift taps are local to the current focus", coordinator.engine.state == .idle) {
        return .failure(failure)
    }

    fresh()
    for (keyCode, flags, time) in [
        (55, NSEvent.ModifierFlags.command, 1.00), (56, [.command, .shift], 1.01),
        (55, .shift, 1.02), (56, [], 1.03), (56, .shift, 1.10), (56, [], 1.11)
    ] as [(UInt16, NSEvent.ModifierFlags, TimeInterval)] {
        _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: keyCode, modifierFlags: flags, timestamp: time))
    }
    if let failure = check("Releasing Command before Shift is not a clean Shift tap", coordinator.engine.state == .idle) {
        return .failure(failure)
    }

    fresh()
    type("zzzz")
    _ = send(KeyEventPayload(keyCode: 18, modifierFlags: .shift, characters: "!", charactersIgnoringModifiers: "!"))
    if let failure = check("Shift+1 with no predictions types a symbol", client.text == "zzzz!") {
        return .failure(failure)
    }

    for payload in [
        KeyEventPayload(keyCode: 48, modifierFlags: .shift, characters: "\u{19}"),
        KeyEventPayload(keyCode: 126, modifierFlags: [.shift, .function, .numericPad], characters: "\u{F700}"),
        KeyEventPayload(keyCode: 36, modifierFlags: .shift, characters: "\r"),
        KeyEventPayload(keyCode: 43, modifierFlags: [.control, .option], charactersIgnoringModifiers: ",")
    ] {
        fresh()
        type("my")
        let handled = send(payload)
        if let failure = check("Modified editing or accessibility shortcut \(payload.keyCode)", !handled && client.text == "my" && client.markedText.isEmpty) {
            return .failure(failure)
        }
    }

    // 以下為標點、半形句點與 Caps Lock 的外層案例。
    func key(_ ch: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], produced: String? = nil) -> KeyEventPayload {
        KeyEventPayload(keyCode: code, modifierFlags: flags, characters: produced ?? ch, charactersIgnoringModifiers: ch)
    }
    func capsLockKey(lit: Bool) -> KeyEventPayload {
        KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 57, modifierFlags: lit ? .capsLock : [])
    }
    let spaceKey = key(" ", code: 49)
    let periodKey = key(".", code: 47)

    // 組字中開燈：原樣送出緩衝，亮燈期間出鍵面半形，Tab 交還程式，熄燈後空白仍選字。
    fresh()
    type("my")
    _ = send(capsLockKey(lit: true))
    let capsCommitted = client.text == "my" && client.markedText.isEmpty
    for (ch, flags) in [(".", .capsLock), ("F", .capsLock), ("I", [.capsLock, .shift]), ("L", .capsLock), ("E", .capsLock)] as [(String, NSEvent.ModifierFlags)] {
        _ = send(key(ch, flags: flags))
    }
    let capsTabHandled = send(key("\t", code: 48, flags: .capsLock))
    let capsText = client.text
    client.text += "\t"
    _ = send(capsLockKey(lit: false))
    type("my")
    _ = send(spaceKey)
    if let failure = check("Caps Lock half-width layer", capsCommitted && capsText == "my.fIle" && !capsTabHandled && client.text == "my.fIle\t下") {
        return .failure(failure)
    }

    // 系統把 Caps Lock 攔為輸入來源切換鍵時，旗標不亮，混打不受影響。
    fresh()
    type("my")
    _ = send(capsLockKey(lit: false))
    _ = send(spaceKey)
    if let failure = check("Caps Lock taken over by the system", !coordinator.engine.capsLockEnabled && client.text == "下") {
        return .failure(failure)
    }

    // 取得焦點時依實際旗標同步燈號。
    fresh(text: "下")
    coordinator.syncCapsLock(isOn: true, client: nil)
    _ = send(key(".", code: 47, flags: .capsLock))
    if let failure = check("Caps Lock synced on focus", coordinator.engine.capsLockEnabled && client.text == "下.") {
        return .failure(failure)
    }

    // 句點只在可信的中文前文後出「。」。
    fresh(text: "下")
    _ = send(periodKey)
    let readableChinese = client.text
    // 空文件的第一鍵先暫存一個按鍵，寬度照樣看語境；結束組字後落地。
    fresh()
    _ = send(periodKey)
    let lineStartStaged = client.text.isEmpty && client.markedText == "."
    coordinator.commitComposition(client: client)
    let lineStart = lineStartStaged && client.markedText.isEmpty ? client.text : "未暫存"
    fresh(text: "下")
    client.allowsReadingText = false
    _ = send(periodKey)
    if let failure = check("Period follows trusted context", readableChinese == "下。" && lineStart == "." && client.text == "下.") {
        return .failure(failure)
    }

    // 拒絕回讀的宿主：連續輸入可沿用本機尾字，游標移動後就不再可信。
    // 這種宿主讀不回剛送出的文字，所以可對調寬度的標點會先當成標記文字，下一個按鍵才落地。
    fresh()
    client.allowsReadingText = false
    type("my")
    _ = send(spaceKey)
    _ = send(periodKey)
    let continuous = client.text + client.markedText
    _ = send(KeyEventPayload(keyCode: 123, modifierFlags: [.function, .numericPad], characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}"))
    _ = send(periodKey)
    if let failure = check("Unreadable host keeps only continuous context",
                           continuous == "下。" && client.text + client.markedText == "下。.") {
        return .failure(failure)
    }

    // 永遠回報游標在 0 的終端機：剛送出的中文字仍是可信前文，換欄位後重新判斷。
    fresh()
    client.reportsCursorAtZero = true
    client.allowsReadingText = false
    type("my")
    _ = send(spaceKey)
    _ = send(periodKey)
    // 可反悔的送出在這種宿主先當標記文字，下一個按鍵才正式交出去。
    let terminalChinese = client.text + client.markedText
    type("ls")
    _ = send(key("\r", code: 36))
    _ = send(periodKey)
    let terminalEnglish = client.text + client.markedText
    coordinator.commitComposition(client: client)
    coordinator.resetForFocusChange()
    _ = send(periodKey)
    if let failure = check("Client that always reports cursor at zero",
                           terminalChinese == "下。" && terminalEnglish == "下。ls."
                            && client.text + client.markedText == "下。ls..") {
        return .failure(failure)
    }

    // Ctrl 加標點在行首也強制出全形，每個新鍵各出一個字。
    fresh()
    let ctrlPeriodHandled = send(key(".", code: 47, flags: .control))
    let ctrlFullwidthHandled = [
        send(key("\\", code: 42, flags: .control)),
        send(key(";", code: 41, flags: .control)),
        send(key("!", code: 18, flags: [.control, .shift])),
        send(key("?", code: 44, flags: [.control, .shift])),
        send(key("(", code: 25, flags: [.control, .shift])),
        send(key(")", code: 29, flags: [.control, .shift])),
        // 按著 Ctrl 時宿主回報沒套用 Shift 的鍵面字元（虛擬機實打看到的情形）。
        send(key("1", code: 18, flags: [.control, .shift])),
        send(key("/", code: 44, flags: [.control, .shift])),
        send(key("9", code: 25, flags: [.control, .shift])),
        send(key("0", code: 29, flags: [.control, .shift]))
    ].allSatisfy { $0 }
    if let failure = check("Ctrl punctuation forces the full-width forms",
                           ctrlPeriodHandled && ctrlFullwidthHandled && client.text == "。、；！？（）！？（）") {
        return .failure(failure)
    }

    // 直引號固定半形；`my.file` 不被候選打斷。
    fresh()
    _ = send(key("\"", code: 39, flags: .shift))
    type("hello")
    _ = send(key("\"", code: 39, flags: .shift))
    let quoted = client.text
    fresh()
    type("my")
    _ = send(periodKey)
    type("file")
    _ = send(key("\r", code: 36))
    if let failure = check("Straight quotes and dotted names", quoted == "\"hello\"" && client.text == "my.file") {
        return .failure(failure)
    }

    // Option+. 連同原字母送出半形句點。
    fresh()
    type("my")
    let optionPeriodHandled = send(key(".", code: 47, flags: .option, produced: "≥"))
    if let failure = check("Option+period keeps the typed letters", optionPeriodHandled && client.text == "my.") {
        return .failure(failure)
    }

    // Option+Shift+H 只改之後的標點，不動候選焦點。
    fresh()
    type("no")
    _ = send(KeyEventPayload(keyCode: 125, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}"))
    let toggleHandled = send(key("H", code: 4, flags: [.option, .shift], produced: "Ó"))
    let focusKept = coordinator.engine.state == .selectingCandidate && coordinator.engine.selectedCandidateIndex == 1
    _ = send(spaceKey)
    _ = send(key(",", code: 43))
    if let failure = check("Option+Shift+H toggles half-width punctuation", toggleHandled && focusKept && !coordinator.engine.configuration.autoPunctuationEnabled && client.text == "欠,") {
        return .failure(failure)
    }

    // Shift+Space 聚焦候選清單，不選字；之後的句點接在中文字後。
    fresh()
    type("my")
    let shiftSpaceHandled = send(key(" ", code: 49, flags: .shift))
    let listFocused = coordinator.engine.state == .selectingCandidate && client.text.isEmpty && client.markedText == "my"
    _ = send(periodKey)
    if let failure = check("Shift+Space focuses the candidate list", shiftSpaceHandled && listFocused && client.text == "下。") {
        return .failure(failure)
    }

    // 英文選詞學習：一個宿主採用的詞，另一個宿主與重新載入後都排在前面，清除後還原。
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("goshawk-self-test-\(ProcessInfo.processInfo.processIdentifier)/usage-history.json")
    defer { try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent()) }
    let store = UsageHistoryStore(fileURL: historyURL)
    let shiftTwo = KeyEventPayload(keyCode: 19, modifierFlags: .shift, characters: "@", charactersIgnoringModifiers: "@")
    func firstPrediction(_ session: InputSessionCoordinator) -> String? {
        session.engine.currentOverlay?.englishTrack.predictions.first
    }
    fresh()
    coordinator = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: store)
    type("func")
    let defaultFirst = firstPrediction(coordinator)
    _ = send(shiftTwo)
    let learnedText = client.text
    let otherHost = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: store)
    let otherClient = FakeIMKClient()
    for ch in "func" {
        _ = otherHost.handlePayload(KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)), client: otherClient)
    }
    let sharedFirst = firstPrediction(otherHost)
    let reloadedFirst = UsageHistoryStore(fileURL: historyURL).history.english.first?.word
    let filePermissions = (try? FileManager.default.attributesOfItem(atPath: historyURL.path)[.posixPermissions]) as? Int
    do {
        try otherHost.clearUsageHistory()
    } catch {
        return .failure(SelfTestFailure(message: error.localizedDescription))
    }
    type("func")
    let clearedFirst = firstPrediction(coordinator)
    let fileRemoved = !FileManager.default.fileExists(atPath: historyURL.path)
    if let failure = check("English choice learning is shared, persisted and clearable",
                           defaultFirst == "function" && learnedText == "functions " && sharedFirst == "functions"
                            && reloadedFirst == "functions" && filePermissions == 0o600
                            && clearedFirst == "function" && fileRemoved) {
        return .failure(failure)
    }

    // Exercise marked text and UTF-16 selections against AppKit's editing implementation.
    fresh()
    let native = TextViewTestClient()
    native.view.string = "𠮷舊字。"
    native.view.setSelectedRange(NSRange(location: 2, length: 2))
    for ch in "my" {
        _ = coordinator.handlePayload(KeyEventPayload(keyCode: 0, characters: String(ch)), client: native)
    }
    let markedSelectionOK = native.view.markedRange() == NSRange(location: 2, length: 2)
        && native.view.string == "𠮷my。"
    _ = coordinator.handlePayload(KeyEventPayload(keyCode: 49), client: native)
    if let failure = check("Native selection replaced exactly once", markedSelectionOK && !native.view.hasMarkedText() && native.view.string == "𠮷下。") {
        return .failure(SelfTestFailure(message: failure.message + " native='\(native.view.string)'"))
    }

    // Overlay anchoring: a zero cursor rect falls back to the last position, then the mouse.
    let mouse = NSPoint(x: 640, y: 480)
    let known = NSRect(x: 300, y: 300, width: 2, height: 18)
    let anchorsOK = CandidateOverlayPanel.resolveAnchorRect(reported: known, lastKnown: nil, mouseLocation: mouse) == known
        && CandidateOverlayPanel.resolveAnchorRect(reported: .zero, lastKnown: known, mouseLocation: mouse) == known
        && CandidateOverlayPanel.resolveAnchorRect(reported: .zero, lastKnown: nil, mouseLocation: mouse).origin == mouse
    if let failure = check("Zero cursor rect fallback", anchorsOK) {
        return .failure(failure)
    }

    // Herdr 與 Chrome 實際回傳過的未初始化矩形，不能把浮窗釘到螢幕角落。
    let denormal = CGFloat(1.6080749353408704e-314)
    let garbage = NSRect(x: denormal, y: 0, width: denormal, height: denormal)
    let negativeHeight = NSRect(x: denormal, y: 13165.46, width: denormal, height: -1)
    let garbageOK = [garbage, negativeHeight].allSatisfy {
        CandidateOverlayPanel.resolveAnchorRect(reported: $0, lastKnown: nil, mouseLocation: mouse).origin == mouse
    } && CandidateOverlayPanel.isUsableCursorRect(NSRect(x: 1949, y: 226, width: 1, height: 24))
    if let failure = check("Uninitialised cursor rect is rejected", garbageOK) {
        return .failure(failure)
    }

    // Multi-display: pick the screen holding the cursor, or the nearest one for edge points.
    let primary = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875))
    let upper = (frame: NSRect(x: 200, y: 900, width: 2560, height: 1440), visibleFrame: NSRect(x: 200, y: 900, width: 2560, height: 1415))
    let screensOK = CandidateOverlayPanel.screenFrame(for: NSPoint(x: 1000, y: 1500), screens: [primary, upper]) == upper.visibleFrame
        && CandidateOverlayPanel.screenFrame(for: NSPoint(x: 100, y: 100), screens: [primary, upper]) == primary.visibleFrame
        && CandidateOverlayPanel.screenFrame(for: NSPoint(x: 2900, y: 2400), screens: [primary, upper]) == upper.visibleFrame
        && CandidateOverlayPanel.screenFrame(for: .zero, screens: []) == nil
    if let failure = check("Screen selection across displays", screensOK) {
        return .failure(failure)
    }

    let panelSize = NSSize(width: 250, height: 60)
    let origin = CandidateOverlayPanel.clampedOrigin(
        for: panelSize,
        cursorRect: NSRect(x: 25, y: -1000, width: 1, height: 18),
        screenFrame: primary.visibleFrame
    )
    if !primary.visibleFrame.contains(NSRect(origin: origin, size: panelSize)) {
        return .failure(SelfTestFailure(message: "Anchor on disconnected lower screen: y=\(origin.y)"))
    }
    passed += 1

    // The English track shows the focused prediction, in the casing Tab will commit.
    let focused = CandidateOverlayPanel.formatTracks(for: OverlayState(
        englishTrack: EnglishTrack(typed: "doc", predictions: ["doc", "docker", "document"], selectedIndex: 1),
        cangjieTrack: nil
    ), showsEnglishActions: true).english.string
    let cased = CandidateOverlayPanel.formatTracks(for: OverlayState(
        englishTrack: EnglishTrack(typed: "usest", predictions: ["useState"], selectedIndex: 0),
        cangjieTrack: nil
    ), showsEnglishActions: true).english.string
    if let failure = check("Overlay shows focused prediction", focused == "docker  Tab  |  ⇧1 doc  ⇧3 document" && cased == "useState  Tab") {
        return .failure(SelfTestFailure(message: failure.message + " focused='\(focused)' cased='\(cased)'"))
    }

    // A focused Chinese candidate takes Tab. Chinese-only mode has no English track actions.
    for mixed in [true, false] {
        fresh()
        coordinator.updateConfiguration(client: client) { $0.mixedModeEnabled = mixed }
        type("no")
        if mixed {
            _ = send(KeyEventPayload(keyCode: 125))
        }
        guard let overlay = coordinator.engine.currentOverlay else {
            return .failure(SelfTestFailure(message: "Missing Chinese candidates"))
        }
        let tracks = CandidateOverlayPanel.formatTracks(for: overlay, showsEnglishActions: coordinator.englishActionsAvailable)
        _ = send(KeyEventPayload(keyCode: 48))
        let tabOK = mixed ? client.text == "欠" : client.text.isEmpty && client.markedText == "no"
        if let failure = check("English hints match Chinese candidate input", tracks.english.string == "no" && tracks.cangjie != nil && tabOK) {
            return .failure(failure)
        }
    }

    // 同一組字靠近右下角時，候選增減不可讓浮窗反覆跳動。
    guard let screen = NSScreen.main else {
        return .failure(SelfTestFailure(message: "Missing screen for overlay checks"))
    }
    fresh()
    let panel = CandidateOverlayPanel()
    let cursor = NSRect(x: screen.visibleFrame.maxX - 20, y: screen.visibleFrame.minY + 2, width: 1, height: 18)
    let render: OverlayUpdate = { overlay, readingPanel, _ in
        panel.update(
            overlay: overlay,
            layerPanel: readingPanel,
            cursorRect: cursor,
            showsEnglishActions: coordinator.englishActionsAvailable
        )
    }
    func press(_ ch: String) {
        _ = coordinator.handlePayload(KeyEventPayload(keyCode: 0, characters: ch, charactersIgnoringModifiers: ch), client: client, onOverlayUpdate: render)
    }
    press("m")
    press("y")
    let dualFrame = panel.frame
    press("z")
    if let failure = check("Overlay stable above the caret", panel.isVisible && !panel.isKeyWindow
        && panel.frame.minX == dualFrame.minX && panel.frame.minY >= cursor.maxY
        && dualFrame.minY >= cursor.maxY) {
        return .failure(failure)
    }
    _ = coordinator.handlePayload(KeyEventPayload(keyCode: 36), client: client, onOverlayUpdate: render)
    if let failure = check("Commit closes panel", !panel.isVisible) { return .failure(failure) }
    press("m")
    coordinator.commitComposition(client: client, onOverlayUpdate: render)
    if let failure = check("Deactivation closes composing panel", !panel.isVisible && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 以下為單字讀音反查的外層案例。
    let lookupShortcut = KeyEventPayload(
        keyCode: 41,
        modifierFlags: [.control, .shift],
        characters: ":",
        charactersIgnoringModifiers: ":"
    )
    func readingKeys(_ keys: String) {
        for ch in keys {
            _ = send(KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)))
        }
    }
    let escapeKey = KeyEventPayload(keyCode: 53, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}")
    let enterKey = key("\r", code: 36)
    let downKey = KeyEventPayload(keyCode: 125, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}")

    // 快捷鍵開啟反查：標記文字照舊，查詢鍵一個字元都不送進宿主。
    fresh()
    type("my")
    let openHandled = send(lookupShortcut)
    let opened = coordinator.engine.readingLookup != nil && client.markedText == "my" && client.text.isEmpty
    readingKeys("hji4")
    let quietWhileTyping = client.text.isEmpty && client.markedText == "my"
        && coordinator.engine.currentReadingLookupPanel?.rows.first?.character == "錯"
    if let failure = check("Reading lookup opens without touching the host", openHandled && opened && quietWhileTyping) {
        return .failure(failure)
    }

    // Esc 完整還原：標記文字仍是 my，空白鍵照樣送出「下」。
    _ = send(escapeKey)
    let restored = coordinator.engine.readingLookup == nil && client.text.isEmpty && client.markedText == "my"
    _ = send(spaceKey)
    if let failure = check("Esc restores the suspended composition", restored && client.text == "下") {
        return .failure(failure)
    }

    // 選字一次取代原標記：宿主只多一個字，標記文字清空，下一輪回雙軌。
    fresh()
    type("my")
    _ = send(lookupShortcut)
    readingKeys("hji4")
    // 「厝」是 ㄘㄨㄛˋ 的第 5 個候選。
    for _ in 0..<5 {
        _ = send(downKey)
    }
    _ = send(enterKey)
    let picked = client.text == "厝" && client.markedText.isEmpty && coordinator.engine.readingLookup == nil
    type("my")
    _ = send(spaceKey)
    if let failure = check("Picking a reading candidate replaces the marked text once", picked && client.text == "厝下") {
        return .failure(failure)
    }

    // 從閒置開啟：宿主沒有原字母可標記，改用讀音當暫時的標記文字，終端機才會把 Enter
    // 交給輸入法。選字後只留下那個字；取消或切換欄位時暫時的標記要清乾淨。
    fresh()
    _ = send(lookupShortcut)
    let placeholderOnOpen = client.markedText == "？" && client.text.isEmpty
    readingKeys("hji4")
    let placeholderShowsReading = client.markedText == "ㄘㄨㄛˋ" && client.text.isEmpty
    _ = send(enterKey)
    let idlePick = client.text == "錯" && client.markedText.isEmpty && coordinator.engine.readingLookup == nil
    fresh()
    _ = send(lookupShortcut)
    readingKeys("hji")
    _ = send(escapeKey)
    let idleCancel = client.text.isEmpty && client.markedText.isEmpty
    fresh()
    _ = send(lookupShortcut)
    readingKeys("hji4")
    coordinator.commitComposition(client: client)
    let idleBlur = client.text.isEmpty && client.markedText.isEmpty && coordinator.engine.readingLookup == nil
    if let failure = check("Reading lookup from idle marks the reading until it closes",
                           placeholderOnOpen && placeholderShowsReading && idlePick && idleCancel && idleBlur) {
        return .failure(failure)
    }

    // 切換欄位：宿主結束組字時先丟掉反查，只送出原字母。
    fresh()
    type("my")
    _ = send(lookupShortcut)
    readingKeys("hji4")
    coordinator.commitComposition(client: client)
    let committedRaw = client.text == "my" && coordinator.engine.readingLookup == nil
    let newField = FakeIMKClient()
    coordinator.resetForFocusChange()
    _ = coordinator.handlePayload(spaceKey, client: newField)
    if let failure = check("Focus change discards the lookup and commits the letters only",
                           committedRaw && newField.text == " " && !newField.text.contains("厝")) {
        return .failure(failure)
    }

    fresh()
    type("oj")
    _ = send(downKey)
    _ = send(lookupShortcut)
    coordinator.commitComposition(client: client)
    if let failure = check("宿主結束反查時只保留已聚焦候選的原碼", client.text == "oj") {
        return .failure(failure)
    }

    // NSTextView 會把暫時讀音一起回報，能驗出把它誤認為已送出前文的情形。
    let readingHost = TextViewTestClient()
    let readingSession = InputSessionCoordinator(configuration: EngineConfiguration())
    readingHost.view.string = "abc"
    readingHost.view.setSelectedRange(NSRange(location: 3, length: 0))
    readingSession.toggleReadingLookup(client: readingHost)
    for ch in "hji4" {
        _ = readingSession.handlePayload(key(String(ch), code: 0), client: readingHost)
    }
    _ = readingSession.handlePayload(enterKey, client: readingHost)
    if let failure = check("英文後開反查仍依原本前文補空格", readingHost.view.string == "abc 錯") {
        return .failure(failure)
    }

    for inSnippet in [false, true] {
        let host = TextViewTestClient()
        let session = InputSessionCoordinator(configuration: EngineConfiguration())
        if inSnippet {
            _ = session.handlePayload(key("`", code: 50), client: host)
        }
        for ch in "id" { _ = session.handlePayload(key(String(ch)), client: host) }
        _ = session.handlePayload(key("\t", code: 48), client: host)
        session.toggleReadingLookup(client: host)
        for ch in "hji4" { _ = session.handlePayload(key(String(ch)), client: host) }
        let contextIntact = session.engine.pendingAutoSpace == !inSnippet && session.engine.snippet.isInside == inSnippet
        session.pickReadingLookupRow(1, client: host)
        let expected = inSnippet ? "`id錯" : "id 錯"
        if let failure = check("反查期間保留自動空格與片段，選字後收到 \(expected)",
                               contextIntact && host.view.string == expected) {
            return .failure(failure)
        }
    }

    // Cmd+V 開著反查時交還宿主，宿主不得收到候選字。
    fresh()
    type("my")
    _ = send(lookupShortcut)
    readingKeys("hji4")
    let pasteHandled = send(KeyEventPayload(keyCode: 9, modifierFlags: .command, characters: "v", charactersIgnoringModifiers: "v"))
    if let failure = check("Cmd+V while the lookup is open",
                           !pasteHandled && client.text == "my" && coordinator.engine.readingLookup == nil) {
        return .failure(failure)
    }

    // 從閒置開啟、用拼音查字並把方案偏好存進本機。
    let suiteName = "goshawk-self-test-\(ProcessInfo.processInfo.processIdentifier)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        return .failure(SelfTestFailure(message: "Cannot create the preferences suite"))
    }
    defer { suite.removePersistentDomain(forName: suiteName) }
    let prefStore = PreferencesStore(defaults: suite)
    let prefSession = InputSessionCoordinator(configuration: prefStore.loadConfiguration(), preferences: prefStore)
    let prefClient = FakeIMKClient()
    _ = prefSession.handlePayload(lookupShortcut, client: prefClient)
    _ = prefSession.handlePayload(key("\t", code: 48), client: prefClient)
    for ch in "cuo4" {
        _ = prefSession.handlePayload(
            KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)),
            client: prefClient
        )
    }
    let pinyinRows = prefSession.engine.currentReadingLookupPanel?.rows.first?.character
    _ = prefSession.handlePayload(enterKey, client: prefClient)
    let savedScheme = suite.string(forKey: "goshawk.readingScheme")
    let reloaded = PreferencesStore(defaults: suite).loadConfiguration().readingScheme
    if let failure = check("Pinyin lookup from idle saves the scheme preference",
                           pinyinRows == "錯" && prefClient.text == "錯"
                            && savedScheme == PhoneticScheme.pinyin.rawValue && reloaded == .pinyin) {
        return .failure(SelfTestFailure(message: failure.message + " saved='\(savedScheme ?? "nil")'"))
    }

    // 版面的純計算：四欄文字、頁尾、無障礙標籤與缺碼列。
    let sampleRow = ReadingLookupPanel.Row(number: 1, character: "厝", code: "mta", radicals: "一廿日")
    let filteredRow = ReadingLookupPanel.Row(number: 2, character: "匕", code: "uh", radicals: "山竹", directInputAvailable: false)
    let missingRow = ReadingLookupPanel.Row(number: 3, character: "㑁", code: nil, radicals: nil)
    let samplePanel = ReadingLookupPanel(
        scheme: .dachen,
        inputDisplay: "ㄘㄨㄛˋ",
        cangjieVersion: .v5,
        status: .results,
        rows: [sampleRow, filteredRow, missingRow],
        focusedRow: 0,
        isSelecting: false,
        page: 1,
        pageCount: 3
    )
    let emptyPanel = ReadingLookupPanel(
        scheme: .pinyin,
        inputDisplay: "zzz",
        cangjieVersion: .v3,
        status: .noResults,
        rows: [],
        focusedRow: nil,
        isSelecting: false,
        page: 1,
        pageCount: 1
    )
    let columns = ReadingLookupView.columns(for: sampleRow)
    let missingColumns = ReadingLookupView.columns(for: missingRow)
    let layoutOK = columns == ("1", "厝", "mta", "一廿日")
        && ReadingLookupView.columns(for: filteredRow) == ("2", "匕", "uh", "山竹  此碼無法正查")
        && missingColumns == ("3", "㑁", "本代未收錄", "")
        && ReadingLookupView.headerText(for: samplePanel) == "ㄘㄨㄛˋ  倉頡五代"
        && ReadingLookupView.headerText(for: emptyPanel) == "zzz  倉頡三代"
        && ReadingLookupView.footerText(for: samplePanel) == "第 1 頁，共 3 頁  ↓ 選字  Tab 切換方案  Esc 關閉"
        && ReadingLookupView.footerText(for: emptyPanel) == "↓ 選字  Tab 切換方案  Esc 關閉"
        && ReadingLookupView.placeholderText(for: .noResults) == "查無此讀音"
        && ReadingLookupView.placeholderText(for: .results) == nil
        && ReadingLookupView.rowAccessibilityLabel(for: sampleRow) == "第 1 列，厝，字母碼 mta，字根 一廿日"
        && ReadingLookupView.rowAccessibilityLabel(for: filteredRow) == "第 2 列，匕，字母碼 uh，字根 山竹，此碼無法正查"
        && ReadingLookupView.rowAccessibilityLabel(for: missingRow) == "第 3 列，㑁，本代未收錄"
        && ReadingLookupView.accessibilityLabel(for: samplePanel) == "單字讀音反查，ㄘㄨㄛˋ，倉頡五代，第 1 頁，共 3 頁"
        && ReadingLookupView.accessibilityLabel(for: emptyPanel) == "單字讀音反查，zzz，倉頡三代，查無此讀音"
    if let failure = check("Reading panel layout text", layoutOK) {
        return .failure(SelfTestFailure(message: failure.message
            + " header='\(ReadingLookupView.headerText(for: samplePanel))'"
            + " footer='\(ReadingLookupView.footerText(for: samplePanel))'"))
    }

    // 倉頡重碼與讀音反查的學習紀錄同樣跨宿主共用、存檔重載，清除後還原。
    // `oj` 兩代都收「午、什」，選兩次「什」才會變首選。
    let learnURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("goshawk-self-test-learning-\(ProcessInfo.processInfo.processIdentifier)/usage-history.json")
    defer { try? FileManager.default.removeItem(at: learnURL.deletingLastPathComponent()) }
    let learnStore = UsageHistoryStore(fileURL: learnURL)
    func firstCandidate(_ session: InputSessionCoordinator) -> String? {
        session.engine.currentOverlay?.cangjieTrack?.candidates.first
    }
    func typeInto(_ session: InputSessionCoordinator, _ host: FakeIMKClient, _ letters: String) {
        for ch in letters {
            _ = session.handlePayload(
                KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)),
                client: host
            )
        }
    }
    fresh()
    coordinator = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: learnStore)
    type("oj")
    let cangjieDefaultFirst = firstCandidate(coordinator)
    _ = send(escapeKey)
    for _ in 0..<2 {
        type("oj")
        _ = send(downKey)
        _ = send(spaceKey)
    }
    // 讀音反查：選過的字下次排第一。「波」是 ㄅㄛ 一聲的第二個字。
    _ = send(lookupShortcut)
    readingKeys("1i")
    _ = send(spaceKey)
    _ = send(downKey)
    _ = send(KeyEventPayload(keyCode: 19, characters: "2", charactersIgnoringModifiers: "2"))
    let readingPicked = client.text.hasSuffix("波")

    _ = send(lookupShortcut)
    readingKeys("1i")
    _ = send(spaceKey)
    coordinator.pickReadingLookupRow(1, client: client)
    if let failure = check("滑鼠選字與鍵盤共用學習紀錄",
                           learnStore.history.reading.first?.character == "波"
                            && learnStore.history.reading.first?.count == 2) {
        return .failure(failure)
    }

    let learnHost = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: learnStore)
    let learnClient = FakeIMKClient()
    typeInto(learnHost, learnClient, "oj")
    let sharedCangjieFirst = firstCandidate(learnHost)
    _ = learnHost.handlePayload(escapeKey, client: learnClient)
    _ = learnHost.handlePayload(lookupShortcut, client: learnClient)
    typeInto(learnHost, learnClient, "1i")
    _ = learnHost.handlePayload(spaceKey, client: learnClient)
    let sharedReadingFirst = learnHost.engine.currentReadingLookupPanel?.rows.first?.character
    _ = learnHost.handlePayload(escapeKey, client: learnClient)

    let reloadedLearning = UsageHistoryStore(fileURL: learnURL).history
    let persisted = reloadedLearning.cangjie.first?.code == "oj"
        && reloadedLearning.reading.first?.character == "波"
    do {
        try learnHost.clearUsageHistory()
    } catch {
        return .failure(SelfTestFailure(message: error.localizedDescription))
    }
    type("oj")
    let clearedCangjieFirst = firstCandidate(coordinator)
    if let failure = check("Cangjie and reading learning are shared, persisted and clearable",
                           cangjieDefaultFirst == "午" && readingPicked
                            && sharedCangjieFirst == "什" && sharedReadingFirst == "波"
                            && persisted && clearedCangjieFirst == "午") {
        return .failure(SelfTestFailure(message: failure.message
            + " default='\(cangjieDefaultFirst ?? "nil")' shared='\(sharedCangjieFirst ?? "nil")'"
            + " reading='\(sharedReadingFirst ?? "nil")' cleared='\(clearedCangjieFirst ?? "nil")'"))
    }

    // 以下為一鍵反悔的外層案例。
    switch runRevertChecks() {
    case .success(let count):
        passed += count
    case .failure(let failure):
        return .failure(failure)
    }

    // 以下為行內程式片段語境的外層案例。
    switch runSnippetContextChecks() {
    case .success(let count):
        passed += count
    case .failure(let failure):
        return .failure(failure)
    }

    // 以下為符號面板的外層案例。
    switch runSymbolPanelChecks() {
    case .success(let count):
        passed += count
    case .failure(let failure):
        return .failure(failure)
    }

    // 設定視窗：每個控制項的初始狀態與偏好一致，切換後偏好被寫入並發出通知，
    // 作用中的協調器重新載入設定且先結束組字。
    switch runSettingsWindowChecks() {
    case .success(let count):
        passed += count
    case .failure(let failure):
        return .failure(failure)
    }

    // 浮窗字級：設定視窗的選單寫得進偏好，三檔在五種畫面都畫得出來、不出螢幕、不截字。
    switch runOverlayFontSizeChecks() {
    case .success(let count):
        passed += count
    case .failure(let failure):
        return .failure(failure)
    }

    // 實際顯示：反查面板取代雙軌內容，仍不取得鍵盤焦點，關閉後浮窗收起。
    fresh()
    let readingPanelWindow = CandidateOverlayPanel()
    let readingRender: OverlayUpdate = { overlay, readingPanel, _ in
        readingPanelWindow.update(
            overlay: overlay,
            layerPanel: readingPanel,
            cursorRect: cursor,
            showsEnglishActions: coordinator.englishActionsAvailable
        )
    }
    for ch in "my" {
        _ = coordinator.handlePayload(
            KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)),
            client: client,
            onOverlayUpdate: readingRender
        )
    }
    let dualHeight = readingPanelWindow.frame.height
    _ = coordinator.handlePayload(lookupShortcut, client: client, onOverlayUpdate: readingRender)
    for ch in "hji4" {
        _ = coordinator.handlePayload(
            KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)),
            client: client,
            onOverlayUpdate: readingRender
        )
    }
    let readingVisible = readingPanelWindow.isVisible
        && !readingPanelWindow.isKeyWindow
        && readingPanelWindow.frame.height > dualHeight
        && !readingPanelWindow.ignoresMouseEvents
    _ = coordinator.handlePayload(escapeKey, client: client, onOverlayUpdate: readingRender)
    let backToDual = readingPanelWindow.isVisible && readingPanelWindow.ignoresMouseEvents
    _ = coordinator.handlePayload(escapeKey, client: client, onOverlayUpdate: readingRender)
    if let failure = check("Reading panel shows in the shared overlay window",
                           readingVisible && backToDual && !readingPanelWindow.isVisible) {
        return .failure(failure)
    }

    return .success(passed)
}

struct SelfTestFailure: Error {
    let message: String
}

/// 符號面板的外層檢查：快捷鍵翻譯、暫時標記文字、三條選取的路、最近使用的共用與存檔、
/// 版面的純計算與實際顯示。初始的最近使用依序是「——……‧〔〕※→×±」，都是鍵盤直接打不出來的符號；
/// 「標點」分頁第一頁是「。．.，,、；;：」，「符號」分頁第一頁是「【】〔〕［］｛｝〖」。
@MainActor
func runSymbolPanelChecks() -> Result<Int, SelfTestFailure> {
    var passed = 0
    var coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
    var client = FakeIMKClient()

    func fresh(terminal: Bool = false, text: String = "") {
        coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
        client = FakeIMKClient()
        client.text = text
        if terminal {
            client.reportsCursorAtZero = true
            client.allowsReadingText = false
        }
    }
    func send(_ payload: KeyEventPayload) -> Bool {
        coordinator.handlePayload(payload, client: client)
    }
    func key(_ ch: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> KeyEventPayload {
        KeyEventPayload(keyCode: code, modifierFlags: flags, characters: ch, charactersIgnoringModifiers: ch)
    }
    func type(_ letters: String) {
        for ch in letters { _ = send(key(String(ch))) }
    }
    func check(_ name: String, _ condition: Bool) -> SelfTestFailure? {
        if condition {
            passed += 1
            return nil
        }
        let panel = coordinator.engine.currentSymbolPanelContent
        return SelfTestFailure(message: "符號面板：\(name): text='\(client.text)' marked='\(client.markedText)' inserted=\(client.insertedStrings) state=\(coordinator.engine.state.rawValue) buffer='\(coordinator.engine.buffer)' tab=\(panel?.tab.rawValue ?? "nil") page=\(panel?.page ?? 0) rows='\(panel?.rows.map(\.symbol).joined() ?? "")'")
    }
    func rows(_ session: InputSessionCoordinator) -> String? {
        session.engine.currentSymbolPanelContent?.rows.map(\.symbol).joined()
    }
    // 按著 Option+Shift 時宿主回報的是套用修飾鍵後的字元，鍵位才是 B。
    let panelShortcut = KeyEventPayload(keyCode: 11, modifierFlags: [.option, .shift],
                                        characters: "ı", charactersIgnoringModifiers: "B")
    let lookupShortcut = KeyEventPayload(keyCode: 41, modifierFlags: [.control, .shift],
                                         characters: ":", charactersIgnoringModifiers: ":")
    let spaceKey = key(" ", code: 49)
    let tabKey = key("\t", code: 48)
    let enterKey = key("\r", code: 36)
    let escapeKey = key("\u{1B}", code: 53)
    let downKey = key("\u{F701}", code: 125)
    let upKey = key("\u{F700}", code: 126)
    let leftKey = KeyEventPayload(keyCode: 123, modifierFlags: [.function, .numericPad],
                                  characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}")
    let rightKey = KeyEventPayload(keyCode: 124, modifierFlags: [.function, .numericPad],
                                   characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}")

    // 快捷鍵依鍵位辨識：宿主把字元回報成非字母的符號時照樣認得，再按一次關閉。
    fresh()
    let openHandled = send(panelShortcut)
    let openedByShortcut = coordinator.engine.symbolPanel != nil
    let closeHandled = send(KeyEventPayload(keyCode: 11, modifierFlags: [.option, .shift],
                                            characters: "ı", charactersIgnoringModifiers: "'"))
    if let failure = check("Option+Shift+B 開啟，回報字元不是字母時仍認得並關閉",
                           openHandled && openedByShortcut && closeHandled
                            && coordinator.engine.symbolPanel == nil && client.text.isEmpty && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 修飾鍵必須正好是 Option 加 Shift，鍵位必須是 B；其他組合都交還宿主。
    var strayOpened = false
    for payload in [
        KeyEventPayload(keyCode: 0, modifierFlags: [.option, .shift], characters: "ı", charactersIgnoringModifiers: "B"),
        KeyEventPayload(keyCode: 11, modifierFlags: .option, characters: "∫", charactersIgnoringModifiers: "b"),
        KeyEventPayload(keyCode: 11, modifierFlags: [.option, .shift, .control], characters: "ı", charactersIgnoringModifiers: "B"),
        KeyEventPayload(keyCode: 11, modifierFlags: [.option, .shift, .command], characters: "ı", charactersIgnoringModifiers: "B")
    ] {
        fresh()
        if send(payload) || coordinator.engine.symbolPanel != nil { strayOpened = true }
    }
    if let failure = check("其他鍵位與修飾鍵組合不開面板", !strayOpened) {
        return .failure(failure)
    }

    // Caps Lock 亮燈時不開，快捷鍵交還宿主。
    fresh()
    let capsHandled = send(KeyEventPayload(keyCode: 11, modifierFlags: [.option, .shift, .capsLock],
                                           characters: "ı", charactersIgnoringModifiers: "B"))
    if let failure = check("Caps Lock 亮燈時不開面板", !capsHandled && coordinator.engine.symbolPanel == nil) {
        return .failure(failure)
    }

    // 與讀音反查互斥：一個開著時，另一個的快捷鍵被吃掉，不開也不關。
    fresh()
    _ = send(lookupShortcut)
    let symbolsWhileLookup = send(panelShortcut)
    let lookupKept = coordinator.engine.readingLookup != nil && coordinator.engine.symbolPanel == nil
    fresh()
    _ = send(panelShortcut)
    let lookupWhileSymbols = send(lookupShortcut)
    if let failure = check("反查與符號面板互斥",
                           symbolsWhileLookup && lookupKept && lookupWhileSymbols
                            && coordinator.engine.symbolPanel != nil && coordinator.engine.readingLookup == nil) {
        return .failure(failure)
    }

    // Option+Shift+H 沒有面板時照舊切換半形標點；面板開著時不作用。
    fresh()
    let halfwidthToggle = KeyEventPayload(keyCode: 4, modifierFlags: [.option, .shift],
                                          characters: "Ó", charactersIgnoringModifiers: "H")
    let toggledWithoutPanel = send(halfwidthToggle) && !coordinator.engine.configuration.autoPunctuationEnabled
    fresh()
    _ = send(panelShortcut)
    _ = send(halfwidthToggle)
    if let failure = check("Option+Shift+H 照舊，面板開著時不改設定",
                           toggledWithoutPanel && coordinator.engine.configuration.autoPunctuationEnabled) {
        return .failure(failure)
    }

    // 組字中開啟：標記文字維持原字母，面板裡的字母、退格、標點與左右方向鍵都不進宿主。
    fresh()
    type("my")
    _ = send(panelShortcut)
    let openedOverBuffer = coordinator.engine.symbolPanel != nil && client.markedText == "my" && client.text.isEmpty
    var allHandled = true
    for payload in [key("a"), key("\u{8}", code: 51), key(",", code: 43), leftKey, rightKey, upKey] {
        if !send(payload) { allHandled = false }
    }
    if let failure = check("組字中開啟不動標記文字，面板裡的按鍵不進宿主",
                           openedOverBuffer && allHandled && client.text.isEmpty && client.markedText == "my"
                            && client.insertedStrings.isEmpty && coordinator.engine.buffer == "my"
                            && coordinator.engine.symbolPanel != nil) {
        return .failure(failure)
    }

    // Esc 完整還原：標記文字仍是 my，空白鍵照樣送出「下」。
    _ = send(escapeKey)
    let restored = coordinator.engine.symbolPanel == nil && client.text.isEmpty && client.markedText == "my"
    _ = send(spaceKey)
    if let failure = check("Esc 還原原本的組字", restored && client.text == "下") {
        return .failure(failure)
    }

    // 三條選取的路各只送出一次：數字直選、方向鍵加 Return、點選列。
    // 底下的 my 照逗號鍵的規則結束，所以符號前面是首選字「下」，不是原字母。
    fresh()
    type("my")
    _ = send(panelShortcut)
    _ = send(key("2", code: 19))
    if let failure = check("數字直選只送一次",
                           client.text == "下……" && client.insertedStrings == ["下……"] && client.markedText.isEmpty
                            && coordinator.engine.symbolPanel == nil && coordinator.engine.state == .idle) {
        return .failure(failure)
    }
    fresh()
    type("my")
    _ = send(panelShortcut)
    _ = send(downKey)
    _ = send(downKey)
    _ = send(enterKey)
    if let failure = check("方向鍵加 Return 只送一次",
                           client.text == "下‧" && client.insertedStrings == ["下‧"] && client.markedText.isEmpty
                            && coordinator.engine.symbolPanel == nil) {
        return .failure(failure)
    }
    fresh()
    type("my")
    _ = send(panelShortcut)
    coordinator.pickSymbolPanelRow(8, client: client)
    let clickedOnce = client.text == "下×" && client.insertedStrings == ["下×"] && client.markedText.isEmpty
    // 面板關掉之後才到的點選不作用。
    coordinator.pickSymbolPanelRow(8, client: client)
    if let failure = check("點選列只送一次，面板關閉後的點選不作用",
                           clickedOnce && client.text == "下×" && client.insertedStrings == ["下×"]) {
        return .failure(failure)
    }

    // 選取時底下的組字與逗號鍵相同：只有前綴送原字母，已聚焦候選送焦點字。
    fresh()
    type("yrh")
    _ = send(panelShortcut)
    _ = send(key("8", code: 28))
    let prefixOnly = client.text == "yrh×" && client.insertedStrings == ["yrh×"]
    fresh()
    type("no")
    _ = send(downKey)
    _ = send(panelShortcut)
    _ = send(key("8", code: 28))
    if let failure = check("選取時只有前綴送原字母、已聚焦候選送焦點字",
                           prefixOnly && client.text == "欠×" && client.insertedStrings == ["欠×"]
                            && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 從閒置開啟：宿主沒有標記文字，放焦點符號當暫時的標記，焦點移動時跟著換。
    // 選取、Esc、宿主結束組字三種收尾都不把暫時標記寫進文件。
    fresh()
    _ = send(panelShortcut)
    let placeholderOnOpen = client.markedText == "——" && client.text.isEmpty
    _ = send(downKey)
    let placeholderFollowsFocus = client.markedText == "……" && client.text.isEmpty
    _ = send(enterKey)
    let idlePick = client.text == "……" && client.markedText.isEmpty && client.insertedStrings == ["……"]
    fresh()
    _ = send(panelShortcut)
    _ = send(escapeKey)
    let idleCancel = client.text.isEmpty && client.markedText.isEmpty && client.insertedStrings.isEmpty
    fresh()
    _ = send(panelShortcut)
    coordinator.commitComposition(client: client)
    let idleBlur = client.text.isEmpty && client.markedText.isEmpty && client.insertedStrings.isEmpty
        && coordinator.engine.symbolPanel == nil
    if let failure = check("從閒置開啟的暫時標記與三種收尾",
                           placeholderOnOpen && placeholderFollowsFocus && idlePick && idleCancel && idleBlur) {
        return .failure(failure)
    }

    // 有選取範圍時不放暫時標記，取消後選取的文字還在。
    let selectionHost = TextViewTestClient()
    let selectionSession = InputSessionCoordinator(configuration: EngineConfiguration())
    selectionHost.view.string = "abc"
    selectionHost.view.setSelectedRange(NSRange(location: 0, length: 3))
    selectionSession.toggleSymbolPanel(client: selectionHost)
    let noPlaceholder = selectionSession.engine.symbolPanel != nil && !selectionHost.view.hasMarkedText()
    _ = selectionSession.handlePayload(escapeKey, client: selectionHost)
    if let failure = check("有選取範圍時不放暫時標記",
                           noPlaceholder && selectionHost.view.string == "abc"
                            && selectionHost.view.selectedRange() == NSRange(location: 0, length: 3)) {
        return .failure(SelfTestFailure(message: failure.message + " native='\(selectionHost.view.string)'"))
    }

    // 英文後自動補上的那一格在暫時標記的前面，選收尾標點時仍要收合。
    fresh()
    type("id")
    _ = send(tabKey)
    _ = send(panelShortcut)
    _ = send(tabKey)
    _ = send(key("4", code: 21))
    let collapsedFake = client.text == "id，" && client.insertedStrings == ["id ", "，"]
    let nativeHost = TextViewTestClient()
    let nativeSession = InputSessionCoordinator(configuration: EngineConfiguration())
    for ch in "id" { _ = nativeSession.handlePayload(key(String(ch)), client: nativeHost) }
    _ = nativeSession.handlePayload(tabKey, client: nativeHost)
    nativeSession.toggleSymbolPanel(client: nativeHost)
    let nativePlaceholder = nativeHost.view.hasMarkedText() && nativeHost.view.string == "id ——"
    _ = nativeSession.handlePayload(tabKey, client: nativeHost)
    _ = nativeSession.handlePayload(key("4", code: 21), client: nativeHost)
    if let failure = check("暫時標記前面的自動空格照樣收合",
                           collapsedFake && nativePlaceholder && nativeHost.view.string == "id，"
                            && !nativeHost.view.hasMarkedText()) {
        return .failure(SelfTestFailure(message: failure.message + " native='\(nativeHost.view.string)'"))
    }

    // 切換欄位：宿主結束組字時先丟掉面板，只送出原字母，新欄位收不到焦點符號。
    // 底下先聚焦候選「欠」：沒有面板時宿主結束組字會採用焦點字，有面板時只送原字母。
    fresh()
    type("no")
    _ = send(downKey)
    let focusedCandidate = coordinator.engine.state == .selectingCandidate
    _ = send(panelShortcut)
    _ = send(downKey)
    coordinator.commitComposition(client: client)
    let committedRaw = focusedCandidate && client.text == "no" && client.insertedStrings == ["no"]
        && coordinator.engine.symbolPanel == nil
    let newField = FakeIMKClient()
    coordinator.resetForFocusChange()
    _ = coordinator.handlePayload(spaceKey, client: newField)
    if let failure = check("切換欄位只送出原字母", committedRaw && newField.text == " ") {
        return .failure(failure)
    }

    // Cmd+V 開著面板時交還宿主，宿主只收到原字母。
    fresh()
    type("my")
    _ = send(panelShortcut)
    let pasteHandled = send(KeyEventPayload(keyCode: 9, modifierFlags: .command, characters: "v", charactersIgnoringModifiers: "v"))
    if let failure = check("面板開著時 Cmd+V 交還宿主",
                           !pasteHandled && client.text == "my" && coordinator.engine.symbolPanel == nil) {
        return .failure(failure)
    }

    // Tab 依最近使用、標點、符號的順序輪流，第三次回到最近使用；左右方向鍵翻頁。
    fresh()
    _ = send(panelShortcut)
    let recentRows = rows(coordinator)
    _ = send(tabKey)
    let punctuationTab = coordinator.engine.currentSymbolPanelContent
    let punctuationPlaceholder = client.markedText == "。"
    _ = send(rightKey)
    let secondPage = coordinator.engine.currentSymbolPanelContent
    _ = send(leftKey)
    let firstPageAgain = coordinator.engine.currentSymbolPanelContent
    _ = send(tabKey)
    let symbolsTab = coordinator.engine.currentSymbolPanelContent
    let symbolsPlaceholder = client.markedText == "【"
    _ = send(tabKey)
    let wrappedToRecent = coordinator.engine.symbolPanel?.tab == .recent && client.markedText == "——"
    if let failure = check("Tab 輪流切三個分頁、左右鍵翻頁",
                           recentRows == "——……‧〔〕※→×±"
                            && punctuationTab?.tab == .punctuation && punctuationTab?.pageCount == 5
                            && punctuationTab?.rows.map(\.symbol).joined() == "。．.，,、；;："
                            && punctuationPlaceholder
                            && secondPage?.page == 2 && secondPage?.focusedRow == 0
                            && secondPage?.rows.map(\.symbol).joined() == ":「」『』“”‘’"
                            && firstPageAgain?.page == 1 && firstPageAgain?.focusedRow == 0
                            && symbolsTab?.tab == .symbols && symbolsTab?.pageCount == 13
                            && symbolsTab?.rows.map(\.symbol).joined() == "【】〔〕［］｛｝〖"
                            && symbolsPlaceholder && wrappedToRecent
                            && client.text.isEmpty) {
        return .failure(failure)
    }

    // 分段按鈕與 Tab 同一條路：點哪個分頁就到哪個，隔一個或要繞回去也一樣，點目前這個不動。
    // 要按兩下 Tab 才到的分頁，中間那個分頁不得對外可見：宿主的標記文字只設一次，浮窗只更新一次。
    var overlayUpdates = 0
    let countOverlay: OverlayUpdate = { _, _, _ in overlayUpdates += 1 }
    func clickTab(_ tab: SymbolPanel.Tab) -> Bool {
        let markedBefore = client.setMarkedTextCallCount
        let updatesBefore = overlayUpdates
        coordinator.selectSymbolPanelTab(tab, client: client, onOverlayUpdate: countOverlay)
        return client.setMarkedTextCallCount == markedBefore + 1 && overlayUpdates == updatesBefore + 1
    }
    let jumpedTwo = clickTab(.symbols)
        && coordinator.engine.symbolPanel?.tab == .symbols && client.markedText == "【"
    let markedBeforeSameTab = client.setMarkedTextCallCount
    coordinator.selectSymbolPanelTab(.symbols, client: client, onOverlayUpdate: countOverlay)
    let sameTabClick = coordinator.engine.symbolPanel?.tab == .symbols
        && client.setMarkedTextCallCount == markedBeforeSameTab
    let wrappedToPunctuation = clickTab(.punctuation)
        && coordinator.engine.symbolPanel?.tab == .punctuation && client.markedText == "。"
    let wrappedToRecentByClick = clickTab(.recent)
        && coordinator.engine.symbolPanel?.tab == .recent && client.markedText == "——"
    if let failure = check("分段按鈕切到點的那個分頁，中間的分頁不對外顯示",
                           jumpedTwo && sameTabClick && wrappedToPunctuation && wrappedToRecentByClick
                            && client.text.isEmpty) {
        return .failure(SelfTestFailure(message: failure.message
            + " jumpedTwo=\(jumpedTwo) sameTabClick=\(sameTabClick)"
            + " wrappedToPunctuation=\(wrappedToPunctuation) wrappedToRecentByClick=\(wrappedToRecentByClick)"))
    }

    // 半形標點從面板選出來原樣送出，不因中文語境改成全形。
    fresh(text: "中文")
    _ = send(panelShortcut)
    _ = send(tabKey)
    _ = send(key("5", code: 23))
    if let failure = check("半形標點原樣送出",
                           client.text == "中文," && client.insertedStrings == [","] && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 終端機：開面板時暫存的文字留在標記文字裡，暫時標記不和它疊在一起；選取後各只送一次。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    _ = send(panelShortcut)
    let stagedKept = client.text.isEmpty && client.markedText == "下" && client.insertedStrings.isEmpty
    _ = send(key("2", code: 19))
    if let failure = check("終端機：開面板時暫存文字留著，選取後各送一次",
                           stagedKept && client.text == "下……" && client.markedText.isEmpty
                            && client.insertedStrings == ["下", "……"]) {
        return .failure(failure)
    }

    // 終端機讀不回文字：暫存的 `id ` 之後從面板選收尾標點，宿主與引擎都要是 `id，`，
    // 和直接按 Ctrl+, 相同。Esc 關面板後暫存照舊，下一個標點鍵一樣收得掉那一格。
    fresh(terminal: true)
    type("id")
    _ = send(tabKey)
    _ = send(panelShortcut)
    _ = send(tabKey)
    _ = send(key("4", code: 21))
    let terminalPick = client.text == "id，" && client.insertedStrings == ["id", "，"]
        && coordinator.engine.documentText == "id，" && client.markedText.isEmpty
    fresh(terminal: true)
    type("id")
    _ = send(tabKey)
    _ = send(panelShortcut)
    _ = send(downKey)
    _ = send(escapeKey)
    let terminalEscKeepsStaged = client.text.isEmpty && client.markedText == "id "
        && coordinator.engine.symbolPanel == nil
    // 逗號鍵可以對調寬度，在這種宿主自己也先暫存成標記文字。
    _ = send(key(",", code: 43))
    if let failure = check("終端機：暫存的空格在面板選收尾標點時收合",
                           terminalPick && terminalEscKeepsStaged && client.text == "id"
                            && client.insertedStrings == ["id"] && client.markedText == ","
                            && coordinator.engine.documentText == "id,") {
        return .failure(failure)
    }

    // Shift+空白 不是選取鍵：面板、組字、文件與最近使用都不動。
    fresh()
    type("my")
    _ = send(panelShortcut)
    let recentBefore = coordinator.engine.usageHistory.symbols
    let shiftSpaceHandled = send(key(" ", code: 49, flags: .shift))
    let shiftSpaceKept = coordinator.engine.symbolPanel != nil && coordinator.engine.buffer == "my"
        && client.text.isEmpty && client.markedText == "my" && client.insertedStrings.isEmpty
        && coordinator.engine.usageHistory.symbols == recentBefore
    fresh()
    _ = send(panelShortcut)
    _ = send(key(" ", code: 49, flags: .shift))
    if let failure = check("面板開著時 Shift+空白 吃掉不動",
                           shiftSpaceHandled && shiftSpaceKept && coordinator.engine.symbolPanel != nil
                            && client.text.isEmpty && client.markedText == "——" && client.insertedStrings.isEmpty) {
        return .failure(failure)
    }

    // Home、End、往前刪除與功能鍵翻不出按鍵，面板開著時照樣吃掉，不讓宿主在面板底下動文件。
    fresh(text: "ab")
    _ = send(panelShortcut)
    var strayReleased = false
    for payload in [
        KeyEventPayload(keyCode: 117, modifierFlags: .function, characters: "\u{F728}", charactersIgnoringModifiers: "\u{F728}"),
        KeyEventPayload(keyCode: 115, modifierFlags: .function, characters: "\u{F729}", charactersIgnoringModifiers: "\u{F729}"),
        KeyEventPayload(keyCode: 119, modifierFlags: .function, characters: "\u{F72B}", charactersIgnoringModifiers: "\u{F72B}"),
        KeyEventPayload(keyCode: 122, modifierFlags: .function, characters: "\u{F704}", charactersIgnoringModifiers: "\u{F704}")
    ] {
        if !send(payload) { strayReleased = true }
    }
    if let failure = check("面板開著時 Home、End、往前刪除與功能鍵不交還宿主",
                           !strayReleased && coordinator.engine.symbolPanel != nil && client.text == "ab"
                            && client.markedText == "——" && client.insertedStrings.isEmpty) {
        return .failure(failure)
    }

    // 最近使用跨宿主共用、存檔重載，清除學習紀錄後回到初始的那一組。
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("goshawk-self-test-symbols-\(ProcessInfo.processInfo.processIdentifier)/usage-history.json")
    defer { try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent()) }
    let store = UsageHistoryStore(fileURL: historyURL)
    fresh()
    coordinator = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: store)
    _ = send(panelShortcut)
    _ = send(key("8", code: 28))
    let otherHost = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: store)
    let otherClient = FakeIMKClient()
    _ = otherHost.handlePayload(panelShortcut, client: otherClient)
    let sharedRows = rows(otherHost)
    _ = otherHost.handlePayload(escapeKey, client: otherClient)
    let reloadedSymbols = UsageHistoryStore(fileURL: historyURL).history.symbols
    do {
        try otherHost.clearUsageHistory()
    } catch {
        return .failure(SelfTestFailure(message: error.localizedDescription))
    }
    _ = send(panelShortcut)
    let clearedRows = rows(coordinator)
    if let failure = check("最近使用跨宿主共用、存檔並可清除",
                           client.text == "×" && sharedRows == "×——……‧〔〕※→±" && reloadedSymbols == ["×"]
                            && clearedRows == "——……‧〔〕※→×±"
                            && !FileManager.default.fileExists(atPath: historyURL.path)) {
        return .failure(SelfTestFailure(message: failure.message + " shared='\(sharedRows ?? "nil")' reloaded=\(reloadedSymbols)"))
    }

    // 版面的純計算：三欄文字、分組、頁尾、無障礙標籤與朗讀內容。
    let bracketRow = SymbolPanelContent.Row(number: 1, symbol: "【", name: "左方頭括號",
                                            englishName: "Left black lenticular bracket",
                                            group: "其他括號", englishGroup: "Other brackets")
    let spaceRow = SymbolPanelContent.Row(number: 2, symbol: "　", name: "全形空格",
                                          englishName: "Ideographic space",
                                          group: "其他標點", englishGroup: "Other punctuation")
    let samplePanel = SymbolPanelContent(tab: .recent, rows: [bracketRow, spaceRow], focusedRow: 1, page: 1, pageCount: 2)
    let movedPanel = SymbolPanelContent(tab: .recent, rows: [bracketRow, spaceRow], focusedRow: 0, page: 1, pageCount: 2)
    let otherTabPanel = SymbolPanelContent(tab: .symbols, rows: [bracketRow, spaceRow], focusedRow: 1, page: 1, pageCount: 2)
    let punctuationPanel = SymbolPanelContent(tab: .punctuation, rows: [bracketRow, spaceRow], focusedRow: 0, page: 1, pageCount: 5)
    let emptyPanel = SymbolPanelContent(tab: .symbols, rows: [], focusedRow: nil, page: 1, pageCount: 1)
    let hints = "1–9 選取  ←→ 翻頁  Tab 切換分頁  Esc 關閉"
    let layoutOK = SymbolPanelView.columns(for: bracketRow) == ("1", "【", "左方頭括號")
        && SymbolPanelView.columns(for: spaceRow) == ("2", "　", "全形空格")
        && SymbolPanelView.tabs == [.recent, .punctuation, .symbols]
        && SymbolPanelView.tabs.map(SymbolPanelView.tabTitle) == ["最近使用", "標點", "符號"]
        && SymbolPanelView.accessibilityLabel(for: punctuationPanel) == "符號面板，標點，第 1 頁，共 5 頁"
        && SymbolPanelView.announcement(from: samplePanel, to: punctuationPanel) == "標點，第 1 列，【，左方頭括號，第 1 頁，共 5 頁"
        && SymbolPanelView.groupText(for: samplePanel) == "其他標點"
        && SymbolPanelView.groupText(for: movedPanel) == "其他括號"
        && SymbolPanelView.groupText(for: emptyPanel).isEmpty
        && SymbolPanelView.footerText(for: samplePanel) == "第 1 頁，共 2 頁  \(hints)"
        && SymbolPanelView.footerText(for: emptyPanel) == hints
        && SymbolPanelView.rowAccessibilityLabel(for: bracketRow) == "第 1 列，【，左方頭括號"
        && SymbolPanelView.accessibilityLabel(for: samplePanel) == "符號面板，最近使用，第 1 頁，共 2 頁"
        && SymbolPanelView.accessibilityLabel(for: emptyPanel) == "符號面板，符號"
        && SymbolPanelView.announcement(from: nil, to: samplePanel) == nil
        && SymbolPanelView.announcement(from: samplePanel, to: samplePanel) == nil
        && SymbolPanelView.announcement(from: samplePanel, to: movedPanel) == "第 1 列，【，左方頭括號，第 1 頁，共 2 頁"
        && SymbolPanelView.announcement(from: samplePanel, to: otherTabPanel) == "符號，第 2 列，　，全形空格，第 1 頁，共 2 頁"
    if let failure = check("版面文字", layoutOK) {
        return .failure(SelfTestFailure(message: failure.message
            + " footer='\(SymbolPanelView.footerText(for: samplePanel))'"
            + " label='\(SymbolPanelView.accessibilityLabel(for: samplePanel))'"
            + " spoken='\(SymbolPanelView.announcement(from: samplePanel, to: otherTabPanel) ?? "nil")'"))
    }

    // 符號與分組的名稱依介面語系挑符號表的那一欄，不查翻譯表。
    Localization.current = Localization(strings: [
        UIText.symbolRowLabel.rawValue: "Row %1$d, %2$@, %3$@",
        UIText.symbolTabRecent.rawValue: "Recent",
        UIText.symbolTabPunctuation.rawValue: "Punctuation",
        UIText.symbolTabSymbols.rawValue: "Symbols"
    ])
    let englishOK = SymbolPanelView.columns(for: bracketRow).name == "Left black lenticular bracket"
        && SymbolPanelView.groupText(for: samplePanel) == "Other punctuation"
        && SymbolPanelView.rowAccessibilityLabel(for: spaceRow) == "Row 2, 　, Ideographic space"
        && SymbolPanelView.tabs.map(SymbolPanelView.tabTitle) == ["Recent", "Punctuation", "Symbols"]
    Localization.current = Localization()
    if let failure = check("英文介面顯示符號表的英文名稱", englishOK) {
        return .failure(failure)
    }

    // 實際顯示：面板取代雙軌內容，不取得鍵盤焦點，列與分段按鈕點得到，結果與鍵盤相同。
    guard let screen = NSScreen.main else {
        return .failure(SelfTestFailure(message: "Missing screen for symbol panel checks"))
    }
    fresh()
    let window = CandidateOverlayPanel()
    defer { window.orderOut(nil) }
    let cursor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18)
    let render: OverlayUpdate = { overlay, layerPanel, _ in
        window.update(
            overlay: overlay,
            layerPanel: layerPanel,
            cursorRect: cursor,
            showsEnglishActions: coordinator.englishActionsAvailable
        )
    }
    window.onSymbolRowClick = { row in
        coordinator.pickSymbolPanelRow(row, client: client, onOverlayUpdate: render)
    }
    window.onSymbolTabClick = { tab in
        coordinator.selectSymbolPanelTab(tab, client: client, onOverlayUpdate: render)
    }
    func press(_ payload: KeyEventPayload) {
        _ = coordinator.handlePayload(payload, client: client, onOverlayUpdate: render)
    }
    press(key("m"))
    press(key("y"))
    let dualHeight = window.frame.height
    press(panelShortcut)
    let shown = window.isVisible && !window.isKeyWindow && window.frame.height > dualHeight
        && !window.ignoresMouseEvents && !window.symbolView.isHidden
        && window.symbolView.rowViews.count == 9 && window.symbolView.tabControl.selectedSegment == 0
        && window.symbolView.tabControl.segmentCount == 3
        && (0..<3).map({ window.symbolView.tabControl.label(forSegment: $0) }) == ["最近使用", "標點", "符號"]
    // 點第三段要連按兩次 Tab 才到；再點第二段得繞過最近使用回來。
    window.symbolView.tabControl.selectedSegment = 2
    window.symbolView.tabControl.performClick(nil)
    let thirdSegmentClicked = coordinator.engine.symbolPanel?.tab == .symbols
        && window.symbolView.tabControl.selectedSegment == 2 && window.symbolView.rowViews.count == 9
    window.symbolView.tabControl.selectedSegment = 1
    window.symbolView.tabControl.performClick(nil)
    let tabClicked = thirdSegmentClicked && coordinator.engine.symbolPanel?.tab == .punctuation
        && window.symbolView.tabControl.selectedSegment == 1 && window.symbolView.rowViews.count == 9
    guard let click = NSEvent.mouseEvent(
        with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ), window.symbolView.rowViews.count > 1 else {
        return .failure(SelfTestFailure(message: "符號面板：做不出滑鼠事件或面板沒有列"))
    }
    window.symbolView.rowViews[1].mouseDown(with: click)
    let rowClicked = client.text == "下．" && client.insertedStrings == ["下．"]
        && coordinator.engine.symbolPanel == nil && !window.isVisible
    press(key("m"))
    press(panelShortcut)
    press(escapeKey)
    let backToDual = window.isVisible && window.ignoresMouseEvents && window.symbolView.isHidden
    press(escapeKey)
    if let failure = check("面板顯示在共用浮窗，可點且不搶鍵盤焦點",
                           shown && tabClicked && rowClicked && backToDual && !window.isVisible) {
        return .failure(SelfTestFailure(message: failure.message
            + " shown=\(shown) tabClicked=\(tabClicked) rowClicked=\(rowClicked) backToDual=\(backToDual)"))
    }

    return .success(passed)
}

/// 一鍵反悔的外層檢查。兩種模擬宿主各走一遍：讀得回文字的一般欄位立即送出、反悔時取代；
/// 永遠回報游標在 0 的終端機把可反悔的送出暫存成標記文字，下一個按鍵才落地。
@MainActor
func runRevertChecks() -> Result<Int, SelfTestFailure> {
    var passed = 0
    var coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
    var client = FakeIMKClient()

    func send(_ payload: KeyEventPayload) -> Bool {
        coordinator.handlePayload(payload, client: client)
    }
    func type(_ letters: String) {
        for ch in letters {
            _ = send(KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)))
        }
    }
    /// `verified` 是已經確認讀得回文字、游標又回到空文件開頭的欄位：先送出一個字再把文件清空。
    /// 這種欄位的第一個標點照舊立即送出，用來驗立即取代那條路；沒確認過的欄位第一鍵會先暫存。
    func fresh(terminal: Bool = false, text: String = "", verified: Bool = false) {
        coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
        client = FakeIMKClient()
        client.text = text
        if terminal {
            client.reportsCursorAtZero = true
            client.allowsReadingText = false
        }
        if verified {
            type("my")
            _ = send(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "))
            client.text = ""
            client.insertedStrings = []
        }
    }
    func check(_ name: String, _ condition: Bool) -> SelfTestFailure? {
        if condition {
            passed += 1
            return nil
        }
        return SelfTestFailure(message: "\(name): text='\(client.text)' marked='\(client.markedText)' inserted=\(client.insertedStrings) staged='\(coordinator.stagedCommit ?? "nil")' hint='\(coordinator.revertHint ?? "nil")' state=\(coordinator.engine.state.rawValue) buffer='\(coordinator.engine.buffer)'")
    }
    func key(_ ch: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> KeyEventPayload {
        KeyEventPayload(keyCode: code, modifierFlags: flags, characters: ch, charactersIgnoringModifiers: ch)
    }
    let spaceKey = key(" ", code: 49)
    let shiftSpaceKey = key(" ", code: 49, flags: .shift)
    let tabKey = key("\t", code: 48)
    let enterKey = key("\r", code: 36)
    let commaKey = key(",", code: 43)
    let backspaceKey = key("\u{8}", code: 51)
    // `!` 要按著 Shift 才打得出來，用來驗防誤觸。
    let bangKey = key("!", code: 18, flags: .shift)
    let shiftDown = KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: .shift, timestamp: 5)
    let shiftUp = KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, timestamp: 6)
    let pasteKey = KeyEventPayload(keyCode: 9, modifierFlags: .command, characters: "v", charactersIgnoringModifiers: "v")
    let lookupShortcut = KeyEventPayload(keyCode: 41, modifierFlags: [.control, .shift], characters: ":", charactersIgnoringModifiers: ":")
    let escapeKey = KeyEventPayload(keyCode: 53, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}")

    // ---- 讀得回文字的宿主：立即送出，反悔時取代剛送出的那段。

    // 送出、反悔、再反悔。文字從頭到尾都是正式送出的，宿主沒有殘留的標記文字。
    fresh()
    type("my")
    _ = send(spaceKey)
    let directCommit = client.text == "下" && client.markedText.isEmpty && coordinator.stagedCommit == nil
    let revertHandled = send(shiftSpaceKey)
    let directReverted = client.text == "my " && client.markedText.isEmpty
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: commit, revert, revert back",
                           directCommit && revertHandled && directReverted && client.text == "下" && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // Tab 送出英文後反悔成中文，接著打字照常：中文後面的英文補一格。
    fresh()
    type("my")
    _ = send(tabKey)
    _ = send(shiftSpaceKey)
    let tabReverted = client.text == "下"
    type("my")
    _ = send(tabKey)
    if let failure = check("Readable host: typing continues after a revert", tabReverted && client.text == "下 my ") {
        return .failure(failure)
    }

    // 中文後面接這個流程：對調成英文時中英之間補一格；再接逗號，尾端空格收合。
    fresh()
    type("my")
    _ = send(spaceKey)
    type("my")
    _ = send(spaceKey)
    _ = send(shiftSpaceKey)
    let spaced = client.text == "下 my "
    _ = send(commaKey)
    if let failure = check("Readable host: spacing after Chinese and comma collapse", spaced && client.text == "下 my,") {
        return .failure(failure)
    }

    // 按住 Shift 還沒按空白時紀錄與提示都還在；按了別的鍵之後 Shift+空白 只是空白。
    fresh()
    type("my")
    _ = send(spaceKey)
    _ = send(shiftDown)
    let survivesShiftDown = coordinator.engine.revertRecord != nil && coordinator.revertHint == "my"
    // 標點自己也會留下寬度對調的紀錄，所以改用字母加退格才看得出中英的紀錄已經失效。
    _ = send(key("a"))
    _ = send(backspaceKey)
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: the record lives for one key", survivesShiftDown && client.text == "下 ") {
        return .failure(failure)
    }

    // 標點寬度對調：只取代剛送出的那個標點，來回都一樣，而且不顯示提示。
    fresh()
    type("id")
    _ = send(tabKey)
    _ = send(commaKey)
    let widthCommitted = client.text == "id," && client.markedText.isEmpty
        && coordinator.stagedCommit == nil && coordinator.revertHint == nil
    let widthHandled = send(shiftSpaceKey)
    let widthSwapped = client.text == "id，" && coordinator.revertHint == nil
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: punctuation width swap replaces the punctuation only",
                           widthCommitted && widthHandled && widthSwapped && client.text == "id,") {
        return .failure(failure)
    }

    // VS Code 這類宿主在字數不變的取代之後，回報的前文停在取代前，要到下一次一般送出才跟上。
    // 收合空格的逗號、寬度對調都是一個字換一個字，仍然要能對調、再對調，之後打字的前文也要對。
    fresh()
    client.keepsStaleTextAfterEqualLengthReplacement = true
    type("id")
    _ = send(tabKey)
    _ = send(commaKey)
    _ = send(shiftSpaceKey)
    let staleSwapped = client.text == "id，"
    _ = send(shiftSpaceKey)
    let staleSwappedBack = client.text == "id,"
    _ = send(shiftSpaceKey)
    type("my")
    _ = send(spaceKey)
    _ = send(key(".", code: 47))
    if let failure = check("Host with stale read-back after equal-length replacement still swaps width",
                           staleSwapped && staleSwappedBack && client.text == "id，下。") {
        return .failure(failure)
    }

    // 防誤觸：按著 Shift 打出 `!` 之後手還沒放開就按空白，那是一般空白；放開再按才對調。
    fresh()
    type("id")
    _ = send(tabKey)
    _ = send(bangKey)
    let bangCommitted = client.text == "id!"
    _ = send(shiftSpaceKey)
    let heldShiftIsPlainSpace = client.text == "id! "
    fresh()
    type("id")
    _ = send(tabKey)
    _ = send(bangKey)
    _ = send(shiftUp)
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: Shift held from a shifted key keeps Shift+Space a plain space",
                           bangCommitted && heldShiftIsPlainSpace && client.text == "id！") {
        return .failure(failure)
    }

    // 文字被外力改掉：放棄反悔，什麼都不送也不刪，之後的 Shift+空白 只是空白。
    fresh()
    type("my")
    _ = send(spaceKey)
    client.text = "上"
    let insertedBefore = client.insertedStrings.count
    let abandonedHandled = send(shiftSpaceKey)
    let abandoned = client.text == "上" && client.insertedStrings.count == insertedBefore
        && coordinator.engine.revertRecord == nil && coordinator.revertHint == nil
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: foreign edit abandons the revert", abandonedHandled && abandoned && client.text == "上 ") {
        return .failure(failure)
    }

    // 後面被接了別的字、或宿主這時不給讀：同樣放棄，不盲目回刪。這個欄位之後改用暫存。
    fresh()
    type("my")
    _ = send(spaceKey)
    client.text = "下x"
    _ = send(shiftSpaceKey)
    let appendedKept = client.text == "下x"
    fresh()
    type("my")
    _ = send(tabKey)
    client.allowsReadingText = false
    _ = send(shiftSpaceKey)
    let unreadableKept = client.text == "my " && coordinator.engine.revertRecord == nil
    type("my")
    _ = send(spaceKey)
    let stagedAfterFailure = client.text == "my " && client.markedText == "下"
    _ = send(shiftSpaceKey)
    _ = send(enterKey)
    if let failure = check("Readable host: unreadable text is never deleted blindly",
                           appendedKept && unreadableKept && stagedAfterFailure && client.text == "my my ") {
        return .failure(failure)
    }

    fresh()
    type("my")
    _ = send(spaceKey)
    client.allowsReadingText = false
    _ = send(shiftSpaceKey)
    client.allowsReadingText = true
    type("id")
    _ = send(enterKey)
    let beforeNextCommit = client.text
    type("my")
    _ = send(spaceKey)
    if let failure = check("反悔遭拒後，同一欄位恢復回讀仍維持暫存",
                           client.text == beforeNextCommit && client.markedText == " 下") {
        return .failure(failure)
    }
    coordinator.commitComposition(client: client)
    coordinator.resetForFocusChange()
    client = FakeIMKClient()
    type("my")
    _ = send(spaceKey)
    if let failure = check("換欄位後恢復直接送出", client.text == "下" && client.markedText.isEmpty) {
        return .failure(failure)
    }

    fresh()
    client.allowsReadingText = false
    type("the")
    _ = send(tabKey)
    client.allowsReadingText = true
    type("my")
    _ = send(spaceKey)
    let stagedWhileUnconfirmed = !client.markedText.isEmpty && client.text == "the "
    coordinator.commitComposition(client: client)
    type("my")
    _ = send(spaceKey)
    if let failure = check("僅上次送字讀不到，確認新送出文字後可再次直接送出",
                           stagedWhileUnconfirmed && client.text == "the 下下" && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 真的 NSTextView：前文是 BMP 以外的漢字，取代範圍以 UTF-16 計算仍然只換掉剛送出的那一段。
    fresh()
    let native = TextViewTestClient()
    native.view.string = "𠮷"
    native.view.setSelectedRange(NSRange(location: 2, length: 0))
    func nativeSend(_ payload: KeyEventPayload) {
        _ = coordinator.handlePayload(payload, client: native)
    }
    nativeSend(key("m"))
    nativeSend(key("y"))
    nativeSend(spaceKey)
    let nativeCommitted = native.view.string == "𠮷下" && !native.view.hasMarkedText()
    nativeSend(shiftSpaceKey)
    let nativeReverted = native.view.string == "𠮷 my " && !native.view.hasMarkedText()
    nativeSend(shiftSpaceKey)
    if let failure = check("Native text view: revert replaces exactly the committed range",
                           nativeCommitted && nativeReverted && native.view.string == "𠮷下") {
        return .failure(SelfTestFailure(message: failure.message + " native='\(native.view.string)'"))
    }

    // 送出後當下讀不到，直到按反悔才讀得到舊文字。用真正的標記範圍測後續的空格收合。
    fresh()
    native.view.string = ""
    native.view.setSelectedRange(NSRange(location: 0, length: 0))
    nativeSend(key("m"))
    nativeSend(key("y"))
    native.allowsReadingText = false
    nativeSend(spaceKey)
    native.allowsReadingText = true
    nativeSend(shiftSpaceKey)
    let delayedRevert = native.view.string == "my " && native.view.hasMarkedText()
    nativeSend(commaKey)
    coordinator.commitComposition(client: native)
    if let failure = check("送字延遲讀回時，反悔僅取代已確認的字，逗號收合暫存的尾空格",
                           delayedRevert && native.view.string == "my," && !native.view.hasMarkedText()) {
        return .failure(SelfTestFailure(message: failure.message + " native='\(native.view.string)'"))
    }

    // 學習紀錄：Tab 記了一次 my，反悔成中文後存檔裡也沒有這一筆。
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("goshawk-self-test-revert-\(ProcessInfo.processInfo.processIdentifier)/usage-history.json")
    defer { try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent()) }
    let store = UsageHistoryStore(fileURL: historyURL)
    fresh()
    coordinator = InputSessionCoordinator(configuration: EngineConfiguration(), usageStore: store)
    type("my")
    _ = send(tabKey)
    let learnedMy = store.history.english.first?.word == "my"
    _ = send(shiftSpaceKey)
    let forgotten = store.history.english.isEmpty && client.text == "下"
    // 其他宿主在這中間清掉了紀錄：不反悔，否則舊紀錄會被寫回去。
    type("my")
    _ = send(tabKey)
    do {
        try store.clear()
    } catch {
        return .failure(SelfTestFailure(message: error.localizedDescription))
    }
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: learning follows the revert",
                           learnedMy && forgotten && client.text == "下 my  " && store.history.english.isEmpty) {
        return .failure(failure)
    }

    // 關閉設定：送出後的 Shift+空白 是原本的空白，沒有提示。
    fresh()
    coordinator.updateConfiguration(client: client) { $0.revertEnabled = false }
    type("my")
    _ = send(spaceKey)
    let noHint = coordinator.revertHint == nil
    _ = send(shiftSpaceKey)
    if let failure = check("Revert disabled keeps Shift+Space a plain space", noHint && client.text == "下 ") {
        return .failure(failure)
    }

    // ---- 讀不回文字的宿主（終端機）：可反悔的送出先暫存成標記文字。

    // 送出、反悔、再反悔都只換標記文字，宿主一個字都還沒收下；下一個按鍵才正式送出一次。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    let stagedCommit = client.text.isEmpty && client.markedText == "下" && coordinator.stagedCommit == "下"
    _ = send(shiftDown)
    let stagedSurvivesShift = client.markedText == "下" && client.insertedStrings.isEmpty
    _ = send(shiftSpaceKey)
    let stagedReverted = client.text.isEmpty && client.markedText == "my "
    _ = send(shiftSpaceKey)
    let stagedBack = client.text.isEmpty && client.markedText == "下" && client.insertedStrings.isEmpty
    type("a")
    if let failure = check("Terminal: commit, revert, revert back stay in marked text",
                           stagedCommit && stagedSurvivesShift && stagedReverted && stagedBack
                            && client.text == "下" && client.markedText == "a" && client.insertedStrings == ["下"]
                            && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 反悔成英文後接逗號：尾端空格直接在暫存字串上收掉，逗號自己也先暫存一個按鍵。
    // 接著繼續打字，下一個可反悔的送出再暫存。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    _ = send(shiftSpaceKey)
    _ = send(commaKey)
    let collapsed = client.text == "my" && client.markedText == ","
        && client.insertedStrings == ["my"]
    type("ok")
    let commaDelivered = client.text == "my," && client.insertedStrings == ["my", ","]
    _ = send(tabKey)
    let stagedAgain = client.text == "my," && client.markedText == "ok "
    type("b")
    if let failure = check("Terminal: comma collapses the staged space and typing continues",
                           collapsed && commaDelivered && stagedAgain
                            && client.text == "my,ok " && client.markedText == "b") {
        return .failure(failure)
    }

    // 終端機的標點寬度對調：半形逗號先當標記文字，Shift+空白 直接換掉它，下一個按鍵才落地。
    fresh(terminal: true)
    type("id")
    _ = send(tabKey)
    _ = send(commaKey)
    let widthStaged = client.text == "id" && client.markedText == ","
        && coordinator.stagedCommit == "," && client.insertedStrings == ["id"]
    _ = send(shiftSpaceKey)
    let widthStagedSwap = client.text == "id" && client.markedText == "，"
        && coordinator.stagedCommit == "，" && client.insertedStrings == ["id"]
    _ = send(enterKey)
    if let failure = check("Terminal: punctuation width swap stays in marked text",
                           widthStaged && widthStagedSwap && client.text == "id，"
                            && client.insertedStrings == ["id", "，"] && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 不可反悔的送出照舊立即送出，不經過暫存。
    fresh(terminal: true)
    type("the")
    _ = send(spaceKey)
    let plainImmediate = client.text == "the " && client.markedText.isEmpty && coordinator.stagedCommit == nil
    type("my")
    _ = send(enterKey)
    if let failure = check("Terminal: other commits are immediate", plainImmediate && client.text == "the my" && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // Enter：暫存的文字先送出一次，Enter 交還宿主。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    let enterHandled = send(enterKey)
    if let failure = check("Terminal: Enter delivers the staged text once",
                           !enterHandled && client.text == "下" && client.markedText.isEmpty && client.insertedStrings == ["下"]
                            && coordinator.stagedCommit == nil && coordinator.revertHint == nil) {
        return .failure(failure)
    }

    // Cmd+V：先送出暫存的文字，快捷鍵交還宿主。
    fresh(terminal: true)
    type("my")
    _ = send(tabKey)
    let pasteHandled = send(pasteKey)
    if let failure = check("Terminal: Cmd+V delivers the staged text once",
                           !pasteHandled && client.text == "my " && client.markedText.isEmpty && client.insertedStrings == ["my "]) {
        return .failure(failure)
    }

    // 切換欄位：宿主結束組字時送出一次，新欄位不會收到舊文字，也不能反悔到舊欄位去。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    coordinator.commitComposition(client: client)
    coordinator.commitComposition(client: client)
    coordinator.resetForFocusChange()
    let deliveredOnce = client.text == "下" && client.insertedStrings == ["下"]
    let newField = FakeIMKClient()
    _ = coordinator.handlePayload(shiftSpaceKey, client: newField)
    // 沒有先收到結束組字就換了欄位：暫存的文字不帶進新欄位。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    coordinator.resetForFocusChange()
    let otherField = FakeIMKClient()
    _ = coordinator.handlePayload(spaceKey, client: otherField)
    if let failure = check("Terminal: focus change delivers the staged text once",
                           deliveredOnce && newField.text == " " && otherField.text == " " && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 開啟反查：先送出暫存的文字，再放反查的暫時讀音，兩段標記不會疊在一起。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    _ = send(lookupShortcut)
    let lookupOpened = client.text == "下" && client.markedText == "？" && client.insertedStrings == ["下"]
        && coordinator.engine.readingLookup != nil
    _ = send(escapeKey)
    if let failure = check("Terminal: opening the lookup delivers the staged text first",
                           lookupOpened && client.text == "下" && client.markedText.isEmpty && client.insertedStrings == ["下"]) {
        return .failure(failure)
    }

    // Caps Lock 亮燈與選單切純英文也都先送出暫存的文字。
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 57, modifierFlags: .capsLock))
    let capsDelivered = client.text == "下" && client.markedText.isEmpty && client.insertedStrings == ["下"]
    fresh(terminal: true)
    type("my")
    _ = send(spaceKey)
    coordinator.togglePureEnglish(client: client)
    if let failure = check("Terminal: Caps Lock and the menu deliver the staged text",
                           capsDelivered && client.text == "下" && client.insertedStrings == ["下"]
                            && coordinator.engine.state == .pureEnglish) {
        return .failure(failure)
    }

    // 宿主明說不支援文件存取：即使讀得回文字也用暫存。
    fresh()
    client.declaresDocumentAccess = false
    type("my")
    _ = send(spaceKey)
    let declaredStaged = client.text.isEmpty && client.markedText == "下"
    _ = send(shiftSpaceKey)
    _ = send(enterKey)
    if let failure = check("Host without document access uses the staged path", declaredStaged && client.text == "my ") {
        return .failure(failure)
    }

    // ---- 左方括號的八種循環：每一下只取代那個開頭，選項列跟著目前的種類，下一個按鍵就清掉。
    let leftBracketKey = key("[", code: 33)
    let rightBracketKey = key("]", code: 30)

    fresh(verified: true)
    _ = send(leftBracketKey)
    let openerTyped = client.text == "「" && coordinator.pairChoice == nil && coordinator.revertHint == nil
    _ = send(shiftSpaceKey)
    let openerFirst = client.text == "[" && coordinator.pairChoice == PairChoice(current: .square, digitsPick: false)
    _ = send(shiftSpaceKey)
    _ = send(shiftSpaceKey)
    let openerThird = client.text == "《" && client.markedText.isEmpty && coordinator.stagedCommit == nil
        && coordinator.pairChoice == PairChoice(current: .doubleAngle, digitsPick: false)
        && coordinator.revertHint == nil
    type("a")
    let choiceCleared = coordinator.pairChoice == nil
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    if let failure = check("Readable host: the opener cycles through the pair styles in place",
                           openerTyped && openerFirst && openerThird && choiceCleared && client.text == "《日》") {
        return .failure(failure)
    }

    // 連帶送出的前綴整段取代，前綴本身不變。
    fresh()
    type("a")
    _ = send(leftBracketKey)
    _ = send(shiftSpaceKey)
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: the opener cycle replaces the prefix it was committed with",
                           client.text == "日『" && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 等長取代後回報停在取代前的宿主：連切三次仍然換得掉，之後打字與結尾的前文也對。
    fresh(verified: true)
    client.keepsStaleTextAfterEqualLengthReplacement = true
    _ = send(leftBracketKey)
    _ = send(shiftSpaceKey)
    _ = send(shiftSpaceKey)
    _ = send(shiftSpaceKey)
    let staleCycled = client.text == "《"
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    if let failure = check("Host with stale read-back still cycles the opener three times",
                           staleCycled && client.text == "《下》") {
        return .failure(failure)
    }

    // 外力改過內容：放棄、吃掉按鍵、文件不動，選項列也收掉。
    fresh(verified: true)
    _ = send(leftBracketKey)
    _ = send(shiftSpaceKey)
    client.text = "上"
    let cycleInsertedBefore = client.insertedStrings.count
    let cycleAbandonedHandled = send(shiftSpaceKey)
    if let failure = check("Readable host: foreign edit abandons the opener cycle",
                           cycleAbandonedHandled && client.text == "上"
                            && client.insertedStrings.count == cycleInsertedBefore
                            && coordinator.pairChoice == nil && coordinator.engine.revertRecord == nil) {
        return .failure(failure)
    }

    // 終端機：開頭先當標記文字，循環三次都只換那段標記，下一個按鍵才落地，而且只落地一次。
    fresh(terminal: true)
    type("id")
    _ = send(tabKey)
    _ = send(leftBracketKey)
    let openerStaged = client.text == "id " && client.markedText == "["
        && coordinator.stagedCommit == "[" && client.insertedStrings == ["id "]
    _ = send(shiftSpaceKey)
    _ = send(shiftSpaceKey)
    _ = send(shiftSpaceKey)
    let openerStagedCycle = client.text == "id " && client.markedText == "《"
        && coordinator.stagedCommit == "《" && client.insertedStrings == ["id "]
        && coordinator.pairChoice == PairChoice(current: .doubleAngle, digitsPick: false)
    _ = send(enterKey)
    if let failure = check("Terminal: the opener cycle stays in marked text and lands once",
                           openerStaged && openerStagedCycle && client.text == "id 《"
                            && client.insertedStrings == ["id ", "《"] && coordinator.stagedCommit == nil
                            && coordinator.pairChoice == nil) {
        return .failure(failure)
    }

    // ---- 配到開頭的右方括號之後成對切換：整段讀回相符才一次取代，走不了就吃掉按鍵。

    // 讀得回的宿主：每一下都是一次整段取代，沒有標記文字；之後照常打字。
    fresh()
    _ = send(leftBracketKey)
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    let pairTyped = client.text == "「下」" && coordinator.pairChoice == nil && coordinator.stagedCommit == nil
    let pairInsertsBefore = client.insertedStrings.count
    let pairMarksBefore = client.setMarkedTextCallCount
    let pairHandled = send(shiftSpaceKey)
    let pairFirst = client.text == "[下]" && client.insertedStrings.last == "[下]"
        && client.insertedStrings.count == pairInsertsBefore + 1
        && coordinator.pairChoice == PairChoice(current: .square, digitsPick: true)
        && coordinator.revertHint == nil
    _ = send(shiftSpaceKey)
    let pairSecond = client.text == "『下』" && client.markedText.isEmpty && coordinator.stagedCommit == nil
        && client.setMarkedTextCallCount == pairMarksBefore
        && coordinator.pairChoice == PairChoice(current: .doubleCorner, digitsPick: true)
    type("a")
    let pairChoiceCleared = coordinator.pairChoice == nil
    _ = send(spaceKey)
    type("id")
    _ = send(tabKey)
    if let failure = check("Readable host: the pair switch replaces the whole span in one insert",
                           pairTyped && pairHandled && pairFirst && pairSecond && pairChoiceCleared
                            && client.text == "『下』日 id ") {
        return .failure(failure)
    }

    // 數字直選：緊接一次切換的數字走同一條「讀回整段再一次取代」，選完之後的數字是內容。
    let digitFourKey = key("4", code: 21)
    fresh()
    _ = send(leftBracketKey)
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(shiftSpaceKey)
    let pickInsertsBefore = client.insertedStrings.count
    let pickMarksBefore = client.setMarkedTextCallCount
    let pickHandled = send(digitFourKey)
    let picked = client.text == "《下》" && client.insertedStrings.last == "《下》"
        && client.insertedStrings.count == pickInsertsBefore + 1
        && client.setMarkedTextCallCount == pickMarksBefore && coordinator.stagedCommit == nil
        && coordinator.pairChoice == PairChoice(current: .doubleAngle, digitsPick: false)
    _ = send(digitFourKey)
    let digitIsContent = client.text == "《下》4" && coordinator.pairChoice == nil
    if let failure = check("Readable host: a digit right after a pair switch picks the style, the next digit is content",
                           pickHandled && picked && digitIsContent) {
        return .failure(failure)
    }

    // 選完可以接著循環，再切換一次之後數字又能直選。
    fresh()
    _ = send(leftBracketKey)
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(shiftSpaceKey)
    _ = send(digitFourKey)
    _ = send(shiftSpaceKey)
    let cycledAfterPick = client.text == "〈下〉"
        && coordinator.pairChoice == PairChoice(current: .singleAngle, digitsPick: true)
    _ = send(key("1", code: 18))
    if let failure = check("Readable host: the cycle continues after a digit pick",
                           cycledAfterPick && client.text == "「下」") {
        return .failure(failure)
    }

    // 沒切換過的結尾後面，數字是內容。
    fresh()
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(key("1", code: 18))
    if let failure = check("Readable host: a digit after an unswitched closer is content", client.text == "「日」1") {
        return .failure(failure)
    }

    // 直選前外力改過內容：放棄、吃掉那個數字、文件不動，欄位不降級。
    fresh()
    _ = send(leftBracketKey)
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(shiftSpaceKey)
    client.text = "[上]"
    let editedPickInsertsBefore = client.insertedStrings.count
    let editedPickHandled = send(digitFourKey)
    let editedPickKept = client.text == "[上]" && client.insertedStrings.count == editedPickInsertsBefore
        && client.markedText.isEmpty && coordinator.pairChoice == nil && coordinator.engine.revertRecord == nil
    type("my")
    _ = send(spaceKey)
    if let failure = check("Readable host: a foreign edit abandons the digit pick without downgrading the field",
                           editedPickHandled && editedPickKept && client.text == "[上] 下"
                            && client.markedText.isEmpty && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 收合掉的空格不會回來，開頭前面那一格不動。
    fresh()
    type("id")
    _ = send(tabKey)
    _ = send(leftBracketKey)
    type("id")
    _ = send(tabKey)
    _ = send(rightBracketKey)
    let spacedPairTyped = client.text == "id [id]"
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: the pair switch keeps the spaces",
                           spacedPairTyped && client.text == "id 「id」" && client.insertedStrings.last == "「id」") {
        return .failure(failure)
    }

    // 巢狀：只換最內層剛關上的那一對。
    fresh()
    _ = send(leftBracketKey)
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(shiftSpaceKey)
    let innerSwitched = client.text == "「[日]"
    _ = send(rightBracketKey)
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: the pair switch only touches the pair just closed",
                           innerSwitched && client.text == "[[日]]") {
        return .failure(failure)
    }

    // 真的 NSTextView：整段含 BMP 以外的漢字，取代範圍以 UTF-16 計算，游標留在結尾後面。
    fresh()
    native.allowsReadingText = true
    native.view.string = "前「𠮷"
    native.view.setSelectedRange(NSRange(location: 4, length: 0))
    nativeSend(rightBracketKey)
    let nativePairTyped = native.view.string == "前「𠮷」"
    nativeSend(shiftSpaceKey)
    let nativePairFirst = native.view.string == "前[𠮷]" && !native.view.hasMarkedText()
        && native.view.selectedRange() == NSRange(location: 5, length: 0)
    nativeSend(shiftSpaceKey)
    nativeSend(key("a"))
    nativeSend(spaceKey)
    if let failure = check("Native text view: the pair switch replaces exactly the span",
                           nativePairTyped && nativePairFirst && native.view.string == "前『𠮷』日"
                            && !native.view.hasMarkedText()) {
        return .failure(SelfTestFailure(message: failure.message + " native='\(native.view.string)'"))
    }

    // 等長取代後回報停在取代前的宿主：整段連切三次仍然換得掉，之後打字的前文也對。
    fresh()
    client.keepsStaleTextAfterEqualLengthReplacement = true
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(shiftSpaceKey)
    let stalePairFirst = client.text == "[日]"
    _ = send(shiftSpaceKey)
    let stalePairSecond = client.text == "『日』"
    _ = send(shiftSpaceKey)
    let stalePairThird = client.text == "《日》"
    type("my")
    _ = send(spaceKey)
    _ = send(key(".", code: 47))
    if let failure = check("Host with stale read-back still switches the whole pair three times",
                           stalePairFirst && stalePairSecond && stalePairThird && client.text == "《日》下。") {
        return .failure(failure)
    }

    // 外力改過整段裡的內容：放棄、吃掉按鍵、文件不動。欄位不降級，之後可反悔的送出仍立即送出。
    fresh()
    _ = send(leftBracketKey)
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    client.text = "「上」"
    let editedInsertsBefore = client.insertedStrings.count
    let editedHandled = send(shiftSpaceKey)
    let editedKept = client.text == "「上」" && client.insertedStrings.count == editedInsertsBefore
        && client.markedText.isEmpty && coordinator.pairChoice == nil && coordinator.engine.revertRecord == nil
    type("my")
    _ = send(spaceKey)
    let notDowngraded = client.text == "「上」下" && client.markedText.isEmpty && coordinator.stagedCommit == nil
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: a foreign edit abandons the pair switch without downgrading the field",
                           editedHandled && editedKept && notDowngraded && client.text == "「上」my ") {
        return .failure(failure)
    }

    // 有選取範圍：同樣放棄，選取的文字不會被取代，欄位不降級。
    fresh()
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    client.selectedLength = 2
    let selectionInsertsBefore = client.insertedStrings.count
    let selectionHandled = send(shiftSpaceKey)
    let selectionKept = client.text == "「日」" && client.insertedStrings.count == selectionInsertsBefore
        && coordinator.engine.revertRecord == nil && coordinator.pairChoice == nil
    client.selectedLength = 0
    type("my")
    _ = send(spaceKey)
    if let failure = check("Readable host: a selection abandons the pair switch",
                           selectionHandled && selectionKept && client.text == "「日」下" && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 結尾送出後當下讀不回：不用帶取代範圍的標記文字去換整段，吃掉按鍵。
    fresh()
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    client.allowsReadingText = false
    _ = send(rightBracketKey)
    client.allowsReadingText = true
    let unreadableCloser = client.text == "「日」" && client.markedText.isEmpty && coordinator.stagedCommit == nil
    let unreadableMarksBefore = client.setMarkedTextCallCount
    let unreadableInsertsBefore = client.insertedStrings.count
    let unreadableHandled = send(shiftSpaceKey)
    if let failure = check("Host whose last commit was unreadable swallows the pair switch",
                           unreadableCloser && unreadableHandled && client.text == "「日」"
                            && client.markedText.isEmpty && coordinator.stagedCommit == nil
                            && client.setMarkedTextCallCount == unreadableMarksBefore
                            && client.insertedStrings.count == unreadableInsertsBefore
                            && coordinator.engine.revertRecord == nil) {
        return .failure(failure)
    }

    // 引擎判定整段換不了（跨行）：按鍵被吃掉，文件不動，再按一次才是一般空白。
    fresh(text: "「日\n月")
    _ = send(rightBracketKey)
    let multilineClosed = client.text == "「日\n月」"
    let multilineInsertsBefore = client.insertedStrings.count
    let multilineHandled = send(shiftSpaceKey)
    let multilineKept = client.text == "「日\n月」" && client.insertedStrings.count == multilineInsertsBefore
    _ = send(shiftSpaceKey)
    if let failure = check("Readable host: a pair spanning lines is not switched",
                           multilineClosed && multilineHandled && multilineKept && client.text == "「日\n月」 ") {
        return .failure(failure)
    }

    // 終端機與讀不到文字的宿主：結尾照常暫存，Shift+空白 被吃掉，暫存不動，下一個按鍵只落地一次。
    for terminal in [true, false] {
        fresh(terminal: terminal)
        client.allowsReadingText = false
        type("id")
        _ = send(tabKey)
        _ = send(leftBracketKey)
        type("a")
        _ = send(spaceKey)
        _ = send(rightBracketKey)
        let closerStaged = client.text == "id [日" && client.markedText == "]" && coordinator.stagedCommit == "]"
        let stagedInsertsBefore = client.insertedStrings
        let stagedMarksBefore = client.setMarkedTextCallCount
        let stagedHandled = send(shiftSpaceKey)
        let stagedKept = client.text == "id [日" && client.markedText == "]" && coordinator.stagedCommit == "]"
            && client.insertedStrings == stagedInsertsBefore
            && client.setMarkedTextCallCount == stagedMarksBefore
            && coordinator.pairChoice == nil && coordinator.engine.revertRecord == nil
        _ = send(enterKey)
        if let failure = check("Unreadable host: the staged closer is not switched and lands once (terminal=\(terminal))",
                               closerStaged && stagedHandled && stagedKept && client.text == "id [日]"
                                && client.insertedStrings == stagedInsertsBefore + ["]"]
                                && coordinator.stagedCommit == nil) {
            return .failure(failure)
        }
    }

    // 不支援文件存取但游標位置正常的宿主：欄位沒被判成讀不回，擋下成對切換的只有「正在暫存」。
    // 少了這個條件，整段會被塞在已經落地的開頭後面。
    fresh()
    client.declaresDocumentAccess = false
    type("id")
    _ = send(tabKey)
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    let noAccessStaged = client.text == "id [日" && client.markedText == "]" && coordinator.stagedCommit == "]"
    let noAccessInsertsBefore = client.insertedStrings
    let noAccessHandled = send(shiftSpaceKey)
    let noAccessKept = client.text == "id [日" && client.markedText == "]" && coordinator.stagedCommit == "]"
        && client.insertedStrings == noAccessInsertsBefore
        && coordinator.pairChoice == nil && coordinator.engine.revertRecord == nil
    _ = send(enterKey)
    if let failure = check("Host without document access: the staged closer is not switched and lands once",
                           noAccessStaged && noAccessHandled && noAccessKept && client.text == "id [日]"
                            && client.insertedStrings == noAccessInsertsBefore + ["]"]
                            && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 切換成功、選項列還開著時，宿主從那次取代之後讀不回：下一次切換被擋下，
    // 選項列要跟著收掉，否則畫面上還留著編號，看起來像是還能直選。
    fresh()
    _ = send(leftBracketKey)
    type("a")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    client.stopsReadingAfterNextInsert = true
    _ = send(shiftSpaceKey)
    client.allowsReadingText = true
    let choiceOpen = client.text == "[日]" && coordinator.pairChoice == PairChoice(current: .square, digitsPick: true)
    let gateInsertsBefore = client.insertedStrings
    let gateMarksBefore = client.setMarkedTextCallCount
    let gateHandled = send(shiftSpaceKey)
    if let failure = check("Readable host: a refused pair switch dismisses the open choice row",
                           choiceOpen && gateHandled && client.text == "[日]" && client.markedText.isEmpty
                            && coordinator.pairChoice == nil && coordinator.engine.revertRecord == nil
                            && client.insertedStrings == gateInsertsBefore
                            && client.setMarkedTextCallCount == gateMarksBefore) {
        return .failure(failure)
    }

    // 選項列的內容：八種照固定順序，焦點在目前那一種，編號只在數字會直選時出現。
    let plainRow = CandidateOverlayPanel.formatPairChoice(PairChoice(current: .doubleCorner, digitsPick: false))
    let numberedRow = CandidateOverlayPanel.formatPairChoice(PairChoice(current: .corner, digitsPick: true))
    func isFocused(_ pair: String, in row: NSAttributedString) -> Bool {
        let range = (row.string as NSString).range(of: pair)
        return range.location != NSNotFound
            && row.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil
    }
    let rowOrder = plainRow.string.filter { !$0.isWhitespace } == "「」[]『』《》〈〉【】“”‘’"
    let rowFocus = isFocused("『』", in: plainRow) && !isFocused("「」", in: plainRow) && !isFocused("[]", in: plainRow)
    let rowNumbers = numberedRow.string.filter { !$0.isWhitespace } == "1「」2[]3『』4《》5〈〉6【】7“”8‘’"
        && isFocused("「」", in: numberedRow)
    if let failure = check("Pair choice row: fixed order, focus, numbers only when digits pick",
                           rowOrder && rowFocus && rowNumbers) {
        return .failure(SelfTestFailure(message: failure.message + " row='\(plainRow.string)' numbered='\(numberedRow.string)'"))
    }

    // ---- 欄位的第一個按鍵就是標點：這時還沒有任何一次送出可以證明宿主讀得回文字，
    // 游標又在 0，終端機與空白文件在送出前分不出來。所以先暫存一個按鍵，落地時才知道是哪一種。

    // 終端機的空欄位：`[` 接 Shift+空白 換得了開頭，之後每一段都只落地一次。
    fresh(terminal: true)
    _ = send(leftBracketKey)
    let firstOpenerStaged = client.text.isEmpty && client.markedText == "「" && coordinator.stagedCommit == "「"
        && client.insertedStrings.isEmpty
    let firstOpenerHandled = send(shiftSpaceKey)
    let firstOpenerSwitched = client.text.isEmpty && client.markedText == "[" && client.insertedStrings.isEmpty
    type("my")
    _ = send(spaceKey)
    _ = send(rightBracketKey)
    _ = send(enterKey)
    if let failure = check("Terminal: an opener typed as the first key of an empty field can be switched",
                           firstOpenerStaged && firstOpenerHandled && firstOpenerSwitched
                            && client.text == "[下]" && client.insertedStrings == ["[", "下", "]"]
                            && client.markedText.isEmpty && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 終端機的空欄位：逗號接 Shift+空白 對調寬度，只落地一次。
    fresh(terminal: true)
    _ = send(commaKey)
    let firstCommaStaged = client.text.isEmpty && client.markedText == "，" && client.insertedStrings.isEmpty
    let firstCommaHandled = send(shiftSpaceKey)
    let firstCommaSwapped = client.text.isEmpty && client.markedText == ","
    _ = send(enterKey)
    if let failure = check("Terminal: a comma typed as the first key of an empty field swaps its width",
                           firstCommaStaged && firstCommaHandled && firstCommaSwapped
                            && client.text == "," && client.insertedStrings == [","] && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 終端機的空欄位：`[` 之後直接按 Enter 或失焦，只落地一次，不留標記文字。
    fresh(terminal: true)
    _ = send(leftBracketKey)
    let firstOpenerEnterHandled = send(enterKey)
    let enterLandedOnce = !firstOpenerEnterHandled && client.text == "「" && client.insertedStrings == ["「"]
        && client.markedText.isEmpty && coordinator.stagedCommit == nil
    fresh(terminal: true)
    _ = send(leftBracketKey)
    coordinator.commitComposition(client: client)
    coordinator.resetForFocusChange()
    if let failure = check("Terminal: a first-key opener lands once on Enter or focus loss",
                           enterLandedOnce && client.text == "「" && client.insertedStrings == ["「"]
                            && client.markedText.isEmpty && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 說不支援文件存取的宿主，空欄位的第一鍵本來就暫存，結果與終端機相同。
    fresh()
    client.declaresDocumentAccess = false
    client.allowsReadingText = false
    _ = send(leftBracketKey)
    _ = send(shiftSpaceKey)
    _ = send(enterKey)
    if let failure = check("Host without document access: a first-key opener is switched and lands once",
                           client.text == "[" && client.insertedStrings == ["["] && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 讀得回文字的宿主，空文件的第一鍵同樣暫存一個按鍵，落地後確認讀得回，之後照常立即送出。
    // 整串的結果要與核心重播 `LBRACKET SHIFT_SPACE m y SPACE RBRACKET m y SPACE PERIOD` 相同，
    // 沒有重複的字，後面的中文與標點照常接續。VS Code 的延遲回報模型也走一次。
    for stale in [false, true] {
        fresh()
        client.keepsStaleTextAfterEqualLengthReplacement = stale
        _ = send(leftBracketKey)
        let staged = client.text.isEmpty && client.markedText == "「" && coordinator.stagedCommit == "「"
        _ = send(shiftSpaceKey)
        let switched = client.text.isEmpty && client.markedText == "["
        type("m")
        let landed = client.text == "[" && client.markedText == "m" && client.insertedStrings == ["["]
            && coordinator.stagedCommit == nil
        type("y")
        _ = send(spaceKey)
        // 落地那一次已經確認讀得回，之後的送出不再暫存。
        let direct = client.text == "[下" && client.markedText.isEmpty && coordinator.stagedCommit == nil
        _ = send(rightBracketKey)
        let closed = client.text == "[下]" && client.markedText.isEmpty
        _ = send(shiftSpaceKey)
        // 方括號起點的第一下是角引號，整對一起換，證明讀回已經確認。
        let pairSwitched = client.text == "「下」" && client.markedText.isEmpty
        fresh()
        client.keepsStaleTextAfterEqualLengthReplacement = stale
        _ = send(leftBracketKey)
        _ = send(shiftSpaceKey)
        type("my")
        _ = send(spaceKey)
        _ = send(rightBracketKey)
        type("my")
        _ = send(spaceKey)
        _ = send(key(".", code: 47))
        if let failure = check("Readable host: a first-key opener is staged for one key, then typing is direct (stale=\(stale))",
                               staged && switched && landed && direct && closed && pairSwitched
                                && client.text == "[下] 下。" && client.markedText.isEmpty
                                && client.insertedStrings.joined() == "[下] 下。") {
            return .failure(failure)
        }

        // 逗號：對調、落地一次、接著打字，結果同核心重播 `COMMA SHIFT_SPACE m y SPACE PERIOD`。
        fresh()
        client.keepsStaleTextAfterEqualLengthReplacement = stale
        _ = send(commaKey)
        _ = send(shiftSpaceKey)
        let commaSwapped = client.text.isEmpty && client.markedText == ","
        type("my")
        _ = send(spaceKey)
        _ = send(key(".", code: 47))
        if let failure = check("Readable host: a first-key comma swaps its width and typing continues (stale=\(stale))",
                               commaSwapped && client.text == ", 下。" && client.markedText.isEmpty
                                && client.insertedStrings.joined() == ", 下。") {
            return .failure(failure)
        }
    }

    // 只有還沒確認過的欄位才這樣做。確認讀得回之後，游標回到 0 的標點照舊立即送出；
    // 關閉一鍵反悔時標點不可反悔，第一鍵也立即送出。
    fresh()
    type("my")
    _ = send(spaceKey)
    client.text = ""
    _ = send(leftBracketKey)
    let verifiedIsDirect = client.text == "「" && client.markedText.isEmpty && coordinator.stagedCommit == nil
    fresh()
    coordinator.updateConfiguration(client: client) { $0.revertEnabled = false }
    _ = send(leftBracketKey)
    if let failure = check("Readable host: only an unverified field stages a first-key punctuation",
                           verifiedIsDirect && client.text == "「" && client.markedText.isEmpty
                            && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    // 真的 NSTextView 空文件：同一串按鍵，標記文字由文字檢視自己管。
    do {
        var host = TextViewTestClient()
        func begin(_ string: String = "", selection: NSRange = NSRange(location: 0, length: 0)) {
            fresh()
            host = TextViewTestClient()
            host.view.string = string
            host.view.setSelectedRange(selection)
        }
        func hostSend(_ payload: KeyEventPayload) -> Bool {
            coordinator.handlePayload(payload, client: host)
        }
        func hostCheck(_ name: String, _ condition: Bool) -> SelfTestFailure? {
            check(name, condition).map {
                SelfTestFailure(message: $0.message + " native='\(host.view.string)' marked=\(host.view.markedRange())")
            }
        }

        begin()
        _ = hostSend(leftBracketKey)
        let nativeStaged = host.view.string == "「" && host.view.markedRange() == NSRange(location: 0, length: 1)
        _ = hostSend(shiftSpaceKey)
        let nativeSwitched = host.view.string == "[" && host.view.markedRange() == NSRange(location: 0, length: 1)
        _ = hostSend(key("m"))
        _ = hostSend(key("y"))
        _ = hostSend(spaceKey)
        let nativeDirect = host.view.string == "[下" && !host.view.hasMarkedText() && coordinator.stagedCommit == nil
        _ = hostSend(rightBracketKey)
        let nativeClosed = host.view.string == "[下]" && !host.view.hasMarkedText()
        _ = hostSend(key("m"))
        _ = hostSend(key("y"))
        _ = hostSend(spaceKey)
        _ = hostSend(key(".", code: 47))
        if let failure = hostCheck("Native text view: a first-key opener in an empty document is switched without duplicates",
                                   nativeStaged && nativeSwitched && nativeDirect && nativeClosed
                                    && host.view.string == "[下] 下。" && !host.view.hasMarkedText()
                                    && host.view.selectedRange() == NSRange(location: 6, length: 0)) {
            return .failure(failure)
        }

        // 逗號接 Shift+空白，然後 Enter：對調後只落地一次，Enter 交還文字檢視。
        begin()
        _ = hostSend(commaKey)
        _ = hostSend(shiftSpaceKey)
        let nativeEnterHandled = hostSend(enterKey)
        if let failure = hostCheck("Native text view: a first-key comma swaps its width and lands once on Enter",
                                   !nativeEnterHandled && host.view.string == "," && !host.view.hasMarkedText()
                                    && host.view.selectedRange() == NSRange(location: 1, length: 0)) {
            return .failure(failure)
        }

        // `[` 之後失焦或滑鼠點別處：宿主要求結束組字，只落地一次，不留底線。
        begin()
        _ = hostSend(leftBracketKey)
        coordinator.commitComposition(client: host)
        coordinator.resetForFocusChange()
        if let failure = hostCheck("Native text view: a first-key opener lands once when the host ends composition",
                                   host.view.string == "「" && !host.view.hasMarkedText()
                                    && coordinator.stagedCommit == nil) {
            return .failure(failure)
        }

        // 游標在既有文字的最前面：後面的文字原封不動。
        begin("abc")
        _ = hostSend(leftBracketKey)
        _ = hostSend(shiftSpaceKey)
        _ = hostSend(key("m"))
        _ = hostSend(key("y"))
        _ = hostSend(spaceKey)
        if let failure = hostCheck("Native text view: a first-key opener at the start of existing text keeps that text",
                                   host.view.string == "[下abc" && !host.view.hasMarkedText()
                                    && host.view.selectedRange() == NSRange(location: 2, length: 0)) {
            return .failure(failure)
        }

        // 整份文件被選取時打 `[`：選取範圍被取代一次，與直接打字相同，之後的切換不再多吃字。
        begin("abc", selection: NSRange(location: 0, length: 3))
        _ = hostSend(leftBracketKey)
        let selectionReplaced = host.view.string == "「"
        _ = hostSend(shiftSpaceKey)
        _ = hostSend(enterKey)
        if let failure = hostCheck("Native text view: a first-key opener over a selection replaces it exactly once",
                                   selectionReplaced && host.view.string == "[" && !host.view.hasMarkedText()) {
            return .failure(failure)
        }

        // 文件有內容、選取範圍從 0 開始也算第一鍵：逗號先帶底線。這時開符號面板，
        // 暫存的逗號留著不落地，也不另放焦點符號的暫時標記，關掉面板後原樣還在。
        begin("abc def", selection: NSRange(location: 0, length: 3))
        _ = hostSend(commaKey)
        let stagedMark = NSRange(location: 0, length: 1)
        let commaStaged = host.view.string == "， def" && host.view.markedRange() == stagedMark
        coordinator.toggleSymbolPanel(client: host)
        let panelKeepsStaged = host.view.string == "， def" && host.view.markedRange() == stagedMark
            && coordinator.stagedCommit == "，"
        _ = hostSend(escapeKey)
        let closedKeepsStaged = host.view.string == "， def" && host.view.markedRange() == stagedMark
        _ = hostSend(enterKey)
        if let failure = hostCheck("Native text view: a staged first-key comma stays staged while the symbol panel is open",
                                   commaStaged && panelKeepsStaged && closedKeepsStaged
                                    && host.view.string == "， def" && !host.view.hasMarkedText()
                                    && coordinator.stagedCommit == nil) {
            return .failure(failure)
        }
    }

    // 提示：內容是對調後的字詞，反悔後換成另一邊，下一個按鍵就消失。浮窗不取得鍵盤焦點。
    guard let screen = NSScreen.main else {
        return .failure(SelfTestFailure(message: "Missing screen for the revert hint checks"))
    }

    // 選項列的顯示：單按括號不顯示，切換之後出現在宿主回報的游標位置（閒置打出的括號沒有
    // 組字時的位置可沿用），下一個不是切換的按鍵就換掉，收掉組字後浮窗關閉。
    for terminal in [false, true] {
        fresh(terminal: terminal)
        let panel = CandidateOverlayPanel()
        let cursor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18)
        client.cursorRect = cursor
        let render: OverlayUpdate = { overlay, layerPanel, rect in
            panel.update(
                overlay: overlay,
                layerPanel: layerPanel,
                cursorRect: rect,
                showsEnglishActions: coordinator.englishActionsAvailable,
                revertHint: coordinator.revertHint,
                pairChoice: coordinator.pairChoice
            )
        }
        func press(_ payload: KeyEventPayload) {
            _ = coordinator.handlePayload(payload, client: client, onOverlayUpdate: render)
        }
        if terminal {
            // 終端機先送出一個詞，驗的是欄位已知讀不回之後的暫存；第一鍵就是標點的情況另有案例。
            press(key("i"))
            press(key("d"))
            press(tabKey)
        }
        press(leftBracketKey)
        let hiddenAfterTyping = panel.shownPairChoice == nil && !panel.isVisible
        press(shiftSpaceKey)
        let shownAtCursor = panel.isVisible && !panel.isKeyWindow
            && panel.shownPairChoice == coordinator.pairChoice && coordinator.pairChoice != nil
            && panel.shownCommitHint == nil && panel.frame.minX == cursor.minX
        press(shiftSpaceKey)
        let follows = panel.isVisible && panel.shownPairChoice == coordinator.pairChoice
            && panel.shownPairChoice?.digitsPick == false
        let secondStyle = panel.shownPairChoice?.current
        press(key("a"))
        let replaced = panel.isVisible && panel.shownPairChoice == nil
        press(escapeKey)
        if let failure = check("Pair choice row visibility and lifetime (terminal=\(terminal))",
                               hiddenAfterTyping && shownAtCursor && follows
                                && secondStyle == .doubleCorner
                                && replaced && !panel.isVisible) {
            return .failure(SelfTestFailure(message: failure.message
                + " shown=\(String(describing: panel.shownPairChoice)) frame=\(panel.frame) cursor=\(cursor)"))
        }
    }

    // 成對切換的選項列：讀得回的宿主換成功才出現，焦點跟著種類走，這時數字會直選所以顯示編號；
    // 用數字選完之後選項列留著但不再顯示編號。終端機換不了，所以不出現。
    // 看不到選項列就代表這次沒換成。
    for terminal in [false, true] {
        fresh(terminal: terminal)
        let panel = CandidateOverlayPanel()
        let cursor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18)
        client.cursorRect = cursor
        let render: OverlayUpdate = { overlay, layerPanel, rect in
            panel.update(
                overlay: overlay,
                layerPanel: layerPanel,
                cursorRect: rect,
                showsEnglishActions: coordinator.englishActionsAvailable,
                revertHint: coordinator.revertHint,
                pairChoice: coordinator.pairChoice
            )
        }
        func press(_ payload: KeyEventPayload) {
            _ = coordinator.handlePayload(payload, client: client, onOverlayUpdate: render)
        }
        press(key("i"))
        press(key("d"))
        press(tabKey)
        press(leftBracketKey)
        press(rightBracketKey)
        let hiddenAfterCloser = panel.shownPairChoice == nil
        press(shiftSpaceKey)
        let afterSwitch = panel.shownPairChoice
        let shown = panel.isVisible && !panel.isKeyWindow && afterSwitch == coordinator.pairChoice
            && afterSwitch == PairChoice(current: .corner, digitsPick: true)
            && panel.shownCommitHint == nil && panel.frame.minX == cursor.minX
        press(key("4", code: 21))
        let afterPick = panel.shownPairChoice
        let pickShown = panel.isVisible && afterPick == PairChoice(current: .doubleAngle, digitsPick: false)
        press(key("a"))
        let goneAfterNextKey = panel.shownPairChoice == nil
        press(escapeKey)
        // 終端機上那個數字不是直選，照一般數字打進去，選項列始終沒有出現。
        let expected = terminal ? afterSwitch == nil && afterPick == nil : shown && pickShown
        if let failure = check("Pair switch choice row appears only when the switch happened (terminal=\(terminal))",
                               hiddenAfterCloser && expected && goneAfterNextKey && !panel.isVisible) {
            return .failure(SelfTestFailure(message: failure.message
                + " shown=\(String(describing: afterSwitch)) frame=\(panel.frame) cursor=\(cursor)"))
        }
    }

    // 成對切換被擋下時的提示。浮窗閃一行原因，文件與暫存不動，下一個按鍵就收掉；
    // 沒有按鍵時計時器自己收，而且不動之後開的組字窗。
    do {
        var panel = CandidateOverlayPanel()
        let cursor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18)
        let render: OverlayUpdate = { overlay, layerPanel, rect in
            panel.update(
                overlay: overlay,
                layerPanel: layerPanel,
                cursorRect: rect,
                showsEnglishActions: coordinator.englishActionsAvailable,
                revertHint: coordinator.revertHint,
                pairChoice: coordinator.pairChoice,
                pairSwitchNotice: coordinator.pairSwitchNotice
            )
        }
        func press(_ payload: KeyEventPayload) {
            _ = coordinator.handlePayload(payload, client: client, onOverlayUpdate: render)
        }
        func start(terminal: Bool = false, text: String = "") {
            fresh(terminal: terminal, text: text)
            panel = CandidateOverlayPanel()
            panel.pairSwitchNoticeLifetime = 0.05
            client.cursorRect = cursor
        }
        func noticeDetail() -> String {
            " notice=\(String(describing: panel.shownPairSwitchNotice)) hint='\(panel.shownCommitHint ?? "nil")'"
                + " visible=\(panel.isVisible) frame=\(panel.frame) cursor=\(cursor)"
        }

        // 引擎擋下（跨行）：提示出現在游標位置，不搶焦點也不收滑鼠，下一個按鍵換成組字窗。
        start(text: "「日\n月")
        press(rightBracketKey)
        let quietAfterCloser = !panel.isVisible && panel.shownPairSwitchNotice == nil
        press(shiftSpaceKey)
        let spanShown = panel.isVisible && !panel.isKeyWindow && panel.ignoresMouseEvents
            && panel.shownPairSwitchNotice == .spanUnsupported
            && panel.shownCommitHint == UIText.pairSwitchSpanUnsupported.text
            && panel.shownPairChoice == nil && panel.frame.minX == cursor.minX
            && client.text == "「日\n月」" && client.markedText.isEmpty
        press(key("a"))
        let spanGone = panel.isVisible && panel.shownPairSwitchNotice == nil && panel.shownCommitHint == nil
            && coordinator.pairSwitchNotice == nil
        press(escapeKey)
        if let failure = check("Pair switch notice: a span the engine refuses shows the reason until the next key",
                               quietAfterCloser && spanShown && spanGone && !panel.isVisible) {
            return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
        }

        // 超過三十二個字同樣提示；再按一次是一般空白，提示收掉。
        start(text: "「" + String(repeating: "字", count: 31))
        press(rightBracketKey)
        press(shiftSpaceKey)
        let longShown = panel.isVisible && panel.shownPairSwitchNotice == .spanUnsupported
        press(shiftSpaceKey)
        if let failure = check("Pair switch notice: the second Shift+Space is a plain space and clears the notice",
                               longShown && !panel.isVisible && panel.shownPairSwitchNotice == nil
                                && client.text.hasSuffix("字」 ")) {
            return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
        }

        // 沒有下一個按鍵：計時器到期自己收。
        start(text: "「日\n月")
        press(rightBracketKey)
        press(shiftSpaceKey)
        let shownBeforeExpiry = panel.isVisible && panel.shownPairSwitchNotice == .spanUnsupported
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        if let failure = check("Pair switch notice: expires by itself",
                               shownBeforeExpiry && !panel.isVisible && panel.shownPairSwitchNotice == nil
                                && panel.shownCommitHint == nil && client.text == "「日\n月」") {
            return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
        }

        // 到期前已經開了組字窗：計時器不得把它收掉。
        start(text: "「日\n月")
        press(rightBracketKey)
        press(shiftSpaceKey)
        press(key("a"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let composingKept = panel.isVisible && coordinator.engine.buffer == "a"
        press(escapeKey)
        if let failure = check("Pair switch notice: the timer leaves a later composing overlay alone", composingKept) {
            return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
        }

        // 終端機與讀不到文字的宿主：外層放棄，提示換成宿主那一則，暫存與文件不動，下一個按鍵收掉並只落地一次。
        for terminal in [true, false] {
            start(terminal: terminal)
            client.allowsReadingText = false
            press(key("i"))
            press(key("d"))
            press(tabKey)
            press(leftBracketKey)
            press(key("a"))
            press(spaceKey)
            press(rightBracketKey)
            let staged = client.text == "id [日" && client.markedText == "]" && coordinator.stagedCommit == "]"
            let insertsBefore = client.insertedStrings
            let marksBefore = client.setMarkedTextCallCount
            press(shiftSpaceKey)
            let hostShown = panel.isVisible && !panel.isKeyWindow && panel.ignoresMouseEvents
                && panel.shownPairSwitchNotice == .hostReadbackUnavailable
                && panel.shownCommitHint == UIText.pairSwitchHostUnavailable.text
                && panel.shownPairChoice == nil && panel.frame.minX == cursor.minX
            let stagedKept = client.text == "id [日" && client.markedText == "]" && coordinator.stagedCommit == "]"
                && client.insertedStrings == insertsBefore && client.setMarkedTextCallCount == marksBefore
                && coordinator.engine.revertRecord == nil
            press(enterKey)
            if let failure = check("Pair switch notice: an unreadable host shows its own reason and keeps the staged closer (terminal=\(terminal))",
                                   staged && hostShown && stagedKept && !panel.isVisible
                                    && panel.shownPairSwitchNotice == nil && coordinator.pairSwitchNotice == nil
                                    && client.text == "id [日]" && client.insertedStrings == insertsBefore + ["]"]) {
                return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
            }
        }

        // 不是成對切換就不提示：過期的 Shift+空白 是一般空白，中英對調讀回不符時只是安靜放棄。
        start()
        press(leftBracketKey)
        press(key("a"))
        press(spaceKey)
        press(rightBracketKey)
        press(key("a"))
        press(spaceKey)
        press(key("1", code: 18))
        press(shiftSpaceKey)
        let staleQuiet = panel.shownPairSwitchNotice == nil && coordinator.pairSwitchNotice == nil
        start()
        press(key("m"))
        press(key("y"))
        press(spaceKey)
        client.text = "上"
        press(shiftSpaceKey)
        if let failure = check("Pair switch notice: silent for a stale Shift+Space and for other refused reverts",
                               staleQuiet && panel.shownPairSwitchNotice == nil && coordinator.pairSwitchNotice == nil
                                && !panel.isVisible && client.text == "上") {
            return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
        }

        // 更長的整對：讀回的前文每個按鍵都裁成前文視窗的長度，開頭一出視窗 `]` 就看不到它。
        // 分不出這個全形結尾是不是某一對的結尾，所以同樣擋下並提示，絕不只換結尾的寬度。
        for count in [32, 40] {
            let text = "「" + String(repeating: "字", count: count)
            start(text: text)
            press(rightBracketKey)
            let closed = client.text == text + "」"
            let insertsBefore = client.insertedStrings
            press(shiftSpaceKey)
            let blocked = panel.isVisible && panel.shownPairSwitchNotice == .spanUnsupported
                && panel.shownCommitHint == UIText.pairSwitchSpanUnsupported.text
                && panel.frame.minX == cursor.minX
                && client.text == text + "」" && client.markedText.isEmpty
                && client.insertedStrings == insertsBefore
            press(shiftSpaceKey)
            if let failure = check("Pair switch notice: an opener beyond the context window is refused with the reason (\(count) characters inside)",
                                   closed && blocked && client.text == text + "」 " && !panel.isVisible
                                    && panel.shownPairSwitchNotice == nil && coordinator.pairSwitchNotice == nil) {
                return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
            }
        }

        // 整份文件都讀得到、確定沒有開頭的落單結尾照舊換寬度，不提示。
        start(text: String(repeating: "字", count: 20))
        press(rightBracketKey)
        press(shiftSpaceKey)
        if let failure = check("Pair switch notice: a lone closer in a fully visible document still swaps width silently",
                               client.text == String(repeating: "字", count: 20) + "]" && !panel.isVisible
                                && panel.shownPairSwitchNotice == nil && coordinator.pairSwitchNotice == nil) {
            return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
        }

        // 計時器收掉之後，沒有宿主可用的選單動作只重畫浮窗，不得把過期的提示再叫出來。
        let redrawsWithoutClient: [(String, () -> Void)] = [
            ("reading lookup", { coordinator.toggleReadingLookup(client: nil, onOverlayUpdate: render) }),
            ("pure English", { coordinator.togglePureEnglish(client: nil, onOverlayUpdate: render) }),
            ("Caps Lock", {
                coordinator.syncCapsLock(isOn: !coordinator.engine.capsLockEnabled, client: nil, onOverlayUpdate: render)
            }),
        ]
        for (name, redraw) in redrawsWithoutClient {
            start(text: "「日\n月")
            press(rightBracketKey)
            press(shiftSpaceKey)
            let shown = panel.shownPairSwitchNotice == .spanUnsupported
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let expired = !panel.isVisible
            redraw()
            if let failure = check("Pair switch notice: a redraw without a client does not bring back an expired notice (\(name))",
                                   shown && expired && !panel.isVisible && panel.shownPairSwitchNotice == nil
                                    && coordinator.pairSwitchNotice == nil) {
                return .failure(SelfTestFailure(message: failure.message + noticeDetail()))
            }
        }
    }
    for terminal in [false, true] {
        fresh(terminal: terminal)
        let panel = CandidateOverlayPanel()
        let cursor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18)
        let render: OverlayUpdate = { overlay, readingPanel, rect in
            panel.update(
                overlay: overlay,
                layerPanel: readingPanel,
                cursorRect: rect == .zero ? .zero : cursor,
                showsEnglishActions: coordinator.englishActionsAvailable,
                revertHint: coordinator.revertHint
            )
        }
        func press(_ payload: KeyEventPayload) {
            _ = coordinator.handlePayload(payload, client: client, onOverlayUpdate: render)
        }
        press(key("m"))
        press(key("y"))
        let composingFrame = panel.frame
        press(spaceKey)
        let hintAfterCommit = panel.isVisible && !panel.isKeyWindow && panel.shownCommitHint == "⇧空白 改成 my"
            && panel.frame.minX == composingFrame.minX
        press(shiftSpaceKey)
        let hintAfterRevert = panel.isVisible && panel.shownCommitHint == "⇧空白 改成 下"
        press(key("a"))
        let hintGone = panel.isVisible && panel.shownCommitHint == nil
        press(escapeKey)
        if let failure = check("Revert hint text and lifetime (terminal=\(terminal))",
                               hintAfterCommit && hintAfterRevert && hintGone && !panel.isVisible) {
            return .failure(SelfTestFailure(message: failure.message + " shown='\(panel.shownCommitHint ?? "nil")'"))
        }
    }

    return .success(passed)
}

/// 行內程式片段語境的外層檢查：浮窗的標記與焦點、游標移動與失焦會重置語境、
/// 讀不回文字的宿主在片段裡也能反悔。
@MainActor
func runSnippetContextChecks() -> Result<Int, SelfTestFailure> {
    var passed = 0
    var coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
    var client = FakeIMKClient()

    func fresh(terminal: Bool = false) {
        coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
        client = FakeIMKClient()
        if terminal {
            client.reportsCursorAtZero = true
            client.allowsReadingText = false
        }
    }
    func send(_ payload: KeyEventPayload) -> Bool {
        coordinator.handlePayload(payload, client: client)
    }
    func key(_ ch: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> KeyEventPayload {
        KeyEventPayload(keyCode: code, modifierFlags: flags, characters: ch, charactersIgnoringModifiers: ch)
    }
    func type(_ letters: String) {
        for ch in letters {
            _ = send(key(String(ch)))
        }
    }
    func check(_ name: String, _ condition: Bool) -> SelfTestFailure? {
        if condition {
            passed += 1
            return nil
        }
        return SelfTestFailure(message: "\(name): text='\(client.text)' marked='\(client.markedText)' staged='\(coordinator.stagedCommit ?? "nil")' snippet=\(coordinator.engine.snippet) state=\(coordinator.engine.state.rawValue)")
    }
    let backtick = key("`", code: 50)
    let spaceKey = key(" ", code: 49)
    let shiftSpaceKey = key(" ", code: 49, flags: .shift)
    let leftArrow = KeyEventPayload(keyCode: 123, modifierFlags: .function, characters: "", charactersIgnoringModifiers: "")
    let enterKey = key("\r", code: 36)

    /// 浮窗某一行上有沒有焦點色塊。
    func hasSelectionFill(_ text: NSAttributedString?) -> Bool {
        guard let text else { return false }
        var found = false
        text.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { found = true }
        }
        return found
    }

    // 片段裡英文優先：浮窗標出「片段」，焦點落在上行已打的字母，下行不標焦點。
    fresh()
    _ = send(backtick)
    type("my")
    guard let snippetOverlay = coordinator.engine.currentOverlay else {
        return .failure(SelfTestFailure(message: "片段裡缺少浮窗內容"))
    }
    let snippetTracks = CandidateOverlayPanel.formatTracks(
        for: snippetOverlay,
        showsEnglishActions: coordinator.englishActionsAvailable
    )
    let badgeShown = snippetTracks.english.string.hasPrefix("片段")
    let typedRange = (snippetTracks.english.string as NSString).range(of: "my")
    let englishFocused = typedRange.location != NSNotFound
        && snippetTracks.english.attribute(.backgroundColor, at: typedRange.location, effectiveRange: nil) != nil
    let cangjieUnfocused = snippetTracks.cangjie != nil && !hasSelectionFill(snippetTracks.cangjie)
    if let failure = check("片段的浮窗標記與焦點", badgeShown && englishFocused && cangjieUnfocused) {
        return .failure(failure)
    }

    // 黏中之後焦點回到下行的中文字，上行不標焦點。
    _ = send(shiftSpaceKey)
    _ = send(spaceKey)
    type("my")
    guard let stickyOverlay = coordinator.engine.currentOverlay else {
        return .failure(SelfTestFailure(message: "黏中時缺少浮窗內容"))
    }
    let stickyTracks = CandidateOverlayPanel.formatTracks(
        for: stickyOverlay,
        showsEnglishActions: coordinator.englishActionsAvailable
    )
    let stickyTypedRange = (stickyTracks.english.string as NSString).range(of: "my")
    let stickyEnglishPlain = stickyTypedRange.location != NSNotFound
        && stickyTracks.english.attribute(.backgroundColor, at: stickyTypedRange.location, effectiveRange: nil) == nil
    if let failure = check("黏中時焦點回到中文首選字",
                           stickyOverlay.inCodeSnippet && stickyEnglishPlain && hasSelectionFill(stickyTracks.cangjie)) {
        return .failure(failure)
    }

    // 一般欄位：片段裡的空白鍵送出原字母加空格，立即送出。
    fresh()
    _ = send(backtick)
    type("id")
    _ = send(spaceKey)
    if let failure = check("片段裡的空白鍵送出英文", client.text == "`id " && client.markedText.isEmpty) {
        return .failure(failure)
    }

    // 片段裡打錯字按退格修正：引擎放行退格，但片段語境留著，之後有候選字的碼加空白仍是英文。
    fresh()
    _ = send(backtick)
    type("id")
    _ = send(spaceKey)
    let backspaceKey = KeyEventPayload(keyCode: 51, modifierFlags: [], characters: "", charactersIgnoringModifiers: "")
    let backspaceForwarded = send(backspaceKey) == false
    // 宿主收下退格之後自己刪掉那個字元，前文才與引擎的鏡像相符。
    client.text.removeLast()
    type("my")
    _ = send(spaceKey)
    if let failure = check("片段裡的退格不結束語境",
                           backspaceForwarded && client.text == "`idmy ") {
        return .failure(failure)
    }

    // 方向鍵移動游標、切換欄位與宿主結束組字都讓片段語境結束，之後空白鍵回到中文優先。
    for (name, reset) in [
        ("方向鍵", { _ = send(leftArrow) }),
        ("切換欄位", { coordinator.resetForFocusChange() }),
        ("宿主結束組字", { coordinator.commitComposition(client: client) })
    ] as [(String, () -> Void)] {
        fresh()
        _ = send(backtick)
        reset()
        type("id")
        _ = send(spaceKey)
        if let failure = check("\(name)之後片段語境結束", client.text == "`床") {
            return .failure(failure)
        }
    }

    // 讀不回文字的宿主（終端機）：片段裡可反悔的送出同樣先暫存成標記文字，下一個按鍵才落地。
    fresh(terminal: true)
    _ = send(backtick)
    type("my")
    _ = send(spaceKey)
    let stagedRaw = client.text == "`" && client.markedText == "my " && coordinator.stagedCommit == "my "
    _ = send(shiftSpaceKey)
    let stagedSwapped = client.text == "`" && client.markedText == "下"
    _ = send(enterKey)
    if let failure = check("終端機在片段裡的可反悔送出",
                           stagedRaw && stagedSwapped && client.text == "`下"
                            && client.insertedStrings == ["`", "下"] && coordinator.stagedCommit == nil) {
        return .failure(failure)
    }

    return .success(passed)
}

/// 通知次數。`@Sendable` 的通知回呼不能寫區域變數，所以用一個盒子。
final class NotificationCounter: @unchecked Sendable {
    var value = 0
}

/// 浮窗字級的外層檢查。先看設定視窗的選單讀寫偏好並發出通知，再把雙軌、讀音反查、符號面板、
/// 成對符號選項列與單行提示各用三檔字級畫一次，游標放在螢幕右下角逼它裁切。
@MainActor
func runOverlayFontSizeChecks() -> Result<Int, SelfTestFailure> {
    var passed = 0
    let pid = ProcessInfo.processInfo.processIdentifier
    let suiteName = "goshawk-self-test-font-size-\(pid)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        return .failure(SelfTestFailure(message: "浮窗字級：建不出偏好網域"))
    }
    defer { suite.removePersistentDomain(forName: suiteName) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goshawk-self-test-font-size-\(pid)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let preferences = PreferencesStore(defaults: suite)
    let statistics = LocalUsageStatistics(url: directory.appendingPathComponent("statistics.json"),
                                          defaults: suite, build: "test")
    defer { statistics.shutdown() }
    let settings = SettingsWindowController(
        preferences: preferences,
        usageStore: UsageHistoryStore(fileURL: directory.appendingPathComponent("usage-history.json")),
        statistics: statistics,
        updates: UpdateChecker(defaults: suite, currentVersion: nil, fetch: { _ in })
    )
    let counter = NotificationCounter()
    let observer = NotificationCenter.default.addObserver(
        forName: .goshawkPreferencesDidChange, object: nil, queue: nil
    ) { _ in counter.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    let control = settings.overlayFontSizeControl
    func choose(_ index: Int) {
        control.selectItem(at: index)
        if let action = control.action {
            NSApp.sendAction(action, to: control.target, from: control)
        }
    }
    let configurationBefore = preferences.loadConfiguration()
    let initialOK = control.itemTitles == ["小", "標準", "大"]
        && control.indexOfSelectedItem == 1
        && control.isDescendant(of: settings.pages[.punctuationAndAppearance]?.view ?? NSView())
        && preferences.loadOverlayFontSize() == .medium
    choose(2)
    let wroteLarge = preferences.loadOverlayFontSize() == .large
        && suite.string(forKey: "goshawk.overlayFontSize") == "large"
        && counter.value == 1
    choose(0)
    let wroteSmall = preferences.loadOverlayFontSize() == .small && counter.value == 2
    preferences.saveOverlayFontSize(.medium)
    settings.reloadFromPreferences()
    guard initialOK, wroteLarge, wroteSmall, control.indexOfSelectedItem == 1,
          preferences.loadConfiguration() == configurationBefore else {
        return .failure(SelfTestFailure(message: "浮窗字級：設定視窗的選單沒有正確讀寫偏好"
            + "（initial=\(initialOK) large=\(wroteLarge) small=\(wroteSmall) 通知 \(counter.value) 次，選項 \(control.itemTitles)）"))
    }
    passed += 1

    // 偏好到共用浮窗這一段：控制器取得焦點時套一次，之後設定視窗每發一則通知再套一次，
    // 放掉之後不再跟。
    let shared = CandidateOverlayPanel.shared
    let sharedBefore = shared.fontSize
    defer { shared.fontSize = sharedBefore }
    preferences.saveOverlayFontSize(.large)
    var follower: OverlayFontSizeFollower? = OverlayFontSizeFollower(preferences: preferences)
    follower?.apply()
    let appliedOnFocus = shared.fontSize
    choose(0)
    let appliedOnNotification = shared.fontSize
    follower = nil
    choose(2)
    let afterRelease = shared.fontSize
    preferences.saveOverlayFontSize(.medium)
    settings.reloadFromPreferences()
    guard appliedOnFocus == .large, appliedOnNotification == .small, afterRelease == .small else {
        return .failure(SelfTestFailure(message: "浮窗字級：偏好沒有套到共用的浮窗"
            + "（取得焦點後 \(appliedOnFocus.rawValue)，收到通知後 \(appliedOnNotification.rawValue)，放掉後 \(afterRelease.rawValue)）"))
    }
    passed += 1

    guard let screen = NSScreen.main else {
        return .failure(SelfTestFailure(message: "浮窗字級：沒有螢幕可以檢查浮窗"))
    }
    // 每個畫面的內容都從引擎取，不自己拼。
    func capture(_ payloads: [KeyEventPayload]) -> (overlay: OverlayState?, layerPanel: LayerPanelContent?) {
        let session = InputSessionCoordinator(configuration: EngineConfiguration())
        let host = FakeIMKClient()
        var last: (OverlayState?, LayerPanelContent?) = (nil, nil)
        for payload in payloads {
            _ = session.handlePayload(payload, client: host) { overlay, layerPanel, _ in last = (overlay, layerPanel) }
        }
        return last
    }
    func letters(_ text: String) -> [KeyEventPayload] {
        text.map { KeyEventPayload(keyCode: 0, characters: String($0), charactersIgnoringModifiers: String($0)) }
    }
    let lookupShortcut = KeyEventPayload(keyCode: 41, modifierFlags: [.control, .shift],
                                         characters: ":", charactersIgnoringModifiers: ":")
    let symbolShortcut = KeyEventPayload(keyCode: 11, modifierFlags: [.option, .shift],
                                         characters: "ı", charactersIgnoringModifiers: "B")
    // 雙軌要兩軌都有東西：上行有英文預測與按鍵提示，下行有候選字。
    let dual = capture(letters("no"))
    let reading = capture([lookupShortcut] + letters("hji4"))
    let symbols = capture([symbolShortcut])
    guard let dualOverlay = dual.overlay, dualOverlay.cangjieTrack?.candidates.isEmpty == false,
          dualOverlay.englishTrack.predictions.count > 1,
          case .reading(let readingContent)? = reading.layerPanel, !readingContent.rows.isEmpty,
          case .symbols(let symbolContent)? = symbols.layerPanel, symbolContent.rows.count == 9 else {
        return .failure(SelfTestFailure(message: "浮窗字級：引擎沒有給出要畫的雙軌、反查或符號面板內容"))
    }

    let cursor = NSRect(x: screen.visibleFrame.maxX - 20, y: screen.visibleFrame.minY + 2, width: 1, height: 18)
    let panel = CandidateOverlayPanel()
    defer { panel.orderOut(nil) }
    let scenes: [(name: String, draw: () -> Void)] = [
        ("雙軌", { panel.update(overlay: dualOverlay, layerPanel: nil, cursorRect: cursor, showsEnglishActions: true) }),
        ("讀音反查", { panel.update(overlay: nil, layerPanel: reading.layerPanel, cursorRect: cursor, showsEnglishActions: false) }),
        ("符號面板", { panel.update(overlay: nil, layerPanel: symbols.layerPanel, cursorRect: cursor, showsEnglishActions: false) }),
        ("成對符號選項列", { panel.update(overlay: nil, layerPanel: nil, cursorRect: cursor, showsEnglishActions: false,
                                   pairChoice: PairChoice(current: .corner, digitsPick: true)) }),
        // 接詞與反悔兩則提示並排，寬度才會超過浮窗的最小寬度，看得出字級的差別。
        ("單行提示", { panel.update(overlay: nil, layerPanel: nil, cursorRect: cursor, showsEnglishActions: false,
                                revertHint: "my", continuation: "輸入法") })
    ]
    /// 看得見的文字與分段按鈕都拿到了自己要的寬度，沒有被壓到截字。
    func untruncated(_ view: NSView) -> Bool {
        if view.isHidden { return true }
        if view is NSTextField || view is NSSegmentedControl,
           view.frame.width + 0.5 < view.intrinsicContentSize.width {
            return false
        }
        return view.subviews.allSatisfy(untruncated)
    }
    /// 看得見的文字與分段按鈕裡，字體點數不在這一檔字級表上的那些。整個浮窗的大小由最寬的欄
    /// 與列高帶動，單一標籤寫死點數時大小不一定變，所以逐一核對。
    func offTableFonts(in view: NSView, metrics: OverlayFontMetrics) -> [String] {
        if view.isHidden { return [] }
        let allowed: Set<CGFloat> = [metrics.primary, metrics.secondary, metrics.hint, metrics.caption]
        var sizes: Set<CGFloat> = []
        if let field = view as? NSTextField {
            let text = field.attributedStringValue
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                sizes.insert((value as? NSFont ?? field.font)?.pointSize ?? 0)
            }
        } else if let control = view as? NSSegmentedControl {
            sizes.insert(control.font?.pointSize ?? 0)
        }
        let own = sizes.subtracting(allowed).sorted().map { "\(type(of: view)) \($0) 點" }
        return own + view.subviews.flatMap { offTableFonts(in: $0, metrics: metrics) }
    }
    for scene in scenes {
        var sizes: [OverlayFontSize: NSSize] = [:]
        // 新建的浮窗還沒被指定字級，畫出來的就是預設。
        if panel.fontSize != .medium { panel.fontSize = .medium }
        scene.draw()
        let defaultSize = panel.frame.size
        for fontSize in [OverlayFontSize.small, .large, .medium] {
            panel.fontSize = fontSize
            // 換檔會先收起浮窗，重畫之後才是新字級的大小。
            let hiddenAfterChange = !panel.isVisible
            scene.draw()
            panel.contentView?.layoutSubtreeIfNeeded()
            sizes[fontSize] = panel.frame.size
            guard hiddenAfterChange, panel.isVisible, !panel.isKeyWindow,
                  screen.visibleFrame.contains(panel.frame),
                  panel.frame.width <= CandidateOverlayPanel.maxPanelWidth,
                  untruncated(panel.contentView ?? NSView()) else {
                return .failure(SelfTestFailure(message: "浮窗字級：\(scene.name)在 \(fontSize.rawValue) 檔畫不出來、超出螢幕或截字"
                    + "（換檔後收起=\(hiddenAfterChange) 顯示=\(panel.isVisible) 位置 \(panel.frame)，螢幕 \(screen.visibleFrame)）"))
            }
            let strays = offTableFonts(in: panel.contentView ?? NSView(), metrics: fontSize.metrics)
            guard strays.isEmpty else {
                return .failure(SelfTestFailure(message: "浮窗字級：\(scene.name)在 \(fontSize.rawValue) 檔有字體點數不在字級表上（\(Set(strays).sorted().joined(separator: "、"))）"))
            }
        }
        guard let small = sizes[.small], let medium = sizes[.medium], let large = sizes[.large],
              medium == defaultSize,
              small.width < large.width, small.height < large.height,
              small.width <= medium.width, medium.width <= large.width,
              small.height <= medium.height, medium.height <= large.height else {
            return .failure(SelfTestFailure(message: "浮窗字級：\(scene.name)的大小沒有跟著字級變"
                + "（預設 \(defaultSize)，小 \(String(describing: sizes[.small]))，標準 \(String(describing: sizes[.medium]))，大 \(String(describing: sizes[.large]))）"))
        }
        passed += 1
    }

    // 標準檔的格式化結果就是不帶字級的呼叫，其他兩檔只換點數、文字不變。
    let pointSizes = { (text: NSAttributedString) -> Set<CGFloat> in
        var found: Set<CGFloat> = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { found.insert(font.pointSize) }
        }
        return found
    }
    let baseline = CandidateOverlayPanel.formatTracks(for: dualOverlay, showsEnglishActions: true)
    let formatsOK = OverlayFontSize.allCases.allSatisfy { fontSize in
        let tracks = CandidateOverlayPanel.formatTracks(for: dualOverlay, showsEnglishActions: true, fontSize: fontSize)
        let metrics = fontSize.metrics
        return tracks.english.string == baseline.english.string
            && tracks.cangjie?.string == baseline.cangjie?.string
            && pointSizes(tracks.english).isSubset(of: [metrics.secondary, metrics.caption])
            && tracks.cangjie.map(pointSizes) == [metrics.primary, metrics.secondary, metrics.caption]
            && (fontSize != .medium || (tracks.english == baseline.english && tracks.cangjie == baseline.cangjie))
    }
    guard formatsOK else {
        return .failure(SelfTestFailure(message: "浮窗字級：雙軌的字體點數沒有照字級表，或標準檔與原本不同"))
    }
    passed += 1

    return .success(passed)
}

/// 設定視窗的檢查：控制項的初始狀態與偏好一致、按下後偏好被寫入並發出通知、
/// 作用中的協調器重新載入設定且先結束組字。不需要真的把視窗顯示出來。
@MainActor
func runSettingsWindowChecks() -> Result<Int, SelfTestFailure> {
    var passed = 0
    let pid = ProcessInfo.processInfo.processIdentifier
    let suiteName = "goshawk-self-test-settings-\(pid)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        return .failure(SelfTestFailure(message: "Cannot create the settings preferences suite"))
    }
    defer { suite.removePersistentDomain(forName: suiteName) }
    let historyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("goshawk-self-test-settings-\(pid)/usage-history.json")
    defer { try? FileManager.default.removeItem(at: historyURL.deletingLastPathComponent()) }

    let preferences = PreferencesStore(defaults: suite)
    let statistics = LocalUsageStatistics(url: historyURL.deletingLastPathComponent().appendingPathComponent("statistics.json"),
                                          defaults: suite, build: "test")
    defer { statistics.shutdown() }
    // 「複製診斷資訊」寫到這個專用的剪貼簿，不蓋掉使用者剪貼簿裡的東西。
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let settings = SettingsWindowController(
        preferences: preferences,
        usageStore: UsageHistoryStore(fileURL: historyURL),
        statistics: statistics,
        updates: UpdateChecker(defaults: suite, currentVersion: nil, fetch: { _ in }),
        pasteboard: pasteboard
    )
    guard settings.updateCheckbox.state == .on else {
        return .failure(SelfTestFailure(message: "自動檢查更新預設應開啟"))
    }
    settings.updateCheckbox.performClick(nil)
    guard !UpdateChecker(defaults: suite, currentVersion: nil, fetch: { _ in }).isEnabled else {
        return .failure(SelfTestFailure(message: "設定無法關閉自動檢查更新"))
    }
    passed += 1
    guard settings.statisticsControls.toggle.state == .off else {
        return .failure(SelfTestFailure(message: "本機使用統計預設應關閉"))
    }
    settings.statisticsControls.toggle.performClick(nil)
    guard statistics.enabled else { return .failure(SelfTestFailure(message: "設定無法開啟本機使用統計")) }
    settings.statisticsControls.toggle.performClick(nil)
    guard !statistics.enabled else { return .failure(SelfTestFailure(message: "設定無法暫停本機使用統計")) }
    passed += 1

    var configuration = preferences.loadConfiguration()
    let initialStatesMatch = settings.checkboxes.count == SettingsToggle.allCases.count
        && SettingsToggle.allCases.allSatisfy {
            settings.checkboxes[$0]?.state == ($0.isOn(in: configuration) ? .on : .off)
        }
        && settings.cangjieVersionControl.indexOfSelectedItem == 0
        && settings.readingSchemeControl.indexOfSelectedItem == 0
    guard initialStatesMatch, settings.window.title == UIText.settingsTabGeneral.text else {
        let states = SettingsToggle.allCases
            .map { "\($0.rawValue)=\(settings.checkboxes[$0]?.state.rawValue ?? -9)" }
            .joined(separator: " ")
        return .failure(SelfTestFailure(message: "設定視窗的初始狀態與偏好不符（\(settings.checkboxes.count) 個開關，\(states)）"))
    }
    passed += 1

    // 分頁版面：四個分頁照固定順序，每一頁不必捲動就放得完，每個控制項都在它該在的那一頁，
    // 文字沒有被截斷，也沒有東西超出頁面。回傳哪裡不對，沒問題就是 nil。
    func pageLayoutProblem(in settings: SettingsWindowController) -> String? {
        // 分頁是系統設定視窗那種工具列：四項照順序，每項都有圖示與文字，選得起來，使用者不能自訂。
        let items = settings.window.toolbar?.items ?? []
        let labels = items.map(\.label)
        guard labels == SettingsTab.allCases.map(\.title.text), labels.count == 4,
              let toolbar = settings.window.toolbar, toolbar.isVisible,
              settings.window.toolbarStyle == .preference, toolbar.displayMode == .iconAndLabel,
              !toolbar.allowsUserCustomization,
              items.allSatisfy({ $0.image != nil && $0.action != nil && $0.target != nil }),
              Set(items.compactMap { $0.image?.tiffRepresentation }).count == 4,
              !(settings.window.contentView is NSScrollView),
              !settings.window.styleMask.contains(.resizable) else {
            return "工具列的分頁不是四個、順序不對、少了圖示，或視窗仍可捲動（\(labels)）"
        }
        // 工具列就是分頁，右鍵選單不能把它改成只有圖示或只有文字。
        if #available(macOS 15.0, *), toolbar.allowsDisplayModeCustomization {
            return "工具列仍可從右鍵選單改顯示模式"
        }
        // 換頁時新的一頁要在視窗調整大小之前就放進內容區，高度動畫的期間才不會是空白。
        // 每次視窗大小改變的當下，內容區裡必須已經是新選到的那一頁。
        let resizes = NotificationCounter()
        let blankResizes = NotificationCounter()
        let resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: settings.window, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                resizes.value += 1
                let shown = settings.window.contentView?.subviews ?? []
                if shown.count != 1 || shown.first !== settings.pages[settings.selectedTab]?.view {
                    blankResizes.value += 1
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(resizeObserver) }
        // 按工具列上的項目真的會換頁，視窗標題跟著換成那一頁的名稱。
        for (item, tab) in zip(items, SettingsTab.allCases).reversed() {
            guard let action = item.action, NSApp.sendAction(action, to: item.target, from: item),
                  settings.selectedTab == tab, toolbar.selectedItemIdentifier == item.itemIdentifier,
                  settings.window.title == tab.title.text,
                  let shown = settings.window.contentView?.subviews, shown.count == 1,
                  shown.first === settings.pages[tab]?.view else {
                return "按工具列的「\(item.label)」沒有換到那一頁，或視窗標題沒有跟著換"
            }
        }
        guard resizes.value > 0, blankResizes.value == 0 else {
            return "換頁時視窗先調大小才放進新的一頁（調整 \(resizes.value) 次，其中 \(blankResizes.value) 次內容區不是新的一頁）"
        }
        // 每個開關該在哪一頁寫死在這裡，不從視窗自己用的分組推：把開關搬到別的分組要在這裡失敗。
        func home(of toggle: SettingsToggle) -> SettingsTab {
            switch toggle {
            case .mixedMode, .developerVocabulary, .chineseContinuation, .personalTerms, .revert, .autoSpace,
                 .learnsEnglishPredictions, .learnsCangjieOrder, .learnsReadingLookupOrder:
                return .general
            case .halfwidthPunctuation, .ctrlBrackets:
                return .punctuationAndAppearance
            }
        }
        let homes: [(String, NSView, SettingsTab)] = SettingsToggle.allCases.map {
            ($0.rawValue, settings.checkboxes[$0] ?? NSView(), home(of: $0))
        } + [
            ("倉頡代別", settings.cangjieVersionControl, .general),
            ("個人術語欄位", settings.personalTermField, .general),
            ("加入術語", settings.addTermButton, .general),
            ("刪除術語", settings.removeTermButton, .general),
            ("鍵盤方案", settings.readingSchemeControl, .punctuationAndAppearance),
            ("浮窗字體大小", settings.overlayFontSizeControl, .punctuationAndAppearance),
            ("App 圖示", settings.appIconView, .about),
            ("自動檢查更新", settings.updateCheckbox, .about),
            ("複製診斷資訊", settings.copyDiagnosticsButton, .about),
            ("統計開關", settings.statisticsControls.toggle, .about),
            ("統計說明", settings.statisticsControls.note, .about),
            ("檢視統計", settings.statisticsControls.inspect, .about),
            ("清除統計", settings.statisticsControls.erase, .about)
        ] + ShortcutHint.allCases.flatMap { hint -> [(String, NSView, SettingsTab)] in
            let fields = settings.shortcutFields[hint]
            return [("\(hint) 說明", fields?.summary ?? NSView(), .shortcuts)]
                + (fields?.keys ?? []).map { ("\(hint) 鍵帽", $0, .shortcuts) }
        }
        for (name, control, tab) in homes {
            guard let page = settings.pages[tab]?.view, control.isDescendant(of: page) else {
                return "\(name) 不在「\(tab.title.text)」分頁"
            }
        }
        /// 這個視圖拿到的大小排得完它的文字。真的換成多行的看高度，其餘看寬度。
        /// 一般按鈕的 `wraps` 預設是 true，但被壓窄時不會換行，只會截掉標題，所以不能只看 `wraps`：
        /// 要看這個寬度下算出來的高度有沒有比單行高。
        func clipped(_ view: NSView) -> Bool {
            guard let control = view as? NSControl, control is NSTextField || control is NSButton,
                  let cell = control.cell else { return false }
            if control.frame.width <= 0 { return true }
            let oneLine = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 10_000))
            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: control.frame.width, height: 10_000))
            if cell.wraps, needed.height > oneLine.height + 0.5 {
                return control.frame.height + 0.5 < needed.height
            }
            return control.frame.width + 0.5 < control.intrinsicContentSize.width
        }
        func firstProblem(in view: NSView, page: NSView, bounds: NSRect) -> String? {
            if view.isHidden { return nil }
            // 比的是對齊用的範圍：標籤與按鈕的外框本來就比看得到的部分大一圈。
            let frame = view.superview?.convert(view.alignmentRect(forFrame: view.frame), to: page) ?? view.bounds
            let text = (view as? NSTextField)?.stringValue ?? (view as? NSButton)?.title ?? view.className
            // 直接掛在頁面上的那一層占滿整頁，再往下的每個視圖都要留在分組的寬度裡，不能蓋到頁面留白。
            let margin = view.superview === page ? 0 : (SettingsWindowController.pageWidth - SettingsWindowController.groupWidth) / 2
            let allowed = bounds.insetBy(dx: margin - 0.5, dy: -0.5)
            if view !== page, !allowed.contains(frame) { return "「\(text)」超出分組的寬度或頁面（\(frame)）" }
            if clipped(view) { return "「\(text)」被截斷（\(view.frame.size)）" }
            // 系統控制項裡面的子視圖不歸我們排。
            if view is NSControl { return nil }
            return view.subviews.lazy.compactMap { firstProblem(in: $0, page: page, bounds: bounds) }.first
        }
        for tab in SettingsTab.allCases {
            guard let page = settings.pages[tab] else { return "少了「\(tab.title.text)」分頁" }
            let content = settings.contentSize(for: tab)
            guard page.size.height <= 520, page.size.height > 100, content.width <= 560 else {
                return "「\(tab.title.text)」分頁的內容高 \(page.size.height) 點、視窗內容寬 \(content.width) 點，超過上限 520 與 560"
            }
            settings.select(tab)
            guard settings.selectedTab == tab, settings.window.title == tab.title.text,
                  settings.window.contentRect(forFrameRect: settings.window.frame).size == content,
                  let container = settings.window.contentView, page.view.superview === container,
                  container.bounds.size == content, page.view.frame.minY == 0,
                  container.bounds.height + 0.5 >= page.size.height else {
                return "切到「\(tab.title.text)」後視窗沒有調成那一頁的大小（視窗 \(settings.window.frame.size)，應為 \(content)）"
            }
            page.view.layoutSubtreeIfNeeded()
            let bounds = NSRect(origin: .zero, size: page.size)
            if let problem = firstProblem(in: page.view, page: page.view, bounds: bounds) {
                return "「\(tab.title.text)」分頁：\(problem)"
            }
            // 同一頁的左緣：分組標題、核取方塊與「標籤加選單」的標籤都貼著 20 點的視窗邊距；
            // 說明用次要標籤色的小字，接在核取方塊底下的對齊方塊的標題文字，其餘貼著邊距。
            func left(_ view: NSView) -> CGFloat {
                (view.superview?.convert(view.alignmentRect(forFrame: view.frame), to: page.view) ?? .zero).minX
            }
            let margin = (SettingsWindowController.pageWidth - SettingsWindowController.groupWidth) / 2
            let onPage = { (view: NSView) in view.isDescendant(of: page.view) }
            let leading: [NSView] = (settings.groupTitles[tab] ?? []) + (settings.fieldLabels[tab] ?? [])
                + settings.checkboxes.values.filter(onPage)
                + [settings.updateCheckbox, settings.statisticsControls.toggle, settings.appIconView,
                   settings.statisticsControls.inspect].filter(onPage)
            if let stray = leading.first(where: { abs(left($0) - margin) > 0.5 }) {
                let text = (stray as? NSTextField)?.stringValue ?? (stray as? NSButton)?.title ?? stray.className
                return "「\(tab.title.text)」分頁：「\(text)」的左緣在 \(left(stray))，不是視窗邊距 \(margin)"
            }
            let popUps = (settings.fieldLabels[tab] ?? []).compactMap { label in
                label.superview?.subviews.first(where: { $0 is NSPopUpButton })
            }
            // 選單緊接在它的標籤後面，中間只隔一個標準間距。
            for (label, popUp) in zip(settings.fieldLabels[tab] ?? [], popUps) {
                let gap = left(popUp) - (label.superview?.convert(label.alignmentRect(forFrame: label.frame), to: page.view) ?? .zero).maxX
                guard popUps.count == (settings.fieldLabels[tab] ?? []).count, gap >= 4, gap <= 12 else {
                    return "「\(tab.title.text)」分頁：「\(label.stringValue)」與它的選單相距 \(gap) 點"
                }
            }
            for (note, checkbox) in settings.notes where onPage(note) {
                // 圖示旁邊那幾句排在圖示右邊的那一欄。
                let besideIcon = settings.appIconView.superview.map(note.isDescendant(of:)) == true
                let expected = besideIcon
                    ? margin + SettingsWindowController.appIconSize + SettingsWindowController.identitySpacing
                    : margin + (checkbox == nil ? 0 : SettingsWindowController.checkboxTitleIndent)
                guard abs(left(note) - expected) <= 0.5, note.textColor == .secondaryLabelColor,
                      note.font?.pointSize == NSFont.smallSystemFontSize else {
                    return "「\(tab.title.text)」分頁：說明「\(note.stringValue)」的左緣（\(left(note))，應為 \(expected)）、顏色或字級不對"
                }
                if let checkbox {
                    let gap = note.convert(note.bounds, to: page.view).minY - checkbox.convert(checkbox.bounds, to: page.view).maxY
                    guard onPage(checkbox), gap >= 0, gap <= 8 else {
                        return "「\(tab.title.text)」分頁：說明「\(note.stringValue)」沒有緊跟在它說明的核取方塊底下（相距 \(gap)）"
                    }
                }
            }
        }
        settings.select(.general)
        guard settings.notes.count >= 8 else { return "說明文字少於八句（\(settings.notes.count)）" }

        // 「關於」最上面是 App 圖示，授權聲明的按鈕與說明都不把檔名露給使用者。
        let exposed = ([settings.thirdPartyButton.title] + settings.notes.map(\.note.stringValue))
            .first(where: { $0.contains("THIRD_PARTY") || $0.contains(".md") })
        guard settings.appIconView.image != nil, !settings.appIconView.isAccessibilityElement(),
              settings.appIconView.frame.size == NSSize(width: SettingsWindowController.appIconSize,
                                                        height: SettingsWindowController.appIconSize),
              exposed == nil else {
            return "「關於」少了 App 圖示，或文字裡露出檔名（\(exposed ?? "")）"
        }

        // 「輔助說明」的兩顆按鈕各占一列，「複製診斷資訊」的說明緊接在它自己底下。
        if let about = settings.pages[.about]?.view,
           let copyNote = settings.notes.first(where: { $0.note.stringValue == UIText.settingsCopyDiagnosticsNote.text })?.note {
            settings.select(.about)
            about.layoutSubtreeIfNeeded()
            func frame(_ view: NSView) -> NSRect {
                view.superview?.convert(view.alignmentRect(forFrame: view.frame), to: about) ?? .zero
            }
            let guide = frame(settings.guideButton)
            let copy = frame(settings.copyDiagnosticsButton)
            let note = copyNote.convert(copyNote.bounds, to: about)
            settings.select(.general)
            guard copy.minY >= guide.maxY, abs(copy.minX - guide.minX) < 0.5,
                  note.minY >= copy.maxY, note.minY - copy.maxY <= 8 else {
                return "「輔助說明」的按鈕沒有各占一列，或診斷資訊的說明沒有緊接在它的按鈕底下（指南 \(guide)、複製 \(copy)、說明 \(note)）"
            }
        } else {
            return "「關於」找不到「複製診斷資訊」的說明"
        }

        // 個人術語那一列比分組內容寬的時候不會超出分組，而是整列往左擠掉內容的縮排，
        // 上面的範圍檢查看不出來，所以另外比它與所屬開關的左緣。
        if let general = settings.pages[.general]?.view, let row = settings.personalTermField.superview,
           let toggle = settings.checkboxes[.personalTerms], let toggleParent = toggle.superview {
            general.layoutSubtreeIfNeeded()
            let rowLeft = row.convert(row.bounds, to: general).minX
            let toggleLeft = toggleParent.convert(toggle.alignmentRect(forFrame: toggle.frame), to: general).minX
            guard abs(rowLeft - toggleLeft) < 0.5 else {
                return "個人術語那一列的左緣（\(rowLeft)）沒有對齊它的開關（\(toggleLeft)），這一列比分組寬"
            }
        }

        // 快捷鍵分頁：八列照固定順序由上往下排，一鍵一帽，兩欄各自對齊，說明會換行。
        guard let shortcuts = settings.pages[.shortcuts]?.view else { return "少了快捷鍵分頁" }
        let rows = ShortcutHint.allCases.compactMap { settings.shortcutFields[$0] }
        guard rows.count == 8, ShortcutHint.allCases.count == 8 else { return "快捷鍵不是八列" }
        for (hint, row) in zip(ShortcutHint.allCases, rows) {
            let caps = row.keys
            guard caps.map(\.key) == hint.keys, !caps.isEmpty,
                  caps.allSatisfy({ $0.isAccessibilityElement() && $0.accessibilityLabel() == $0.key.name
                      && $0.frame.size == $0.intrinsicContentSize }),
                  row.summary.stringValue == hint.summary.text, !row.summary.isEditable,
                  row.summary.maximumNumberOfLines == 0, row.summary.cell?.wraps == true,
                  row.summary.lineBreakMode == .byWordWrapping else {
                return "快捷鍵「\(hint)」那一列的鍵帽、無障礙名稱或說明不對"
            }
        }
        func left(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: shortcuts).minX }
        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: shortcuts).minY }
        let tops = rows.map { top($0.summary) }
        guard Set(rows.compactMap { $0.keys.first.map(left) }).count == 1,
              Set(rows.map { left($0.summary) }).count == 1,
              tops == tops.sorted(), Set(tops).count == 8 else {
            return "快捷鍵的兩欄沒有對齊或順序不對"
        }
        // 說明欄緊接在最寬那一列鍵帽後面，中間只隔一個標準間距，視線不必跳過一大段空白。
        let widestKeys = rows.compactMap { $0.keys.last.map { $0.convert($0.bounds, to: shortcuts).maxX } }.max() ?? 0
        let summaryLeft = rows.first.map { left($0.summary) } ?? 0
        guard summaryLeft - widestKeys >= 8, summaryLeft - widestKeys <= 16 else {
            return "快捷鍵的說明欄離最寬那一列鍵帽 \(summaryLeft - widestKeys) 點，應該只隔一個標準間距"
        }
        return nil
    }
    if let problem = pageLayoutProblem(in: settings) {
        return .failure(SelfTestFailure(message: "設定視窗的分頁版面：\(problem)"))
    }
    passed += 1
    // 英文比中文長，有的標題與說明要換行才放得下，所以有翻譯表時（打包後）用英文再建一次視窗來看。
    if let english = Localization.englishStrings() {
        Localization.current = Localization(strings: english)
        defer { Localization.current = Localization() }
        let englishSettings = SettingsWindowController(
            preferences: preferences,
            usageStore: UsageHistoryStore(fileURL: historyURL),
            statistics: statistics,
            updates: UpdateChecker(defaults: suite, currentVersion: nil, fetch: { _ in })
        )
        guard englishSettings.shortcutFields[.space]?.keys.first?.key.name == "Space" else {
            return .failure(SelfTestFailure(message: "英文語系下空白鍵的鍵帽不是 Space"))
        }
        if let problem = pageLayoutProblem(in: englishSettings) {
            return .failure(SelfTestFailure(message: "英文語系下設定視窗的分頁版面：\(problem)"))
        }
        passed += 1
    }

    // 非預設的偏好也要如實反映，包含與偏好取反的「使用半形標點符號」。
    configuration.mixedModeEnabled = false
    configuration.autoPunctuationEnabled = false
    configuration.learnsCangjieOrder = false
    configuration.cangjieVersion = .v5
    configuration.readingScheme = .pinyin
    preferences.save(configuration)
    settings.reloadFromPreferences()
    guard settings.checkboxes[.mixedMode]?.state == .off,
          settings.checkboxes[.halfwidthPunctuation]?.state == .on,
          settings.checkboxes[.learnsCangjieOrder]?.state == .off,
          settings.checkboxes[.learnsReadingLookupOrder]?.state == .on,
          settings.cangjieVersionControl.indexOfSelectedItem == 1,
          settings.readingSchemeControl.indexOfSelectedItem == 1 else {
        return .failure(SelfTestFailure(message: "設定視窗沒有反映已存的偏好"))
    }
    passed += 1

    // 複製診斷資訊：按鈕在「關於」那一組裡，按下後剪貼簿拿到現在這份偏好的摘要，
    // 個人術語只有筆數，按鈕標題短暫換成「已複製」再自己換回來。
    do {
        let button = settings.copyDiagnosticsButton
        guard let document = settings.pages[.about]?.view,
              button.isDescendant(of: document),
              button.title == UIText.settingsCopyDiagnostics.text,
              button.convert(button.bounds, to: document).minY
                > settings.updateCheckbox.convert(settings.updateCheckbox.bounds, to: document).minY,
              pasteboard.string(forType: .string) == nil else {
            return .failure(SelfTestFailure(message: "設定視窗的「關於」沒有「複製診斷資訊」按鈕，或還沒按就動了剪貼簿"))
        }
        var withTerms = configuration
        withTerms.personalTermsEnabled = true
        withTerms.personalTerms = PersonalTerms(["SecretInternalToken999", "kubectl"])
        preferences.save(withTerms)
        preferences.saveOverlayFontSize(.large)
        defer {
            preferences.save(configuration)
            preferences.saveOverlayFontSize(.medium)
        }
        let general = NSPasteboard.general.changeCount
        button.performClick(nil)
        let copied = pasteboard.string(forType: .string) ?? ""
        let lines = copied.components(separatedBy: "\n")
        func field(_ label: UIText, _ value: String) -> String {
            UIText.diagnosticField.text(label.text, value)
        }
        let on = UIText.diagnosticOn.text
        let off = UIText.diagnosticOff.text
        let contentOK = lines.first == UIText.diagnosticTitle.text
            && lines.count == 8 + SettingsToggle.allCases.count
            && lines.contains(UIText.diagnosticVersion.text(DiagnosticReport.appVersion(), DiagnosticReport.architecture))
            && lines.contains(UIText.diagnosticField.text("macOS", ProcessInfo.processInfo.operatingSystemVersionString))
            && lines.contains(field(.settingsCangjieVersion, UIText.cangjieV5.text))
            && lines.contains(field(.menuMixedMode, off))
            && lines.contains(field(.menuHalfwidthPunctuation, on))
            && lines.contains(field(.settingsLearnCangjie, off))
            && lines.contains(field(.settingsPersonalTerms, UIText.diagnosticTermCount.text(on, 2)))
            && lines.contains(field(.diagnosticReadingScheme, UIText.readingSchemePinyin.text))
            && lines.contains(field(.settingsOverlayFontSize, UIText.overlayFontSizeLarge.text))
            && lines.contains(field(.statisticsToggle, off))
            && lines.contains(field(.settingsUpdateCheck, off))
        let privateOK = !copied.contains("SecretInternalToken999") && !copied.contains("kubectl")
            && !copied.contains("/Users/") && !copied.contains(NSUserName())
        guard contentOK, privateOK, copied == settings.diagnosticReport,
              NSPasteboard.general.changeCount == general else {
            return .failure(SelfTestFailure(message: "複製到剪貼簿的診斷資訊不對，或含有不該出現的內容：\(lines.count) 行"))
        }
        passed += 1
        guard button.title == UIText.settingsDiagnosticsCopied.text else {
            return .failure(SelfTestFailure(message: "複製診斷資訊後按鈕沒有顯示「已複製」"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(SettingsWindowController.diagnosticsFeedbackLifetime + 0.3))
        guard button.title == UIText.settingsCopyDiagnostics.text else {
            return .failure(SelfTestFailure(message: "「已複製」沒有自己換回「複製診斷資訊」"))
        }
        passed += 1
    }

    let counter = NotificationCounter()
    let observer = NotificationCenter.default.addObserver(
        forName: .goshawkPreferencesDidChange,
        object: nil,
        queue: nil
    ) { _ in counter.value += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }

    let session = InputSessionCoordinator(
        configuration: preferences.loadConfiguration(),
        preferences: preferences
    )
    let host = FakeIMKClient()
    for ch in "my" {
        _ = session.handlePayload(
            KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)),
            client: host
        )
    }
    settings.checkboxes[.mixedMode]?.performClick(nil)
    settings.checkboxes[.learnsCangjieOrder]?.performClick(nil)
    settings.readingSchemeControl.selectItem(at: 0)
    if let action = settings.readingSchemeControl.action {
        NSApp.sendAction(action, to: settings.readingSchemeControl.target, from: settings.readingSchemeControl)
    }
    let stored = preferences.loadConfiguration()
    // 控制器收到通知後走的就是這條路。
    session.reloadConfiguration(client: host)
    guard stored.mixedModeEnabled, stored.learnsCangjieOrder, stored.readingScheme == .dachen,
          counter.value == 3,
          session.engine.configuration.mixedModeEnabled,
          session.engine.configuration.learnsCangjieOrder,
          session.engine.configuration.readingScheme == .dachen,
          session.engine.buffer.isEmpty,
          host.text == "my" else {
        return .failure(SelfTestFailure(message: "改設定後偏好、通知或作用中的協調器沒有跟上（通知 \(counter.value) 次，文件 '\(host.text)'）"))
    }
    passed += 1

    // 一鍵反悔的核取方塊：預設勾選，取消後偏好寫成 false，作用中的協調器不再反悔。
    let revertKey = "goshawk.revertEnabled"
    let revertDefaultOn = settings.checkboxes[.revert]?.state == .on
        && settings.checkboxes[.revert]?.title == UIText.settingsRevert.text
        && SettingsToggle.revert.group == .settingsGroupInput
        && stored.revertEnabled
    settings.checkboxes[.revert]?.performClick(nil)
    session.reloadConfiguration(client: host)
    let revertOff = suite.object(forKey: revertKey) as? Bool == false
        && !preferences.loadConfiguration().revertEnabled
        && !session.engine.configuration.revertEnabled
        && counter.value == 4
    for ch in "my" {
        _ = session.handlePayload(
            KeyEventPayload(keyCode: 0, characters: String(ch), charactersIgnoringModifiers: String(ch)),
            client: host
        )
    }
    _ = session.handlePayload(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "), client: host)
    let noRecord = session.engine.revertRecord == nil && session.revertHint == nil
    settings.checkboxes[.revert]?.performClick(nil)
    settings.reloadFromPreferences()
    guard revertDefaultOn, revertOff, noRecord,
          suite.object(forKey: revertKey) as? Bool == true,
          settings.checkboxes[.revert]?.state == .on else {
        return .failure(SelfTestFailure(message: "一鍵反悔的核取方塊沒有正確讀寫偏好（通知 \(counter.value) 次，文件 '\(host.text)'）"))
    }
    passed += 1

    guard settings.checkboxes[.chineseContinuation]?.state == .off,
          settings.checkboxes[.personalTerms]?.state == .off else {
        return .failure(SelfTestFailure(message: "新的偏好不應預先開啟接詞或個人術語"))
    }
    // 補完沒勾選時，術語欄位與兩顆按鈕都停用；勾選後一起啟用。
    let termControls: [NSControl] = [settings.personalTermField, settings.addTermButton, settings.removeTermButton]
    guard termControls.allSatisfy({ !$0.isEnabled }) else {
        return .failure(SelfTestFailure(message: "英文個人術語補完沒勾選時，術語欄位或按鈕仍可使用"))
    }
    settings.checkboxes[.personalTerms]?.performClick(nil)
    guard termControls.allSatisfy(\.isEnabled) else {
        return .failure(SelfTestFailure(message: "勾選英文個人術語補完後，術語欄位或按鈕沒有啟用"))
    }
    settings.personalTermField.stringValue = "GoshawkIME"
    settings.addTermButton.performClick(nil)
    settings.reloadFromPreferences()
    let termConfig = preferences.loadConfiguration()
    guard termConfig.personalTermsEnabled, !termConfig.chineseContinuationEnabled,
          termConfig.personalTerms.words == ["GoshawkIME"],
          settings.personalTermField.objectValues as? [String] == ["GoshawkIME"] else {
        return .failure(SelfTestFailure(message: "從設定加入術語後沒有正確存檔與列出"))
    }
    let textHost = TextViewTestClient()
    let trial = InputSessionCoordinator(configuration: termConfig, preferences: preferences)
    func type(_ text: String) {
        for ch in text {
            _ = trial.handlePayload(KeyEventPayload(keyCode: 0, characters: String(ch),
                                                   charactersIgnoringModifiers: String(ch)), client: textHost)
        }
    }
    type("goshaw")
    _ = trial.handlePayload(KeyEventPayload(keyCode: 48, characters: "\t", charactersIgnoringModifiers: "\t"), client: textHost)
    guard textHost.view.string == "GoshawkIME " else {
        return .failure(SelfTestFailure(message: "文字欄位沒有收到保留大小寫的術語"))
    }
    settings.personalTermField.stringValue = "goshawkime"
    settings.removeTermButton.performClick(nil)
    settings.reloadFromPreferences()
    guard preferences.loadConfiguration().personalTerms.words.isEmpty,
          settings.personalTermField.numberOfItems == 0 else {
        return .failure(SelfTestFailure(message: "從設定刪除術語之後仍然留在選單或偏好"))
    }
    passed += 1

    settings.checkboxes[.chineseContinuation]?.performClick(nil)
    trial.reloadConfiguration(client: textHost)
    let panel = CandidateOverlayPanel.shared
    defer { panel.orderOut(nil) }
    let accept = KeyEventPayload(keyCode: 36, modifierFlags: .option, characters: "\r", charactersIgnoringModifiers: "\r")
    func composeAfter(_ prefix: String) {
        trial.resetForFocusChange()
        textHost.view.string = prefix
        textHost.view.setSelectedRange(NSRange(location: prefix.utf16.count, length: 0))
        type("fdyj")
        _ = trial.handlePayload(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "),
                                client: textHost) { overlay, reading, rect in
            panel.update(overlay: overlay, layerPanel: reading, cursorRect: rect, showsEnglishActions: false,
                         revertHint: trial.revertHint, continuation: trial.engine.chineseContinuation)
        }
    }
    composeAfter("用 SQL 查詢資")
    guard panel.isVisible, panel.shownCommitHint?.contains(UIText.continuationHint.text("庫")) == true,
          textHost.view.string == "用 SQL 查詢資料",
          trial.handlePayload(accept, client: textHost),
          textHost.view.string == "用 SQL 查詢資料庫",
          !trial.handlePayload(accept, client: textHost) else {
        return .failure(SelfTestFailure(message: "中文接詞的浮窗、採用按鍵或原文字欄位結果有誤"))
    }
    composeAfter("SQL 資")
    let prefixEnd = textHost.view.string.utf16.count
    textHost.view.textStorage?.append(NSAttributedString(string: "保留"))
    textHost.view.setSelectedRange(NSRange(location: prefixEnd, length: 2))
    guard !trial.handlePayload(accept, client: textHost), textHost.view.string == "SQL 資料保留" else {
        return .failure(SelfTestFailure(message: "接詞取代了使用者手動選取的文字"))
    }
    composeAfter("存放檔案的資")
    guard trial.engine.chineseContinuation == "夾" else {
        return .failure(SelfTestFailure(message: "檔案前文沒有提示資料夾"))
    }
    trial.commitComposition(client: textHost)
    trial.resetForFocusChange()
    let nextHost = TextViewTestClient()
    guard !trial.handlePayload(accept, client: nextHost), nextHost.view.string.isEmpty,
          textHost.view.string == "存放檔案的資料" else {
        return .failure(SelfTestFailure(message: "換欄位後舊接詞仍被採用"))
    }
    passed += 1

    // 介面文字的翻譯清單：套件裡的英文翻譯必須涵蓋程式裡每一個經過在地化函式的字串。
    if let english = Localization.englishStrings() {
        let missing = UIText.allCases.map(\.rawValue).filter { english[$0] == nil }
        guard missing.isEmpty else {
            return .failure(SelfTestFailure(message: "en.lproj/Localizable.strings 缺少翻譯：\(missing.joined(separator: " | "))"))
        }
        let translated = Localization(strings: english)
        guard translated.text(for: UIText.menuSettings.rawValue) == "Settings…",
              translated.text(for: UIText.productName.rawValue) == "Goshawk" else {
            return .failure(SelfTestFailure(message: "en.lproj/Localizable.strings 的內容不是預期的英文"))
        }
        passed += 1
    }

    return .success(passed)
}

struct AppSelfTestReport: Codable {
    let status: String
    let shellRegressionChecks: Int
    /// 程式裡每一個經過在地化函式的字串原文，供打包驗證比對翻譯檔。
    let localizableStrings: [String]
    let cangjieV5Codes: Int
    let cangjieV3Codes: Int
    let englishWords: Int
    let simulatedDocument: String
    let dualTrackFormattedEnglish: String
    let dualTrackFormattedCangjie: String?
    let clampedX: Double
    let clampedY: Double
}

@MainActor
func runAppSelfTest() -> Int32 {
    _ = NSApplication.shared
    // 版面與 VoiceOver 的斷言固定用中文原文，不受執行環境的語系影響。
    // 英文翻譯另外由 runSettingsWindowChecks 比對套件裡的翻譯檔。
    Localization.current = Localization()
    let cj5Count = CangjieDictionary.sharedV5.codeCount
    let cj3Count = CangjieDictionary.sharedV3.codeCount
    let enCount = EnglishPredictor.shared.wordCount

    let coordinator = InputSessionCoordinator(configuration: EngineConfiguration())
    let client = FakeIMKClient()

    func send(_ payload: KeyEventPayload) -> Bool {
        coordinator.handlePayload(payload, client: client) { overlay, _, _ in
            client.lastOverlay = overlay
        }
    }

    // 1. Type "m y" -> inspect dual overlay -> Space -> "下"
    _ = send(KeyEventPayload(keyCode: 46, characters: "m", charactersIgnoringModifiers: "m"))
    _ = send(KeyEventPayload(keyCode: 16, characters: "y", charactersIgnoringModifiers: "y"))
    guard let dualOverlay = client.lastOverlay,
          dualOverlay.cangjieTrack?.candidates.first == "下" else {
        fputs("Self-test failed: expected dual overlay for 'my' -> '下'\n", stderr)
        return 1
    }
    let formattedDual = CandidateOverlayPanel.formatTracks(for: dualOverlay, showsEnglishActions: coordinator.englishActionsAvailable)
    _ = send(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "))

    // 2. Type "h e l l o" + Tab + "," -> "下 hello,"
    for (code, ch) in [(4, "h"), (14, "e"), (37, "l"), (37, "l"), (31, "o")] as [(UInt16, String)] {
        _ = send(KeyEventPayload(keyCode: code, characters: ch, charactersIgnoringModifiers: ch))
    }
    _ = send(KeyEventPayload(keyCode: 48, characters: "\t", charactersIgnoringModifiers: "\t"))
    _ = send(KeyEventPayload(keyCode: 43, characters: ",", charactersIgnoringModifiers: ","))

    // 3. Space + "i s" + Shift+2 (select 2nd English prediction) -> "下 hello, <2nd> "
    _ = send(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "))
    _ = send(KeyEventPayload(keyCode: 34, characters: "i", charactersIgnoringModifiers: "i"))
    _ = send(KeyEventPayload(keyCode: 1, characters: "s", charactersIgnoringModifiers: "s"))
    let secondPred = coordinator.engine.currentOverlay?.englishTrack.predictions.dropFirst().first
    _ = send(KeyEventPayload(keyCode: 19, modifierFlags: .shift, characters: "@", charactersIgnoringModifiers: "2"))

    // 4. Double-shift pure English mode toggle + Cangjie commit after exiting
    _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: .shift, timestamp: 1.0))
    _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: [], timestamp: 1.05))
    _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: .shift, timestamp: 1.15))
    _ = send(KeyEventPayload(isKeyDown: false, isFlagsChanged: true, keyCode: 56, modifierFlags: [], timestamp: 1.20))
    guard coordinator.engine.state == .pureEnglish else {
        fputs("Self-test failed: double shift did not enter pureEnglish\n", stderr)
        return 1
    }
    _ = send(KeyEventPayload(keyCode: 46, characters: "m", charactersIgnoringModifiers: "m"))
    _ = send(KeyEventPayload(keyCode: 16, characters: "y", charactersIgnoringModifiers: "y"))
    _ = send(KeyEventPayload(keyCode: 49, characters: " ", charactersIgnoringModifiers: " "))

    let expectedPrefix = "下 hello, \(secondPred ?? "issue") my "
    guard client.text == expectedPrefix,
          cj5Count > 10_000,
          cj3Count > 10_000,
          enCount > 9_000 else {
        fputs("Self-test failed: text='\(client.text)' expected='\(expectedPrefix)' counts=(\(cj5Count),\(cj3Count),\(enCount))\n", stderr)
        return 1
    }

    let clamped = CandidateOverlayPanel.clampedOrigin(
        for: NSSize(width: 240, height: 60),
        cursorRect: NSRect(x: 1400, y: 12, width: 2, height: 18),
        screenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )

    let shellChecks: Int
    switch runShellRegressionChecks() {
    case .success(let count):
        shellChecks = count
    case .failure(let failure):
        fputs("Self-test failed: \(failure.message)\n", stderr)
        return 1
    }

    let statisticsChecks: Int
    do { statisticsChecks = try runStatisticsChecks() }
    catch {
        fputs("Self-test failed: \(error)\n", stderr)
        return 1
    }
    let report = AppSelfTestReport(
        status: "ok",
        shellRegressionChecks: shellChecks + statisticsChecks,
        localizableStrings: UIText.allCases.map(\.rawValue).sorted(),
        cangjieV5Codes: cj5Count,
        cangjieV3Codes: cj3Count,
        englishWords: enCount,
        simulatedDocument: client.text,
        dualTrackFormattedEnglish: formattedDual.english.string,
        dualTrackFormattedCangjie: formattedDual.cangjie?.string,
        clampedX: Double(clamped.x),
        clampedY: Double(clamped.y)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(report) {
        print(String(decoding: data, as: UTF8.self))
    }
    return 0
}

/// 開發用（`--settings-shots <資料夾>`）：把設定視窗的每個分頁在中文與英文、淺色與深色各畫成一張 PNG，
/// 並印出每一頁的內容大小，改版面時拿來看有沒有截斷或對不齊。不顯示視窗，也不動使用者的偏好。
/// 圖上連標題列與工具列一起畫；視窗沒有真的顯示，所以標題與沒選到的分頁是非作用中視窗的淡色。
/// 英文要有翻譯表，所以從打包後的 App 執行。
@MainActor
func renderSettingsScreenshots(to directory: URL) -> Int32 {
    _ = NSApplication.shared
    let pid = ProcessInfo.processInfo.processIdentifier
    let suiteName = "goshawk-settings-shots-\(pid)"
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    guard let suite = UserDefaults(suiteName: suiteName), let english = Localization.englishStrings() else {
        fputs("畫不出設定視窗：沒有英文翻譯表（請從打包後的 App 執行）或建不出偏好網域\n", stderr)
        return 1
    }
    defer {
        suite.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        Localization.current = Localization.resolved()
    }
    let names: [SettingsTab: String] = [
        .general: "general", .punctuationAndAppearance: "punctuation", .shortcuts: "shortcuts", .about: "about"
    ]
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (language, strings) in [("zh", [:]), ("en", english)] {
            Localization.current = Localization(strings: strings)
            let statistics = LocalUsageStatistics(url: scratch.appendingPathComponent("statistics.json"),
                                                  defaults: suite, build: "shots")
            defer { statistics.shutdown() }
            let settings = SettingsWindowController(
                preferences: PreferencesStore(defaults: suite),
                usageStore: UsageHistoryStore(fileURL: scratch.appendingPathComponent("usage-history.json")),
                statistics: statistics,
                updates: UpdateChecker(defaults: suite, currentVersion: nil, fetch: { _ in })
            )
            // 分頁列的標籤要等事件迴圈轉過一輪才排好，不等的話第一張圖的分頁列是空的。
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            for (theme, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                guard let appearance = NSAppearance(named: appearanceName) else { continue }
                settings.window.appearance = appearance
                for tab in SettingsTab.allCases {
                    settings.select(tab)
                    // 畫的是視窗的外框視圖，標題列與工具列的分頁圖示才會在圖上。
                    guard let content = settings.window.contentView, let view = content.superview,
                          let name = names[tab], let page = settings.pages[tab] else { continue }
                    view.layoutSubtreeIfNeeded()
                    settings.window.displayIfNeeded()
                    // 一點畫兩個像素，與 Retina 螢幕上看到的一樣；一比一時半點位置的分隔線會糊掉。
                    func bitmap() -> NSBitmapImageRep? {
                        let rep = NSBitmapImageRep(
                            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2,
                            pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                        )
                        rep?.size = view.bounds.size
                        return rep
                    }
                    guard let capture = bitmap(), let canvas = bitmap(),
                          let context = NSGraphicsContext(bitmapImageRep: canvas) else { continue }
                    view.cacheDisplay(in: view.bounds, to: capture)
                    // 內容視圖自己不畫視窗底色，先鋪一層再疊上去。
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = context
                    appearance.performAsCurrentDrawingAppearance {
                        NSColor.windowBackgroundColor.setFill()
                        NSRect(origin: .zero, size: view.bounds.size).fill()
                    }
                    capture.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero,
                                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    guard let png = canvas.representation(using: .png, properties: [:]) else { continue }
                    let url = directory.appendingPathComponent("\(language)-\(theme)-\(name).png")
                    try png.write(to: url, options: .atomic)
                    print("\(url.path)\t分頁內容 \(Int(page.size.width))x\(Int(page.size.height))\t視窗內容 \(Int(content.bounds.width))x\(Int(content.bounds.height))")
                }
            }
        }
    } catch {
        fputs("畫不出設定視窗：\(error.localizedDescription)\n", stderr)
        return 1
    }
    return 0
}
