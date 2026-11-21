import Foundation

public struct CangjieDictionary: Sendable {
    public static let radicalMap: [Character: Character] = [
        "a": "日", "b": "月", "c": "金", "d": "木", "e": "水",
        "f": "火", "g": "土", "h": "竹", "i": "戈", "j": "十",
        "k": "大", "l": "中", "m": "一", "n": "弓", "o": "人",
        "p": "心", "q": "手", "r": "口", "s": "尸", "t": "廿",
        "u": "山", "v": "女", "w": "田", "x": "難", "y": "卜"
    ]

    public static let sharedV5: CangjieDictionary = loadBundled(resourceName: "cangjie5")
    public static let sharedV3: CangjieDictionary = loadBundled(resourceName: "cangjie3")

    public static func shared(version: CangjieVersion = .v5) -> CangjieDictionary {
        switch version {
        case .v5:
            return sharedV5
        case .v3:
            return sharedV3
        }
    }

    private let entries: [String: [String]]
    private let prefixes: Set<String>

    public var codeCount: Int { entries.count }

    /// Largest candidate list of any code. Selection has no paging, so a table whose
    /// lists outgrow the visible candidate count would hold unreachable characters.
    public var maxCandidateCount: Int { entries.values.map(\.count).max() ?? 0 }

    public init(entries: [String: [String]] = CangjieDictionary.seedEntries) {
        // Malformed codes (empty, too long, non-radical keys) can never be typed; dropping
        // them here also keeps the prefix loop below from trapping on an empty code.
        let usable = entries.filter { Self.isValidCangjieCodeShape($0.key) && !$0.value.isEmpty }
        self.entries = usable
        var prefixSet = Set<String>()
        prefixSet.reserveCapacity(usable.count * 2)
        for code in usable.keys {
            for length in 1...code.count {
                prefixSet.insert(String(code.prefix(length)))
            }
        }
        self.prefixes = prefixSet
    }

    public static func isValidCangjieCodeShape(_ code: String) -> Bool {
        guard !code.isEmpty, code.count <= 5 else {
            return false
        }
        return code.allSatisfy { radicalMap[$0] != nil }
    }

    public func hasCandidatesOrPrefix(for code: String) -> Bool {
        guard Self.isValidCangjieCodeShape(code) else {
            return false
        }
        return prefixes.contains(code)
    }

    public func candidates(for code: String) -> [String] {
        guard Self.isValidCangjieCodeShape(code) else {
            return []
        }
        return entries[code] ?? []
    }

    public func radicals(for code: String) -> String {
        String(code.compactMap { Self.radicalMap[$0] })
    }

    public static func parseTableTSV(_ contents: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let tabIndex = line.firstIndex(of: "\t") else { continue }
            let code = String(line[..<tabIndex]).lowercased()
            let rhs = line[line.index(after: tabIndex)...]
            guard isValidCangjieCodeShape(code) else { continue }
            // A code listed twice extends its candidate list instead of replacing it.
            var cands = result[code] ?? []
            for cand in rhs.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
            where !cands.contains(cand) {
                cands.append(cand)
            }
            guard !cands.isEmpty else { continue }
            result[code] = cands
        }
        return result
    }

    private static func loadBundled(resourceName: String) -> CangjieDictionary {
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "tsv"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            let parsed = parseTableTSV(contents)
            if !parsed.isEmpty {
                return CangjieDictionary(entries: parsed)
            }
        }
        return CangjieDictionary(entries: seedEntries)
    }

    // Authentic Cangjie 5 subset used as fallback if resource bundle is unavailable.
    public static let seedEntries: [String: [String]] = [
        "a": ["日", "曰"],
        "b": ["月"],
        "c": ["金"],
        "d": ["木"],
        "e": ["水"],
        "f": ["火"],
        "g": ["土"],
        "h": ["竹"],
        "i": ["戈", "、"],
        "j": ["十"],
        "k": ["大"],
        "l": ["中"],
        "m": ["一"],
        "n": ["弓"],
        "o": ["人"],
        "p": ["心"],
        "q": ["手"],
        "r": ["口"],
        "s": ["尸"],
        "t": ["廿"],
        "u": ["山"],
        "v": ["女"],
        "w": ["田"],
        "y": ["卜"],
        "ab": ["明"],
        "am": ["旦"],
        "an": ["門"],
        "by": ["丹"],
        "doo": ["來"],
        "he": ["反", "夊"],
        "hqi": ["我"],
        "hsp": ["怎"],
        "osp": ["怎"],
        "id": ["床"],
        "ihs": ["成"],
        "me": ["汞"],
        "mk": ["天"],
        "my": ["下"],
        "no": ["欠", "久"],
        "ok": ["矢"],
        "onf": ["你"],
        "oog": ["坐", "倠"],
        "pt": ["世"],
        "so": ["尺"],
        "vnd": ["好"],
        "woll": ["界"],
        "yymr": ["這"]
    ]
}
