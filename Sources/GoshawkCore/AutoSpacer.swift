import Foundation

public enum OutgoingTokenKind: Sendable {
    case chinese
    case englishOrNumber
    case punctuation
    case space
}

public enum AutoSpacer {
    public static let prefixOrOpeningSymbols: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "-", "_", "/", "\\",
        "$", "@", "#", "+", "*", "&", "~", "^", "=", "|"
    ]

    public static let closingASCIIPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "%", ">"
    ]

    /// Closing punctuation that swallows the trailing space left by an English commit
    /// `>` is deliberately absent: `a > b` and `->` must keep their space.
    public static let spaceCollapsingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "%"
    ]

    public static let fullwidthPunctuation: Set<Character> = [
        "，", "。", "！", "？", "；", "：", "「", "」", "『", "』",
        "（", "）", "、", "…", "—", "《", "》", "〈", "〉", "【", "】",
        // 彎引號是中文引號的另一種寫法，後面的空格比照角引號。結尾彎引號後面的標點寬度
        // 不看這裡，看整個引號外面的字（`PunctuationMapper.contextCharacter`）。
        "“", "”", "‘", "’"
    ]

    public static func isFullwidthPunctuation(_ ch: Character) -> Bool {
        if fullwidthPunctuation.contains(ch) {
            return true
        }
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3001...0x303F, // CJK Symbols and Punctuation (U+3000 is whitespace)
             0xFE30...0xFE4F, // CJK Compatibility Forms
             0xFF01...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65:
            return true
        default:
            return false
        }
    }

    public static func leadingSpace(
        before contextChar: Character?,
        for outgoing: OutgoingTokenKind,
        enabled: Bool
    ) -> String {
        guard enabled, let prev = contextChar else {
            return ""
        }
        if isWhitespace(prev) || isFullwidthPunctuation(prev) || prefixOrOpeningSymbols.contains(prev) {
            return ""
        }

        switch outgoing {
        case .englishOrNumber:
            return isChinese(prev) ? " " : ""
        case .chinese:
            if isASCIILetter(prev) || isASCIIDigit(prev) || closingASCIIPunctuation.contains(prev) {
                return " "
            }
            return ""
        case .punctuation, .space:
            return ""
        }
    }

    public static func isChinese(_ ch: Character) -> Bool {
        // Judge by the base scalar so a Han character followed by a variation selector
        // still counts as Chinese.
        guard let scalar = ch.unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x323AF, // Extensions B through H; the Cangjie tables reach past B
             0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    public static func isASCIILetter(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (65...90).contains(ascii) || (97...122).contains(ascii)
    }

    public static func isASCIIDigit(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (48...57).contains(ascii)
    }

    public static func isWhitespace(_ ch: Character) -> Bool {
        // Character.isWhitespace also covers "\r\n" (one grapheme) and no-break spaces.
        ch.isWhitespace
    }
}
