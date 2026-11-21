import Foundation

public struct PunctuationResult: Sendable, Equatable {
    public let text: String
    public let shouldCollapsePendingAutoSpace: Bool

    public init(text: String, shouldCollapsePendingAutoSpace: Bool) {
        self.text = text
        self.shouldCollapsePendingAutoSpace = shouldCollapsePendingAutoSpace
    }
}

/// 片段對標點語境透明時，用這個取代文件尾端的語境字元。
public enum PunctuationContextOverride: Sendable, Equatable {
    case character(Character)
    /// 開啟片段時前面沒有字或前文未知，也就是語境字元為「無」。
    case unknown

    var value: Character? {
        if case .character(let ch) = self { return ch }
        return nil
    }
}

/// 這次標點要用哪個寬度。`automatic` 照語境判，另兩個由半形標點設定、Option 單次半形
/// 或 Shift+空白 對調明確指定。
public enum PunctuationWidth: Sendable, Equatable {
    case automatic
    case halfwidth
    case fullwidth
}

public enum PunctuationMapper {
    /// 中文語境的輸出。直引號不在表內，任何語境都維持半形。
    private static let fullwidthMap: [Character: String] = [
        ",": "，",
        ".": "。",
        "!": "！",
        "?": "？",
        ";": "；",
        ":": "：",
        "(": "（",
        ")": "）",
        "[": "「",
        "]": "」",
        "{": "『",
        "}": "』",
        "\\": "、"
    ]

    private static let asciiPunctuationKeys: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "\"", "'", "(", ")", "[", "]", "\\",
        "/", "-", "_", "@", "#", "$", "%", "^", "&", "*", "+", "=", "<", ">", "~", "`", "|", "{", "}"
    ]

    public static func isPunctuationKey(_ ch: Character) -> Bool {
        asciiPunctuationKeys.contains(ch)
    }

    /// 這個鍵面字元的全形寫法，沒有就回 nil。有全形寫法的鍵才能用 Shift+空白 對調寬度。
    public static func fullwidthForm(for ch: Character) -> String? {
        fullwidthMap[ch]
    }

    /// 這個鍵面字元會不會收合英文後自動補上的那一格空格。只看鍵，不看送出的寬度：
    /// 收尾標點（`, . ! ? ; : ) ] } %`）不論出半形或全形都收合，開啟的括號與引號都不收合。
    public static func collapsesPendingAutoSpace(_ ch: Character) -> Bool {
        AutoSpacer.spaceCollapsingPunctuation.contains(ch)
    }

    /// `width` 指定寬度時一律照它輸出（半形標點設定、Option 單次半形或 Shift+空白 對調），
    /// 沒有全形寫法的鍵一律是鍵面字元。收尾標點不論出哪個寬度，都會收合英文後自動補上的那一格空格。
    /// `contextOverride` 不是 nil 時，判斷寬度的語境字元改用它，不看文件尾端那一個；
    /// 括號配對仍看文件，所以成對的括號寬度不受影響。
    public static func map(
        character ch: Character,
        documentText: String,
        pendingAutoSpace: Bool,
        width: PunctuationWidth,
        contextOverride: PunctuationContextOverride? = nil
    ) -> PunctuationResult {
        let hasPendingSpace = pendingAutoSpace && documentText.hasSuffix(" ")
        let effectivePrev = contextOverride.map(\.value)
            ?? (hasPendingSpace ? documentText.dropLast().last : documentText.last)
        let collapses = hasPendingSpace && collapsesPendingAutoSpace(ch)
        let halfwidth = PunctuationResult(text: String(ch), shouldCollapsePendingAutoSpace: collapses)

        guard width != .halfwidth, let full = fullwidthMap[ch] else {
            return halfwidth
        }

        let fullwidth = PunctuationResult(text: full, shouldCollapsePendingAutoSpace: collapses)
        if width == .fullwidth {
            return fullwidth
        }

        // 右括號沿用尚未關閉的左括號寬度，`fn() {}` 與「引言」才會成對。
        if let opener = halfwidthOpeners[ch],
           let opensFullwidth = unmatchedOpenerIsFullwidth(in: documentText, halfOpener: opener, halfCloser: ch) {
            return opensFullwidth ? fullwidth : halfwidth
        }

        if ch == "." {
            guard let prev = effectivePrev else {
                // 行首、空白後或前文未知時輸出半形，`.gitignore`、`./build.sh`、`cd ..` 才不會被改寫。
                // 片段透明時的「無」是中文語境，所以出全形。
                return contextOverride == nil ? halfwidth : fullwidth
            }
            guard AutoSpacer.isChinese(prev) || AutoSpacer.isFullwidthPunctuation(prev) else {
                return halfwidth
            }
            return fullwidth
        }

        // 其他標點略過同一行的空格找語境字元，`fn() {` 的大括號仍在英數語境。
        let context = contextOverride == nil ? documentText.last(where: { $0 != " " }) : effectivePrev
        if let context,
           AutoSpacer.isASCIILetter(context) || AutoSpacer.isASCIIDigit(context) || AutoSpacer.closingASCIIPunctuation.contains(context) {
            return halfwidth
        }
        return fullwidth
    }

    private static let halfwidthOpeners: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    private static func unmatchedOpenerIsFullwidth(in text: String, halfOpener: Character, halfCloser: Character) -> Bool? {
        guard let fullOpener = fullwidthMap[halfOpener]?.first, let fullCloser = fullwidthMap[halfCloser]?.first else {
            return nil
        }
        var depth = 0
        for ch in text.reversed() {
            if ch == halfCloser || ch == fullCloser {
                depth += 1
            } else if ch == halfOpener || ch == fullOpener {
                if depth == 0 { return ch == fullOpener }
                depth -= 1
            }
        }
        return nil
    }
}
