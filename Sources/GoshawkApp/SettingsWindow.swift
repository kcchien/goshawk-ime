import AppKit
import Foundation
import GoshawkCore

/// 偏好改變後通知目前作用中的控制器重新載入。系統會為每個宿主程式各建一個控制器，
/// 設定視窗只寫偏好，靠這個通知讓作用中的那個跟上。
extension Notification.Name {
    static let goshawkPreferencesDidChange = Notification.Name("goshawk.preferencesDidChange")
}

/// 設定視窗裡的每個布林開關。這張表同時決定標題、分組與它對應的設定欄位，
/// 新增一個開關只要加一個成員，視窗與自我檢查都會自動涵蓋它。
enum SettingsToggle: String, CaseIterable {
    case mixedMode
    case developerVocabulary
    case chineseContinuation
    case personalTerms
    case revert
    case autoSpace
    case halfwidthPunctuation
    case ctrlBrackets
    case learnsEnglishPredictions
    case learnsCangjieOrder
    case learnsReadingLookupOrder

    var group: UIText {
        switch self {
        case .mixedMode, .developerVocabulary, .revert, .chineseContinuation, .personalTerms, .autoSpace:
            return .settingsGroupInput
        case .halfwidthPunctuation, .ctrlBrackets:
            return .settingsGroupPunctuation
        case .learnsEnglishPredictions, .learnsCangjieOrder, .learnsReadingLookupOrder:
            return .settingsGroupLearning
        }
    }

    var title: UIText {
        switch self {
        case .chineseContinuation: return .settingsChineseContinuation
        case .personalTerms: return .settingsPersonalTerms
        case .mixedMode:
            return .menuMixedMode
        case .developerVocabulary:
            return .menuDeveloperVocabulary
        case .revert:
            return .settingsRevert
        case .autoSpace:
            return .menuAutoSpace
        case .halfwidthPunctuation:
            return .menuHalfwidthPunctuation
        case .ctrlBrackets:
            return .menuCtrlBrackets
        case .learnsEnglishPredictions:
            return .settingsLearnEnglish
        case .learnsCangjieOrder:
            return .settingsLearnCangjie
        case .learnsReadingLookupOrder:
            return .settingsLearnReading
        }
    }

    /// 勾選狀態。「使用半形標點符號」與 `autoPunctuationEnabled` 共用偏好，狀態取反。
    func isOn(in configuration: EngineConfiguration) -> Bool {
        switch self {
        case .chineseContinuation: return configuration.chineseContinuationEnabled
        case .personalTerms: return configuration.personalTermsEnabled
        case .mixedMode:
            return configuration.mixedModeEnabled
        case .developerVocabulary:
            return configuration.developerVocabularyEnabled
        case .revert:
            return configuration.revertEnabled
        case .autoSpace:
            return configuration.autoSpaceEnabled
        case .halfwidthPunctuation:
            return !configuration.autoPunctuationEnabled
        case .ctrlBrackets:
            return configuration.ctrlBracketsQuotesEnabled
        case .learnsEnglishPredictions:
            return configuration.learnsEnglishPredictions
        case .learnsCangjieOrder:
            return configuration.learnsCangjieOrder
        case .learnsReadingLookupOrder:
            return configuration.learnsReadingLookupOrder
        }
    }

    func set(_ isOn: Bool, in configuration: inout EngineConfiguration) {
        switch self {
        case .chineseContinuation: configuration.chineseContinuationEnabled = isOn
        case .personalTerms: configuration.personalTermsEnabled = isOn
        case .mixedMode:
            configuration.mixedModeEnabled = isOn
        case .developerVocabulary:
            configuration.developerVocabularyEnabled = isOn
        case .revert:
            configuration.revertEnabled = isOn
        case .autoSpace:
            configuration.autoSpaceEnabled = isOn
        case .halfwidthPunctuation:
            configuration.autoPunctuationEnabled = !isOn
        case .ctrlBrackets:
            configuration.ctrlBracketsQuotesEnabled = isOn
        case .learnsEnglishPredictions:
            configuration.learnsEnglishPredictions = isOn
        case .learnsCangjieOrder:
            configuration.learnsCangjieOrder = isOn
        case .learnsReadingLookupOrder:
            configuration.learnsReadingLookupOrder = isOn
        }
    }
}

