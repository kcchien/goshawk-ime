import AppKit
import Foundation
import GoshawkCore

struct KeyEventPayload: Sendable {
    let isKeyDown: Bool
    let isFlagsChanged: Bool
    let keyCode: UInt16
    let modifierFlags: NSEvent.ModifierFlags
    let characters: String?
    let charactersIgnoringModifiers: String?
    let timestamp: TimeInterval

    init(
        isKeyDown: Bool = true,
        isFlagsChanged: Bool = false,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String? = nil,
        charactersIgnoringModifiers: String? = nil,
        timestamp: TimeInterval = 0
    ) {
        self.isKeyDown = isKeyDown
        self.isFlagsChanged = isFlagsChanged
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.timestamp = timestamp
    }

    init?(event: NSEvent) {
        switch event.type {
        case .keyDown:
            self.init(
                isKeyDown: true,
                isFlagsChanged: false,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                characters: event.characters,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                timestamp: event.timestamp
            )
        case .flagsChanged:
            self.init(
                isKeyDown: false,
                isFlagsChanged: true,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                characters: nil,
                charactersIgnoringModifiers: nil,
                timestamp: event.timestamp
            )
        default:
            return nil
        }
    }
}

struct EventTranslator {
    private var shiftDetector = ShiftTapDetector()
    /// 上一個按鍵是按著 Shift 打出來的字元，而且 Shift 從那時到現在都沒放開。
    /// 這時的 Shift+空白 是手還沒離開 Shift 的誤觸（`Hello!` 接空白），當成一般空白。
    private var shiftHeldSinceShiftedKey = false

    /// `Ctrl` 加這些鍵面字元送出對應的全形標點。角引號另有偏好可停用，不在這裡。
    private static let ctrlFullwidthKeys: Set<Character> = Set(KeyInput.ctrlFullwidthTokens.values)

    /// `Ctrl+Shift` 加這些鍵時，沒套用 Shift 的鍵面字元對應到要送的那個標點鍵。
    private static let ctrlShiftedBaseKeys: [Character: Character] = [
        "1": "!", "/": "?", "9": "(", "0": ")"
    ]

    private static let shiftDigitKeyCodes: [UInt16: Int] = [
        18: 1, // 1
        19: 2, // 2
        20: 3, // 3
        21: 4, // 4
        23: 5, // 5
        22: 6, // 6
        26: 7, // 7
        28: 8, // 8
        25: 9  // 9
    ]

    private static func isPrintableASCII(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (0x20...0x7E).contains(ascii)
    }

    /// Returns nil for keys the IME does not interpret; the caller forwards those to the
    /// client. `acceptsEnglishSelection` is true only while an English prediction list is
    /// showing, so Shift+digit otherwise stays an ordinary symbol key.
    /// `readingLookupActive` 為真時，可印字元與瀏覽鍵都屬於反查面板，雙擊 Shift、
    /// Shift+數字選英文與 Option+Shift+H 都不作用。
    mutating func translate(
        _ payload: KeyEventPayload,
        readingLookupActive: Bool = false,
        acceptsEnglishSelection: () -> Bool
    ) -> TranslatedEvent? {
        if !readingLookupActive, Self.isHalfwidthPunctuationToggle(payload) {
            shiftDetector.noteNonModifierKeyPressed()
            shiftHeldSinceShiftedKey = false
            return .toggleHalfwidthPunctuation
        }
        let key = translateKey(
            payload,
            readingLookupActive: readingLookupActive,
            acceptsEnglishSelection: acceptsEnglishSelection
        )
        noteShiftedCharacterKey(payload, produced: key)
        return key.map(TranslatedEvent.key)
    }

    /// 每個按鍵結束時更新防誤觸的旗標：只有按著 Shift 打出字元的按鍵會把它設起來，
    /// 其他按鍵都清掉。Shift 放開由修飾鍵事件清掉。
    private mutating func noteShiftedCharacterKey(_ payload: KeyEventPayload, produced key: KeyInput?) {
        guard payload.isKeyDown else { return }
        if case .character = key, payload.modifierFlags.contains(.shift) {
            shiftHeldSinceShiftedKey = true
        } else {
            shiftHeldSinceShiftedKey = false
        }
    }

    private static func isHalfwidthPunctuationToggle(_ payload: KeyEventPayload) -> Bool {
        payload.isKeyDown
            && payload.modifierFlags.intersection([.command, .control, .option, .shift]) == [.option, .shift]
            && payload.charactersIgnoringModifiers?.lowercased() == "h"
    }

    /// 反查開啟時的瀏覽鍵。`Page Up` 與 `Page Down` 只在這裡用到。
    private static func readingLookupKey(_ payload: KeyEventPayload) -> KeyInput? {
        switch payload.keyCode {
        case 53: // kVK_Escape
            return .escape
        case 36, 76: // kVK_Return, kVK_ANSI_KeypadEnter
            return .enter
        case 48: // kVK_Tab
            return .tab
        case 51: // kVK_Delete
            return .backspace
        case 49: // kVK_Space
            return .space
        case 125:
            return .arrowDown
        case 126:
            return .arrowUp
        case 116: // kVK_PageUp
            return .pageUp
        case 121: // kVK_PageDown
            return .pageDown
        default:
            break
        }
        // 讀音鍵以鍵面字元為準，Shift 不當成另一鍵。
        guard let chars = payload.charactersIgnoringModifiers,
              chars.count == 1,
              let ch = chars.first,
              isPrintableASCII(ch) else {
            return nil
        }
        return .character(ch.lowercased().first ?? ch)
    }

