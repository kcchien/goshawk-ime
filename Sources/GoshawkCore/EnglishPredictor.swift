import Foundation

public struct EnglishEntry: Sendable, Hashable {
    public let word: String
    public let frequency: Int
    public let isDeveloperTerm: Bool

    public init(word: String, frequency: Int, isDeveloperTerm: Bool = false) {
        self.word = word
        self.frequency = frequency
        self.isDeveloperTerm = isDeveloperTerm
    }
}

public struct EnglishPredictor: Sendable {
    public static let shared: EnglishPredictor = loadBundled()

    private struct IndexedEntry: Sendable {
        let lower: String
        let entry: EnglishEntry
    }

    private let sortedByLower: [IndexedEntry]
    private let exactWordsLowercased: [String: EnglishEntry]
    private let prefix1Buckets: [Character: [IndexedEntry]]
    private let prefix2Buckets: [String: [IndexedEntry]]

    public var wordCount: Int { sortedByLower.count }

    public init(entries: [EnglishEntry] = EnglishPredictor.seedEntries) {
        let sortedByFreq = entries.sorted { lhs, rhs in
            if lhs.frequency != rhs.frequency {
                return lhs.frequency > rhs.frequency
            }
            if lhs.word.count != rhs.word.count {
                return lhs.word.count < rhs.word.count
            }
            return lhs.word.lowercased() < rhs.word.lowercased()
        }

        var exactMap: [String: EnglishEntry] = [:]
        exactMap.reserveCapacity(sortedByFreq.count)
        var deduped: [IndexedEntry] = []
        deduped.reserveCapacity(sortedByFreq.count)

        var buckets1: [Character: [IndexedEntry]] = [:]
        var buckets2: [String: [IndexedEntry]] = [:]

        for entry in sortedByFreq {
            let lower = entry.word.lowercased()
            if exactMap[lower] == nil {
                exactMap[lower] = entry
                let indexed = IndexedEntry(lower: lower, entry: entry)
                deduped.append(indexed)
                if let first = lower.first {
                    buckets1[first, default: []].append(indexed)
                }
                if lower.count >= 2 {
                    buckets2[String(lower.prefix(2)), default: []].append(indexed)
                }
            }
        }

        self.exactWordsLowercased = exactMap
        self.prefix1Buckets = buckets1
        self.prefix2Buckets = buckets2
        self.sortedByLower = deduped.sorted { $0.lower < $1.lower }
    }

