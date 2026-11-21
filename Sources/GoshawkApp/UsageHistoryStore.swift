import Foundation
import GoshawkCore

/// 學習紀錄的本機檔案。系統會為每個宿主程式各建一個控制器，所以紀錄由這裡統一保管。
final class UsageHistoryStore {
    /// InputMethodKit 的事件與選單動作都在主執行緒，沒有並行存取。
    nonisolated(unsafe) static let shared = UsageHistoryStore(fileURL: defaultFileURL)

    private(set) var history: UsageHistory
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(UsageHistory.self, from: data) {
            history = decoded
        } else {
            history = UsageHistory()
        }
    }

    func update(_ newHistory: UsageHistory) {
        guard newHistory != history else { return }
        history = newHistory
        save()
    }

    func clear() {
        history = UsageHistory()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
            // 只有本人可讀寫。
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("蒼鷹輸入法：學習紀錄寫入失敗：\(error.localizedDescription)")
        }
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GoshawkIME/usage-history.json")
    }
}
