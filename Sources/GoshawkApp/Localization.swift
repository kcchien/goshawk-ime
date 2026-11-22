import Foundation

/// 輸入法自己的介面文字。原文是台灣繁體中文，英文翻譯放在套件的
/// `en.lproj/Localizable.strings`，鍵就是這裡的原文。
///
/// 每一段介面文字都必須是這個列舉的一個成員，`allCases` 才能當成翻譯的清單：
/// 打包驗證會拿它比對 `Localizable.strings`，少一條就失敗。
/// 注音符號、倉頡字根、候選字本身與按鍵名稱（`Tab`、`Return`）不翻譯。
enum UIText: String, CaseIterable {
    case productName = "蒼鷹輸入法 (Goshawk)"

    // 輸入法選單
    case menuPureEnglish = "純英文模式（雙擊 Shift）"
    case menuMixedMode = "中英混打模式"
    case menuAutoSpace = "中英與中數自動補空格"
    case menuHalfwidthPunctuation = "使用半形標點符號"
    case menuDeveloperVocabulary = "工程與程式英文詞庫"
    case menuCtrlBrackets = "Ctrl+[ ] 輸出全形引號"
    case menuClearHistory = "清除學習紀錄"
    case menuGuide = "使用指南與 30 秒練習…"
    case menuSettings = "設定…"
    case menuUpdateAvailable = "有新版 %1$@，前往下載…"

    // 讀音反查面板
    case readingLookup = "單字讀音反查"
    // 只支援標準（大千）排列，不需要區分排列，所以介面上直接叫「注音」。
    case readingSchemeDachen = "注音"
    case readingSchemePinyin = "拼音"
    case readingPromptDachen = "打注音查單字"
    case readingPromptPinyin = "打拼音查單字"
    case readingNoResults = "查無此讀音"
    case readingCodeMissing = "本代未收錄"
    case readingDirectInputUnavailable = "此碼無法正查"
    case readingHintsBrowsing = "↓ 選字  Tab 切換方案  Esc 關閉"
    case readingHintsSelecting = "1–9 選字  PgUp／PgDn 翻頁  Esc 關閉"
    case readingPageFooter = "第 %1$d 頁，共 %2$d 頁"
    case readingRowLabel = "第 %1$d 列，%2$@，字母碼 %3$@，字根 %4$@"
    case readingRowLabelMissing = "第 %1$d 列，%2$@，本代未收錄"
    /// VoiceOver 朗讀時串接各段用的分隔符。
    case listSeparator = "，"

    // 符號面板。符號與分組的名稱在符號表裡，不在這裡。
    case symbolPanel = "符號面板"
    case symbolTabRecent = "最近使用"
    case symbolTabPunctuation = "標點"
    case symbolTabSymbols = "符號"
    case symbolHints = "1–9 選取  ←→ 翻頁  Tab 切換分頁  Esc 關閉"
    case symbolRowLabel = "第 %1$d 列，%2$@，%3$@"

    // 一鍵反悔。送出後浮窗的提示，參數是對調後的字詞。
    case revertHint = "⇧空白 改成 %1$@"
    // 成對切換被擋下時浮窗閃一行的原因。
    case pairSwitchSpanUnsupported = "整段無法切換，請於開頭先選種類"
    case pairSwitchHostUnavailable = "此程式無法整對切換，請於開頭先選種類"

    /// 行內程式片段語境的浮窗標記。
    case snippetBadge = "片段"
    case continuationHint = "Option+Return 接上「%1$@」"
    case settingsChineseContinuation = "中文接詞（Option+Return 採用）"
    case settingsPersonalTerms = "英文個人術語補完"
    case settingsTermFormat = "輸入至少兩碼的英數詞，字首為字母"
    case settingsAddTerm = "加入"
    case settingsRemoveTerm = "移除"

    // 安裝。使用者在「Input Methods」以外的地方點兩下 App 時出現。
    case installQuestion = "要安裝蒼鷹輸入法嗎？"
    case installQuestionDetail = "會把蒼鷹複製到你的「資源庫／Input Methods」並加入輸入來源。只裝給目前這個使用者。"
    case installConfirm = "安裝"
    case installDone = "安裝完成"
    case installDoneDetail = "從選單列的輸入法選單選「蒼鷹輸入法」就能開始打字。選單裡沒有的話，到「系統設定」→「鍵盤」→「文字輸入」→「編輯」，按「＋」在「繁體中文」裡加入。"
    // 覆蓋既有版本時的完成說明：前面與全新安裝相同，後面多一句。系統可能還握著舊版的行程。
    case installUpgradeDoneDetail = "從選單列的輸入法選單選「蒼鷹輸入法」就能開始打字。選單裡沒有的話，到「系統設定」→「鍵盤」→「文字輸入」→「編輯」，按「＋」在「繁體中文」裡加入。升級後若仍看到舊版行為，請登出 Mac 再登入。"
    case installFailed = "安裝沒有完成"
    case installOpenGuide = "開啟 30 秒上手指南"
    case installClose = "好"

    // 倉頡代別
    case cangjieV5 = "倉頡五代"
    case cangjieV3 = "倉頡三代"

