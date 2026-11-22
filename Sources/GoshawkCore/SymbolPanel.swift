import Foundation

/// 疊在組字之上的一層。同一時間最多開一個，所以用列舉表示，兩個同時開著就表示不出來。
/// 有疊加層時主組字的緩衝、模式與兩軌焦點全部凍結，取消只要把它設回 nil。
public enum InputLayer: Sendable, Hashable {
    case readingLookup(ReadingLookup)
    case symbolPanel(SymbolPanel)
}

/// 符號面板的狀態。數字一律直選本頁的列，所以沒有「是否進入選取」這種狀態。
public struct SymbolPanel: Sendable, Hashable {
    public enum Tab: String, Sendable, Hashable, Codable {
        /// 最近使用：選過的符號在前，後面接初始的常用符號。
        case recent
        /// 標準標點的全形與半形寫法，照符號表的順序。
        case punctuation
        /// 符號表裡其餘的符號，照檔案順序。
        case symbols

        /// Tab 鍵切到的下一個分頁，三個輪流。
        public var next: Tab {
            switch self {
            case .recent: return .punctuation
            case .punctuation: return .symbols
            case .symbols: return .recent
            }
        }
    }

    /// 每頁列數。數字鍵 1 至 9 對應本頁的列。
    public static let rowsPerPage = 9

    public var tab: Tab
    /// 在目前分頁清單中的絕對位置。頁碼由它推得，不另存。
    public var focusIndex: Int

    public init(tab: Tab = .recent, focusIndex: Int = 0) {
        self.tab = tab
        self.focusIndex = focusIndex
    }

    /// 目前焦點所在的頁，0 起算。
    public var pageIndex: Int { focusIndex / Self.rowsPerPage }
}

/// 符號面板要畫的全部內容。清單與分頁由核心算好，外層只挑語系顯示。
public struct SymbolPanelContent: Sendable, Hashable, Codable {
    public struct Row: Sendable, Hashable, Codable {
        /// 本頁序號，1 起算。
        public let number: Int
        public let symbol: String
        public let name: String
        public let englishName: String
        public let group: String
        public let englishGroup: String

        public init(number: Int, symbol: String, name: String, englishName: String, group: String, englishGroup: String) {
            self.number = number
            self.symbol = symbol
            self.name = name
            self.englishName = englishName
            self.group = group
            self.englishGroup = englishGroup
        }
    }

    public let tab: SymbolPanel.Tab
    /// 只有目前這一頁，至多九列。
    public let rows: [Row]
    /// 焦點在 `rows` 裡的索引。清單是空的時為 nil。
    public let focusedRow: Int?
    /// 1 起算。
    public let page: Int
    public let pageCount: Int

    public init(tab: SymbolPanel.Tab, rows: [Row], focusedRow: Int?, page: Int, pageCount: Int) {
        self.tab = tab
        self.rows = rows
        self.focusedRow = focusedRow
        self.page = page
        self.pageCount = pageCount
    }
}

/// 符號面板的符號表。本專案自行編列，載入時驗證格式，壞掉的表整份不用。
public struct SymbolTable: Sendable {
    public struct Entry: Sendable, Hashable {
        public let symbol: String
        public let name: String
        public let englishName: String
        public let group: String
        public let englishGroup: String
        /// 這個符號列在哪個分頁，只會是「標點」或「符號」。
        public let tab: SymbolPanel.Tab
        /// 列入初始的最近使用：還沒選過任何符號時，「最近使用」分頁先顯示這些。
        public let isInitialRecent: Bool
    }

    /// 行號從 1 起算，對應檔案裡的實際行，註解行也算。
    public enum ParseError: Error, Equatable {
        case fieldCount(line: Int)
        case emptyField(line: Int)
        case unknownMarker(line: Int)
        case unknownTab(line: Int)
        case symbolBeforeGroup(line: Int)
        case duplicateSymbol(line: Int, symbol: String)
    }

    public static let empty = SymbolTable(entries: [])
    /// 載入失敗時是空表，面板開得起來但沒有列，打字不受影響。
    public static let shared: SymbolTable = (try? loadBundled()) ?? .empty

    public let entries: [Entry]
    private let entryBySymbol: [String: Entry]

    private init(entries: [Entry]) {
        self.entries = entries
        self.entryBySymbol = Dictionary(entries.map { ($0.symbol, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `#` 開頭的列是註解；`@` 開頭的列是分組（中文組名、英文組名、所屬分頁，
    /// 分頁只能是 `punctuation` 或 `symbols`）；
    /// 其餘每列是符號、中文名稱、英文名稱，第四欄只能是 `*`，表示列入初始的最近使用。
    /// 符號可以是全形空格，所以欄位一律不去頭尾空白。
    public init(tsv: String) throws {
        var entries: [Entry] = []
        var seen = Set<String>()
        var group: (name: String, english: String, tab: SymbolPanel.Tab)?
        let lines = tsv.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (offset, line) in lines.enumerated() where !line.isEmpty && !line.hasPrefix("#") {
            let number = offset + 1
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if line.hasPrefix("@") {
                guard fields.count == 3 else { throw ParseError.fieldCount(line: number) }
                let name = String(fields[0].dropFirst())
                guard !name.isEmpty, !fields[1].isEmpty else { throw ParseError.emptyField(line: number) }
                // 「最近使用」的內容來自紀錄與初始標記，符號表不能把分組指到它。
                guard let tab = SymbolPanel.Tab(rawValue: fields[2]), tab != .recent else {
                    throw ParseError.unknownTab(line: number)
                }
                group = (name, fields[1], tab)
                continue
            }
            guard fields.count == 3 || fields.count == 4 else { throw ParseError.fieldCount(line: number) }
            guard fields.prefix(3).allSatisfy({ !$0.isEmpty }) else { throw ParseError.emptyField(line: number) }
            if fields.count == 4, fields[3] != "*" { throw ParseError.unknownMarker(line: number) }
            guard let group else { throw ParseError.symbolBeforeGroup(line: number) }
            guard seen.insert(fields[0]).inserted else {
                throw ParseError.duplicateSymbol(line: number, symbol: fields[0])
            }
            entries.append(Entry(
                symbol: fields[0],
                name: fields[1],
                englishName: fields[2],
                group: group.name,
                englishGroup: group.english,
                tab: group.tab,
                isInitialRecent: fields.count == 4
            ))
        }
        self.init(entries: entries)
    }

    public static func loadBundled() throws -> SymbolTable {
        guard let url = Bundle.module.url(forResource: "symbols", withExtension: "tsv") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try SymbolTable(tsv: String(contentsOf: url, encoding: .utf8))
    }

    public func entry(for symbol: String) -> Entry? {
        entryBySymbol[symbol]
    }

    /// 「標點」或「符號」分頁的清單，照檔案順序。
    public func entries(in tab: SymbolPanel.Tab) -> [Entry] {
        entries.filter { $0.tab == tab }
    }

    /// 「最近使用」分頁的清單：選過的符號在前（`history` 最近的在最前面），
    /// 後面接初始符號裡還沒出現的，合計不超過上限。紀錄裡不在表內的符號略過，
    /// 換了符號表之後舊紀錄才不會讓面板出現沒有名稱的列。
    public func recentEntries(history: [String]) -> [Entry] {
        var seen = Set<String>()
        let chosen = history.compactMap { entryBySymbol[$0] }.filter { seen.insert($0.symbol).inserted }
        let initial = entries.filter { $0.isInitialRecent && !seen.contains($0.symbol) }
        return Array((chosen + initial).prefix(UsageHistory.symbolCapacity))
    }
}
