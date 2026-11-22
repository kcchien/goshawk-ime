import Foundation
import GoshawkCore

/// 回報問題時貼上的環境摘要。設定視窗「關於」的「複製診斷資訊」把它放進剪貼簿。
///
/// 內容是白名單：只有版本、架構、系統版本與各項設定的狀態，每一行都由 `build` 逐項寫出。
/// 個人術語只寫開關與筆數，字詞、學習紀錄、最近使用的符號、使用統計與打字內容一律不放。
/// 要加欄位就在 `build` 加一行，不要把整個設定或偏好倒出來。
enum DiagnosticReport {
    static func build(
        appVersion: String,
        architecture: String,
        osVersion: String,
        configuration: EngineConfiguration,
        overlayFontSize: OverlayFontSize,
        updateCheckEnabled: Bool,
        statisticsEnabled: Bool
    ) -> String {
        func state(_ isOn: Bool) -> String {
            (isOn ? UIText.diagnosticOn : UIText.diagnosticOff).text
        }
        func field(_ label: String, _ value: String) -> String {
            UIText.diagnosticField.text(label, value)
        }

        var lines = [
            UIText.diagnosticTitle.text,
            UIText.diagnosticVersion.text(appVersion, architecture),
            field("macOS", osVersion),
            field(
                UIText.settingsCangjieVersion.text,
                (configuration.cangjieVersion == .v3 ? UIText.cangjieV3 : UIText.cangjieV5).text
            )
        ]
        // 標題與設定視窗的核取方塊相同，回報的人對得上自己看到的畫面。
        for toggle in SettingsToggle.allCases {
            var value = state(toggle.isOn(in: configuration))
            if toggle == .personalTerms {
                value = UIText.diagnosticTermCount.text(value, configuration.personalTerms.words.count)
            }
            lines.append(field(toggle.title.text, value))
        }
        lines += [
            field(
                UIText.diagnosticReadingScheme.text,
                (configuration.readingScheme == .dachen ? UIText.readingSchemeDachen : UIText.readingSchemePinyin).text
            ),
            field(UIText.settingsOverlayFontSize.text, overlayFontSize.title.text),
            field(UIText.statisticsToggle.text, state(statisticsEnabled)),
            field(UIText.settingsUpdateCheck.text, state(updateCheckEnabled))
        ]
        return lines.joined(separator: "\n")
    }

    /// 目前執行的這一份是哪個架構。通用執行檔在 Rosetta 下回報 `x86_64`，那就是實際在跑的那一份。
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    /// 版本號由建置腳本寫進套件資訊。不是從打包的 App 執行時讀不到，寫成 `dev`。
    static func appVersion(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
