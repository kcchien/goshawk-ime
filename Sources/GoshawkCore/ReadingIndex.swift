import Foundation

/// 聲調。輕聲排在四聲之後。
public enum Tone: Int, Sendable, Hashable, CaseIterable, Codable {
    case first = 1
    case second
    case third
    case fourth
    case neutral

    /// 注音調號。一聲不加調號。
    public var bopomofoMark: String {
        switch self {
        case .first:
            return ""
        case .second:
            return "ˊ"
        case .third:
            return "ˇ"
        case .fourth:
            return "ˋ"
        case .neutral:
            return "˙"
        }
    }

    /// 拼音調號數字。一聲顯示 `1`。
    public var pinyinDigit: String { String(rawValue) }
}

/// 讀音輸入的鍵盤方案。
public enum PhoneticScheme: String, Sendable, Hashable, CaseIterable, Codable {
    case dachen
    case pinyin
}

/// 一次查詢。`bopomofo` 是去調注音，兩種鍵盤都會正規化成它。`tone` 為 nil 表示不指定聲調。
public struct ReadingQuery: Sendable, Hashable, Codable {
    public let bopomofo: String
    public let tone: Tone?

    public init(bopomofo: String, tone: Tone?) {
        self.bopomofo = bopomofo
        self.tone = tone
    }
}

/// 索引對使用者已打鍵序的解讀。面板依此決定顯示候選、維持等待或顯示查無此讀音。
public enum ReadingInput: Sendable, Hashable {
    case empty
    /// 還不是完整音節，但是某個收錄音節的開頭。
    case partial
    case syllable(ReadingQuery)
    /// 不是任何收錄音節的開頭。
    case unknown
}

/// 一個候選字與它在指定代別的原生拆碼。`nativeCodes` 為空代表本代未收錄。
public struct ReadingCandidate: Sendable, Hashable, Codable {
    public let character: String
    public let nativeCodes: [String]

    public init(character: String, nativeCodes: [String]) {
        self.character = character
        self.nativeCodes = nativeCodes
    }
}

/// 單字讀音反查索引。純值型別，資料與排序隨程式打包，查詢全程離線。
public struct ReadingIndex: Sendable {
    /// 大千鍵位，抄自 bpmf.cin 的 `%keyname`，不含調號鍵。
    public static let dachenKeyMap: [Character: Character] = [
        "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
        "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
        "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
        "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
        "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
        "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
        "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
        "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
        "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
        "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ",
        "-": "ㄦ"
    ]

    /// 大千聲調鍵。空白鍵指定一聲。
    public static let dachenToneKeys: [Character: Tone] = [
        " ": .first, "6": .second, "3": .third, "4": .fourth, "7": .neutral
    ]

    private static let toneByMark: [Character: Tone] = [
        "ˊ": .second, "ˇ": .third, "ˋ": .fourth, "˙": .neutral
    ]

    private static let bopomofoSymbols: Set<Character> = Set(dachenKeyMap.values)

    private static let dachenKeyBySymbol: [Character: Character] = Dictionary(
        uniqueKeysWithValues: dachenKeyMap.map { ($0.value, $0.key) }
    )

    private static let dachenKeyByTone: [Tone: Character] = Dictionary(
        uniqueKeysWithValues: dachenToneKeys.map { ($0.value, $0.key) }
    )

    /// 面板上的一聲調號。注音的一聲本來不加調號，顯示時與「不指定聲調」同形，
    /// 所以使用者按過空白鍵時補一個 `ˉ`，讓他看得出已經指定一聲。
    private static let firstToneDisplayMark = "ˉ"

    public static let shared: ReadingIndex = loadBundled()

    private struct NativeCodes: Sendable {
        let v5: [String]
        let v3: [String]
    }

    /// 讀音表裡聲調欄的這個值代表「不指定聲調時的候選順序」。
    private static let tonelessRowMarker = 0

    private let rows: [ReadingQuery: [String]]
    /// 去調注音到不指定聲調時的候選順序。順序在建置時跨聲調排好，執行期不排序。
    private let tonelessRows: [String: [String]]
    private let pinyinByBopomofo: [String: String]
    private let bopomofoByPinyin: [String: String]
    private let bopomofoPrefixes: Set<String>
    private let pinyinPrefixes: Set<String>
    private let nativeCodeTable: [String: NativeCodes]

    /// 收錄的去調音節數。
    public var syllableCount: Int { pinyinByBopomofo.count }
    /// 收錄的帶調音節列數。
    public var tonedSyllableCount: Int { rows.count }
    /// 可查到的字數，依字去重。
    public var characterCount: Int { Set(rows.values.joined()).count }

