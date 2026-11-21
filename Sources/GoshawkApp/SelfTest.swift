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

    func insertText(_ string: String, replacementRange: NSRange) {
        insertedStrings.append(string)
        markedText = ""
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

    /// 一般文字欄位的游標在標記文字後面（NSTextView 就是這樣），所以標記文字算進位置。
    func selectedRange() -> NSRange {
        reportsCursorAtZero
            ? NSRange(location: 0, length: 0)
            : NSRange(location: (text as NSString).length + (markedText as NSString).length, length: 0)
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

    func insertText(_ string: String, replacementRange: NSRange) {
        view.insertText(string, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: String, selectionRange: NSRange, replacementRange: NSRange) {
        view.setMarkedText(string, selectedRange: selectionRange, replacementRange: replacementRange)
    }

    func selectedRange() -> NSRange { view.selectedRange() }

    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        view.attributedSubstring(forProposedRange: range, actualRange: nil)
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
    fresh()
    _ = send(periodKey)
    let lineStart = client.text
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
    otherHost.clearUsageHistory()
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
            readingPanel: readingPanel,
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
    let missingRow = ReadingLookupPanel.Row(number: 3, character: "㑁", code: nil, radicals: nil)
    let samplePanel = ReadingLookupPanel(
        scheme: .dachen,
        inputDisplay: "ㄘㄨㄛˋ",
        cangjieVersion: .v5,
        status: .results,
        rows: [sampleRow, missingRow],
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
        && missingColumns == ("3", "㑁", "本代未收錄", "")
        && ReadingLookupView.headerText(for: samplePanel) == "ㄘㄨㄛˋ  倉頡五代"
        && ReadingLookupView.headerText(for: emptyPanel) == "zzz  倉頡三代"
        && ReadingLookupView.footerText(for: samplePanel) == "第 1 頁，共 3 頁  ↓ 選字  Tab 切換方案  Esc 關閉"
        && ReadingLookupView.footerText(for: emptyPanel) == "↓ 選字  Tab 切換方案  Esc 關閉"
        && ReadingLookupView.placeholderText(for: .noResults) == "查無此讀音"
        && ReadingLookupView.placeholderText(for: .results) == nil
        && ReadingLookupView.rowAccessibilityLabel(for: sampleRow) == "第 1 列，厝，字母碼 mta，字根 一廿日"
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
    learnHost.clearUsageHistory()
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

    // 設定視窗：每個控制項的初始狀態與偏好一致，切換後偏好被寫入並發出通知，
    // 作用中的協調器重新載入設定且先結束組字。
    switch runSettingsWindowChecks() {
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
            readingPanel: readingPanel,
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

/// 一鍵反悔的外層檢查。兩種模擬宿主各走一遍：讀得回文字的一般欄位立即送出、反悔時取代；
/// 永遠回報游標在 0 的終端機把可反悔的送出暫存成標記文字，下一個按鍵才落地。
@MainActor
func runRevertChecks() -> Result<Int, SelfTestFailure> {
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
    store.clear()
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

    // 提示：內容是對調後的字詞，反悔後換成另一邊，下一個按鍵就消失。浮窗不取得鍵盤焦點。
    guard let screen = NSScreen.main else {
        return .failure(SelfTestFailure(message: "Missing screen for the revert hint checks"))
    }
    for terminal in [false, true] {
        fresh(terminal: terminal)
        let panel = CandidateOverlayPanel()
        let cursor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY, width: 1, height: 18)
        let render: OverlayUpdate = { overlay, readingPanel, rect in
            panel.update(
                overlay: overlay,
                readingPanel: readingPanel,
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
        let hintAfterCommit = panel.isVisible && !panel.isKeyWindow && panel.shownRevertHint == "⇧空白 改成 my"
            && panel.frame.minX == composingFrame.minX
        press(shiftSpaceKey)
        let hintAfterRevert = panel.isVisible && panel.shownRevertHint == "⇧空白 改成 下"
        press(key("a"))
        let hintGone = panel.isVisible && panel.shownRevertHint == nil
        press(escapeKey)
        if let failure = check("Revert hint text and lifetime (terminal=\(terminal))",
                               hintAfterCommit && hintAfterRevert && hintGone && !panel.isVisible) {
            return .failure(SelfTestFailure(message: failure.message + " shown='\(panel.shownRevertHint ?? "nil")'"))
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
    let settings = SettingsWindowController(
        preferences: preferences,
        usageStore: UsageHistoryStore(fileURL: historyURL)
    )

    var configuration = preferences.loadConfiguration()
    let initialStatesMatch = settings.checkboxes.count == SettingsToggle.allCases.count
        && SettingsToggle.allCases.allSatisfy {
            settings.checkboxes[$0]?.state == ($0.isOn(in: configuration) ? .on : .off)
        }
        && settings.cangjieVersionControl.indexOfSelectedItem == 0
        && settings.readingSchemeControl.indexOfSelectedItem == 0
    let size = settings.documentSize
    // 螢幕夠高就完整顯示；螢幕矮時視窗縮到放得下，內容留在捲動視圖裡；再矮也保留最小高度。
    let scrollView = settings.window.contentView as? NSScrollView
    let scrollingOK = scrollView?.documentView?.frame.size == size
        && scrollView?.hasVerticalScroller == true
        && settings.window.contentMaxSize == size
        && SettingsWindowController.contentHeight(documentHeight: 640, screenVisibleHeight: 1000) == 640
        && SettingsWindowController.contentHeight(documentHeight: 640, screenVisibleHeight: 500) == 420
        && SettingsWindowController.contentHeight(documentHeight: 640, screenVisibleHeight: 200) == 240
        && SettingsWindowController.contentHeight(documentHeight: 180, screenVisibleHeight: 200) == 180
    guard scrollingOK else {
        return .failure(SelfTestFailure(message: "設定視窗的內容沒有放進可捲動的區域，或高度計算不對（內容 \(size)，上限 \(settings.window.contentMaxSize)）"))
    }
    passed += 1
    guard initialStatesMatch,
          settings.window.title == UIText.settingsTitle.text,
          size.width > 300, size.height > 300 else {
        let states = SettingsToggle.allCases
            .map { "\($0.rawValue)=\(settings.checkboxes[$0]?.state.rawValue ?? -9)" }
            .joined(separator: " ")
        return .failure(SelfTestFailure(message: "設定視窗的初始狀態與偏好不符（\(settings.checkboxes.count) 個開關，\(size)，\(states)）"))
    }
    passed += 1

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

    let report = AppSelfTestReport(
        status: "ok",
        shellRegressionChecks: shellChecks,
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
