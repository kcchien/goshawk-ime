import Foundation

/// 使用者的輸入習慣。只記詞庫或碼表裡的詞、字與次數，不記原始按鍵或文件內容。
/// 三類紀錄各自獨立：英文預測、倉頡重碼順序、讀音反查順序。
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

    /// 至少要被送出這麼多次，一個字才會越過碼表排在它前面的字。手滑一次不改順序。
    public static let cangjiePromotionThreshold = 2

    /// 依最近採用排序，最新的在最前面。`word` 一律小寫。
    public private(set) var english: [Entry] = []
    /// 依最近用到排序，最新的碼在最前面。
    public private(set) var cangjie: [CangjieEntry] = []
    /// 讀音反查選過的字，依最近選取排序，最新的在最前面。
    public private(set) var reading: [CharacterCount] = []

    public init(
        englishWords: [String] = [],
        cangjieChoices: [(code: String, character: String)] = [],
        readingChoices: [String] = []
    ) {
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
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        english = try container.decodeIfPresent([Entry].self, forKey: .english) ?? []
        cangjie = try container.decodeIfPresent([CangjieEntry].self, forKey: .cangjie) ?? []
        reading = try container.decodeIfPresent([CharacterCount].self, forKey: .reading) ?? []
    }

    public var isEmpty: Bool { english.isEmpty && cangjie.isEmpty && reading.isEmpty }

    public mutating func recordEnglish(_ word: String) {
        let lower = word.lowercased()
        guard !lower.isEmpty else { return }
        var entry = Entry(word: lower, count: 1)
        if let index = english.firstIndex(where: { $0.word == lower }) {
            entry.count = english.remove(at: index).count + 1
        }
        english.insert(entry, at: 0)
        if english.count > Self.capacity {
            english.removeLast(english.count - Self.capacity)
        }
    }

    /// 記下使用者在 `code` 這個碼下送出了 `character`。呼叫端負責只在重碼時呼叫。
    public mutating func recordCangjie(code: String, character: String) {
        guard !code.isEmpty, !character.isEmpty else { return }
        var entry = CangjieEntry(code: code, choices: [])
        if let index = cangjie.firstIndex(where: { $0.code == code }) {
            entry.choices = cangjie.remove(at: index).choices
        }
        entry.choices = Self.bumped(entry.choices, character: character)
        cangjie.insert(entry, at: 0)
        if cangjie.count > Self.cangjieCapacity {
            cangjie.removeLast(cangjie.count - Self.cangjieCapacity)
        }
    }

    /// 記下使用者在讀音反查選了 `character`。跨讀音共用，不分是哪一個讀音選的。
    public mutating func recordReading(_ character: String) {
        guard !character.isEmpty else { return }
        reading = Self.bumped(reading, character: character)
        if reading.count > Self.readingCapacity {
            reading.removeLast(reading.count - Self.readingCapacity)
        }
    }

    private static func bumped(_ counts: [CharacterCount], character: String) -> [CharacterCount] {
        var result = counts
        var entry = CharacterCount(character: character, count: 1)
        if let index = result.firstIndex(where: { $0.character == character }) {
            entry.count = result.remove(at: index).count + 1
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
        /// 次數與最近程度。沒選過的字排在所有選過的字之後。
        func rank(_ item: Item) -> (count: Int, recency: Int) {
            let name = character(item)
            guard let index = reading.firstIndex(where: { $0.character == name }) else {
                return (0, Int.max)
            }
            return (reading[index].count, index)
        }
        return items.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element)
                let right = rank(rhs.element)
                if left.count != right.count {
                    return left.count > right.count
                }
                if left.recency != right.recency {
                    return left.recency < right.recency
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
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
