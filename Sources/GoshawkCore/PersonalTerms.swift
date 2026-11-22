import Foundation

/// 只接受引擎能逐碼輸入的英數術語。使用者明確加入的拼法與大小寫保留在本機偏好。
public struct PersonalTerms: Equatable, Sendable {
    public static let empty = PersonalTerms()
    public private(set) var words: [String] = []

    public init(_ terms: [String] = []) {
        var byLowercase: [String: String] = [:]
        for term in terms where Self.isValid(term) {
            byLowercase[term.lowercased()] = term
        }
        words = byLowercase.keys.sorted().compactMap { byLowercase[$0] }
    }

    public static func isValid(_ term: String) -> Bool {
        guard term.count >= 2, let first = term.first, AutoSpacer.isASCIILetter(first) else { return false }
        return term.allSatisfy { AutoSpacer.isASCIILetter($0) || AutoSpacer.isASCIIDigit($0) }
    }

    public func contains(_ word: String) -> Bool {
        let key = word.lowercased()
        var low = words.startIndex, high = words.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            let candidate = words[middle].lowercased()
            if candidate == key { return true }
            if candidate < key { low = middle + 1 } else { high = middle }
        }
        return false
    }
}