    // 設定視窗
    // 四個分頁的名稱是「一般」「標點與外觀」「快捷鍵」「關於」，也是視窗切到那一頁時的標題。
    case settingsTabGeneral = "一般"
    case settingsTabPunctuationAndAppearance = "標點與外觀"
    case settingsGroupInput = "輸入"
    case settingsGroupPunctuation = "標點符號"
    case settingsGroupAppearance = "外觀"
    case settingsGroupLearning = "學習"
    case settingsGroupReadingLookup = "讀音反查"
    case settingsGroupAbout = "關於"
    case settingsGroupUpdates = "更新"
    case settingsGroupHelp = "輔助說明"
    case settingsCangjieVersion = "倉頡代別"
    case settingsReadingScheme = "預設鍵盤方案"
    case settingsOverlayFontSize = "浮窗字體大小"
    case overlayFontSizeSmall = "小"
    case overlayFontSizeMedium = "標準"
    case overlayFontSizeLarge = "大"
    case settingsRevert = "送出後可用 Shift+空白 對調中英文、標點寬度或成對符號的種類"
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
    case settingsUpdateCheck = "自動檢查更新"
    case settingsUpdateCheckNote = "每天最多向 GitHub 查詢一次最新版本號，有新版時輸入法選單會多一列。查詢不含輸入內容與個人資料。"
    case settingsLicense = "原始碼採 MIT 授權。"
    case settingsThirdParty = "隨附詞庫各有來源與授權。"
    case settingsOpenThirdParty = "第三方授權聲明…"
    case settingsOpenGuide = "開啟使用指南與 30 秒練習"
    // 回報問題用的環境摘要。按鈕按下後標題短暫換成「已複製」。
    case settingsCopyDiagnostics = "複製診斷資訊"
    case settingsDiagnosticsCopied = "已複製"
    case settingsCopyDiagnosticsNote = "把版本、系統與各項設定的開關狀態複製到剪貼簿，方便回報問題時貼上。不含輸入內容、個人術語與學習紀錄。"
    // 診斷資訊的內容。各設定那幾行的標題沿用設定視窗的文字。
    case diagnosticTitle = "蒼鷹輸入法診斷資訊"
    /// 參數是版本號與處理器架構。
    case diagnosticVersion = "蒼鷹版本：%1$@（%2$@）"
    /// 參數是欄位名稱與它的值。
    case diagnosticField = "%1$@：%2$@"
    case diagnosticOn = "開"
    case diagnosticOff = "關"
    /// 參數是開關狀態與個人術語的筆數。只寫筆數，不寫字詞。
    case diagnosticTermCount = "%1$@（%2$d 筆）"
    case diagnosticReadingScheme = "讀音反查鍵盤方案"
    // 設定視窗的「快捷鍵」分頁。每一列是鍵帽與一句說明，只供閱讀。鍵帽上的按鍵名稱不翻譯，
    // 只有空白鍵與「[ 與 ]」中間那個字跟著語系。
    case settingsGroupShortcuts = "快捷鍵"
    case keycapSpace = "空白"
    case shortcutPairJoiner = "與"
    case shortcutSpaceSummary = "送出倉頡首選字（反引號片段內送出英文）"
    case shortcutTabSummary = "接受英文預測並補空格"
    case shortcutReturnSummary = "原樣送出已打字母，保留大小寫"
    case shortcutRevertSummary = "對調剛送出的中英文、標點全半形或成對符號"
    case shortcutSnippetSummary = "行內程式片段（英文優先、半形標點）"
    case shortcutPairSummary = "成對符號（八種可切換，結尾自動配對）"
    case shortcutLookupSummary = "單字讀音反查（注音與拼音）"
    case shortcutSymbolsSummary = "開啟符號面板"
    case statisticsTitle = "本機使用統計"
    case statisticsToggle = "在這台 Mac 記錄使用統計"
    case statisticsNote = "只保留最近 30 天的次數與耗時分布，不記輸入內容。取消勾選即可暫停。"
    case statisticsFileUnavailable = "目前暫停記錄，既有統計檔無法讀取。重新開啟設定可再試，或清除舊統計後重新開始。"
    case statisticsInspect = "檢視與匯出…"
    case statisticsErase = "清除統計…"
    case statisticsEraseQuestion = "要清除本機使用統計嗎？"
    case statisticsPreview = "預覽匯出內容…"
    case statisticsPreviewTitle = "即將匯出的統計資料"
    case statisticsSave = "儲存 JSON…"
    case statisticsEmpty = "最近 30 天尚無紀錄。"
    case statisticsTrack = "中英對調 %1$d／%2$d 次機會，暫存 %3$d 次、實交 %4$d 次、宿主拒絕 %5$d 次"
    case statisticsPunctuation = "標點對調 %1$d／%2$d 次機會，暫存 %3$d 次、實交 %4$d 次、宿主拒絕 %5$d 次"
    case statisticsSelection = "重碼選字共按 %1$d 次移動鍵，送出 %2$d 次"
    case statisticsEnglish = "英文候選第 1 至 9 名採用次數：%1$@。有英文候選的送出共 %2$d 次。"
    case statisticsLookup = "反查開啟 %1$d 次、翻頁 %2$d 次、選字 %3$d 次、取消 %4$d 次"
    case statisticsLatency = "%1$@（%2$d 次）P95 %3$@，P99 %4$@"
    case statisticsComposing = "一般組字"
    case statisticsCommit = "文字送出"
    case statisticsContinuations = "中文接詞採用 %1$d 次，浮窗提示 %2$d 次。"
    case statisticsPersonalTerms = "採用浮窗上的個人術語 %1$d 次，送出的組字中曾顯示個人術語 %2$d 次。"

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

    /// 符號表自帶中英兩欄名稱，不查翻譯表。介面走英文翻譯時挑英文那一欄。
    var usesEnglishNames: Bool { !strings.isEmpty }

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
