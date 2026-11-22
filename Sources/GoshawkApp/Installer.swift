import AppKit
import Carbon

/// 把自己裝進「Input Methods」並向系統註冊輸入來源。
///
/// 註冊要呼叫系統的輸入來源介面，放在 App 裡，使用者的電腦就不需要 Swift 工具鏈：
/// dmg 裡點兩下、安裝腳本與 `--install` 走的都是這裡。
@MainActor
enum Installer {
    static let bundleIdentifier = "com.kc.inputmethod.Goshawk"

    struct Failure: Error {
        let message: String
    }

    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/GoshawkIME.app")
    }

    /// 系統只從「Input Methods」啟動輸入法。從別處被開啟，代表使用者點了還沒安裝的那一份。
    static var isLaunchedForInstall: Bool {
        let bundleURL = Bundle.main.bundleURL
        return bundleURL.pathExtension == "app"
            && bundleURL.deletingLastPathComponent().lastPathComponent != "Input Methods"
    }

    /// 安裝視窗完成畫面的說明。覆蓋既有版本時多提醒一句：系統可能還握著舊版，要登出再登入。
    static func completionDetail(isUpgrade: Bool) -> UIText {
        isUpgrade ? .installUpgradeDoneDetail : .installDoneDetail
    }

    /// 執行複製並回傳完成畫面的說明。複製之後安裝位置一定有東西，所以在複製之前看是不是升級。
    static func copyAndDescribe(destination: URL, copy: () throws -> Void) rethrows -> UIText {
        let isUpgrade = FileManager.default.fileExists(atPath: destination.path)
        try copy()
        return completionDetail(isUpgrade: isUpgrade)
    }

    /// 重複執行的結果相同：已安裝就覆蓋成這一份，已註冊就維持註冊。
    static func install() throws {
        try copyToInputMethods()
        try registerInputSource()
    }

    private static func copyToInputMethods() throws {
        let source = Bundle.main.bundleURL
        guard source.pathExtension == "app" else {
            throw Failure(message: "要從 GoshawkIME.app 裡執行才能安裝。")
        }
        let destination = installedURL
        if source.standardizedFileURL != destination.standardizedFileURL {
            do {
                try copyBundle(from: source, to: destination)
                terminateInstalledInstances()
            } catch {
                throw Failure(message: "無法複製到 \(destination.path)：\(error.localizedDescription)")
            }
        }
    }

    static func copyBundle(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 先在目的磁碟備妥整份 App。複製出錯時，舊版仍可繼續使用。
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination, create: true)
        defer { try? files.removeItem(at: work) }
        let staged = work.appendingPathComponent(destination.lastPathComponent)
        try files.copyItem(at: source, to: staged)
        removeQuarantine(at: staged)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staged, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: staged, to: destination)
        }
    }

    /// 下載標記會跟著複製過來。留著的話，系統第一次啟動輸入法時會再問一次要不要打開，
    /// 接著從隨機路徑啟動，這份程式看到自己不在「Input Methods」就又跳出安裝視窗，打字沒有反應。
    private static func removeQuarantine(at bundle: URL) {
        let inside = FileManager.default.enumerator(atPath: bundle.path)?
            .compactMap { ($0 as? String).map { bundle.path + "/" + $0 } } ?? []
        for path in [bundle.path] + inside {
            removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private static func registerInputSource() throws {
        let status = TISRegisterInputSource(installedURL as CFURL)
        guard status == noErr else {
            throw Failure(message: "系統拒絕註冊輸入來源，錯誤碼 \(status)。")
        }
        var registered = sources(bundleIdentifier: bundleIdentifier)
        for _ in 0..<10 where registered.isEmpty {
            Thread.sleep(forTimeInterval: 0.2)
            registered = sources(bundleIdentifier: bundleIdentifier)
        }
        guard !registered.isEmpty else {
            throw Failure(message: "註冊後找不到輸入來源 \(bundleIdentifier)。請登出再登入後重試。")
        }
        for source in registered {
            TISEnableInputSource(source)
        }
        let mode = [kTISPropertyInputSourceID as String: bundleIdentifier + ".Cangjie"] as CFDictionary
        guard let enabled = TISCreateInputSourceList(mode, false)?.takeRetainedValue() as? [TISInputSource],
              !enabled.isEmpty else {
            throw Failure(message: "輸入法已安裝，但系統未啟用倉頡。請在系統設定的鍵盤輸入方式加入蒼鷹輸入法。")
        }
        disableSources(bundleIdentifier: "com.kc.inputmethod.KCIME")  // 舊版輸入來源留到新版可用再停用。
    }

    /// 只移除輸入法本身。偏好與學習紀錄留著，重新安裝時還在。
    static func uninstall() throws {
        disableSources(bundleIdentifier: bundleIdentifier)
        terminateInstalledInstances()
        let destination = installedURL
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        do {
            try FileManager.default.removeItem(at: destination)
        } catch {
            throw Failure(message: "無法移除 \(destination.path)：\(error.localizedDescription)")
        }
    }

    static func runCommandLine(_ action: () throws -> Void, done: String) -> Int32 {
        do {
            try action()
            print(done)
            return 0
        } catch let failure as Failure {
            fputs(failure.message + "\n", stderr)
            return 1
        } catch {
            fputs("\(error)\n", stderr)
            return 1
        }
    }

    /// 使用者在 Finder 點兩下時的流程：先問，再安裝，最後說明怎麼切換過去。
    static func runInteractive() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let window = InstallWindow()
        app.runModal(for: window.panel)
    }

    /// 詢問、複製、說明怎麼切換都在同一個視窗，使用者關掉它之後才註冊輸入來源。
    ///
    /// 順序不能倒過來：輸入來源一啟用，系統就把這個行程的視窗壓到其他程式後面，
    /// 層級與 `orderFrontRegardless` 都改不回來，使用者只看到 Dock 圖示在跳。
    @MainActor
    private final class InstallWindow: NSObject {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
            styleMask: [.titled], backing: .buffered, defer: false)
        private let title = NSTextField(labelWithString: UIText.installQuestion.text)
        private let detail = NSTextField(wrappingLabelWithString: UIText.installQuestionDetail.text)
        private let primary = NSButton(title: UIText.installConfirm.text, target: nil, action: nil)
        private let cancel = NSButton(title: UIText.settingsCancel.text, target: nil, action: nil)
        private enum Step { case asking, copied, failed }
        private var step = Step.asking

        override init() {
            super.init()
            let icon = NSImageView(image: NSApplication.shared.applicationIconImage)
            icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            detail.preferredMaxLayoutWidth = 340
            primary.keyEquivalent = "\r"
            primary.target = self
            primary.action = #selector(primaryPressed)
            cancel.keyEquivalent = "\u{1b}"
            cancel.target = self
            cancel.action = #selector(secondaryPressed)

            let buttons = NSStackView(views: [cancel, primary])
            let stack = NSStackView(views: [icon, title, detail, buttons])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            panel.contentView = stack
            panel.title = UIText.productName.text
            panel.level = .floating
            panel.center()
        }

        @objc private func primaryPressed() {
            do {
                switch step {
                case .asking:
                    let done = try Installer.copyAndDescribe(
                        destination: Installer.installedURL, copy: Installer.copyToInputMethods)
                    step = .copied
                    title.stringValue = UIText.installDone.text
                    detail.stringValue = done.text
                    // 複製完成後同時提供「開啟 30 秒上手指南」與「好」，兩顆都會先註冊輸入來源再關閉。
                    primary.title = UIText.installOpenGuide.text
                    cancel.title = UIText.installClose.text
                    cancel.isHidden = false
                case .copied:
                    try Installer.registerInputSource()
                    GuideLauncher.open()
                    close()
                case .failed:
                    close()
                }
            } catch {
                showFailure(error)
            }
        }

        @objc private func secondaryPressed() {
            switch step {
            case .asking, .failed:
                close()
            case .copied:
                do {
                    try Installer.registerInputSource()
                    close()
                } catch {
                    showFailure(error)
                }
            }
        }

        private func showFailure(_ error: any Error) {
            step = .failed
            title.stringValue = UIText.installFailed.text
            detail.stringValue = (error as? Failure)?.message ?? "\(error)"
            primary.title = UIText.installClose.text
            cancel.isHidden = true
        }

        @objc private func close() {
            NSApplication.shared.stopModal()
            panel.orderOut(nil)
        }
    }

    private static func sources(bundleIdentifier: String) -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleIdentifier] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    private static func disableSources(bundleIdentifier: String) {
        for source in sources(bundleIdentifier: bundleIdentifier) {
            TISDisableInputSource(source)
        }
    }

    /// 執行中的舊版握著舊的執行檔，不先結束，系統會繼續用它。
    private static func terminateInstalledInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        where running.processIdentifier != me && running.bundleURL?.standardizedFileURL.path == installedURL.standardizedFileURL.path {
            running.forceTerminate()
        }
    }
}
