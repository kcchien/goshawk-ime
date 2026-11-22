import Foundation
import Testing
@testable import GoshawkApp

@MainActor
@Test("覆蓋升級的完成說明比全新安裝多一句登出再登入的提醒")
func completionDetailDependsOnUpgrade() {
    let fresh = Installer.completionDetail(isUpgrade: false)
    let upgrade = Installer.completionDetail(isUpgrade: true)
    #expect(fresh == .installDoneDetail)
    #expect(upgrade != fresh)
    // 升級版是在原本的說明後面補一句，怎麼切換過去的說明不能少。
    #expect(upgrade.rawValue.hasPrefix(fresh.rawValue))
    #expect(upgrade.rawValue.hasSuffix("升級後若仍看到舊版行為，請登出 Mac 再登入。"))
    #expect(!fresh.rawValue.contains("登出"))
}

@MainActor
@Test("安裝位置原本有沒有舊版，決定複製後顯示哪一段完成說明")
func copyDescribesFreshInstallAndUpgrade() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let source = root.appendingPathComponent("下載/GoshawkIME.app")
    let destination = root.appendingPathComponent("Input Methods/GoshawkIME.app")
    try files.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("內容".utf8).write(to: source.appendingPathComponent("資源"))
    let copy = { try Installer.copyBundle(from: source, to: destination) }

    // 第一次複製時安裝位置是空的；複製完就有東西了，所以同樣的動作再做一次就是升級。
    #expect(try Installer.copyAndDescribe(destination: destination, copy: copy) == .installDoneDetail)
    #expect(files.fileExists(atPath: destination.path))
    #expect(try Installer.copyAndDescribe(destination: destination, copy: copy) == .installUpgradeDoneDetail)

    // 複製失敗時不回傳說明，錯誤原樣往外丟。
    #expect(throws: (any Error).self) {
        try Installer.copyAndDescribe(destination: destination) {
            try Installer.copyBundle(from: root.appendingPathComponent("不存在.app"), to: destination)
        }
    }
}

@MainActor
@Test("首次安裝、失敗後重試與升級都保留一份完整的輸入法")
func replaceInstalledBundle() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: root) }
    let source = root.appendingPathComponent("下載/GoshawkIME.app")
    let destination = root.appendingPathComponent("Input Methods/GoshawkIME.app")
    try files.createDirectory(at: source, withIntermediateDirectories: true)
    let old = Data("原版".utf8)
    try old.write(to: source.appendingPathComponent("原版資源"))

    try Installer.copyBundle(from: source, to: destination)
    let installed = destination.appendingPathComponent("原版資源")
    #expect(try Data(contentsOf: installed) == old)

    // 下載檔消失時，複製失敗也必須留下可用的原版。
    #expect(throws: (any Error).self) {
        try Installer.copyBundle(from: root.appendingPathComponent("不存在.app"), to: destination)
    }
    #expect(try Data(contentsOf: installed) == old)

    let new = Data("新版".utf8)
    try files.removeItem(at: source.appendingPathComponent("原版資源"))
    try new.write(to: source.appendingPathComponent("新版資源"))
    try Installer.copyBundle(from: source, to: destination)
    #expect(try Data(contentsOf: destination.appendingPathComponent("新版資源")) == new)
    #expect(!files.fileExists(atPath: installed.path))
}
