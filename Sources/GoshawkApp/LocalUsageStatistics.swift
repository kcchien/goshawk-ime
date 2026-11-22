import AppKit
import Darwin
import Foundation
import GoshawkCore

/// 檔案只接受日期、建置版本、模式、計數與耗時級距。每個工作階段先把事件縮成這些數值。
struct StatisticsGroup: Codable, Hashable, Sendable {
    let dateUTC: String
    let build: String
    let cangjie: String
    let mode: Mode

    enum Mode: String, Codable, Sendable { case mixed, chinese, snippet, literal }
}

enum StatisticsMetric: String, Sendable {
    case trackOpportunities, punctuationOpportunities
    case stagedTrackSwaps, committedTrackSwaps, stagedPunctuationSwaps, committedPunctuationSwaps
    case refusedTrackSwaps, refusedPunctuationSwaps
    case ambiguousChineseCommits, candidateNavigationKeys
    case completionsWithEnglishPredictions
    case chineseContinuationOffers, chineseContinuationAcceptances
    case compositionsWithPersonalTermOffer, personalTermAcceptances
    case lookupOpens, lookupPageTurns, lookupSelections, lookupCancellations
}

enum StatisticsRoute: String, CaseIterable { case composing, lookup, commit }

struct StatisticsTotals: Codable, Sendable {
    var counts: [String: Int] = [:]
    var englishRanks: [Int] = Array(repeating: 0, count: 9)
    var latency: [String: [Int]] = [:]

    /// 微秒級距的上界，最後一桶收超過上界的樣本。
    static let microsecondLimits = [250, 500, 1000, 2000, 4000, 8000, 16000, 32000, 64000, 128000]
    mutating func sample(_ route: StatisticsRoute, nanoseconds: UInt64) {
        let index = Self.microsecondLimits.firstIndex { nanoseconds <= UInt64($0) * 1000 } ?? Self.microsecondLimits.count
        latency[route.rawValue, default: Array(repeating: 0, count: Self.microsecondLimits.count + 1)][index] += 1
    }

    mutating func add(_ metric: StatisticsMetric, _ count: Int = 1) {
        counts[metric.rawValue, default: 0] += count
    }

    func count(_ metric: StatisticsMetric) -> Int { counts[metric.rawValue] ?? 0 }

    mutating func merge(_ other: Self) {
        for (key, n) in other.counts { counts[key, default: 0] += n }
        for i in englishRanks.indices { englishRanks[i] += other.englishRanks[i] }
        for (route, buckets) in other.latency {
            for i in buckets.indices {
                latency[route, default: Array(repeating: 0, count: buckets.count)][i] += buckets[i]
            }
        }
    }

    static func percentile(_ percent: Int, buckets: [Int]) -> String {
        let n = buckets.reduce(0, +)
        guard n > 0 else { return "—" }
        let target = (n * percent + 99) / 100
        var cumulative = 0
        for (i, count) in buckets.enumerated() {
            cumulative += count
            if cumulative >= target {
                guard i < microsecondLimits.count else { return ">128 ms" }
                return "≤\(Double(microsecondLimits[i]) / 1000) ms"
            }
        }
        return "—"
    }
}

struct StatisticsRow: Codable, Sendable {
    let group: StatisticsGroup
    var totals: StatisticsTotals
}

private struct StatisticsFile: Codable, Sendable {
    let format: Int
    let latencyUpperBoundsMicroseconds: [Int]
    let rows: [StatisticsRow]
}

/// 只有這條佇列會讀寫待存快照。寫入失敗時保留最新總計，重試不會重複累加。
private final class StatisticsFileWriter: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.kc.goshawk.statistics.write", qos: .utility)
    private var pending: [StatisticsRow]?
    private var retryScheduled = false

    init(url: URL) { self.url = url }

    func submit(_ rows: [StatisticsRow]) {
        queue.async {
            self.pending = rows
            self.writePending()
        }
    }

    func clear() throws {
        try queue.sync {
            // 清除只授權刪除統計檔。路徑若是目錄，保留目錄及其內容並回報失敗。
            if unlink(url.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            pending = nil
        }
    }

    func finish() {
        queue.sync { writePending() }
    }

    private func writePending() {
        guard let rows = pending else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try LocalUsageStatistics.encode(rows).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            pending = nil
        } catch {
            guard !retryScheduled else { return }
            NSLog("蒼鷹輸入法：無法寫入本機使用統計，稍後重試")
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.writePending()
            }
        }
    }
}