    /// 全部帶調音節，供全表往返測試列舉。順序固定為注音碼序再聲調。
    var tonedQueries: [ReadingQuery] {
        rows.keys.sorted {
            ($0.bopomofo, $0.tone?.rawValue ?? 0) < ($1.bopomofo, $1.tone?.rawValue ?? 0)
        }
    }

    public init(readingsTSV: String, nativeCodesTSV: String) {
        var rows: [ReadingQuery: [String]] = [:]
        var tonelessRows: [String: [String]] = [:]
        var pinyinByBopomofo: [String: String] = [:]
        var bopomofoByPinyin: [String: String] = [:]
        var bopomofoPrefixes = Set<String>()
        var pinyinPrefixes = Set<String>()

        for line in readingsTSV.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4, let toneValue = Int(fields[2]) else { continue }
            let tone = Tone(rawValue: toneValue)
            guard tone != nil || toneValue == Self.tonelessRowMarker else { continue }
            let bopomofo = String(fields[0])
            let pinyin = String(fields[1])
            guard !bopomofo.isEmpty, !pinyin.isEmpty, !fields[3].isEmpty else { continue }

            var characters: [String] = []
            var seen = Set<String>()
            for char in fields[3] where seen.insert(String(char)).inserted {
                characters.append(String(char))
            }
            guard let tone else {
                // 這一列只決定順序，音節與拼音由帶調的列登記。
                tonelessRows[bopomofo] = characters
                continue
            }
            rows[ReadingQuery(bopomofo: bopomofo, tone: tone)] = characters

            pinyinByBopomofo[bopomofo] = pinyin
            bopomofoByPinyin[pinyin] = bopomofo
            for length in 1...bopomofo.count {
                bopomofoPrefixes.insert(String(bopomofo.prefix(length)))
            }
            for length in 1...pinyin.count {
                pinyinPrefixes.insert(String(pinyin.prefix(length)))
            }
        }

