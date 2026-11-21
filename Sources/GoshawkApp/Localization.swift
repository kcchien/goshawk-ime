import Foundation

/// 輸入法自己的介面文字。原文是台灣繁體中文，英文翻譯放在套件的
/// `en.lproj/Localizable.strings`，鍵就是這裡的原文。
///
/// 每一段介面文字都必須是這個列舉的一個成員，`allCases` 才能當成翻譯的清單：
/// 打包驗證會拿它比對 `Localizable.strings`，少一條就失敗。
/// 注音符號、倉頡字根、候選字本身與按鍵名稱（`Tab`、`Enter`）不翻譯。
enum UIText: String, CaseIterable {
    case productName = "蒼鷹輸入法 (Goshawk)"

    // 輸入法選單
    case menuPureEnglish = "純英文模式（雙擊 Shift）"
    case menuMixedMode = "中英混打模式"
    case menuAutoSpace = "中英與中數自動補空格"
    case menuHalfwidthPunctuation = "使用半形標點符號"
    case menuDeveloperVocabulary = "工程與程式英文詞庫"
    case menuCtrlBrackets = "Ctrl + [ ] 輸出全形引號"
    case menuClearHistory = "清除學習紀錄"
    case menuSettings = "設定…"

    // 讀音反查面板
    case readingLookup = "單字讀音反查"
    // 只支援標準（大千）排列，不需要區分排列，所以介面上直接叫「注音」。
    case readingSchemeDachen = "注音"
    case readingSchemePinyin = "拼音"
    case readingPromptDachen = "打注音查單字"
    case readingPromptPinyin = "打拼音查單字"
    case readingNoResults = "查無此讀音"
    case readingCodeMissing = "本代未收錄"
    case readingHintsBrowsing = "↓ 選字  Tab 切換方案  Esc 關閉"
    case readingHintsSelecting = "1–9 選字  PgUp／PgDn 翻頁  Esc 關閉"
    case readingPageFooter = "第 %1$d 頁，共 %2$d 頁"
    case readingRowLabel = "第 %1$d 列，%2$@，字母碼 %3$@，字根 %4$@"
    case readingRowLabelMissing = "第 %1$d 列，%2$@，本代未收錄"
    /// VoiceOver 朗讀時串接各段用的分隔符。
    case listSeparator = "，"

    // 一鍵反悔。送出後浮窗的提示，參數是對調後的字詞。
    case revertHint = "⇧空白 改成 %1$@"

    /// 行內程式片段語境的浮窗標記。
    case snippetBadge = "片段"

    // 安裝。使用者在「Input Methods」以外的地方點兩下 App 時出現。
    case installQuestion = "要安裝蒼鷹輸入法嗎？"
    case installQuestionDetail = "會把蒼鷹複製到你的「資源庫／Input Methods」並加入輸入來源。只裝給目前這個使用者。"
    case installConfirm = "安裝"
    case installDone = "安裝完成"
    case installDoneDetail = "從選單列的輸入法選單選「蒼鷹輸入法」就能開始打字。選單裡沒有的話，到「系統設定」→「鍵盤」→「文字輸入」→「編輯」，按「＋」在「繁體中文」裡加入。"
    case installFailed = "安裝沒有完成"
    case installClose = "好"

    // 倉頡代別
    case cangjieV5 = "倉頡五代"
    case cangjieV3 = "倉頡三代"

    // 設定視窗
    case settingsTitle = "蒼鷹輸入法設定"
    case settingsGroupInput = "輸入"
    case settingsGroupTypography = "排版與標點"
    case settingsGroupLearning = "學習"
    case settingsGroupReadingLookup = "讀音反查"
    case settingsGroupAbout = "關於"
    case settingsCangjieVersion = "倉頡代別"
    case settingsReadingScheme = "預設鍵盤方案"
    case settingsRevert = "送出後可用 Shift+空白 對調中英文或標點寬度"
    case settingsLearnEnglish = "依使用習慣調整英文預測"
    case settingsLearnCangjie = "依使用習慣調整倉頡重碼順序"
    case settingsLearnCangjieNote = "關閉後同一組按鍵永遠送出同一個字。"
    case settingsLearnReading = "依使用習慣調整讀音反查順序"
    case settingsLearningStorageNote = "學習紀錄只存在這台電腦，不會上傳。"
    case settingsClearHistory = "清除學習紀錄…"
    case settingsClearHistoryQuestion = "要清除學習紀錄嗎？"
    case settingsClearHistoryDetail = "英文預測、倉頡重碼與讀音反查的順序都會回到預設。這個動作無法還原。"
    case settingsClearHistoryConfirm = "清除"
    case settingsCancel = "取消"
    case settingsVersion = "版本 %1$@"
    case settingsLicense = "原始碼採 MIT 授權。"
    case settingsThirdParty = "隨附詞庫的來源與授權見 THIRD_PARTY_NOTICES.md。"
    case settingsOpenThirdParty = "開啟 THIRD_PARTY_NOTICES.md"

    /// 目前語系下的文字。查不到翻譯就是原文。
    var text: String {
        Localization.current.text(for: rawValue)
    }

    /// 帶參數的文字。原文裡的 `%1$d`、`%2$@` 依位置填入，翻譯可以換順序。
    func text(_ arguments: any CVarArg...) -> String {
        String(format: text, arguments: arguments)
    }
}

/// 介面文字的查表。中文走原文不查表，英文查 `en.lproj/Localizable.strings`。
struct Localization: Sendable {
    /// InputMethodKit 的事件、選單動作與設定視窗都在主執行緒，沒有並行存取。
    nonisolated(unsafe) static var current = Localization.resolved()

    /// 鍵是中文原文。空的表示用原文，也就是中文。
    private let strings: [String: String]

    init(strings: [String: String] = [:]) {
        self.strings = strings
    }

    func text(for key: String) -> String {
        strings[key] ?? key
    }

    /// 套件裡的英文翻譯表。沒有套件包（`swift run`）時為 nil。
    static func englishStrings(in bundle: Bundle = .main) -> [String: String]? {
        guard let url = bundle.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: "en.lproj"
        ) else {
            return nil
        }
        return NSDictionary(contentsOf: url) as? [String: String]
    }

    /// 依套件協商出的語系挑選。`GOSHAWK_UI_LANGUAGE` 可強制，截圖與自我檢查用它。
    static func resolved(in bundle: Bundle = .main) -> Localization {
        let requested = ProcessInfo.processInfo.environment["GOSHAWK_UI_LANGUAGE"]
            ?? bundle.preferredLocalizations.first
            ?? "en"
        guard requested.hasPrefix("en") else {
            return Localization()
        }
        return Localization(strings: englishStrings(in: bundle) ?? [:])
    }
}
