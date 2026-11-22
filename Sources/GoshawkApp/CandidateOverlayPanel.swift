import AppKit
import Foundation
import GoshawkCore

extension EnglishTrack {
    /// 浮窗展示焦點與最多三個其他選項。其餘名次仍可按快捷鍵，但不列入顯示次數。
    func displayedPredictionIndices(showsActions: Bool) -> [Int] {
        guard showsActions, !predictions.isEmpty else { return [] }
        let focus = predictions.indices.contains(selectedIndex) ? selectedIndex : 0
        guard predictions[focus].lowercased().hasPrefix(typed.lowercased()) else { return [] }
        return [focus] + predictions.indices.lazy.filter { $0 != focus }.prefix(3)
    }
}

@MainActor
final class CandidateOverlayPanel: NSPanel {
    static let shared = CandidateOverlayPanel()

    private let visualEffectView = NSVisualEffectView()
    private let rootStack = NSStackView()
    private let stackView = NSStackView()
    private let englishLabel = NSTextField(labelWithString: "")
    private let divider = NSBox()
    private let cangjieLabel = NSTextField(labelWithString: "")
    private let readingView = ReadingLookupView()
    let symbolView = SymbolPanelView()
    private var lastShown: (overlay: OverlayState, anchorRect: NSRect, showsEnglishActions: Bool)?
    private var lastReadingShown: (panel: ReadingLookupPanel, anchorRect: NSRect)?
    private var lastSymbolShown: (panel: SymbolPanelContent, anchorRect: NSRect)?
    private var lastAnchorRect: NSRect?

    /// 浮窗上所有畫面共用的字級。換檔時先收起浮窗並清掉「內容沒變就不重排」的紀錄，
    /// 下一次更新才會用新的字級重畫、重算視窗大小。
    var fontSize: OverlayFontSize = .medium {
        didSet {
            guard fontSize != oldValue else { return }
            readingView.fontSize = fontSize
            symbolView.fontSize = fontSize
            update(overlay: nil, layerPanel: nil, cursorRect: .zero, showsEnglishActions: false)
        }
    }

    /// 點選符號面板的某一列。
    var onSymbolRowClick: ((Int) -> Void)? {
        get { symbolView.onRowClick }
        set { symbolView.onRowClick = newValue }
    }

    /// 點選符號面板的分頁分段按鈕。
    var onSymbolTabClick: ((SymbolPanel.Tab) -> Void)? {
        get { symbolView.onTabClick }
        set { symbolView.onTabClick = newValue }
    }

    /// 點選反查面板的某一列。
    var onReadingRowClick: ((Int) -> Void)? {
        get { readingView.onRowClick }
        set { readingView.onRowClick = newValue }
    }

    /// 點選反查面板的方案分段按鈕。
    var onReadingSchemeClick: (() -> Void)? {
        get { readingView.onSchemeClick }
        set { readingView.onSchemeClick = newValue }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        // fullScreenAuxiliary lets the panel appear over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient, .fullScreenAuxiliary]

        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 10
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = 0.5
        visualEffectView.layer?.borderColor = NSColor.separatorColor.cgColor

        // A long buffer truncates at the head so the letters being typed and the key hints
        // stay visible; both labels may compress once the panel hits its width cap.
        englishLabel.maximumNumberOfLines = 1
        englishLabel.lineBreakMode = .byTruncatingHead
        englishLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cangjieLabel.maximumNumberOfLines = 1
        cangjieLabel.lineBreakMode = .byTruncatingTail
        cangjieLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 5
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(englishLabel)
        divider.boxType = .separator
        stackView.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -24).isActive = true
        stackView.addArrangedSubview(cangjieLabel)

        // 雙軌、反查與符號面板共用同一個浮窗容器與同一套定位，同一時間只顯示其中一個。
        // 外層用 NSStackView，被隱藏的才會整個脫離版面。
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(stackView)
        rootStack.addArrangedSubview(readingView)
        rootStack.addArrangedSubview(symbolView)
        readingView.isHidden = true
        symbolView.isHidden = true