        var nativeCodeTable: [String: NativeCodes] = [:]
        for line in nativeCodesTSV.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty else { continue }
            nativeCodeTable[String(fields[0])] = NativeCodes(
                v5: Self.parseCodeList(fields[1]),
                v3: Self.parseCodeList(fields[2])
            )
        }

        self.rows = rows
        self.tonelessRows = tonelessRows
        self.pinyinByBopomofo = pinyinByBopomofo
        self.bopomofoByPinyin = bopomofoByPinyin
        self.bopomofoPrefixes = bopomofoPrefixes
        self.pinyinPrefixes = pinyinPrefixes
        self.nativeCodeTable = nativeCodeTable
    }

    /// 解讀使用者在指定鍵盤打下的原始鍵序。
    public func interpret(_ keys: String, scheme: PhoneticScheme) -> ReadingInput {
        guard !keys.isEmpty else { return .empty }
        switch scheme {
        case .dachen:
            return interpretDachen(keys)
        case .pinyin:
            return interpretPinyin(keys)
        }
    }

    /// 查這個讀音的候選字。不指定聲調時是各聲調候選依字去重的聯集，順序照讀音表為這個
    /// 音節排好的那一列：各聲調的常用字一起排在前面。讀音表沒有那一列的音節（只有一個
    /// 聲調，或手寫的小表）依一、二、三、四、輕聲串接。
    public func characters(for query: ReadingQuery) -> [String] {
        if query.tone != nil {
            return rows[query] ?? []
        }
        if let ordered = tonelessRows[query.bopomofo] {
            return ordered
        }
        var merged: [String] = []
        var seen = Set<String>()
        for tone in Tone.allCases {
            let key = ReadingQuery(bopomofo: query.bopomofo, tone: tone)
            for character in rows[key] ?? [] where seen.insert(character).inserted {
                merged.append(character)
            }
        }
        return merged
    }

    /// 查候選字並附上該代別的原生拆碼。
    public func candidates(for query: ReadingQuery, version: CangjieVersion) -> [ReadingCandidate] {
        characters(for: query).map { character in
            ReadingCandidate(
                character: character,
                nativeCodes: nativeCodes(for: character, version: version)
            )
        }
    }

    /// 單一字在指定代別的原生拆碼，依來源順序。空陣列代表本代未收錄。
    public func nativeCodes(for character: String, version: CangjieVersion) -> [String] {
        guard let codes = nativeCodeTable[character] else { return [] }
        switch version {
        case .v5:
            return codes.v5
        case .v3:
            return codes.v3
        }
    }

    /// 以指定方案顯示同一讀音與聲調。不指定聲調時不顯示調號或數字。
    public func display(_ query: ReadingQuery, scheme: PhoneticScheme) -> String {
        switch scheme {
        case .dachen:
            return query.bopomofo + (query.tone?.bopomofoMark ?? "")
        case .pinyin:
            let base = pinyinByBopomofo[query.bopomofo] ?? query.bopomofo
            return base + (query.tone?.pinyinDigit ?? "")
        }
    }

    /// 同一讀音與聲調在另一個方案要打的鍵序。切換方案時用它改寫面板上已打的鍵。
    /// 大千的一聲是結尾空白，拼音的一聲是 `1`；不指定聲調時不加聲調鍵。
    public func keys(for query: ReadingQuery, scheme: PhoneticScheme) -> String {
        switch scheme {
        case .dachen:
            var keys = ""
            for symbol in query.bopomofo {
                keys.append(Self.dachenKeyBySymbol[symbol] ?? symbol)
            }
            if let tone = query.tone, let toneKey = Self.dachenKeyByTone[tone] {
                keys.append(toneKey)
            }
            return keys
        case .pinyin:
            let base = pinyinByBopomofo[query.bopomofo] ?? query.bopomofo
            // 鍵盤上沒有 ü，資料裡的 ü 要寫回使用者實際按的 `v`。
            return base.replacingOccurrences(of: "ü", with: "v") + (query.tone?.pinyinDigit ?? "")
        }
    }

    /// 面板上方要顯示的讀音。大千把每個已打的鍵換成注音符號與調號，拼音直接顯示鍵序。
    /// 尚未成音或查無此讀音時也照樣逐鍵顯示，使用者才看得出自己打了什麼。
    public static func displayKeys(_ keys: String, scheme: PhoneticScheme) -> String {
        guard scheme == .dachen else { return keys }
        var body = Array(keys)
        var toneMark = ""
        if body.count > 1, let last = body.last, let tone = dachenToneKeys[last] {
            toneMark = tone == .first ? firstToneDisplayMark : tone.bopomofoMark
            body.removeLast()
        }
        var display = ""
        for key in body {
            if bopomofoSymbols.contains(key) {
                display.append(key)
            } else if let lower = key.lowercased().first, let symbol = dachenKeyMap[lower] {
                display.append(symbol)
            } else {
                display.append(key)
            }
        }
        return display + toneMark
    }

    private func interpretDachen(_ keys: String) -> ReadingInput {
        var body = Array(keys)
        var tone: Tone?
        if body.count > 1, let last = body.last {
            if let keyTone = Self.dachenToneKeys[last] {
                tone = keyTone
                body.removeLast()
            } else if let markTone = Self.toneByMark[last] {
                tone = markTone
                body.removeLast()
            }
        }

        var bopomofo = ""
        for key in body {
            if Self.bopomofoSymbols.contains(key) {
                bopomofo.append(key)
            } else if let lower = key.lowercased().first, let symbol = Self.dachenKeyMap[lower] {
                bopomofo.append(symbol)
            } else {
                return .unknown
            }
        }
        return classify(bopomofo: bopomofo, tone: tone)
    }

    private func interpretPinyin(_ keys: String) -> ReadingInput {
        var body = Array(keys.lowercased())
        var tone: Tone?
        if body.count > 1,
           let last = body.last,
           let digit = last.wholeNumberValue,
           let parsed = Tone(rawValue: digit) {
            tone = parsed
            body.removeLast()
        }

        // `v` 是 ü 的鍵盤替代寫法，正規化後才查表。
        let pinyin = String(body).replacingOccurrences(of: "v", with: "ü")
        if let bopomofo = bopomofoByPinyin[pinyin] {
            return .syllable(ReadingQuery(bopomofo: bopomofo, tone: tone))
        }
        return pinyinPrefixes.contains(pinyin) ? .partial : .unknown
    }

    private func classify(bopomofo: String, tone: Tone?) -> ReadingInput {
        guard !bopomofo.isEmpty else { return .unknown }
        if pinyinByBopomofo[bopomofo] != nil {
            return .syllable(ReadingQuery(bopomofo: bopomofo, tone: tone))
        }
        return bopomofoPrefixes.contains(bopomofo) ? .partial : .unknown
    }

    private static func parseCodeList(_ field: Substring) -> [String] {
        field.split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }
            .filter(CangjieDictionary.isValidCangjieCodeShape)
    }

    private static func loadBundled() -> ReadingIndex {
        func text(_ name: String) -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: "tsv"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
            return contents
        }
        return ReadingIndex(
            readingsTSV: text("readings"),
            nativeCodesTSV: text("cangjie_native")
        )
    }
}
