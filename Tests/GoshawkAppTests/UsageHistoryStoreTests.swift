import Foundation
import GoshawkCore
@testable import GoshawkApp
import Testing

@Suite("學習紀錄檔案")
struct UsageHistoryStoreTests {
    @Test("讀取失敗保留檔案，恢復後合併這段時間的採用紀錄")
    func recoverUnreadableHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-history.json")
        let brokenData = Data("{".utf8)
        try brokenData.write(to: file)
        let store = UsageHistoryStore(fileURL: file)
        var recent = UsageHistory(englishWords: ["functions"], cangjieChoices: [("oj", "什")], readingChoices: ["波"],
                                  recentSymbols: ["【", "「"])
        store.update(recent)
        #expect(try Data(contentsOf: file) == brokenData)

        let earlier = UsageHistory(englishWords: ["functions", "foundation"], cangjieChoices: [("oj", "什")], readingChoices: ["波"],
                                   recentSymbols: ["「", "》"])
        try JSONEncoder().encode(earlier).write(to: file, options: .atomic)
        recent.recordEnglish("future")
        store.update(recent)
        let fromDisk = UsageHistoryStore(fileURL: file).history
        #expect(fromDisk == store.history)
        #expect(fromDisk.english.map(\.word) == ["future", "functions", "foundation"])
        #expect(fromDisk.english.map(\.count) == [1, 2, 1])
        #expect(fromDisk.cangjie.first?.choices.first?.count == 2)
        #expect(fromDisk.reading.first?.count == 2)
        // 這段時間選的符號排在檔案裡原有的前面，同一個符號只留一份。
        #expect(fromDisk.symbols == ["【", "「", "》"])
    }

    @Test("儲存目錄暫時無法使用時保留學習，恢復後可存檔與重複清除")
    func retryFailedWrite() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: sandbox) }
        let directory = sandbox.appendingPathComponent("history")
        let held = sandbox.appendingPathComponent("held")
        let file = directory.appendingPathComponent("usage-history.json")
        let store = UsageHistoryStore(fileURL: file)
        var learned = UsageHistory(englishWords: ["first"])
        store.update(learned)
        let before = try Data(contentsOf: file)
        try fm.moveItem(at: directory, to: held)
        try Data().write(to: directory)
        learned.recordEnglish("second")
        store.update(learned)
        #expect(store.history == learned)
        #expect(try Data(contentsOf: held.appendingPathComponent(file.lastPathComponent)) == before)
        try fm.removeItem(at: directory)
        try fm.moveItem(at: held, to: directory)
        learned.recordEnglish("third")
        store.update(learned)
        #expect(UsageHistoryStore(fileURL: file).history == learned)
        try store.clear()
        try store.clear()
        #expect(!fm.fileExists(atPath: file.path))
    }

    @Test("清除失敗保留學習，檔案路徑意外成為目錄時也不刪裡面的資料")
    func failedClearPreservesHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage-history.json")
        let store = UsageHistoryStore(fileURL: file)
        let learned = UsageHistory(englishWords: ["functions"])
        store.update(learned)
        try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("original.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let marker = file.appendingPathComponent("keep")
        try Data().write(to: marker)
        #expect(throws: (any Error).self) { try store.clear() }
        #expect(store.history == learned)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
