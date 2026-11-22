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

    /// 不是從標點鍵打出來的標點（符號面板選的）會不會收合那一格空格。
    /// 找出會打出它的那個鍵，沿用同一條只看鍵的規則：半形寫法就是鍵面字元本身，
    /// 全形寫法查是哪個鍵的全形；沒有鍵打得出來的符號不收合。
    public static func collapsesPendingAutoSpace(emitting text: String) -> Bool {
        if text.count == 1, let key = text.first, collapsesPendingAutoSpace(key) {
            return true
        }
        return fullwidthMap.contains { $0.value == text && collapsesPendingAutoSpace($0.key) }
    }

    private static let curlyOpeners: [Character: Character] = ["”": "“", "’": "‘"]

    /// 決定標點寬度的語境字元。先從尾端略過 `ignorable`（句點什麼都不略過，其他標點略過空格，
    /// 片段另外略過反引號），剩下的最後一個字元通常就是答案。
    /// 例外是結尾彎引號：中文與英文都用它收尾，本身看不出語境，所以看整個引號外面，依序是
    /// 1. 同一行找得到對應的開頭彎引號，就看開頭前面那個字（略過空格）：
    ///    `他說“AI”` 看「說」，`He said “hello”` 看 `d`。
    /// 2. 開頭在行首，或找不到開頭（`users’` 的撇號、`3”` 的吋），看引號裡最後一個字。
    /// 3. 引號裡最後是空白、換行或沒有字，就把彎引號自己當語境字元，它算全形標點。
    /// 開頭彎引號不特別處理，後面照全形標點算。成對符號的掃描與自動空格不走這裡。
    public static func contextCharacter(
        before text: Substring,
        ignoring ignorable: (Character) -> Bool
    ) -> Character? {
        var end = text.endIndex
        while end > text.startIndex, ignorable(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        let head = text[..<end]
        guard let last = head.last else { return nil }
        guard let opener = curlyOpeners[last] else { return last }

        let quoted = head.dropLast()
        if let openerIndex = curlyOpenerIndex(in: quoted, opener: opener, closer: last),
           let outer = contextCharacter(before: quoted[..<openerIndex], ignoring: { $0 == " " || ignorable($0) }),
           !outer.isNewline {
            return outer
        }
        if let inside = quoted.last(where: { curlyOpeners[$0] == nil }), !inside.isWhitespace {
            return inside
        }
        return last
    }

    /// `text` 尾端那個結尾彎引號對應的開頭，只在同一行裡找，同一種的巢狀照深度抵銷。
    private static func curlyOpenerIndex(in text: Substring, opener: Character, closer: Character) -> Substring.Index? {
        var depth = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            let ch = text[index]
            if ch.isNewline {
                return nil
            }
            if ch == closer {
                depth += 1
            } else if ch == opener {
                if depth == 0 { return index }
                depth -= 1
            }
        }
        return nil
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
        let beforeCursor = hasPendingSpace ? documentText.dropLast() : documentText[...]
        let effectivePrev = contextOverride.map(\.value)
            ?? contextCharacter(before: beforeCursor, ignoring: { _ in false })
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
        let context = contextOverride == nil
            ? contextCharacter(before: documentText[...], ignoring: { $0 == " " })
            : effectivePrev
        if let context,
           AutoSpacer.isASCIILetter(context) || AutoSpacer.isASCIIDigit(context) || AutoSpacer.closingASCIIPunctuation.contains(context) {
            return halfwidth
        }
        return fullwidth
    }

    /// 右方括號不在這裡：它跟隨的是八種成對符號裡未關閉的那一個，由 `unclosedPairOpener` 判。
    private static let halfwidthOpeners: [Character: Character] = [")": "(", "}": "{"]

    /// 游標前最近一個還沒關上的成對符號開頭，以及它在 `text` 裡的位置。
    /// 從尾端往回掃，八種各自計深度，所以內容裡別種符號的落單結尾不會抵銷這個開頭。
    /// `stopAtBacktick` 用在片段裡：片段外的開頭不該由片段裡的結尾去關。
    /// 不在換行處停，跨行的引言照樣關得起來。
    public static func unclosedPairOpener(
        in text: String,
        stopAtBacktick: Bool
    ) -> (style: PairStyle, index: String.Index)? {
        var depth: [PairStyle: Int] = [:]
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            let ch = text[index]
            if stopAtBacktick, ch == "`" {
                return nil
            }
            if let style = PairStyle.style(closing: ch) {
                depth[style, default: 0] += 1
            } else if let style = PairStyle.style(opening: ch) {
                let open = depth[style, default: 0]
                if open == 0 {
                    return (style, index)
                }
                depth[style] = open - 1
            }
        }
        return nil
    }

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