/// IMK、設定與計時器都在主執行緒修改總計。磁碟操作照先後排入同一佇列。
final class LocalUsageStatistics: NSObject {
    nonisolated(unsafe) static let shared: LocalUsageStatistics = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LocalUsageStatistics(
            url: directory.appendingPathComponent("GoshawkIME/Statistics/local-statistics.json"),
            defaults: .standard, build: Bundle.main.object(forInfoDictionaryKey: "GoshawkBuildIdentifier") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        )
    }()

    private let url: URL
    private let fileWriter: StatisticsFileWriter
    private let defaults: UserDefaults
    private let build: String
    private let now: () -> Date
    private let enabledKey = "goshawk.localStatisticsEnabled"
    private var totals: [StatisticsGroup: StatisticsTotals] = [:]
    private var flushTimer: Timer?
    private var retentionTimer: Timer?
    private var utcDay = Int.min
    private var dayName = ""
    private var oldestDay = ""
    private var dirty = false
    private(set) var generation = 0
    private(set) var recordingRequested: Bool
    private(set) var fileUnavailable = false
    var enabled: Bool { recordingRequested && !fileUnavailable }

    init(url: URL, defaults: UserDefaults, build: String, now: @escaping () -> Date = Date.init) {
        self.url = url
        fileWriter = StatisticsFileWriter(url: url)
        self.defaults = defaults
        self.build = build
        self.now = now
        recordingRequested = defaults.bool(forKey: enabledKey)
        super.init()
        load()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                              name: NSApplication.willTerminateNotification, object: nil)
    }

    func retryLoadingIfNeeded() {
        if fileUnavailable { load() }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(StatisticsFile.self, from: data)
            guard file.format == 1, file.latencyUpperBoundsMicroseconds == StatisticsTotals.microsecondLimits else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var loaded: [StatisticsGroup: StatisticsTotals] = [:]
            for row in file.rows {
                guard Self.valid(row), loaded.updateValue(row.totals, forKey: row.group) == nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            totals = loaded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            totals = [:]
        } catch {
            fileUnavailable = true
            return
        }
        fileUnavailable = false
        // 重試成功當天可能已經看過日期，仍要把剛讀回的舊資料套用保留期限。
        utcDay = Int.min
        rollDay()
    }

    private static func valid(_ row: StatisticsRow) -> Bool {
        let totals = row.totals
        return (row.group.cangjie == "v3" || row.group.cangjie == "v5")
            && totals.englishRanks.count == 9 && totals.englishRanks.allSatisfy { $0 >= 0 }
            && totals.counts.allSatisfy { StatisticsMetric(rawValue: $0.key) != nil && $0.value >= 0 }
            && totals.latency.allSatisfy { route, buckets in
                StatisticsRoute(rawValue: route) != nil && buckets.count == StatisticsTotals.microsecondLimits.count + 1
                    && buckets.allSatisfy { $0 >= 0 }
            }
    }

    func setEnabled(_ value: Bool) {
        guard value != recordingRequested else { return }
        recordingRequested = value
        defaults.set(value, forKey: enabledKey)
        generation += 1
        if !value { flush() }
    }

    func group(for engine: InputEngine) -> StatisticsGroup {
        rollDay()
        let mode: StatisticsGroup.Mode
        if engine.isLiteralLayer { mode = .literal }
        else if engine.snippet.isInside { mode = .snippet }
        else { mode = engine.configuration.mixedModeEnabled ? .mixed : .chinese }
        return StatisticsGroup(dateUTC: dayName, build: build, cangjie: engine.configuration.cangjieVersion.rawValue, mode: mode)
    }

    func update(_ group: StatisticsGroup, _ change: (inout StatisticsTotals) -> Void) {
        guard enabled, group.dateUTC >= oldestDay, group.dateUTC <= dayName else { return }
        change(&totals[group, default: StatisticsTotals()])
        dirty = true
        if flushTimer == nil {
            flushTimer = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(flush), userInfo: nil, repeats: false)
        }
        scheduleRetention()
    }

    func rows() -> [StatisticsRow] {
        rollDay()
        return sortedRows()
    }

    private func sortedRows() -> [StatisticsRow] {
        return totals.map { StatisticsRow(group: $0.key, totals: $0.value) }.sorted {
            let lhs = $0.group, rhs = $1.group
            return (lhs.dateUTC, lhs.build, lhs.cangjie, lhs.mode.rawValue) < (rhs.dateUTC, rhs.build, rhs.cangjie, rhs.mode.rawValue)
        }
    }

    static func encode(_ rows: [StatisticsRow]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(StatisticsFile(format: 1, latencyUpperBoundsMicroseconds: StatisticsTotals.microsecondLimits, rows: rows))
    }

    func clear() throws {
        try fileWriter.clear()
        fileUnavailable = false
        generation += 1
        flushTimer?.invalidate()
        flushTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        totals.removeAll()
        dirty = false
    }

    @objc private func flush() {
        flushTimer?.invalidate()
        flushTimer = nil
        guard dirty else { return }
        dirty = false
        fileWriter.submit(sortedRows())
    }

    @objc private func applicationWillTerminate(_ notification: Notification) { shutdown() }

    func shutdown() {
        retentionTimer?.invalidate()
        retentionTimer = nil
        flush()
        fileWriter.finish()
    }

    @objc private func rollDay() {
        let day = Int(floor(now().timeIntervalSince1970 / 86400))
        guard day != utcDay else { return }
        utcDay = day
        func isoDay(_ day: Int) -> String {
            let date = Date(timeIntervalSince1970: Double(day) * 86400)
            return String(date.ISO8601Format().prefix(10))
        }
        dayName = isoDay(day)
        oldestDay = isoDay(day - 29)
        let previousCount = totals.count
        totals = totals.filter { $0.key.dateUTC >= oldestDay && $0.key.dateUTC <= dayName }
        if totals.count != previousCount {
            dirty = true
            flush()
        }
        scheduleRetention()
    }

    private func scheduleRetention() {
        guard !totals.isEmpty, retentionTimer?.isValid != true else { return }
        let seconds = Double(utcDay + 1) * 86400 - now().timeIntervalSince1970
        retentionTimer = Timer.scheduledTimer(timeInterval: max(1, seconds), target: self,
                                             selector: #selector(onDayBoundary), userInfo: nil, repeats: false)
    }

    @objc private func onDayBoundary() {
        retentionTimer = nil
        rollDay()
        scheduleRetention()
    }
}
