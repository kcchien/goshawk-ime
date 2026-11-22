import Darwin
import Foundation
import GoshawkCore

/// 學習紀錄的本機檔案。系統會為每個宿主程式各建一個控制器，所以紀錄由這裡統一保管。
final class UsageHistoryStore {
    /// InputMethodKit 的事件與選單動作都在主執行緒，沒有並行存取。
    nonisolated(unsafe) static let shared = UsageHistoryStore(fileURL: defaultFileURL)

    private(set) var history = UsageHistory()
    private let fileURL: URL

    private enum Pending {
        case readOriginal
        case write
    }
    private var pending: Pending?
    private var retryAfter = ContinuousClock.now

    init(fileURL: URL) {
        self.fileURL = fileURL
        do {
            history = try read()
        } catch {
            pending = .readOriginal
            report(error)
        }
    }

    private func read() throws -> UsageHistory {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(UsageHistory.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return UsageHistory()
        }
    }

    func update(_ newHistory: UsageHistory) {
        let changed = newHistory != history
        // 有新採用立即重試。其他按鍵只在先前失敗時重試，避免每鍵都讀寫故障的磁碟。
        guard changed || (pending != nil && ContinuousClock.now >= retryAfter) else { return }
        history = newHistory
        do {
            if pending == .readOriginal {
                var original = try read()
                let recent = history
                original.recordSession(recent)
                history = original
                if recent.isEmpty {
                    pending = nil
                    return
                }
            }
            pending = .write
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(history).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            pending = nil
        } catch {
            if ContinuousClock.now >= retryAfter { report(error) }
        }
    }

    private func report(_ error: any Error) {
        retryAfter = .now.advanced(by: .seconds(5))
        NSLog("蒼鷹輸入法：學習紀錄未同步，將重試：\(error.localizedDescription)")
    }

    func clear() throws {
        // 此處只刪學習檔；若路徑上是目錄，unlink 會報錯且保留其內容。
        if unlink(fileURL.path) != 0, errno != ENOENT {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        history = UsageHistory()
        pending = nil
    }

    private static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("GoshawkIME/usage-history.json")
    }
}
