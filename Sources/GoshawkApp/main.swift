import AppKit
import Foundation
import InputMethodKit

if CommandLine.arguments.contains("--self-test") {
    let code = MainActor.assumeIsolated { runAppSelfTest() }
    exit(code)
}
if CommandLine.arguments.contains("--install") {
    exit(MainActor.assumeIsolated {
        Installer.runCommandLine(Installer.install, done: "已安裝並啟用蒼鷹輸入法：\(Installer.installedURL.path)")
    })
}
if CommandLine.arguments.contains("--uninstall") {
    exit(MainActor.assumeIsolated {
        Installer.runCommandLine(Installer.uninstall, done: "已移除蒼鷹輸入法。")
    })
}
if MainActor.assumeIsolated({ Installer.isLaunchedForInstall }) {
    MainActor.assumeIsolated { Installer.runInteractive() }
    exit(0)
}

let connectionName = (Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String) ?? "com.kc.inputmethod.Goshawk_Connection"
let bundleID = Bundle.main.bundleIdentifier ?? "com.kc.inputmethod.Goshawk"
let server = IMKServer(name: connectionName, bundleIdentifier: bundleID)
withExtendedLifetime(server) {
    NSApplication.shared.run()
}
