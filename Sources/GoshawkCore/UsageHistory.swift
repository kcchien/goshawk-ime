import Foundation

/// 使用者的輸入習慣。只記詞庫或碼表裡的詞、字與次數，不記原始按鍵或文件內容。
/// 四類紀錄各自獨立：英文預測、倉頡重碼順序、讀音反查順序，以及符號面板最近選過的符號。
/// 前三類是候選學習，各有開關；最近使用的符號不重排任何候選，沒有開關。
public struct UsageHistory: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public let word: String
        public var count: Int
    }

    /// 一個字與使用者選它的次數。倉頡重碼與讀音反查共用這個形狀。
    public struct CharacterCount: Sendable, Hashable, Codable {
        public let character: String
        public var count: Int

        public init(character: String, count: Int) {
            self.character = character
            self.count = count
        }
    }

    /// 一個倉頡碼下使用者送出過的字。`choices` 依最近送出排序，最新的在最前面。
    public struct CangjieEntry: Sendable, Hashable, Codable {
        public let code: String
        public var choices: [CharacterCount]

        public init(code: String, choices: [CharacterCount]) {
            self.code = code
            self.choices = choices
        }
    }

    /// 超過上限時丟掉最久沒採用的詞。
    public static let capacity = 512
    /// 倉頡重碼紀錄的碼數上限。超過時丟掉最久沒用到的碼。
    public static let cangjieCapacity = 512
    /// 讀音反查紀錄的字數上限。超過時丟掉最久沒選的字。
    public static let readingCapacity = 512
    /// 最近使用的符號上限，也就是符號面板「最近使用」分頁的兩頁。
    public static let symbolCapacity = 18

    /// 至少要被送出這麼多次，一個字才會越過碼表排在它前面的字。手滑一次不改順序。
    public static let cangjiePromotionThreshold = 2

    /// 依最近採用排序，最新的在最前面。`word` 一律小寫。
    public private(set) var english: [Entry] = []
    /// 依最近用到排序，最新的碼在最前面。
    public private(set) var cangjie: [CangjieEntry] = []
    /// 讀音反查選過的字，依最近選取排序，最新的在最前面。
    public private(set) var reading: [CharacterCount] = []
    /// 符號面板選過的符號，最近選的在最前面，同一個符號只留一份。
    public private(set) var symbols: [String] = []

    /// `recentSymbols` 依最近使用排序，最近的在最前面。
    public init(
        englishWords: [String] = [],
        cangjieChoices: [(code: String, character: String)] = [],
        readingChoices: [String] = [],
        recentSymbols: [String] = []
    ) {
        for symbol in recentSymbols.reversed() {
            recordSymbol(symbol)
        }
        for word in englishWords.reversed() {
            recordEnglish(word)
        }
        for choice in cangjieChoices {
            recordCangjie(code: choice.code, character: choice.character)
        }
        for character in readingChoices {
            recordReading(character)
        }
    }

    /// 舊版存檔只有英文紀錄，缺的欄位視為空。
    private enum CodingKeys: String, CodingKey {
        case english
        case cangjie
        case reading
        case symbols
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        english = try container.decodeIfPresent([Entry].self, forKey: .english) ?? []
        cangjie = try container.decodeIfPresent([CangjieEntry].self, forKey: .cangjie) ?? []
        reading = try container.decodeIfPresent([CharacterCount].self, forKey: .reading) ?? []
        // 存檔可能被手動改過：照記錄的規則重放，重複、空字串與超過上限的都在這裡收掉。
        for symbol in (try container.decodeIfPresent([String].self, forKey: .symbols) ?? []).reversed() {
            recordSymbol(symbol)
        }
    }

    public var isEmpty: Bool { english.isEmpty && cangjie.isEmpty && reading.isEmpty && symbols.isEmpty }

    /// 讀回先前不可用的存檔後，接上這段時間的學習，保留最近使用順序與各類上限。
    package mutating func recordSession(_ recent: UsageHistory) {
        for word in recent.english.reversed() {
            recordEnglish(word.word, count: word.count)
        }
        for entry in recent.cangjie.reversed() {
            for choice in entry.choices.reversed() {
                recordCangjie(code: entry.code, character: choice.character, count: choice.count)
            }
        }
        for choice in recent.reading.reversed() {
            recordReading(choice.character, count: choice.count)
        }
        for symbol in recent.symbols.reversed() {
            recordSymbol(symbol)
        }
    }

    private static func total(_ previous: Int, adding count: Int) -> Int {
        let (sum, overflow) = max(0, previous).addingReportingOverflow(count)
        return overflow ? Int.max : sum
    }

    public mutating func recordEnglish(_ word: String) {
        recordEnglish(word, count: 1)
    }

    private mutating func recordEnglish(_ word: String, count: Int) {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return }
        var entry = Entry(word: lower, count: count)
        if let index = english.firstIndex(where: { $0.word == lower }) {
            entry.count = Self.total(english.remove(at: index).count, adding: count)
        }
        english.insert(entry, at: 0)
        if english.count > Self.capacity {
            english.removeLast(english.count - Self.capacity)
        }
    }

    /// 記下使用者在 `code` 這個碼下送出了 `character`。呼叫端負責只在重碼時呼叫。
    public mutating func recordCangjie(code: String, character: String) {
        recordCangjie(code: code, character: character, count: 1)
    }

    private mutating func recordCangjie(code: String, character: String, count: Int) {
        guard !code.isEmpty, !character.isEmpty else { return }
        var entry = CangjieEntry(code: code, choices: [])
        if let index = cangjie.firstIndex(where: { $0.code == code }) {
            entry.choices = cangjie.remove(at: index).choices
        }
        entry.choices = Self.bumped(entry.choices, character: character, count: count)
        cangjie.insert(entry, at: 0)
        if cangjie.count > Self.cangjieCapacity {
            cangjie.removeLast(cangjie.count - Self.cangjieCapacity)
        }
    }

    /// 記下使用者在讀音反查選了 `character`。跨讀音共用，不分是哪一個讀音選的。
    public mutating func recordReading(_ character: String) {
        recordReading(character, count: 1)
    }

    private mutating func recordReading(_ character: String, count: Int) {
        guard !character.isEmpty else { return }
        reading = Self.bumped(reading, character: character, count: count)
        if reading.count > Self.readingCapacity {
            reading.removeLast(reading.count - Self.readingCapacity)
        }
    }

    /// 記下使用者在符號面板選了 `symbol`。只記順序，不記次數。
    public mutating func recordSymbol(_ symbol: String) {
        guard !symbol.isEmpty else { return }
        symbols.removeAll { $0 == symbol }
        symbols.insert(symbol, at: 0)
        if symbols.count > Self.symbolCapacity {
            symbols.removeLast(symbols.count - Self.symbolCapacity)
        }
    }

    private static func bumped(_ counts: [CharacterCount], character: String, count: Int) -> [CharacterCount] {
        var result = counts
        var entry = CharacterCount(character: character, count: count)
        if let index = result.firstIndex(where: { $0.character == character }) {
            entry.count = Self.total(result.remove(at: index).count, adding: count)
        }
        result.insert(entry, at: 0)
        return result
    }

    /// 依學習紀錄重排一個碼的倉頡候選。只重排，不增減。
    /// 送出次數到達門檻的字在前，次數相同時維持碼表順序；沒到門檻的字等同沒紀錄。
    func orderedCangjieCandidates(_ candidates: [String], code: String) -> [String] {
        guard let entry = cangjie.first(where: { $0.code == code }), candidates.count > 1 else {
            return candidates
        }
        func weight(_ character: String) -> Int {
            guard let choice = entry.choices.first(where: { $0.character == character }),
                  choice.count >= Self.cangjiePromotionThreshold else {
                return 0
            }
            return choice.count
        }
        return candidates.enumerated()
            .sorted { lhs, rhs in
                let left = weight(lhs.element)
                let right = weight(rhs.element)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 依學習紀錄重排讀音反查的候選。選過的字在最前面，次數多的在前，
    /// 次數相同時最近選的在前，其餘維持資料順序。只重排，不增減。
    func orderedByReadingChoices<Item>(_ items: [Item], character: (Item) -> String) -> [Item] {
        guard !reading.isEmpty, items.count > 1 else {
            return items
        }
        // 同一個讀音可有數百個候選，只查一次每個字的採用次數和最近順序。
        var ranks: [String: (count: Int, recency: Int)] = [:]
        for (index, entry) in reading.enumerated() where ranks[entry.character] == nil {
            ranks[entry.character] = (entry.count, index)
        }
        return items.enumerated()
            .map { (index, item) in
                (item: item, index: index, rank: ranks[character(item)] ?? (count: 0, recency: Int.max))
            }
            .sorted { lhs, rhs in
                if lhs.rank.count != rhs.rank.count {
                    return lhs.rank.count > rhs.rank.count
                }
                if lhs.rank.recency != rhs.rank.recency {
                    return lhs.rank.recency < rhs.rank.recency
                }
                return lhs.index < rhs.index
            }
            .map(\.item)
    }

    /// 以 `lowerPrefix` 開頭的已採用詞。次數多的在前，同次數時最近採用的在前。
    func adoptedEnglishWords(matching lowerPrefix: String) -> [String] {
        english.enumerated()
            .filter { $0.element.word.hasPrefix(lowerPrefix) }
            .sorted { lhs, rhs in
                lhs.element.count != rhs.element.count
                    ? lhs.element.count > rhs.element.count
                    : lhs.offset < rhs.offset
            }
            .map(\.element.word)
    }
}
