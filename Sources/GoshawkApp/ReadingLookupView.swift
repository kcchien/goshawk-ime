import AppKit
import Foundation
import GoshawkCore

/// 反查面板的一列。四欄固定寬度，所以每列的欄位左緣與文字基線都對齊。
@MainActor
final class ReadingLookupRowView: NSView {
    /// 本頁序號，1 起算。數字鍵與點選都用它。
    let number: Int
    var onClick: ((Int) -> Void)?

    private let markerLabel = NSTextField(labelWithString: "")
    private let numberLabel = NSTextField(labelWithString: "")
    private let characterLabel = NSTextField(labelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let radicalLabel = NSTextField(labelWithString: "")
    private let row = NSStackView()

    static let focusFill = NSColor(srgbRed: 0.13, green: 0.36, blue: 0.32, alpha: 1)

    init(row rowModel: ReadingLookupPanel.Row) {
        self.number = rowModel.number
        super.init(frame: .zero)

        let columns = ReadingLookupView.columns(for: rowModel)
        markerLabel.stringValue = "▸"
        numberLabel.stringValue = columns.number
        characterLabel.stringValue = columns.character
        codeLabel.stringValue = columns.code
        radicalLabel.stringValue = columns.radicals

        markerLabel.font = .systemFont(ofSize: 11, weight: .bold)
        numberLabel.font = .systemFont(ofSize: 11, weight: .medium)
        characterLabel.font = .systemFont(ofSize: 17, weight: .medium)
        codeLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        radicalLabel.font = .systemFont(ofSize: 13, weight: .regular)

        for (label, width) in [(markerLabel, 10.0), (numberLabel, 14.0), (characterLabel, 24.0), (codeLabel, 62.0)] {
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        radicalLabel.maximumNumberOfLines = 1
        radicalLabel.lineBreakMode = .byTruncatingTail

        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        for label in [markerLabel, numberLabel, characterLabel, codeLabel, radicalLabel] {
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
        setAccessibilityLabel(ReadingLookupView.rowAccessibilityLabel(for: rowModel))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 焦點列除了深綠底白字，還多一個前導標記與較重的字重，不只靠顏色辨識。
    func setFocused(_ focused: Bool, highContrast: Bool) {
        markerLabel.isHidden = !focused
        layer?.backgroundColor = focused ? Self.focusFill.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = focused && highContrast ? 1.5 : 0
        layer?.borderColor = NSColor.labelColor.cgColor
        characterLabel.font = .systemFont(ofSize: 17, weight: focused ? .bold : .medium)
        let primary = focused ? NSColor.white : NSColor.labelColor
        let secondary = focused ? NSColor.white : NSColor.secondaryLabelColor
        markerLabel.textColor = primary
        numberLabel.textColor = secondary
        characterLabel.textColor = primary
        codeLabel.textColor = primary
        radicalLabel.textColor = secondary
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(number)
    }
}

/// 反查面板的內容：上方讀音與方案、中間四欄候選、下方頁碼與操作提示。
@MainActor
final class ReadingLookupView: NSStackView {
    var onRowClick: ((Int) -> Void)?
    var onSchemeClick: (() -> Void)?

    private let readingLabel = NSTextField(labelWithString: "")
    private let schemeControl = NSSegmentedControl(
        labels: [UIText.readingSchemeDachen.text, UIText.readingSchemePinyin.text],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let headerRow = NSStackView()
    private let rowsStack = NSStackView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let divider = NSBox()

    init() {
        super.init(frame: .zero)

        readingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        readingLabel.maximumNumberOfLines = 1
        placeholderLabel.font = .systemFont(ofSize: 13, weight: .regular)
        placeholderLabel.textColor = .secondaryLabelColor
        footerLabel.font = .systemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor

        schemeControl.segmentStyle = .texturedRounded
        schemeControl.target = self
        schemeControl.action = #selector(schemeChanged(_:))
        schemeControl.font = .systemFont(ofSize: 11, weight: .regular)

        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = 10
        headerRow.addArrangedSubview(readingLabel)
        headerRow.addArrangedSubview(schemeControl)

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
        addArrangedSubview(placeholderLabel)
        addArrangedSubview(footerLabel)
        divider.widthAnchor.constraint(equalTo: widthAnchor, constant: -20).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func schemeChanged(_ sender: Any?) {
        onSchemeClick?()
    }

    func render(_ panel: ReadingLookupPanel) {
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        readingLabel.stringValue = Self.headerText(for: panel)
        schemeControl.selectedSegment = panel.scheme == .dachen ? 0 : 1
        footerLabel.stringValue = Self.footerText(for: panel)

        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, row) in panel.rows.enumerated() {
            let view = ReadingLookupRowView(row: row)
            view.onClick = { [weak self] number in self?.onRowClick?(number) }
            view.setFocused(index == panel.focusedRow, highContrast: highContrast)
            rowsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        rowsStack.isHidden = panel.rows.isEmpty

        if let placeholder = Self.placeholderText(for: panel.status) {
            placeholderLabel.stringValue = placeholder
            placeholderLabel.isHidden = false
        } else {
            placeholderLabel.stringValue = ""
            placeholderLabel.isHidden = true
        }

        setAccessibilityLabel(Self.accessibilityLabel(for: panel))
    }

    /// 只有使用者手動移動焦點或換頁時朗讀，打字更新候選時不朗讀。
    func announceIfFocusMoved(from previous: ReadingLookupPanel?, to panel: ReadingLookupPanel) {
        guard let previous,
              previous.inputDisplay == panel.inputDisplay,
              previous.scheme == panel.scheme,
              previous.page != panel.page
                || previous.focusedRow != panel.focusedRow
                || previous.isSelecting != panel.isSelecting else {
            return
        }
        let spoken: String
        if let focused = panel.focusedRow, panel.rows.indices.contains(focused) {
            spoken = [
                Self.rowAccessibilityLabel(for: panel.rows[focused]),
                UIText.readingPageFooter.text(panel.page, panel.pageCount)
            ].joined(separator: UIText.listSeparator.text)
        } else {
            spoken = Self.accessibilityLabel(for: panel)
        }
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

    static func versionLabel(for version: CangjieVersion) -> String {
        version == .v5 ? UIText.cangjieV5.text : UIText.cangjieV3.text
    }

    static func columns(for row: ReadingLookupPanel.Row) -> (number: String, character: String, code: String, radicals: String) {
        guard let code = row.code else {
            return ("\(row.number)", row.character, UIText.readingCodeMissing.text, "")
        }
        return ("\(row.number)", row.character, code, row.radicals ?? "")
    }

    static func headerText(for panel: ReadingLookupPanel) -> String {
        let reading = panel.inputDisplay.isEmpty
            ? (panel.scheme == .dachen ? UIText.readingPromptDachen.text : UIText.readingPromptPinyin.text)
            : panel.inputDisplay
        return "\(reading)  \(versionLabel(for: panel.cangjieVersion))"
    }

    static func placeholderText(for status: ReadingLookupPanel.Status) -> String? {
        switch status {
        case .results, .empty:
            return nil
        case .partial:
            return "…"
        case .noResults:
            return UIText.readingNoResults.text
        }
    }

    static func footerText(for panel: ReadingLookupPanel) -> String {
        let hints = panel.isSelecting
            ? UIText.readingHintsSelecting.text
            : UIText.readingHintsBrowsing.text
        guard panel.status == .results else {
            return hints
        }
        return "\(UIText.readingPageFooter.text(panel.page, panel.pageCount))  \(hints)"
    }

    static func rowAccessibilityLabel(for row: ReadingLookupPanel.Row) -> String {
        guard let code = row.code else {
            return UIText.readingRowLabelMissing.text(row.number, row.character)
        }
        return UIText.readingRowLabel.text(row.number, row.character, code, row.radicals ?? "")
    }

    static func accessibilityLabel(for panel: ReadingLookupPanel) -> String {
        let separator = UIText.listSeparator.text
        var parts = [
            UIText.readingLookup.text,
            headerText(for: panel).replacingOccurrences(of: "  ", with: separator)
        ]
        if panel.status == .noResults {
            parts.append(UIText.readingNoResults.text)
        } else if panel.status == .results {
            parts.append(UIText.readingPageFooter.text(panel.page, panel.pageCount))
        }
        return parts.joined(separator: separator)
    }
}