/// 設定視窗的分頁，成員的順序就是分頁的順序。
enum SettingsTab: CaseIterable {
    case general
    case punctuationAndAppearance
    case shortcuts
    case about

    var title: UIText {
        switch self {
        case .general: return .settingsTabGeneral
        case .punctuationAndAppearance: return .settingsTabPunctuationAndAppearance
        case .shortcuts: return .settingsGroupShortcuts
        case .about: return .settingsGroupAbout
        }
    }

    /// 工具列上那一項的系統圖示（SF Symbols）。
    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        // 不用 textformat 這類會跟著系統語言換樣子的圖示：中文系統會把它畫成「格式」兩個字。
        case .punctuationAndAppearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .about: return "info.circle"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("goshawk.settings.\(self)")
    }
}

/// 一顆鍵帽。`glyph` 是鍵盤上印的符號，`name` 是按鍵名稱，也是 VoiceOver 讀出的內容。
struct KeyCap: Equatable {
    let glyph: String?
    let name: String

    var display: String { glyph.map { "\($0) \(name)" } ?? name }

    static let shift = KeyCap(glyph: "⇧", name: "Shift")
    static let control = KeyCap(glyph: "⌃", name: "Ctrl")
    static let option = KeyCap(glyph: "⌥", name: "Option")
    static let tab = KeyCap(glyph: "⇥", name: "Tab")
    /// 用 Mac 鍵盤上的叫法，設定視窗裡提到這顆鍵的文字也一律寫 Return。
    static let returnKey = KeyCap(glyph: "↩", name: "Return")
    static var space: KeyCap { KeyCap(glyph: "␣", name: UIText.keycapSpace.text) }
    static func character(_ character: String) -> KeyCap { KeyCap(glyph: nil, name: character) }
}

/// 設定視窗「快捷鍵」分頁的每一列，成員的順序就是顯示的順序。只供閱讀，不對應任何偏好。
enum ShortcutHint: CaseIterable {
    case space
    case tab
    case returnKey
    case revert
    case snippet
    case pair
    case readingLookup
    case symbolPanel

    /// 一鍵一帽，組合鍵拆開。
    var keys: [KeyCap] {
        switch self {
        case .space: return [.space]
        case .tab: return [.tab]
        case .returnKey: return [.returnKey]
        case .revert: return [.shift, .space]
        case .snippet: return [.character("`"), .character("`")]
        case .pair: return [.character("["), .character("]")]
        case .readingLookup: return [.control, .shift, .character(";")]
        case .symbolPanel: return [.option, .shift, .character("B")]
        }
    }

    /// 鍵帽之間的連接文字。一起按的是 `+`，其餘兩列不是組合鍵。
    var joiner: String {
        switch self {
        case .snippet: return "⋯"
        case .pair: return UIText.shortcutPairJoiner.text
        default: return "+"
        }
    }

    var summary: UIText {
        switch self {
        case .space: return .shortcutSpaceSummary
        case .tab: return .shortcutTabSummary
        case .returnKey: return .shortcutReturnSummary
        case .revert: return .shortcutRevertSummary
        case .snippet: return .shortcutSnippetSummary
        case .pair: return .shortcutPairSummary
        case .readingLookup: return .shortcutLookupSummary
        case .symbolPanel: return .shortcutSymbolsSummary
        }
    }
}

private final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

/// 設定視窗的文字標籤。系統的標籤在文字左右各留 2 點，照外框對齊時文字會比核取方塊與按鈕的左緣偏右；
/// 這裡把對齊用的範圍改成文字本身，同一頁的文字與控制項才是同一條左緣。
final class SettingsLabel: NSTextField {
    static let textPadding: CGFloat = 2

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: Self.textPadding, bottom: 0, right: Self.textPadding)
    }
}

/// 一句說明文字與它的縮排。分組排版時認得它，讓它貼近上面那個它所說明的控制項。
private final class NoteRow: NSStackView {}

/// 圓角邊框的鍵帽。顏色都取系統的動態色，在畫的時候才解析，深色與「增加對比」不必另外處理。
final class KeyCapView: NSView {
    let key: KeyCap

