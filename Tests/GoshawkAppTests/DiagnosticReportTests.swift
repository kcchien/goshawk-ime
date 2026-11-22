import Foundation
import GoshawkCore
import Testing
@testable import GoshawkApp

private func report(
    _ configuration: EngineConfiguration = EngineConfiguration(),
    overlayFontSize: OverlayFontSize = .medium,
    updateCheckEnabled: Bool = true,
    statisticsEnabled: Bool = false
) -> String {
    DiagnosticReport.build(
        appVersion: "9.8.7",
        architecture: "arm64",
        osVersion: "Version 27.2 (Build 26C1234)",
        configuration: configuration,
        overlayFontSize: overlayFontSize,
        updateCheckEnabled: updateCheckEnabled,
        statisticsEnabled: statisticsEnabled
    )
}

private func field(_ label: String, _ value: String) -> String {
    UIText.diagnosticField.text(label, value)
}

private let on = UIText.diagnosticOn.text
private let off = UIText.diagnosticOff.text

/// 某個開關那一行該有的內容。個人術語那一行在狀態後面多寫筆數。
private func toggleLine(_ toggle: SettingsToggle, isOn: Bool, termCount: Int = 0) -> String {
    let state = isOn ? on : off
    return field(
        toggle.title.text,
        toggle == .personalTerms ? UIText.diagnosticTermCount.text(state, termCount) : state
    )
}

@Test("診斷資訊是固定格式：標題、版本與架構、系統版本，接著每個設定各一行，順序不變")
func diagnosticReportHasFixedFormat() {
    let lines = report().components(separatedBy: "\n")
    var expected = [
        UIText.diagnosticTitle.text,
        UIText.diagnosticVersion.text("9.8.7", "arm64"),
        field("macOS", "Version 27.2 (Build 26C1234)"),
        field(UIText.settingsCangjieVersion.text, UIText.cangjieV3.text)
    ]
    // 預設值：半形標點、中文接詞與個人術語關閉，其餘開啟。
    let defaultsOff: Set<SettingsToggle> = [.halfwidthPunctuation, .chineseContinuation, .personalTerms]
    for toggle in SettingsToggle.allCases {
        expected.append(toggleLine(toggle, isOn: !defaultsOff.contains(toggle)))
    }
    #expect(lines.contains("英文個人術語補完：關（0 筆）"))
    #expect(lines.contains("中英混打模式：開"))
    expected += [
        field(UIText.diagnosticReadingScheme.text, UIText.readingSchemeDachen.text),
        field(UIText.settingsOverlayFontSize.text, UIText.overlayFontSizeMedium.text),
        field(UIText.statisticsToggle.text, off),
        field(UIText.settingsUpdateCheck.text, on)
    ]
    #expect(lines == expected)
    #expect(lines.count == 19)
}

@Test("每個開關、代別、反查方案、字級、統計與檢查更新的狀態都如實反映")
func diagnosticReportReflectsEverySetting() {
    for toggle in SettingsToggle.allCases {
        var configuration = EngineConfiguration()
        let before = toggle.isOn(in: configuration)
        toggle.set(!before, in: &configuration)
        let baseline = report().components(separatedBy: "\n")
        let changed = report(configuration).components(separatedBy: "\n")
        let differing = zip(baseline, changed).filter { $0 != $1 }
        // 只有那個開關的那一行變了，而且變成相反的狀態。
        #expect(differing.count == 1, "\(toggle.rawValue)")
        #expect(differing.first?.0 == toggleLine(toggle, isOn: before), "\(toggle.rawValue)")
        #expect(differing.first?.1 == toggleLine(toggle, isOn: !before), "\(toggle.rawValue)")
    }

    var configuration = EngineConfiguration()
    configuration.cangjieVersion = .v5
    configuration.readingScheme = .pinyin
    let lines = report(configuration, overlayFontSize: .large, updateCheckEnabled: false, statisticsEnabled: true)
        .components(separatedBy: "\n")
    #expect(lines.contains(field(UIText.settingsCangjieVersion.text, UIText.cangjieV5.text)))
    #expect(lines.contains(field(UIText.diagnosticReadingScheme.text, UIText.readingSchemePinyin.text)))
    #expect(lines.contains(field(UIText.settingsOverlayFontSize.text, UIText.overlayFontSizeLarge.text)))
    #expect(lines.contains(field(UIText.statisticsToggle.text, on)))
    #expect(lines.contains(field(UIText.settingsUpdateCheck.text, off)))
    #expect(report(overlayFontSize: .small).contains(
        field(UIText.settingsOverlayFontSize.text, UIText.overlayFontSizeSmall.text)))
}

@Test("個人術語只輸出開關與筆數，字詞本身不會出現在診斷資訊裡")
func diagnosticReportNeverLeaksPersonalTerms() {
    var configuration = EngineConfiguration()
    configuration.personalTermsEnabled = true
    configuration.personalTerms = PersonalTerms(["SecretInternalToken999", "kubectl", "Zeroconf"])
    #expect(configuration.personalTerms.words.count == 3)

    let text = report(configuration)
    #expect(!text.contains("SecretInternalToken999"))
    for word in configuration.personalTerms.words {
        #expect(!text.localizedCaseInsensitiveContains(word))
    }
    #expect(!text.contains("/Users/"))
    #expect(!text.contains(NSHomeDirectory()))
    #expect(!text.contains(NSUserName()))
    #expect(text.contains(field(
        UIText.settingsPersonalTerms.text, UIText.diagnosticTermCount.text(on, 3))))

    // 關著時清單裡有字詞也一樣不印，筆數照寫。
    configuration.personalTermsEnabled = false
    let disabled = report(configuration)
    #expect(!disabled.contains("SecretInternalToken999"))
    #expect(disabled.contains(field(
        UIText.settingsPersonalTerms.text, UIText.diagnosticTermCount.text(off, 3))))
}

@Test("這台電腦的架構是 arm64 或 x86_64，不是從打包的 App 執行時版本是 dev")
func diagnosticReportEnvironmentFallbacks() {
    #expect(["arm64", "x86_64"].contains(DiagnosticReport.architecture))
    #expect(DiagnosticReport.appVersion(infoDictionary: nil) == "dev")
    #expect(DiagnosticReport.appVersion(infoDictionary: [:]) == "dev")
    #expect(DiagnosticReport.appVersion(infoDictionary: ["CFBundleShortVersionString": "0.1.0"]) == "0.1.0")
}
