import Foundation

/// 發行版本號，例如 `0.2.0`，開頭可以帶 `v`。只認以點分隔的數字，
/// 帶其他字樣的標籤（例如 `0.2.0-beta`）不算發行版本，不會被當成新版提示。
struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]

    init?(_ text: String) {
        let digits = text.hasPrefix("v") ? text.dropFirst() : Substring(text)
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in
            part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) ? Int(part) : nil
        }
        guard !parts.isEmpty, numbers.count == parts.count else { return nil }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// 段數不同時，缺的那幾段當成 0：`0.2` 等於 `0.2.0`。
    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count).lexicographicallyPrecedes(rhs.padded(to: count))
    }
}

/// 檢查有沒有新版。每天最多向公開倉庫的發行頁問一次最新版本號，有新版就讓輸入法選單多一列。
/// 不下載、不安裝，查不到就安靜略過。請求不帶任何使用者資料。
///
/// 查詢的網址不能換：舊版使用者只靠這個網址得知新版，之後每一版都要發在同一個發行頁。
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    nonisolated static let latestReleaseAPI = URL(string: "https://api.github.com/repos/kcchien/goshawk-ime/releases/latest")!
    nonisolated static let releasePage = URL(string: "https://github.com/kcchien/goshawk-ime/releases/latest")!
    nonisolated static let interval: TimeInterval = 24 * 60 * 60

    typealias Fetch = @MainActor (@escaping @Sendable (Data?) -> Void) -> Void

    private enum Key {
        static let enabled = "goshawk.updateCheckEnabled"
        static let lastCheckedAt = "goshawk.updateLastCheckedAt"
        static let latestVersion = "goshawk.updateLatestVersion"
    }

    private let defaults: UserDefaults
    private let currentVersion: ReleaseVersion?
    private let fetch: Fetch
    private let now: () -> Date
    private var isFetching = false

    /// `currentVersion` 是 nil 表示不是從打包的 App 執行（`swift run`、測試），這時不查也不提示。
    init(
        defaults: UserDefaults = .standard,
        currentVersion: ReleaseVersion? = UpdateChecker.bundledVersion,
        fetch: @escaping Fetch = UpdateChecker.fetchLatestRelease,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch
        self.now = now
        defaults.register(defaults: [Key.enabled: true])
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// 比目前執行的版本新的發行版本。關閉檢查、還沒查過或已是最新時為 nil。
    var availableVersion: ReleaseVersion? {
        guard isEnabled, let currentVersion,
              let latest = defaults.string(forKey: Key.latestVersion).flatMap(ReleaseVersion.init),
              latest > currentVersion else {
            return nil
        }
        return latest
    }

    /// 距離上次查詢滿一天就再查一次。查詢失敗也算查過，隔天再試，不在每次切換欄位時重試。
    func checkIfDue() {
        guard isEnabled, currentVersion != nil, !isFetching else { return }
        let last = defaults.object(forKey: Key.lastCheckedAt) as? Date ?? .distantPast
        let elapsed = now().timeIntervalSince(last)
        // 時鐘被往回調時 elapsed 是負的，照樣查，免得卡到那個未來時間才恢復。
        guard elapsed >= Self.interval || elapsed < 0 else { return }
        isFetching = true
        defaults.set(now(), forKey: Key.lastCheckedAt)
        fetch { data in
            Task { @MainActor in
                self.isFetching = false
                if let latest = data.flatMap(Self.latestVersion(fromReleaseJSON:)) {
                    self.defaults.set(latest.description, forKey: Key.latestVersion)
                }
            }
        }
    }

    nonisolated static var bundledVersion: ReleaseVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init)
    }

    /// GitHub「最新發行版」回應裡的版本號。
    nonisolated static func latestVersion(fromReleaseJSON data: Data) -> ReleaseVersion? {
        struct Release: Decodable { let tag_name: String }
        return (try? JSONDecoder().decode(Release.self, from: data)).flatMap { ReleaseVersion($0.tag_name) }
    }

    /// 不留快取與 cookie。使用者代理與語言標頭都寫成固定值，系統預設會填入版本、系統與語系。
    nonisolated static func fetchLatestRelease(completion: @escaping @Sendable (Data?) -> Void) {
        var request = URLRequest(url: latestReleaseAPI, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GoshawkIME", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200 ? data : nil)
        }.resume()
    }

    /// `--check-update`：實際查一次並印出結果，給發行前驗證與問題回報用。不讀寫偏好。
    nonisolated static func runCommandLine() -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox<Data?>(nil)
        fetchLatestRelease { data in
            result.value = data
            done.signal()
        }
        done.wait()
        guard let latest = result.value.flatMap(latestVersion(fromReleaseJSON:)) else {
            FileHandle.standardError.write(Data("查不到最新發行版本。\n".utf8))
            return 1
        }
        guard let current = bundledVersion else {
            print("最新發行版本 \(latest)。這個執行檔不是打包的 App，沒有版本可比。")
            return 0
        }
        print("目前版本 \(current)，最新發行版本 \(latest)，\(latest > current ? "有新版" : "已是最新")。")
        return 0
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