    public func predictions(
        for prefix: String,
        limit: Int = 5,
        includeDeveloperTerms: Bool = true,
        usage: UsageHistory = UsageHistory()
    ) -> [String] {
        guard !prefix.isEmpty, limit > 0 else {
            return []
        }

        let loweredPrefix = prefix.lowercased()

        var results: [String] = []
        var seenLowercased = Set<String>()

        // Lock an exact short word (<= 5 chars) in position 1
        // so typing `is` or `id` + Tab outputs the exact word rather than over-completing.
        if prefix.count <= 5,
           let exact = exactWordsLowercased[loweredPrefix],
           includeDeveloperTerms || !exact.isDeveloperTerm {
            results.append(formatWord(exact.word, typed: prefix))
            seenLowercased.insert(loweredPrefix)
            if results.count >= limit {
                return results
            }
        }

        // 採用過的詞排在詞頻順序之前，但不越過上面鎖定的短詞。
        if !usage.english.isEmpty {
            for lower in usage.adoptedEnglishWords(matching: loweredPrefix) {
                guard let entry = exactWordsLowercased[lower],
                      includeDeveloperTerms || !entry.isDeveloperTerm,
                      seenLowercased.insert(lower).inserted else { continue }
                results.append(formatWord(entry.word, typed: prefix))
                if results.count >= limit {
                    return results
                }
            }
        }

        if loweredPrefix.count == 1, let first = loweredPrefix.first {
            let bucket = prefix1Buckets[first] ?? []
            for item in bucket {
                if !includeDeveloperTerms && item.entry.isDeveloperTerm { continue }
                if seenLowercased.contains(item.lower) { continue }
                results.append(formatWord(item.entry.word, typed: prefix))
                seenLowercased.insert(item.lower)
                if results.count >= limit { break }
            }
            return results
        }

        if loweredPrefix.count == 2 {
            let bucket = prefix2Buckets[loweredPrefix] ?? []
            for item in bucket {
                if !includeDeveloperTerms && item.entry.isDeveloperTerm { continue }
                if seenLowercased.contains(item.lower) { continue }
                results.append(formatWord(item.entry.word, typed: prefix))
                seenLowercased.insert(item.lower)
                if results.count >= limit { break }
            }
            return results
        }

        var idx = lowerBound(for: loweredPrefix)
        var candidates: [IndexedEntry] = []
        while idx < sortedByLower.count {
            let item = sortedByLower[idx]
            if !item.lower.hasPrefix(loweredPrefix) {
                break
            }
            if (includeDeveloperTerms || !item.entry.isDeveloperTerm) && !seenLowercased.contains(item.lower) {
                candidates.append(item)
            }
            idx += 1
        }

        candidates.sort { lhs, rhs in
            if lhs.entry.frequency != rhs.entry.frequency {
                return lhs.entry.frequency > rhs.entry.frequency
            }
            if lhs.lower.count != rhs.lower.count {
                return lhs.lower.count < rhs.lower.count
            }
            return lhs.lower < rhs.lower
        }

        for item in candidates {
            results.append(formatWord(item.entry.word, typed: prefix))
            if results.count >= limit { break }
        }
        return results
    }

    public func isKnownShortExactWord(_ word: String, includeDeveloperTerms: Bool = true) -> Bool {
        guard word.count <= 5 else {
            return false
        }
        guard let entry = exactWordsLowercased[word.lowercased()] else {
            return false
        }
        return includeDeveloperTerms || !entry.isDeveloperTerm
    }

