import Foundation

/// 單字讀音反查疊在既有組字之上的一層狀態。它存在時主組字的緩衝、模式與兩軌焦點全部凍結，
/// 所以取消只要把它設回 nil，不需要另存快照。
public struct ReadingLookup: Sendable, Hashable, Codable {
    /// 每頁列數。數字鍵 1 至 9 對應本頁的列。
    public static let rowsPerPage = 9

    public var scheme: PhoneticScheme
    /// 使用者在目前方案打下的原始鍵序。大千含結尾的聲調鍵（空白代表一聲），拼音含結尾的 1 至 5。
    public var keys: String
    /// 在完整候選清單中的絕對位置。頁碼由它推得，不另存。
    public var focusIndex: Int
    /// 按過 ↓ 進入候選選取後才為真，此時數字 1 至 9 選本頁序號。
    public var isSelecting: Bool

    public init(scheme: PhoneticScheme, keys: String = "", focusIndex: Int = 0, isSelecting: Bool = false) {
        self.scheme = scheme
        self.keys = keys
        self.focusIndex = focusIndex
        self.isSelecting = isSelecting
    }

    /// 目前焦點所在的頁，0 起算。
    public var pageIndex: Int { focusIndex / Self.rowsPerPage }
}

/// 面板要畫的全部內容。候選與分頁由核心算好，外層不得自己再查一次索引。
public struct ReadingLookupPanel: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        /// 還沒打任何讀音鍵。
        case empty
        /// 已打的鍵是某個收錄音節的開頭，還不成音。
        case partial
        case results
        case noResults
    }

    public struct Row: Sendable, Hashable, Codable {
        /// 本頁序號，1 起算。
        public let number: Int
        public let character: String
        /// 優先顯示目前代別能正查到這個字的原生碼。nil 代表本代未收錄。
        public let code: String?
        public let radicals: String?
        /// 正查該碼是否列出這個字。沒有原生碼或讀取舊紀錄時為 nil。
        public let directInputAvailable: Bool?

        public init(number: Int, character: String, code: String?, radicals: String?, directInputAvailable: Bool? = nil) {
            self.number = number
            self.character = character
            self.code = code
            self.radicals = radicals
            self.directInputAvailable = directInputAvailable
        }
    }

    public let scheme: PhoneticScheme
    /// 大千顯示注音符號與調號，拼音顯示原始鍵序。
    public let inputDisplay: String
    public let cangjieVersion: CangjieVersion
    public let status: Status
    /// 只有目前這一頁，至多九列。
    public let rows: [Row]
    /// 焦點在 `rows` 裡的索引。沒有候選時為 nil。
    public let focusedRow: Int?
    public let isSelecting: Bool
    /// 1 起算。
    public let page: Int
    public let pageCount: Int

    public init(
        scheme: PhoneticScheme,
        inputDisplay: String,
        cangjieVersion: CangjieVersion,
        status: Status,
        rows: [Row],
        focusedRow: Int?,
        isSelecting: Bool,
        page: Int,
        pageCount: Int
    ) {
        self.scheme = scheme
        self.inputDisplay = inputDisplay
        self.cangjieVersion = cangjieVersion
        self.status = status
        self.rows = rows
        self.focusedRow = focusedRow
        self.isSelecting = isSelecting
        self.page = page
        self.pageCount = pageCount
    }
}
