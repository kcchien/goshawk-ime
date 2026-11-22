import AppKit
import Foundation
import GoshawkCore

/// 符號面板的一列：焦點標記、編號、符號、名稱。前三欄固定寬度，各列的欄位才對得齊。
@MainActor
final class SymbolPanelRowView: NSView {
    /// 本頁序號，1 起算。數字鍵與點選都用它。
    let number: Int
    var onClick: ((Int) -> Void)?

    private let markerLabel = NSTextField(labelWithString: "▸")
    private let numberLabel = NSTextField(labelWithString: "")
    private let symbolLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private let fontSize: OverlayFontSize

    init(row rowModel: SymbolPanelContent.Row, fontSize: OverlayFontSize) {
        self.number = rowModel.number
        self.fontSize = fontSize
        super.init(frame: .zero)

        let columns = SymbolPanelView.columns(for: rowModel)
        numberLabel.stringValue = columns.number
        symbolLabel.stringValue = columns.symbol
        nameLabel.stringValue = columns.name

        let metrics = fontSize.metrics
        markerLabel.font = .systemFont(ofSize: metrics.caption, weight: .bold)
        numberLabel.font = .systemFont(ofSize: metrics.caption, weight: .medium)
        symbolLabel.font = .systemFont(ofSize: metrics.primary, weight: .medium)
        nameLabel.font = .systemFont(ofSize: metrics.secondary, weight: .regular)

        // 刪節號與破折號佔兩個全形字寬，符號欄要放得下。寬度是標準檔的值，其他檔跟著那一欄的字級縮放。
        let fixedColumns: [(NSTextField, CGFloat, KeyPath<OverlayFontMetrics, CGFloat>)] = [
            (markerLabel, 10, \.caption), (numberLabel, 14, \.caption), (symbolLabel, 40, \.primary)
        ]
        for (label, width, role) in fixedColumns {
            label.widthAnchor.constraint(equalToConstant: fontSize.columnWidth(width, following: role)).isActive = true
        }
        nameLabel.maximumNumberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail

        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        for label in [markerLabel, numberLabel, symbolLabel, nameLabel] {
            row.addArrangedSubview(label)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        wantsLayer = true
        layer?.cornerRadius = 5
        setFocused(false, highContrast: false)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(SymbolPanelView.rowAccessibilityLabel(for: rowModel))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 與反查面板的焦點列同一套樣式：深綠底白字之外還有前導標記與較重的字重，不只靠顏色辨識。
    func setFocused(_ focused: Bool, highContrast: Bool) {
        markerLabel.isHidden = !focused
        layer?.backgroundColor = focused ? ReadingLookupRowView.focusFill.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = focused && highContrast ? 1.5 : 0
        layer?.borderColor = NSColor.labelColor.cgColor
        symbolLabel.font = .systemFont(ofSize: fontSize.metrics.primary, weight: focused ? .bold : .medium)
        let primary = focused ? NSColor.white : NSColor.labelColor
        let secondary = focused ? NSColor.white : NSColor.secondaryLabelColor
        markerLabel.textColor = primary
        numberLabel.textColor = secondary
        symbolLabel.textColor = primary
        nameLabel.textColor = primary
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(number)
    }
}

/// 符號面板的內容：上方分頁與焦點列所在的分組、中間三欄的符號列、下方頁碼與操作提示。
@MainActor
final class SymbolPanelView: NSStackView {
    var onRowClick: ((Int) -> Void)?
    var onTabClick: ((SymbolPanel.Tab) -> Void)?

    /// 分段按鈕的順序，也是 Tab 鍵輪流切換的順序。
    static let tabs: [SymbolPanel.Tab] = [.recent, .punctuation, .symbols]

    let tabControl = NSSegmentedControl(
        labels: SymbolPanelView.tabs.map { SymbolPanelView.tabTitle($0) },
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let groupLabel = NSTextField(labelWithString: "")
    private let headerRow = NSStackView()
    private let rowsStack = NSStackView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let divider = NSBox()

    var rowViews: [SymbolPanelRowView] {
        rowsStack.arrangedSubviews.compactMap { $0 as? SymbolPanelRowView }
    }

    /// 各列在下一次 `render` 重建時才換字級，所以換檔之後要重畫一次。
    var fontSize: OverlayFontSize = .medium {
        didSet { applyFonts() }
    }

    private func applyFonts() {
        let metrics = fontSize.metrics
        groupLabel.font = .systemFont(ofSize: metrics.secondary, weight: .semibold)
        footerLabel.font = .systemFont(ofSize: metrics.caption, weight: .regular)
        tabControl.font = .systemFont(ofSize: metrics.caption, weight: .regular)
    }

    init() {
        super.init(frame: .zero)

        groupLabel.maximumNumberOfLines = 1
        footerLabel.textColor = .secondaryLabelColor

        tabControl.segmentStyle = .texturedRounded
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        applyFonts()

        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = 10
        headerRow.addArrangedSubview(tabControl)
        headerRow.addArrangedSubview(groupLabel)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 1

        divider.boxType = .separator

        orientation = .vertical
        alignment = .leading
        spacing = 5
        edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(headerRow)
        addArrangedSubview(divider)
        addArrangedSubview(rowsStack)
        addArrangedSubview(footerLabel)
        divider.widthAnchor.constraint(equalTo: widthAnchor, constant: -20).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tabChanged(_ sender: Any?) {
        guard Self.tabs.indices.contains(tabControl.selectedSegment) else { return }
        onTabClick?(Self.tabs[tabControl.selectedSegment])
    }

    func render(_ panel: SymbolPanelContent) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        // 分段按鈕的選取狀態一律以引擎為準，點了之後引擎沒換分頁就會被改回來。
        tabControl.selectedSegment = Self.tabs.firstIndex(of: panel.tab) ?? 0
        groupLabel.stringValue = Self.groupText(for: panel)
        footerLabel.stringValue = Self.footerText(for: panel)

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, row) in panel.rows.enumerated() {
            let view = SymbolPanelRowView(row: row, fontSize: fontSize)
            view.onClick = { [weak self] number in self?.onRowClick?(number) }
            view.setFocused(index == panel.focusedRow, highContrast: highContrast)
            rowsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        rowsStack.isHidden = panel.rows.isEmpty

        setAccessibilityLabel(Self.accessibilityLabel(for: panel))
    }

    /// 焦點、頁或分頁改變時朗讀。剛開啟時由面板的群組標籤交代，不另外朗讀。
    func announceIfChanged(from previous: SymbolPanelContent?, to panel: SymbolPanelContent) {
        guard let spoken = Self.announcement(from: previous, to: panel) else { return }
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: spoken,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    // MARK: - 純文字版面計算（可直接斷言）

    static func tabTitle(_ tab: SymbolPanel.Tab) -> String {
        switch tab {
        case .recent: return UIText.symbolTabRecent.text
        case .punctuation: return UIText.symbolTabPunctuation.text
        case .symbols: return UIText.symbolTabSymbols.text
        }
    }

    /// 全形空格那一列的符號欄看不到字，靠名稱欄辨識。
    static func columns(for row: SymbolPanelContent.Row) -> (number: String, symbol: String, name: String) {
        ("\(row.number)", row.symbol, name(for: row))
    }

    static func name(for row: SymbolPanelContent.Row) -> String {
        Localization.current.usesEnglishNames ? row.englishName : row.name
    }

    /// 焦點列所在的分組。沒有任何列時是空字串。
    static func groupText(for panel: SymbolPanelContent) -> String {
        guard let row = focusedRow(of: panel) else { return "" }
        return Localization.current.usesEnglishNames ? row.englishGroup : row.group
    }

    static func footerText(for panel: SymbolPanelContent) -> String {
        guard !panel.rows.isEmpty else {
            return UIText.symbolHints.text
        }
        return "\(UIText.readingPageFooter.text(panel.page, panel.pageCount))  \(UIText.symbolHints.text)"
    }

    static func rowAccessibilityLabel(for row: SymbolPanelContent.Row) -> String {
        UIText.symbolRowLabel.text(row.number, row.symbol, name(for: row))
    }

    static func accessibilityLabel(for panel: SymbolPanelContent) -> String {
        var parts = [UIText.symbolPanel.text, tabTitle(panel.tab)]
        if !panel.rows.isEmpty {
            parts.append(UIText.readingPageFooter.text(panel.page, panel.pageCount))
        }
        return parts.joined(separator: UIText.listSeparator.text)
    }

    /// 要朗讀的內容；什麼都沒變或面板剛開啟時是 nil。換分頁時先念分頁名稱。
    static func announcement(from previous: SymbolPanelContent?, to panel: SymbolPanelContent) -> String? {
        guard let previous,
              previous.tab != panel.tab || previous.page != panel.page || previous.focusedRow != panel.focusedRow else {
            return nil
        }
        var parts: [String] = []
        if previous.tab != panel.tab {
            parts.append(tabTitle(panel.tab))
        }
        if let row = focusedRow(of: panel) {
            parts.append(rowAccessibilityLabel(for: row))
            parts.append(UIText.readingPageFooter.text(panel.page, panel.pageCount))
        }
        return parts.joined(separator: UIText.listSeparator.text)
    }

    private static func focusedRow(of panel: SymbolPanelContent) -> SymbolPanelContent.Row? {
        guard let focused = panel.focusedRow, panel.rows.indices.contains(focused) else { return nil }
        return panel.rows[focused]
    }
}
