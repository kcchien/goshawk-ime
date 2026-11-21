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
    case revert
    case autoSpace
    case halfwidthPunctuation
    case ctrlBrackets
    case learnsEnglishPredictions
    case learnsCangjieOrder
    case learnsReadingLookupOrder

    var group: UIText {
        switch self {
        case .mixedMode, .developerVocabulary, .revert:
            return .settingsGroupInput
        case .autoSpace, .halfwidthPunctuation, .ctrlBrackets:
            return .settingsGroupTypography
        case .learnsEnglishPredictions, .learnsCangjieOrder, .learnsReadingLookupOrder:
            return .settingsGroupLearning
        }
    }

    var title: UIText {
        switch self {
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

private final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}

/// 輸入法的設定視窗。選單的「設定…」開它，同一時間只有一個。
/// 每個控制項直接讀寫 `PreferencesStore`，存完就發通知讓作用中的控制器重新載入。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let window: NSWindow
    /// 自我檢查與截圖用：每個開關的核取方塊。
    private(set) var checkboxes: [SettingsToggle: NSButton] = [:]
    private(set) var cangjieVersionControl = NSPopUpButton()
    private(set) var readingSchemeControl = NSPopUpButton()

    private let preferences: PreferencesStore
    private let usageStore: UsageHistoryStore
    private let clearHistoryButton = NSButton()
    private let thirdPartyButton = NSButton()

    init(preferences: PreferencesStore = PreferencesStore(), usageStore: UsageHistoryStore = .shared) {
        self.preferences = preferences
        self.usageStore = usageStore
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = UIText.settingsTitle.text
        window.isReleasedWhenClosed = false
        window.delegate = self

        let document = buildContentView()
        documentSize = document.fittingSize
        document.frame = NSRect(origin: .zero, size: documentSize)
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        window.contentView = scrollView
        // 只能調高度：寬度固定，最高就是全部內容，再高也沒有東西可顯示。
        window.contentMinSize = NSSize(width: documentSize.width, height: min(Self.minimumHeight, documentSize.height))
        window.contentMaxSize = documentSize
        fitToScreen()
        window.center()
        reloadFromPreferences()
    }

    /// 全部內容的大小。視窗比它矮時內容可以捲動。
    private(set) var documentSize: NSSize = .zero

    static let minimumHeight: CGFloat = 240
    /// 標題列與上下留白，視窗內容最高只能用到螢幕可用高度扣掉這一段。
    static let screenMargin: CGFloat = 80

    /// 內容區的高度：放得下就完整顯示，螢幕太矮就縮到放得下，其餘用捲動看。
    static func contentHeight(documentHeight: CGFloat, screenVisibleHeight: CGFloat) -> CGFloat {
        min(documentHeight, max(min(minimumHeight, documentHeight), screenVisibleHeight - screenMargin))
    }

    private func fitToScreen() {
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? documentSize.height + Self.screenMargin
        let height = Self.contentHeight(documentHeight: documentSize.height, screenVisibleHeight: screenHeight)
        window.setContentSize(NSSize(width: documentSize.width, height: height))
    }

    /// 顯示視窗。輸入法是背景程式，必須先讓自己成為作用中的程式，視窗才拿得到鍵盤焦點。
    func show() {
        NSApp.setActivationPolicy(.accessory)
        reloadFromPreferences()
        if !window.isVisible {
            // 上次開啟後可能換過螢幕或解析度。
            fitToScreen()
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
        let configuration = preferences.loadConfiguration()
        for (toggle, checkbox) in checkboxes {
            checkbox.state = toggle.isOn(in: configuration) ? .on : .off
        }
        cangjieVersionControl.selectItem(at: configuration.cangjieVersion == .v3 ? 0 : 1)
        readingSchemeControl.selectItem(at: configuration.readingScheme == .dachen ? 0 : 1)
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
    }

    @objc private func cangjieVersionChanged(_ sender: NSPopUpButton) {
        let version: CangjieVersion = sender.indexOfSelectedItem == 0 ? .v3 : .v5
        apply { $0.cangjieVersion = version }
    }

    @objc private func readingSchemeChanged(_ sender: NSPopUpButton) {
        let scheme: PhoneticScheme = sender.indexOfSelectedItem == 0 ? .dachen : .pinyin
        apply { $0.readingScheme = scheme }
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
        usageStore.clear()
    }

    @objc private func openThirdPartyNotices(_ sender: Any?) {
        guard let url = Self.thirdPartyNoticesURL else { return }
        NSWorkspace.shared.open(url)
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

    /// 視窗內容的固定寬度。英文標籤比中文長，取夠寬的值讓兩種語系都不換行或截斷。
    static let contentWidth: CGFloat = 460

    private func buildContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for group in [UIText.settingsGroupInput, .settingsGroupTypography, .settingsGroupLearning] {
            var rows: [[NSView]] = []
            for toggle in SettingsToggle.allCases where toggle.group == group {
                rows.append([checkbox(for: toggle)])
                if toggle == .learnsCangjieOrder {
                    // 說明只針對倉頡重碼，所以接在那個開關底下。
                    rows.append([note(.settingsLearnCangjieNote, indent: 18)])
                }
            }
            if group == .settingsGroupInput {
                rows.append(labelled(
                    .settingsCangjieVersion,
                    control: popUp(
                        cangjieVersionControl,
                        titles: [.cangjieV3, .cangjieV5],
                        action: #selector(cangjieVersionChanged(_:))
                    )
                ))
            }
            if group == .settingsGroupLearning {
                rows.append([note(.settingsLearningStorageNote)])
                rows.append([button(clearHistoryButton, title: .settingsClearHistory, action: #selector(clearHistory(_:)))])
            }
            stack.addArrangedSubview(box(group, rows: rows))
        }

        stack.addArrangedSubview(box(.settingsGroupReadingLookup, rows: [
            labelled(
                .settingsReadingScheme,
                control: popUp(
                    readingSchemeControl,
                    titles: [.readingSchemeDachen, .readingSchemePinyin],
                    action: #selector(readingSchemeChanged(_:))
                )
            )
        ]))

        var aboutRows: [[NSView]] = [
            [label(UIText.productName.text, font: .boldSystemFont(ofSize: 13))],
            [note(text: Self.versionText)],
            [note(.settingsLicense)],
            [note(.settingsThirdParty)]
        ]
        if Self.thirdPartyNoticesURL != nil {
            aboutRows.append([button(
                thirdPartyButton,
                title: .settingsOpenThirdParty,
                action: #selector(openThirdPartyNotices(_:))
            )])
        }
        stack.addArrangedSubview(box(.settingsGroupAbout, rows: aboutRows))

        // 捲動視圖的內容要從上往下排，視窗變矮時才會先看到第一組而不是最後一組。
        let root = TopAlignedView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // 固定寬度，說明文字才知道要在哪裡換行，中英文都不會被截斷。
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])
        return root
    }

    /// 一個分組：粗體標題加一條分隔線，底下的控制項縮排對齊。
    private func box(_ title: UIText, rows: [[NSView]]) -> NSView {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        group.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(label(title.text, font: .boldSystemFont(ofSize: 13)))

        let divider = NSBox()
        divider.boxType = .separator
        group.addArrangedSubview(divider)

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 7
        body.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 0, right: 0)
        for row in rows {
            if row.count == 1, let only = row.first {
                body.addArrangedSubview(only)
            } else {
                let line = NSStackView(views: row)
                line.orientation = .horizontal
                line.alignment = .firstBaseline
                line.spacing = 8
                body.addArrangedSubview(line)
            }
        }
        group.addArrangedSubview(body)
        // 每一組的分隔線等長，視覺上才像同一疊設定。
        group.widthAnchor.constraint(equalToConstant: Self.contentWidth - 40).isActive = true
        divider.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func checkbox(for toggle: SettingsToggle) -> NSButton {
        let control = NSButton(
            checkboxWithTitle: toggle.title.text,
            target: self,
            action: #selector(toggleChanged(_:))
        )
        control.setAccessibilityLabel(toggle.title.text)
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
        let text = label(title.text, font: .systemFont(ofSize: 13))
        control.setAccessibilityLabel(title.text)
        return [text, control]
    }

    private func label(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }

    /// 說明文字。`indent` 讓它縮排在它所解釋的那個開關底下。
    private func note(_ title: UIText, indent: CGFloat = 0) -> NSView {
        let field = note(text: title.text)
        guard indent > 0 else {
            return field
        }
        let container = NSStackView(views: [field])
        container.orientation = .horizontal
        container.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return container
    }

    private func note(text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.isSelectable = false
        field.preferredMaxLayoutWidth = Self.contentWidth - 48
        return field
    }
}
