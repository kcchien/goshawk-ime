import Foundation

/// 接詞試驗只在送出中文後查詢。索引以最後兩個字為鍵，候選保留詞頻與可辨識的前文線索。
package enum ChineseContinuation {
    package enum Ranking {
        case context
        case frequencyOnly
    }

    private struct Entry: Sendable {
        let suffix: String
        let count: Int
        let cues: [String]
    }

    private static let entries: [String: [Entry]] = {
        guard let url = Bundle.module.url(forResource: "chinese_continuations", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [Entry]] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard (3...4).contains(fields.count), fields[0].count == 2, !fields[1].isEmpty,
                  let count = Int(fields[2]), count > 0 else { continue }
            let entry = Entry(suffix: String(fields[1]), count: count,
                              cues: fields.count == 4 ? fields[3].split(separator: ",").map { $0.lowercased() } : [])
            result[String(fields[0]), default: []].append(entry)
        }
        // 詞頻相同時保留原本順序，兩種排序共用同一份候選。
        return result.mapValues { $0.sorted { $0.count > $1.count } }
    }()

    package static func suggestion(after text: String, ranking: Ranking = .context) -> String? {
        guard let candidates = entries[String(text.suffix(2))], var best = candidates.first else { return nil }
        guard candidates.count > 1, ranking == .context else { return best.suffix }
        let context = text.suffix(InputEngine.contextWindowLength).dropLast(2).lowercased()
        var bestMatches = 0
        for entry in candidates {
            let matches = entry.cues.count { context.contains($0) }
            if matches > bestMatches {
                best = entry
                bestMatches = matches
            }
        }
        return best.suffix
    }
}