    private mutating func translateKey(
        _ payload: KeyEventPayload,
        readingLookupActive: Bool,
        acceptsEnglishSelection: () -> Bool
    ) -> KeyInput? {
        if payload.isFlagsChanged {
            if !payload.modifierFlags.contains(.shift) {
                // Shift 放開了，下一次的 Shift+空白 不再算是沒放手的誤觸。
                shiftHeldSinceShiftedKey = false
            }
            guard !readingLookupActive else {
                // 反查期間不偵測雙擊 Shift，面板關閉後也不該接上先前的半個手勢。
                shiftDetector = ShiftTapDetector()
                return nil
            }
            let isShiftKey = payload.keyCode == 56 || payload.keyCode == 60
            guard isShiftKey, payload.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else {
                shiftDetector = ShiftTapDetector()
                return nil
            }
            let shiftDown = payload.modifierFlags.contains(.shift)
            if shiftDetector.handleShiftChanged(isDown: shiftDown, timestamp: payload.timestamp) {
                return .doubleShift
            }
            return nil
        }

        guard payload.isKeyDown else {
            return nil
        }

        shiftDetector.noteNonModifierKeyPressed()

        // Let system / app shortcuts using Command pass through untouched.
        if payload.modifierFlags.contains(.command) {
            return nil
        }

        if payload.modifierFlags.contains(.control) {
            guard !payload.modifierFlags.contains(.option) else { return nil }
            // charactersIgnoringModifiers still applies Shift, so Ctrl+Shift+[ reports "{".
            let shifted = payload.modifierFlags.contains(.shift)
            // 讀音反查依分號鍵位辨識，不看 Shift 後的冒號字元。
            if shifted, payload.keyCode == 41 { // kVK_ANSI_Semicolon
                return .toggleReadingLookup
            }
            switch payload.charactersIgnoringModifiers?.first {
            case "[":
                return shifted ? .ctrlShiftLeftBracket : .ctrlLeftBracket
            case "]":
                return shifted ? .ctrlShiftRightBracket : .ctrlRightBracket
            case "{":
                return .ctrlShiftLeftBracket
            case "}":
                return .ctrlShiftRightBracket
            // 按著 Ctrl 時宿主有時回報沒套用 Shift 的鍵面字元（`Ctrl+Shift+1` 報 `1`），
            // 與方括號同樣兩種回報都認。
            case let ch? where shifted && Self.ctrlShiftedBaseKeys[ch] != nil:
                return Self.ctrlShiftedBaseKeys[ch].map(KeyInput.ctrlFullwidth)
            // 角引號之外的全形標點走一張表，鍵面字元就是表的鍵。
            case let ch? where Self.ctrlFullwidthKeys.contains(ch):
                return .ctrlFullwidth(ch)
            default:
                // Ctrl+A / E / K / U / C and friends belong to the client.
                return nil
            }
        }

        if payload.modifierFlags.contains(.option) {
            // Only printable symbols and digits are literals. Option+Delete, Option+Return
            // and Option+arrows are editing commands and must reach the client.
            if let ch = payload.charactersIgnoringModifiers?.first,
               Self.isPrintableASCII(ch),
               ch != " ",
               !AutoSpacer.isASCIILetter(ch) {
                return .optionLiteral(ch)
            }
            return nil
        }

        if readingLookupActive {
            return Self.readingLookupKey(payload)
        }

        if payload.modifierFlags.contains(.shift),
           let rank = Self.shiftDigitKeyCodes[payload.keyCode],
           acceptsEnglishSelection() {
            return .selectEnglishPrediction(rank)
        }

        if payload.modifierFlags.contains(.shift), [48, 36, 76, 125, 126].contains(payload.keyCode) {
            // Back-tab, modified Return and selection arrows belong to the editor.
            return nil
        }

        if payload.modifierFlags.contains(.shift), payload.keyCode == 49 {
            // 打完 `Hello!` 手還沒放開 Shift 就按空白：當成一般空白，不對調寬度。
            return shiftHeldSinceShiftedKey ? .space : .shiftSpace
        }

        switch payload.keyCode {
        case 49: // kVK_Space
            return .space
        case 48: // kVK_Tab
            return .tab
        case 36, 76: // kVK_Return, kVK_ANSI_KeypadEnter
            return .enter
        case 51: // kVK_Delete (Backspace)
            return .backspace
        case 53: // kVK_Escape
            return .escape
        case 125: // kVK_DownArrow
            return .arrowDown
        case 126: // kVK_UpArrow
            return .arrowUp
        default:
            break
        }

        guard let chars = payload.characters, chars.count == 1, let ch = chars.first else {
            return nil
        }
        // Arrows, function keys, Home/End and forward delete arrive as private-use or control
        // characters and are left to the client.
        guard Self.isPrintableASCII(ch) else {
            return nil
        }
        if payload.modifierFlags.contains(.capsLock), AutoSpacer.isASCIILetter(ch) {
            // Caps Lock 亮燈時系統回報大寫字母。半形層要小寫，按住 Shift 才出大寫。
            let letter = String(ch)
            let cased = payload.modifierFlags.contains(.shift) ? letter.uppercased() : letter.lowercased()
            return .character(Character(cased))
        }
        return .character(ch)
    }
}

enum TranslatedEvent: Equatable {
    case key(KeyInput)
    /// Option+Shift+H：切換「使用半形標點符號」。這是偏好設定，不經過引擎的按鍵入口。
    case toggleHalfwidthPunctuation
}
