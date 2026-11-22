import Foundation
import Testing
@testable import GoshawkApp

@Test("離線指南優先指向已安裝套件，避免卸載 dmg 後瀏覽器分頁斷鏈")
func prefersInstalledOfflineGuideOverCurrentBundle() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }

    let installed = root.appendingPathComponent("Input Methods/GoshawkIME.app")
    let mounted = root.appendingPathComponent("Volumes/GoshawkIME.app")
    for app in [installed, mounted] {
        let guide = app.appendingPathComponent(GuideLauncher.relativeGuidePath)
        try files.createDirectory(at: guide.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: guide)
    }

    let resolved = GuideLauncher.preferredURL(
        installedBundleURL: installed,
        currentBundleURL: mounted,
        usesEnglish: true
    )
    #expect(resolved == installed.appendingPathComponent(GuideLauncher.relativeGuidePath))
    // 本機 file:// 網址不得附加 query，否則 macOS LaunchServices 可能無法開啟檔案。
    #expect(resolved.isFileURL)
    #expect(resolved.query == nil)
}

@Test("尚未安裝時改開目前套件裡的離線指南")
func fallsBackToCurrentBundleGuideBeforeInstall() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }

    let missingInstalled = root.appendingPathComponent("Input Methods/GoshawkIME.app")
    let current = root.appendingPathComponent("dist/GoshawkIME.app")
    let guide = current.appendingPathComponent(GuideLauncher.relativeGuidePath)
    try files.createDirectory(at: guide.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("<html></html>".utf8).write(to: guide)

    let resolved = GuideLauncher.preferredURL(
        installedBundleURL: missingInstalled,
        currentBundleURL: current,
        usesEnglish: false
    )
    #expect(resolved == guide)
}

@Test("非套件執行找不到本機指南時安全退回線上版並依語系附帶語言參數")
func fallsBackToOnlineURLWhenUnbundled() {
    let missingInstalled = URL(fileURLWithPath: "/nonexistent/Input Methods/GoshawkIME.app")
    let unbundled = URL(fileURLWithPath: "/nonexistent/.build/debug")

    let zh = GuideLauncher.preferredURL(
        installedBundleURL: missingInstalled,
        currentBundleURL: unbundled,
        usesEnglish: false,
        fileExists: { _ in false }
    )
    #expect(zh.absoluteString == "https://goshawk.kcchien.com/")

    let en = GuideLauncher.preferredURL(
        installedBundleURL: missingInstalled,
        currentBundleURL: unbundled,
        usesEnglish: true,
        fileExists: { _ in false }
    )
    #expect(en.absoluteString == "https://goshawk.kcchien.com/?lang=en")
}