    init(_ key: KeyCap) {
        self.key = key
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(key.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 只有一個字元的鍵（標點與字母）。
    private var isSingleCharacter: Bool { key.glyph == nil && key.name.count == 1 }

    private var title: NSAttributedString {
        // 單一字元的鍵放大一級，分號這類小符號才看得清楚。反引號的字形只占字高的一小塊，
        // 用系統字體幾乎看不出來，所以改用等寬字體再放大。
        let font: NSFont
        if key.name == "`" {
            font = .monospacedSystemFont(ofSize: 22, weight: .bold)
        } else {
            font = .systemFont(ofSize: isSingleCharacter ? 13 : 12, weight: .medium)
        }
        return NSAttributedString(string: key.display, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(26, ceil(title.size().width) + 14), height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor.controlColor.setFill()
        path.fill()
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        (highContrast ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
        let text = title
        let size = text.size()
        var origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        if key.name == "`" {
            // 反引號的墨跡貼在字高的頂端，照行高置中會偏上，所以照實際畫出來的範圍置中。
            let ink = text.boundingRect(with: size, options: [.usesDeviceMetrics])
            origin = NSPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        }
        text.draw(at: origin)
    }
}

/// 輸入法的設定視窗。選單的「設定…」開它，同一時間只有一個。
/// 每個控制項直接讀寫 `PreferencesStore`，存完就發通知讓作用中的控制器重新載入。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    let window: NSWindow
    /// 每個分頁的內容與它排好之後的大小。沒被選到的分頁不在視窗的視圖階層裡，所以分開記。
    private(set) var pages: [SettingsTab: (view: NSView, size: NSSize)] = [:]
    private(set) var selectedTab: SettingsTab = .general
    /// 自我檢查用：每個分頁的分組標題，以及每句說明和它所說明的核取方塊（沒有就是 nil）。
    private(set) var groupTitles: [SettingsTab: [NSTextField]] = [:]
    private(set) var notes: [(note: NSTextField, checkbox: NSButton?)] = []
    let appIconView = NSImageView()
    let thirdPartyButton = NSButton()
    /// 自我檢查與截圖用：每個開關的核取方塊。
    private(set) var checkboxes: [SettingsToggle: NSButton] = [:]
    /// 自我檢查用：快捷鍵分頁每一列的鍵帽與說明。
    private(set) var shortcutFields: [ShortcutHint: (keys: [KeyCapView], summary: NSTextField)] = [:]
    let personalTermField = NSComboBox()
    let addTermButton = NSButton()
    let removeTermButton = NSButton()
    private(set) var cangjieVersionControl = NSPopUpButton()
    private(set) var readingSchemeControl = NSPopUpButton()
    /// 選項的順序就是 `OverlayFontSize.allCases` 的順序。
    private(set) var overlayFontSizeControl = NSPopUpButton()

    private let preferences: PreferencesStore
    private let usageStore: UsageHistoryStore
    private let clearHistoryButton = NSButton()
    let guideButton = NSButton()
    let statisticsControls: StatisticsSettings
    let updateCheckbox = NSButton()
    private let updates: UpdateChecker
    let copyDiagnosticsButton = NSButton()
    private let statistics: LocalUsageStatistics
    /// 診斷資訊寫到哪個剪貼簿。自我檢查換成自己的，不蓋掉使用者剪貼簿裡的東西。
    private let pasteboard: NSPasteboard
    private var diagnosticsFeedbackTimer: Timer?

    init(preferences: PreferencesStore = PreferencesStore(), usageStore: UsageHistoryStore = .shared,
         statistics: LocalUsageStatistics = .shared, updates: UpdateChecker = .shared,
         pasteboard: NSPasteboard = .general) {
        statisticsControls = StatisticsSettings(store: statistics, note: Self.note(text: ""))
        self.statistics = statistics
        self.pasteboard = pasteboard
        self.updates = updates
        self.preferences = preferences
        self.usageStore = usageStore
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.delegate = self

        for tab in SettingsTab.allCases {
            currentTab = tab
            pages[tab] = buildPage(tab)
        }
        // 系統內建 App 的設定視窗那種工具列：標題列下方一排圖示加文字，選到的那一項有底色，
        // 視窗標題就是那一頁的名稱。
        let toolbar = NSToolbar(identifier: "goshawk.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        // macOS 15 起工具列的右鍵選單可以改顯示模式；設定視窗的工具列就是分頁，固定圖示加文字。
        if #available(macOS 15.0, *) {
            toolbar.allowsDisplayModeCustomization = false
        }
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        window.contentView = TopAlignedView()
        select(.general)
        window.center()
        reloadFromPreferences()
    }

    /// 排版當下正在建的那一頁，分組標題記到它名下。
    private var currentTab: SettingsTab = .general

    /// 換到這個分頁：換掉視窗內容，標題改成分頁名稱，視窗跟著那一頁的高度調整，標題列留在原位。
    /// 新的一頁先放進內容區、釘在上緣，再調視窗大小，高度動畫的期間看到的就是新的一頁，不會是空白。
    func select(_ tab: SettingsTab) {
        guard let page = pages[tab], let container = window.contentView else { return }
        selectedTab = tab
        window.toolbar?.selectedItemIdentifier = tab.toolbarIdentifier
        window.title = tab.title.text
        container.subviews.forEach { $0.removeFromSuperview() }
        // 內容區是翻轉座標，原點在左上角；不跟著內容區縮放，視窗變高變矮時這一頁都貼著上緣。
        page.view.frame = NSRect(origin: .zero, size: page.size)
        page.view.autoresizingMask = []
        container.addSubview(page.view)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize(for: tab)))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    /// 視窗內容區在這個分頁的大小：寬度每頁相同，高度剛好放完那一頁，所以每一頁都不必捲動。
    func contentSize(for tab: SettingsTab) -> NSSize {
        NSSize(width: Self.pageWidth, height: pages[tab]?.size.height ?? 0)
    }

    @objc private func toolbarItemChosen(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarIdentifier == sender.itemIdentifier }) else {
            return
        }
        select(tab)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab.allCases.first(where: { $0.toolbarIdentifier == itemIdentifier }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title.text
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil)
        item.target = self
        item.action = #selector(toolbarItemChosen(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map(\.toolbarIdentifier)
    }

