import Foundation
import GoshawkCore

private struct PredictionCounts: Encodable {
    var hits = 0
    var wrongSuffixes = 0
    var missedSuggestions = 0
    var unwantedSuggestions = 0
    var correctAbstentions = 0

    mutating func record(suggestion: String?, expected: String?) {
        switch (suggestion, expected) {
        case (nil, nil): correctAbstentions += 1
        case (nil, _?): missedSuggestions += 1
        case (_?, nil): unwantedSuggestions += 1
        case (let actual?, let expected?):
            if actual == expected { hits += 1 } else { wrongSuffixes += 1 }
        }
    }
}

private struct RankingSummary: Encodable {
    let counts: PredictionCounts
    let suggestionPrecision: Double?
    let exactSuffixRecall: Double?

    init(_ counts: PredictionCounts) {
        self.counts = counts
        let suggested = counts.hits + counts.wrongSuffixes + counts.unwantedSuggestions
        let expected = counts.hits + counts.wrongSuffixes + counts.missedSuggestions
        suggestionPrecision = suggested > 0 ? Double(counts.hits) / Double(suggested) : nil
        exactSuffixRecall = expected > 0 ? Double(counts.hits) / Double(expected) : nil
    }
}

private struct ContinuationEvaluation: Encodable {
    let cases: Int
    let context: RankingSummary
    let frequencyOnly: RankingSummary
    let contextOnlyHits: Int
    let frequencyOnlyHits: Int
}

func runContinuationEvaluation(path: String) throws -> Int32 {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var contextCounts = PredictionCounts()
    var frequencyCounts = PredictionCounts()
    var cases = 0
    var contextOnlyHits = 0
    var frequencyOnlyHits = 0
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    for (index, line) in lines.enumerated() where !line.isEmpty {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[0].isEmpty else {
            fputs("Line \(index + 1): expected nonempty context, TAB, then expected suffix (empty for no suggestion).\n", stderr)
            return 2
        }
        let text = String(fields[0])
        let expected = fields[1].isEmpty ? nil : String(fields[1])
        let context = ChineseContinuation.suggestion(after: text)
        let frequency = ChineseContinuation.suggestion(after: text, ranking: .frequencyOnly)
        contextCounts.record(suggestion: context, expected: expected)
        frequencyCounts.record(suggestion: frequency, expected: expected)
        if let expected, context != frequency {
            if context == expected { contextOnlyHits += 1 }
            if frequency == expected { frequencyOnlyHits += 1 }
        }
        cases += 1
    }
    guard cases > 0 else {
        fputs("Expected at least one continuation case.\n", stderr)
        return 2
    }
    let report = ContinuationEvaluation(cases: cases, context: RankingSummary(contextCounts),
                                        frequencyOnly: RankingSummary(frequencyCounts),
                                        contextOnlyHits: contextOnlyHits, frequencyOnlyHits: frequencyOnlyHits)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
    return 0
}