    private func lowerBound(for target: String) -> Int {
        var low = 0
        var high = sortedByLower.count
        while low < high {
            let mid = (low + high) / 2
            if sortedByLower[mid].lower < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Renders a lexicon word for what the user typed. All-lowercase input takes the lexicon
    /// casing (`usestate` -> `useState`). Once the user types a capital, their letters are
    /// kept verbatim and only the completion is appended, upper-cased when the input is
    /// all caps (`HTT` -> `HTTP`, `Hel` -> `Hello`, `useS` -> `useState`).
    private func formatWord(_ word: String, typed: String) -> String {
        guard typed.contains(where: \.isUppercase), !word.hasPrefix(typed) else {
            return word
        }
        let completion = word.dropFirst(typed.count)
        let isAllCaps = typed.count >= 2 && !typed.contains(where: \.isLowercase)
        return typed + (isAllCaps ? completion.uppercased() : String(completion))
    }

    private static func loadBundled() -> EnglishPredictor {
        if let url = Bundle.module.url(forResource: "english_freq", withExtension: "tsv"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            var parsed: [EnglishEntry] = []
            parsed.reserveCapacity(10_000)
            for line in contents.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t")
                guard parts.count >= 2, let freq = Int(parts[1]) else { continue }
                let isDev = parts.count >= 3 && parts[2] == "1"
                parsed.append(EnglishEntry(word: String(parts[0]), frequency: freq, isDeveloperTerm: isDev))
            }
            if !parsed.isEmpty {
                return EnglishPredictor(entries: parsed)
            }
        }
        return EnglishPredictor(entries: seedEntries)
    }

    public static let seedEntries: [EnglishEntry] = [
        EnglishEntry(word: "the", frequency: 100_000),
        EnglishEntry(word: "be", frequency: 98_000),
        EnglishEntry(word: "to", frequency: 97_000),
        EnglishEntry(word: "of", frequency: 96_000),
        EnglishEntry(word: "and", frequency: 95_000),
        EnglishEntry(word: "a", frequency: 94_000),
        EnglishEntry(word: "in", frequency: 93_000),
        EnglishEntry(word: "is", frequency: 92_000),
        EnglishEntry(word: "it", frequency: 91_000),
        EnglishEntry(word: "on", frequency: 90_000),
        EnglishEntry(word: "for", frequency: 89_000),
        EnglishEntry(word: "do", frequency: 88_000),
        EnglishEntry(word: "go", frequency: 87_000),
        EnglishEntry(word: "no", frequency: 86_000),
        EnglishEntry(word: "so", frequency: 85_000),
        EnglishEntry(word: "by", frequency: 84_000),
        EnglishEntry(word: "my", frequency: 83_000),
        EnglishEntry(word: "he", frequency: 82_000),
        EnglishEntry(word: "me", frequency: 81_000),
        EnglishEntry(word: "we", frequency: 80_000),
        EnglishEntry(word: "us", frequency: 79_000),
        EnglishEntry(word: "am", frequency: 78_000),
        EnglishEntry(word: "an", frequency: 77_000),
        EnglishEntry(word: "as", frequency: 76_000),
        EnglishEntry(word: "at", frequency: 75_000),
        EnglishEntry(word: "if", frequency: 74_000),
        EnglishEntry(word: "or", frequency: 73_000),
        EnglishEntry(word: "up", frequency: 72_000),
        EnglishEntry(word: "ok", frequency: 71_000),
        EnglishEntry(word: "hi", frequency: 70_000),
        EnglishEntry(word: "i", frequency: 69_000),
        EnglishEntry(word: "sure", frequency: 65_000),
        EnglishEntry(word: "code", frequency: 64_000),
        EnglishEntry(word: "doc", frequency: 60_000),
        EnglishEntry(word: "id", frequency: 45_000),
        EnglishEntry(word: "hello", frequency: 99_500),
        EnglishEntry(word: "world", frequency: 99_000),
        EnglishEntry(word: "idea", frequency: 72_000),
        EnglishEntry(word: "into", frequency: 70_000),
        EnglishEntry(word: "issue", frequency: 68_000),
        EnglishEntry(word: "document", frequency: 67_000),
        EnglishEntry(word: "quality", frequency: 66_000),
        EnglishEntry(word: "intelligence", frequency: 65_500),
        EnglishEntry(word: "function", frequency: 64_500),
        EnglishEntry(word: "not", frequency: 89_500),
        EnglishEntry(word: "git", frequency: 85_500, isDeveloperTerm: true),
        EnglishEntry(word: "github", frequency: 84_500, isDeveloperTerm: true),
        EnglishEntry(word: "docker", frequency: 83_500, isDeveloperTerm: true),
        EnglishEntry(word: "kubectl", frequency: 82_500, isDeveloperTerm: true),
        EnglishEntry(word: "k8s", frequency: 81_500, isDeveloperTerm: true),
        EnglishEntry(word: "typescript", frequency: 80_500, isDeveloperTerm: true),
        EnglishEntry(word: "postgres", frequency: 79_500, isDeveloperTerm: true),
        EnglishEntry(word: "useState", frequency: 78_500, isDeveloperTerm: true),
        EnglishEntry(word: "useEffect", frequency: 77_500, isDeveloperTerm: true),
        EnglishEntry(word: "async", frequency: 76_500, isDeveloperTerm: true),
        EnglishEntry(word: "await", frequency: 75_500, isDeveloperTerm: true),
        EnglishEntry(word: "localhost", frequency: 74_500, isDeveloperTerm: true),
        EnglishEntry(word: "terraform", frequency: 73_500, isDeveloperTerm: true),
        EnglishEntry(word: "mp3", frequency: 72_500, isDeveloperTerm: true),
        EnglishEntry(word: "h264", frequency: 71_500, isDeveloperTerm: true),
        EnglishEntry(word: "es6", frequency: 70_500, isDeveloperTerm: true)
    ]
}
