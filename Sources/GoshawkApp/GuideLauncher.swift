import AppKit
import Foundation

/// 開啟蒼鷹輸入法隨附的離線互動說明與 30 秒練習場。
///
/// 指南放在 `GoshawkIME.app/Contents/Resources/Guide/`，全部使用相對路徑、零外部請求，
/// 由系統預設瀏覽器開啟，不把 WebView 塞進輸入法行程，維持低記憶體占用與隱私承諾。
enum GuideLauncher {
    static let onlineURL = URL(string: "https://goshawk.kcchien.com/")!
    static let relativeGuidePath = "Contents/Resources/Guide/index.html"

    /// 檢查指定 App 套件裡是否帶著隨附的離線指南。
    static func bundledGuideURL(
        in appBundleURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        guard appBundleURL.pathExtension == "app" else { return nil }
        let candidate = appBundleURL.appendingPathComponent(relativeGuidePath)
        return fileExists(candidate.path) ? candidate : nil
    }

    /// 決定要開啟的指南網址：
    /// 1. 優先開已安裝套件裡的離線檔（安裝完成後卸載 dmg，瀏覽器分頁重整才不會斷鏈）。
    /// 2. 其次開目前執行中套件裡的離線檔。
    /// 3. 非 `.app` 套件執行（例如 `swift run`）時退回線上版，英文介面附帶 `?lang=en`。
    ///
    /// 本機 `file://` 網址不加 query，避免 macOS LaunchServices 視為無效路徑而拒絕開啟。
    static func preferredURL(
        installedBundleURL: URL,
        currentBundleURL: URL = Bundle.main.bundleURL,
        usesEnglish: Bool = Localization.current.usesEnglishNames,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        if let installed = bundledGuideURL(in: installedBundleURL, fileExists: fileExists) {
            return installed
        }
        if let current = bundledGuideURL(in: currentBundleURL, fileExists: fileExists) {
            return current
        }
        guard usesEnglish, var components = URLComponents(url: onlineURL, resolvingAgainstBaseURL: false) else {
            return onlineURL
        }
        components.queryItems = [URLQueryItem(name: "lang", value: "en")]
        return components.url ?? onlineURL
    }

    @MainActor
    static func open(
        installedBundleURL: URL = Installer.installedURL,
        currentBundleURL: URL = Bundle.main.bundleURL
    ) {
        let url = preferredURL(installedBundleURL: installedBundleURL, currentBundleURL: currentBundleURL)
        NSWorkspace.shared.open(url)
    }
}