    /// 顯示視窗。輸入法是背景程式，必須先讓自己成為作用中的程式，視窗才拿得到鍵盤焦點。
    func show() {
        NSApp.setActivationPolicy(.accessory)
        reloadFromPreferences()
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 關閉後把作用中的程式交還給使用者原本在用的那個。
    func windowWillClose(_ notification: Notification) {
        NSApp.hide(nil)
    }

    // MARK: - 讀寫偏好

    func reloadFromPreferences() {
        statisticsControls.reload()
        updateCheckbox.state = updates.isEnabled ? .on : .off
        let configuration = preferences.loadConfiguration()
        reloadTermChoices(configuration.personalTerms)
        for (toggle, checkbox) in checkboxes {
            checkbox.state = toggle.isOn(in: configuration) ? .on : .off
        }
        updatePersonalTermControls()
        cangjieVersionControl.selectItem(at: configuration.cangjieVersion == .v3 ? 0 : 1)
        readingSchemeControl.selectItem(at: configuration.readingScheme == .dachen ? 0 : 1)
        overlayFontSizeControl.selectItem(
            at: OverlayFontSize.allCases.firstIndex(of: preferences.loadOverlayFontSize()) ?? 0
        )
    }

    private func apply(_ change: (inout EngineConfiguration) -> Void) {
        var configuration = preferences.loadConfiguration()
        change(&configuration)
        preferences.save(configuration)
        NotificationCenter.default.post(name: .goshawkPreferencesDidChange, object: nil)
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let toggle = SettingsToggle.allCases.first(where: { checkboxes[$0] === sender }) else {
            return
        }
        apply { toggle.set(sender.state == .on, in: &$0) }
        updatePersonalTermControls()
    }

    /// 個人術語的欄位與兩顆按鈕只在補完開著時可用，關著時一看就知道改了也不會作用。
    private func updatePersonalTermControls() {
        let isOn = checkboxes[.personalTerms]?.state == .on
        for control in [personalTermField, addTermButton, removeTermButton] as [NSControl] {
            control.isEnabled = isOn
        }
    }

    private func reloadTermChoices(_ terms: PersonalTerms) {
        personalTermField.removeAllItems()
        personalTermField.addItems(withObjectValues: terms.words)
        personalTermField.stringValue = ""
    }

    @objc private func editPersonalTerm(_ sender: NSButton) {
        let word = personalTermField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PersonalTerms.isValid(word) else {
            NSSound.beep()
            return
        }
        apply {
            var words = $0.personalTerms.words.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
            if sender === addTermButton { words.append(word) }
            $0.personalTerms = PersonalTerms(words)
            reloadTermChoices($0.personalTerms)
        }
    }

    @objc private func cangjieVersionChanged(_ sender: NSPopUpButton) {
        let version: CangjieVersion = sender.indexOfSelectedItem == 0 ? .v3 : .v5
        apply { $0.cangjieVersion = version }
    }

    @objc private func readingSchemeChanged(_ sender: NSPopUpButton) {
        let scheme: PhoneticScheme = sender.indexOfSelectedItem == 0 ? .dachen : .pinyin
        apply { $0.readingScheme = scheme }
    }

    /// 字級不在引擎設定裡，所以自己存，再發同一個通知讓作用中的控制器套用到浮窗。
    @objc private func overlayFontSizeChanged(_ sender: NSPopUpButton) {
        guard OverlayFontSize.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences.saveOverlayFontSize(OverlayFontSize.allCases[sender.indexOfSelectedItem])
        NotificationCenter.default.post(name: .goshawkPreferencesDidChange, object: nil)
    }

    @objc private func clearHistory(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = UIText.settingsClearHistoryQuestion.text
        alert.informativeText = UIText.settingsClearHistoryDetail.text
        alert.addButton(withTitle: UIText.settingsClearHistoryConfirm.text)
        alert.addButton(withTitle: UIText.settingsCancel.text)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        do { try usageStore.clear() } catch { NSAlert(error: error).runModal() }
    }

    @objc private func updateCheckChanged(_ sender: NSButton) {
        updates.isEnabled = sender.state == .on
    }

    @objc private func openThirdPartyNotices(_ sender: Any?) {
        guard let url = Self.thirdPartyNoticesURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openGuide(_ sender: Any?) {
        GuideLauncher.open()
    }

    /// 「已複製」在按鈕上停留多久。
    static let diagnosticsFeedbackLifetime: TimeInterval = 1.5

    /// 現在這份偏好的診斷資訊。只在按下按鈕時組，不存檔也不連網。
    var diagnosticReport: String {
        DiagnosticReport.build(
            appVersion: DiagnosticReport.appVersion(),
            architecture: DiagnosticReport.architecture,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            configuration: preferences.loadConfiguration(),
            overlayFontSize: preferences.loadOverlayFontSize(),
            updateCheckEnabled: updates.isEnabled,
            statisticsEnabled: statistics.enabled
        )
    }

    /// 複製後不跳對話框：按鈕標題換成「已複製」，過一會兒自己換回來。
    @objc private func copyDiagnostics(_ sender: Any?) {
        pasteboard.clearContents()
        guard pasteboard.setString(diagnosticReport, forType: .string) else {
            NSSound.beep()
            return
        }
        copyDiagnosticsButton.title = UIText.settingsDiagnosticsCopied.text
        diagnosticsFeedbackTimer?.invalidate()
        let timer = Timer(timeInterval: Self.diagnosticsFeedbackLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.copyDiagnosticsButton.title = UIText.settingsCopyDiagnostics.text
                self?.diagnosticsFeedbackTimer = nil
            }
        }
        diagnosticsFeedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    static var thirdPartyNoticesURL: URL? {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
    }

    static var versionText: String {
        // 版本號由建置腳本從根目錄的 VERSION 寫進套件資訊。不是從打包的 App 執行時讀不到，顯示佔位的 0.0.0。
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return UIText.settingsVersion.text(version)
    }

    // MARK: - 版面

    /// 每個分頁內容的固定寬度。寬度固定，說明文字才知道要在哪裡換行；放不下的標題換行，不截斷。
    static let pageWidth: CGFloat = 520
    /// 系統標準間距：視窗邊距 20，分組之間 20，控制項之間 8，說明與它所說明的控制項之間 4。
    private static let windowMargin: CGFloat = 20
    private static let groupSpacing: CGFloat = 20
    private static let controlSpacing: CGFloat = 8
    private static let noteSpacing: CGFloat = 4
    private static let pageInsets = NSEdgeInsets(
        top: windowMargin, left: windowMargin, bottom: windowMargin, right: windowMargin
    )
    /// 分組的寬度，也是一列控制項最多能用的寬度。
    static let groupWidth: CGFloat = pageWidth - pageInsets.left - pageInsets.right
    /// 核取方塊的標題離方塊左緣多遠。附屬在核取方塊底下的說明與欄位縮排這麼多，才會對齊標題的文字。
    static let checkboxTitleIndent: CGFloat = {
        let sample = NSButton(checkboxWithTitle: "x", target: nil, action: nil)
        let bounds = NSRect(origin: .zero, size: sample.fittingSize)
        let title = sample.cell?.titleRect(forBounds: bounds).minX ?? 20
        return ceil(title - sample.alignmentRectInsets.left)
    }()

    private func buildPage(_ tab: SettingsTab) -> (view: NSView, size: NSSize) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.groupSpacing
        stack.edgeInsets = Self.pageInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        for group in groups(in: tab) {
            stack.addArrangedSubview(group)
        }

        // 只釘左上角與寬度，高度由內容決定。
        let root = TopAlignedView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.pageWidth)
        ])
        return (root, stack.fittingSize)
    }

    private func groups(in tab: SettingsTab) -> [NSView] {
        switch tab {
        case .general:
            let cangjieVersion = labelled(
                .settingsCangjieVersion,
                control: popUp(
                    cangjieVersionControl,
                    titles: [.cangjieV3, .cangjieV5],
                    action: #selector(cangjieVersionChanged(_:))
                )
            )
            // 「只存在這台電腦」說的是上面三個學習開關，所以接在最後一個開關底下，與另一句說明同一條左緣。
            return [
                box(.settingsGroupInput, rows: [cangjieVersion] + toggleRows(in: .settingsGroupInput)),
                box(.settingsGroupLearning, rows: toggleRows(in: .settingsGroupLearning) + [
                    [note(.settingsLearningStorageNote, under: checkboxes[.learnsReadingLookupOrder])],
                    [button(clearHistoryButton, title: .settingsClearHistory, action: #selector(clearHistory(_:)))]
                ])
            ]
        case .punctuationAndAppearance:
            return [
                box(.settingsGroupPunctuation, rows: toggleRows(in: .settingsGroupPunctuation)),
                box(.settingsGroupReadingLookup, rows: [labelled(
                    .settingsReadingScheme,
                    control: popUp(
                        readingSchemeControl,
                        titles: [.readingSchemeDachen, .readingSchemePinyin],
                        action: #selector(readingSchemeChanged(_:))
                    )
                )]),
                box(.settingsGroupAppearance, rows: [labelled(
                    .settingsOverlayFontSize,
                    control: popUp(
                        overlayFontSizeControl,
                        titles: OverlayFontSize.allCases.map(\.title),
                        action: #selector(overlayFontSizeChanged(_:))
                    )
                )])
            ]
        case .shortcuts:
            return [shortcutTable()]
        case .about:
            updateCheckbox.setButtonType(.switch)
            updateCheckbox.title = UIText.settingsUpdateCheck.text
            updateCheckbox.target = self
            updateCheckbox.action = #selector(updateCheckChanged(_:))
            updateCheckbox.setAccessibilityLabel(UIText.settingsUpdateCheck.text)
            return [
                identityHeader(),
                box(.settingsGroupUpdates, rows: [
                    [updateCheckbox], [note(.settingsUpdateCheckNote, under: updateCheckbox)]
                ]),
                // 兩顆按鈕各占一列，「複製診斷資訊」的說明緊接在它自己底下，不會被看成也在說明使用指南。
                box(.settingsGroupHelp, rows: [
                    [button(guideButton, title: .settingsOpenGuide, action: #selector(openGuide(_:)))],
                    [button(copyDiagnosticsButton, title: .settingsCopyDiagnostics, action: #selector(copyDiagnostics(_:)))],
                    [note(.settingsCopyDiagnosticsNote)]
                ]),
                box(.statisticsTitle, rows: [
                    [statisticsControls.toggle],
                    [noteRow(statisticsControls.note, under: statisticsControls.toggle)],
                    [statisticsControls.inspect, statisticsControls.erase]
                ])
            ]
        }
    }

    /// 套件自己的圖示。不是從打包的 App 執行時讀不到，改用系統預設的 App 圖示。
    static var appIcon: NSImage {
        if let name = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String,
           let image = Bundle.main.image(forResource: name) {
            return image
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    /// 「關於」最上面那一段，照系統「關於」面板的層次：圖示、產品名稱、版本，再來是授權。
    /// 靠左排，圖示的外框與底下各分組同一條左緣；圖示資源本身四周有透明留白，
    /// 所以看得到的圖案比分組標題略往內縮，那是資源的正常留白，不另外移動。
    private func identityHeader() -> NSView {
        appIconView.image = Self.appIcon
        appIconView.imageScaling = .scaleProportionallyUpOrDown
        // 圖示只是裝飾，產品名稱就在旁邊，VoiceOver 不必再讀一次。
        appIconView.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            appIconView.widthAnchor.constraint(equalToConstant: Self.appIconSize),
            appIconView.heightAnchor.constraint(equalToConstant: Self.appIconSize)
        ])
        let textWidth = Self.groupWidth - Self.appIconSize - Self.identitySpacing
        let name = label(UIText.productName.text, font: .systemFont(ofSize: 15, weight: .semibold))
        let version = Self.note(text: Self.versionText)
        let license = Self.note(text: UIText.settingsLicense.text)
        let thirdParty = Self.note(text: UIText.settingsThirdParty.text)
        for field in [version, license, thirdParty] {
            field.preferredMaxLayoutWidth = textWidth
            notes.append((field, nil))
        }
        let text = NSStackView(views: [name, version, license, thirdParty])
        if Self.thirdPartyNoticesURL != nil {
            text.addArrangedSubview(button(
                thirdPartyButton,
                title: .settingsOpenThirdParty,
                action: #selector(openThirdPartyNotices(_:))
            ))
        }
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Self.noteSpacing
        text.setCustomSpacing(Self.controlSpacing, after: version)
        text.setCustomSpacing(Self.controlSpacing, after: thirdParty)
        let header = NSStackView(views: [appIconView, text])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = Self.identitySpacing
        header.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true
        return header
    }

    static let appIconSize: CGFloat = 64
    static let identitySpacing: CGFloat = 16

    /// 一個分組裡的開關，照 `SettingsToggle` 的順序，附屬的欄位與說明接在它的開關底下。
    private func toggleRows(in group: UIText) -> [[NSView]] {
        var rows: [[NSView]] = []
        for toggle in SettingsToggle.allCases where toggle.group == group {
            rows.append([checkbox(for: toggle)])
            if toggle == .personalTerms {
                personalTermField.placeholderString = UIText.settingsTermFormat.text
                personalTermField.setAccessibilityLabel(UIText.settingsTermFormat.text)
                // 欄位吃掉兩顆按鈕剩下的寬度：英文的按鈕比中文寬，寫死欄寬會把這一列撐出分組。
                personalTermField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
                personalTermField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let line = NSStackView(views: [
                    personalTermField,
                    button(addTermButton, title: .settingsAddTerm, action: #selector(editPersonalTerm(_:))),
                    button(removeTermButton, title: .settingsRemoveTerm, action: #selector(editPersonalTerm(_:)))
                ])
                line.orientation = .horizontal
                line.alignment = .firstBaseline
                line.spacing = Self.controlSpacing
                line.edgeInsets = NSEdgeInsets(top: 0, left: Self.checkboxTitleIndent, bottom: 0, right: 0)
                line.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true
                rows.append([line])
            }
            if toggle == .learnsCangjieOrder {
                // 說明只針對倉頡重碼，所以接在那個開關底下。
                rows.append([note(.settingsLearnCangjieNote, under: checkboxes[toggle])])
            }
        }
        return rows
    }

    /// 一個分組：系統標題字級的粗體標題，底下的控制項與標題同一條左緣。層次只靠字重與分組之間的留白。
    private func box(_ title: UIText, rows: [[NSView]]) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = Self.controlSpacing
        group.translatesAutoresizingMaskIntoConstraints = false
        let heading = label(title.text, font: .preferredFont(forTextStyle: .headline))
        groupTitles[currentTab, default: []].append(heading)
        group.addArrangedSubview(heading)
        for row in rows {
            if row.count == 1, let only = row.first {
                if only is NoteRow, let previous = group.arrangedSubviews.last {
                    group.setCustomSpacing(Self.noteSpacing, after: previous)
                }
                group.addArrangedSubview(only)
            } else {
                let line = NSStackView(views: row)
                line.orientation = .horizontal
                line.alignment = .firstBaseline
                line.spacing = Self.controlSpacing
                group.addArrangedSubview(line)
            }
        }
        // 每一組等寬，放不下的文字才知道要在哪裡換行。
        group.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true
        return group
    }

    private func checkbox(for toggle: SettingsToggle) -> NSButton {
        let control = NSButton(
            checkboxWithTitle: toggle.title.text,
            target: self,
            action: #selector(toggleChanged(_:))
        )
        control.setAccessibilityLabel(toggle.title.text)
        // 英文標題有的比一列還長。核取方塊不會自己算換行後的高度，所以量好再釘住。
        if control.intrinsicContentSize.width > Self.groupWidth, let cell = control.cell {
            cell.wraps = true
            cell.lineBreakMode = .byWordWrapping
            let wrapped = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.groupWidth, height: 1000))
            control.widthAnchor.constraint(equalToConstant: Self.groupWidth).isActive = true
            control.heightAnchor.constraint(equalToConstant: ceil(wrapped.height)).isActive = true
        }
        checkboxes[toggle] = control
        return control
    }

    private func popUp(_ control: NSPopUpButton, titles: [UIText], action: Selector) -> NSPopUpButton {
        control.removeAllItems()
        control.addItems(withTitles: titles.map(\.text))
        control.target = self
        control.action = action
        return control
    }

    private func button(_ control: NSButton, title: UIText, action: Selector) -> NSButton {
        control.title = title.text
        control.bezelStyle = .rounded
        control.target = self
        control.action = action
        control.setAccessibilityLabel(title.text)
        return control
    }

    private func labelled(_ title: UIText, control: NSView) -> [NSView] {
        let text = label(title.text, font: .systemFont(ofSize: NSFont.systemFontSize))
        control.setAccessibilityLabel(title.text)
        fieldLabels[currentTab, default: []].append(text)
        return [text, control]
    }

    /// 自我檢查用：每個分頁裡「標籤加選單」那幾列的標籤。
    private(set) var fieldLabels: [SettingsTab: [NSTextField]] = [:]

    /// 「快捷鍵」分頁：兩欄對齊的表格，左欄是鍵帽，右欄是一句說明。
    /// 左欄只有最寬那一列那麼寬，說明緊接在後，視線不必跳過一大段空白。
    private func shortcutTable() -> NSView {
        let columnSpacing: CGFloat = 12
        var rows: [[NSView]] = []
        for hint in ShortcutHint.allCases {
            let caps = hint.keys.map(KeyCapView.init)
            var pieces: [NSView] = []
            for cap in caps {
                if !pieces.isEmpty {
                    let joiner = label(hint.joiner, font: .systemFont(ofSize: 12))
                    joiner.textColor = .secondaryLabelColor
                    pieces.append(joiner)
                }
                pieces.append(cap)
            }
            let keys = NSStackView(views: pieces)
            keys.orientation = .horizontal
            keys.alignment = .centerY
            keys.spacing = 4
            // 英文說明比中文長，放不下時換行，不截斷。
            let summary = NSTextField(wrappingLabelWithString: hint.summary.text)
            summary.font = .systemFont(ofSize: NSFont.systemFontSize)
            summary.isSelectable = false
            shortcutFields[hint] = (caps, summary)
            rows.append([keys, summary])
        }
        // 左欄取最寬那一列的寬度，剩下的都給說明。
        let keysWidth = rows.map { ceil($0[0].fittingSize.width) }.max() ?? 0
        let summaryWidth = Self.groupWidth - keysWidth - columnSpacing
        for row in rows {
            (row[1] as? NSTextField)?.preferredMaxLayoutWidth = summaryWidth
            row[1].widthAnchor.constraint(equalToConstant: summaryWidth).isActive = true
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = Self.controlSpacing
        grid.columnSpacing = columnSpacing
        grid.rowAlignment = .none
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = keysWidth
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = SettingsLabel(labelWithString: text)
        field.font = font
        return field
    }

    /// 說明文字，緊跟在它所說明的控制項底下。說明的是核取方塊時傳進 `checkbox`，
    /// 它就縮排到那個方塊的標題文字底下；其餘的與控制項同一條左緣。
    private func note(_ title: UIText, under checkbox: NSButton? = nil) -> NSView {
        noteRow(Self.note(text: title.text), under: checkbox)
    }

    private func noteRow(_ field: NSTextField, under checkbox: NSButton? = nil) -> NSView {
        let indent = checkbox == nil ? 0 : Self.checkboxTitleIndent
        field.preferredMaxLayoutWidth = Self.groupWidth - indent
        notes.append((field, checkbox))
        let container = NoteRow(views: [field])
        container.orientation = .horizontal
        container.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return container
    }

    /// 次要標籤色的小字。
    private static func note(text: String) -> NSTextField {
        let field = SettingsLabel(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        return field
    }
}