        visualEffectView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        contentView = visualEffectView
    }

    /// 候選列與選項列共用的焦點底色。
    private static let selectionFill = NSColor(srgbRed: 0.13, green: 0.36, blue: 0.32, alpha: 1)

    /// 成對符號的選項列：八種照固定順序排成一行，目前那一種用候選列的焦點樣式。
    /// 編號只在數字會直選時顯示，與候選列「數字會選字才顯示編號」一致。
    static func formatPairChoice(_ choice: PairChoice, fontSize: OverlayFontSize = .medium) -> NSAttributedString {
        let metrics = fontSize.metrics
        let pairAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: metrics.primary, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let numberAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: metrics.caption, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let row = NSMutableAttributedString()
        for (index, style) in PairStyle.allCases.enumerated() {
            if index > 0 {
                row.append(NSAttributedString(string: "  ", attributes: pairAttrs))
            }
            var styleAttrs = pairAttrs
            var styleNumberAttrs = numberAttrs
            if style == choice.current {
                for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
                    let color = key == .foregroundColor ? NSColor.white : selectionFill
                    styleAttrs[key] = color
                    styleNumberAttrs[key] = color
                }
                styleAttrs[.font] = NSFont.systemFont(ofSize: metrics.primary, weight: .bold)
            }
            let number = choice.digitsPick ? " \(index + 1) " : " "
            row.append(NSAttributedString(string: number, attributes: styleNumberAttrs))
            row.append(NSAttributedString(string: "\(style.opener)\(style.closer) ", attributes: styleAttrs))
        }
        return row
    }

    static func formatTracks(
        for overlay: OverlayState,
        showsEnglishActions: Bool,
        fontSize: OverlayFontSize = .medium
    ) -> (english: NSAttributedString, cangjie: NSAttributedString?) {
        let metrics = fontSize.metrics
        let engAttr = NSMutableAttributedString()
        var typedAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: metrics.secondary, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let completionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: metrics.secondary, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: metrics.caption, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let selectionFill = Self.selectionFill
        // 片段裡空白鍵送的是英文，焦點就標在上行；黏中時焦點回到下行的中文字。
        let englishFocused = overlay.inCodeSnippet && overlay.spaceCommits == .english
        // 空白鍵送的是已打的字母，補完部分要按 Tab，所以只標已打的那一段。
        if englishFocused {
            typedAttrs[.foregroundColor] = NSColor.white
            typedAttrs[.backgroundColor] = selectionFill
        }
        if overlay.inCodeSnippet {
            engAttr.append(NSAttributedString(string: "\(UIText.snippetBadge.text)  ", attributes: hintAttrs))
        }

        let engTrack = overlay.englishTrack
        // Tab commits the focused prediction (moved with the arrow keys), so that is the
        // word shown as the completion; the others keep their Shift+N numbers.
        let displayed = engTrack.displayedPredictionIndices(showsActions: showsEnglishActions)
        if !showsEnglishActions {
            engAttr.append(NSAttributedString(string: engTrack.typed, attributes: typedAttrs))
        } else if let focus = displayed.first {
            // Show the prediction's own casing: `usestate` commits as `useState`.
            let word = engTrack.predictions[focus]
            engAttr.append(NSAttributedString(string: String(word.prefix(engTrack.typed.count)), attributes: typedAttrs))
            let suffix = String(word.dropFirst(engTrack.typed.count))
            if !suffix.isEmpty {
                engAttr.append(NSAttributedString(string: suffix, attributes: completionAttrs))
            }
            engAttr.append(NSAttributedString(string: "  Tab", attributes: hintAttrs))
            let extras = displayed.dropFirst()
                .map { "⇧\($0 + 1) \(engTrack.predictions[$0])" }
                .joined(separator: "  ")
            if !extras.isEmpty {
                engAttr.append(NSAttributedString(string: "  |  \(extras)", attributes: hintAttrs))
            }
        } else {
            engAttr.append(NSAttributedString(string: engTrack.typed, attributes: typedAttrs))
            engAttr.append(NSAttributedString(string: "  Enter", attributes: hintAttrs))
        }

        guard let cjTrack = overlay.cangjieTrack else {
            return (engAttr, nil)
        }

        let cjAttr = NSMutableAttributedString()
        let radicalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: metrics.secondary, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let candidateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: metrics.primary, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]

        cjAttr.append(NSAttributedString(string: "\(cjTrack.radicals)  ", attributes: radicalAttrs))
        if cjTrack.candidates.isEmpty {
            cjAttr.append(NSAttributedString(string: "…", attributes: hintAttrs))
        } else {
            for (idx, word) in cjTrack.candidates.enumerated() {
                if idx > 0 {
                    cjAttr.append(NSAttributedString(string: "  ", attributes: candidateAttrs))
                }
                // 焦點在上行時，下行不標焦點：空白鍵送不出這個字。
                let selected = idx == cjTrack.selectedIndex && !englishFocused
                var wordAttrs = candidateAttrs
                var numberAttrs = hintAttrs
                if selected {
                    for key in [NSAttributedString.Key.foregroundColor, .backgroundColor] {
                        let color = key == .foregroundColor ? NSColor.white : selectionFill
                        wordAttrs[key] = color
                        numberAttrs[key] = color
                    }
                    wordAttrs[.font] = NSFont.systemFont(ofSize: metrics.primary, weight: .bold)
                }
                // 數字鍵是打字用的時候（單一字母或只有一個候選）不顯示編號。
                let number = cjTrack.digitsSelect ? " \(idx + 1) " : " "
                cjAttr.append(NSAttributedString(string: number, attributes: numberAttrs))
                cjAttr.append(NSAttributedString(string: "\(word) ", attributes: wordAttrs))
            }
        }
        return (engAttr, cjAttr)
    }

    func update(
        overlay: OverlayState?,
        layerPanel: LayerPanelContent?,
        cursorRect: NSRect,
        showsEnglishActions: Bool,
        revertHint: String? = nil,
        pairChoice: PairChoice? = nil,
        pairSwitchNotice: PairSwitchNotice? = nil,
        continuation: String? = nil
    ) {
        // 任何一次更新都代表畫面要換內容了：上一則被擋下的提示連同它的計時器到此為止，
        // 這次還要顯示的話下面會重新排。
        pairSwitchNoticeTimer?.invalidate()
        pairSwitchNoticeTimer = nil
        shownPairSwitchNotice = nil
        switch layerPanel {
        case .reading(let readingPanel):
            shownCommitHint = nil
            shownPairChoice = nil
            updateReading(readingPanel, cursorRect: cursorRect)
            return
        case .symbols(let symbolPanel):
            shownCommitHint = nil
            shownPairChoice = nil
            updateSymbols(symbolPanel, cursorRect: cursorRect)
            return
        case nil:
            break
        }
        lastReadingShown = nil
        lastSymbolShown = nil
        readingView.isHidden = true
        symbolView.isHidden = true
        // 只有疊加層的面板需要滑鼠；雙軌維持點不到，才不會搶走宿主的點擊。
        ignoresMouseEvents = true

        guard let overlay else {
            lastShown = nil
            if let pairChoice {
                showPairChoice(pairChoice, cursorRect: cursorRect)
                return
            }
            shownPairChoice = nil
            if let pairSwitchNotice {
                showPairSwitchNotice(pairSwitchNotice, cursorRect: cursorRect)
                return
            }
            let hints = [continuation.map { UIText.continuationHint.text($0) },
                         revertHint.map(Self.revertHintText)].compactMap { $0 }
            if !hints.isEmpty {
                showCommitHint(hints.joined(separator: "    "), cursorRect: cursorRect)
                return
            }
            shownCommitHint = nil
            lastAnchorRect = nil
            orderOut(nil)
            return
        }
        shownCommitHint = nil
        shownPairChoice = nil

        let anchorRect = Self.resolveAnchorRect(
            reported: cursorRect,
            lastKnown: lastAnchorRect,
            mouseLocation: NSEvent.mouseLocation
        )
        let previousLeft = lastAnchorRect == anchorRect && isVisible ? frame.minX : nil
        lastAnchorRect = anchorRect
        // Keys that change neither the tracks nor the cursor position need no relayout.
        if let lastShown, lastShown.overlay == overlay, lastShown.anchorRect == anchorRect,
           lastShown.showsEnglishActions == showsEnglishActions, isVisible, !stackView.isHidden {
            return
        }
        lastShown = (overlay, anchorRect, showsEnglishActions)
        stackView.isHidden = false

        let formatted = Self.formatTracks(for: overlay, showsEnglishActions: showsEnglishActions, fontSize: fontSize)
        englishLabel.attributedStringValue = formatted.english
        divider.isHidden = formatted.cangjie == nil
        if let cjText = formatted.cangjie {
            cangjieLabel.attributedStringValue = cjText
            cangjieLabel.isHidden = false
        } else {
            cangjieLabel.stringValue = ""
            cangjieLabel.isHidden = true
        }

        place(anchorRect: anchorRect, previousLeft: previousLeft)
    }

    /// 浮窗目前顯示的反悔或接詞提示。沒有顯示時為 nil。
    private(set) var shownCommitHint: String?

    /// 可反悔的送出之後那一行提示：「⇧空白 改成 my」。`preview` 是對調後的字詞。
    static func revertHintText(preview: String) -> String {
        UIText.revertHint.text(preview)
    }

    /// 送出之後，同一個浮窗只留一行提示，停在剛才組字的位置，下一個按鍵就收掉。
    private func showCommitHint(_ text: String, cursorRect: NSRect) {
        let anchorRect = Self.resolveAnchorRect(
            reported: cursorRect,
            lastKnown: lastAnchorRect,
            mouseLocation: NSEvent.mouseLocation
        )
        let previousLeft = lastAnchorRect == anchorRect && isVisible ? frame.minX : nil
        lastAnchorRect = anchorRect
        if shownCommitHint == text, isVisible, !stackView.isHidden {
            return
        }
        shownCommitHint = text
        stackView.isHidden = false
        englishLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize.metrics.hint, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        divider.isHidden = true
        cangjieLabel.stringValue = ""
        cangjieLabel.isHidden = true
        place(anchorRect: anchorRect, previousLeft: previousLeft)
    }

    /// 浮窗目前顯示的「成對切換被擋下」提示。沒有顯示時為 nil。
    private(set) var shownPairSwitchNotice: PairSwitchNotice?
    /// 被擋下的提示最多留這麼久。自我檢查會調短。
    var pairSwitchNoticeLifetime: TimeInterval = 2
    private var pairSwitchNoticeTimer: Timer?

    static func pairSwitchNoticeText(_ notice: PairSwitchNotice) -> String {
        switch notice {
        case .spanUnsupported: UIText.pairSwitchSpanUnsupported.text
        case .hostReadbackUnavailable: UIText.pairSwitchHostUnavailable.text
        }
    }

    /// 成對切換被擋下：沿用送出後那一行提示的樣式，下一個按鍵就收掉。使用者停下來不打字時
    /// 沒有按鍵來收，所以另外排一個計時器，到期時浮窗還是這一則才收，不動之後開的組字窗或面板。
    private func showPairSwitchNotice(_ notice: PairSwitchNotice, cursorRect: NSRect) {
        showCommitHint(Self.pairSwitchNoticeText(notice), cursorRect: cursorRect)
        shownPairSwitchNotice = notice
        let timer = Timer(timeInterval: pairSwitchNoticeLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.shownPairSwitchNotice == notice else { return }
                self.pairSwitchNoticeTimer = nil
                self.shownPairSwitchNotice = nil
                self.shownCommitHint = nil
                self.lastAnchorRect = nil
                self.orderOut(nil)
            }
        }
        pairSwitchNoticeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 浮窗目前顯示的成對符號選項列。沒有顯示時為 nil。
    private(set) var shownPairChoice: PairChoice?

    /// 成對符號切換之後，同一個浮窗只留一行選項列，下一個不是切換的按鍵就收掉。
    private func showPairChoice(_ choice: PairChoice, cursorRect: NSRect) {
        let anchorRect = Self.resolveAnchorRect(
            reported: cursorRect,
            lastKnown: lastAnchorRect,
            mouseLocation: NSEvent.mouseLocation
        )
        let previousLeft = lastAnchorRect == anchorRect && isVisible ? frame.minX : nil
        lastAnchorRect = anchorRect
        shownCommitHint = nil
        shownPairChoice = choice
        stackView.isHidden = false
        englishLabel.attributedStringValue = Self.formatPairChoice(choice, fontSize: fontSize)
        divider.isHidden = true
        cangjieLabel.stringValue = ""
        cangjieLabel.isHidden = true
        place(anchorRect: anchorRect, previousLeft: previousLeft)
    }

    /// 反查開啟：同一個浮窗、同一套定位，內容換成讀音頁。
    private func updateReading(_ panel: ReadingLookupPanel, cursorRect: NSRect) {
        let anchorRect = Self.resolveAnchorRect(
            reported: cursorRect,
            lastKnown: lastAnchorRect,
            mouseLocation: NSEvent.mouseLocation
        )
        let previousLeft = lastAnchorRect == anchorRect && isVisible ? frame.minX : nil
        lastAnchorRect = anchorRect
        let previousPanel = lastReadingShown?.panel
        if let lastReadingShown, lastReadingShown.panel == panel,
           lastReadingShown.anchorRect == anchorRect, isVisible, !readingView.isHidden {
            return
        }
        lastShown = nil
        lastSymbolShown = nil
        lastReadingShown = (panel, anchorRect)

        stackView.isHidden = true
        symbolView.isHidden = true
        readingView.isHidden = false
        // 面板上的列與分段按鈕要點得到。面板本身不會成為 key window，鍵盤焦點仍在宿主。
        ignoresMouseEvents = false

        readingView.render(panel)
        place(anchorRect: anchorRect, previousLeft: previousLeft)
        readingView.announceIfFocusMoved(from: previousPanel, to: panel)
    }

    /// 符號面板開啟：同一個浮窗、同一套定位，內容換成符號頁。
    private func updateSymbols(_ panel: SymbolPanelContent, cursorRect: NSRect) {
        let anchorRect = Self.resolveAnchorRect(
            reported: cursorRect,
            lastKnown: lastAnchorRect,
            mouseLocation: NSEvent.mouseLocation
        )
        let previousLeft = lastAnchorRect == anchorRect && isVisible ? frame.minX : nil
        lastAnchorRect = anchorRect
        let previousPanel = lastSymbolShown?.panel
        if let lastSymbolShown, lastSymbolShown.panel == panel,
           lastSymbolShown.anchorRect == anchorRect, isVisible, !symbolView.isHidden {
            return
        }
        lastShown = nil
        lastReadingShown = nil
        lastSymbolShown = (panel, anchorRect)

        stackView.isHidden = true
        readingView.isHidden = true
        symbolView.isHidden = false
        // 列與分段按鈕要點得到。面板本身不會成為 key window，鍵盤焦點仍在宿主。
        ignoresMouseEvents = false

        symbolView.render(panel)
        place(anchorRect: anchorRect, previousLeft: previousLeft)
        symbolView.announceIfChanged(from: previousPanel, to: panel)
    }

    /// 依目前內容的大小與游標位置放好浮窗。雙軌與反查共用。
    private func place(anchorRect: NSRect, previousLeft: CGFloat?) {
        rootStack.layoutSubtreeIfNeeded()
        let fitting = rootStack.fittingSize
        let screenFrame = Self.screenFrame(
            for: anchorRect.origin,
            screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) }
        ) ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = max(140, min(Self.maxPanelWidth, screenFrame.width - 16))
        let size = NSSize(
            width: min(maxWidth, max(140, ceil(fitting.width) + 2)),
            height: max(28, ceil(fitting.height) + 2)
        )
        var origin = Self.clampedOrigin(for: size, cursorRect: anchorRect, screenFrame: screenFrame)
        if let previousLeft {
            origin.x = max(screenFrame.minX + 8, min(previousLeft, origin.x))
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFront(nil)
    }

    static let maxPanelWidth: CGFloat = 560

    /// Where to anchor the panel. Clients that cannot report a cursor rect answer with
    /// NSZeroRect, which would pin the panel to the bottom-left corner of the main screen;
    /// fall back to the last good position of this composition, then to the mouse pointer.
    static func resolveAnchorRect(reported: NSRect, lastKnown: NSRect?, mouseLocation: NSPoint) -> NSRect {
        if isUsableCursorRect(reported) {
            return reported
        }
        return lastKnown ?? NSRect(origin: mouseLocation, size: .zero)
    }

    /// 游標所在行的矩形至少有一點高。零矩形與宿主回傳的未初始化數值都不能拿來定位。
    nonisolated static func isUsableCursorRect(_ rect: NSRect) -> Bool {
        // `rect.height` 會取絕對值，負的高度要從 `size` 讀。
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        return values.allSatisfy(\.isFinite) && rect.size.height >= 1 && rect.size.height < 1_000 && rect.size.width >= 0
    }

    /// Visible frame of the screen holding `point`, or of the nearest screen when the point
    /// sits on an edge or between displays (global coordinates, origin at bottom-left).
    static func screenFrame(for point: NSPoint, screens: [(frame: NSRect, visibleFrame: NSRect)]) -> NSRect? {
        if let hit = screens.first(where: { $0.frame.contains(point) }) {
            return hit.visibleFrame
        }
        func distanceSquared(to frame: NSRect) -> CGFloat {
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            return dx * dx + dy * dy
        }
        return screens.min { distanceSquared(to: $0.frame) < distanceSquared(to: $1.frame) }?.visibleFrame
    }

    static func clampedOrigin(for panelSize: NSSize, cursorRect: NSRect, screenFrame: NSRect) -> NSPoint {
        let gap: CGFloat = 4
        var x = cursorRect.origin.x
        var y = cursorRect.origin.y - panelSize.height - gap

        if screenFrame.width > 0 && screenFrame.height > 0 {
            if x + panelSize.width > screenFrame.maxX - 8 {
                x = max(screenFrame.minX + 8, screenFrame.maxX - panelSize.width - 8)
            }
            if x < screenFrame.minX + 8 {
                x = screenFrame.minX + 8
            }
            if y < screenFrame.minY + 8 {
                y = cursorRect.maxY + gap
            }
            y = max(screenFrame.minY + 8, min(y, screenFrame.maxY - panelSize.height - 8))
        }
        return NSPoint(x: x, y: y)
    }
}

/// 讓共用浮窗的字級跟著偏好走。控制器取得焦點時呼叫 `apply()`；
/// 設定視窗發出 `goshawk.preferencesDidChange` 時它自己再套一次。
/// IMK 的回呼與這則通知都在主執行緒，所以它只會在主執行緒被碰到。
final class OverlayFontSizeFollower: @unchecked Sendable {
    private let preferences: PreferencesStore
    private var observer: NSObjectProtocol?

    init(preferences: PreferencesStore) {
        self.preferences = preferences
        observer = NotificationCenter.default.addObserver(
            forName: .goshawkPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.apply() }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 浮窗是所有控制器共用的那一個，字級與偏好相同時它什麼都不做。
    func apply() {
        let size = preferences.loadOverlayFontSize()
        MainActor.assumeIsolated { CandidateOverlayPanel.shared.fontSize = size }
    }
}
