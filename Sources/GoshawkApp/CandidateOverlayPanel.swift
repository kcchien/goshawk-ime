import AppKit
import Foundation
import GoshawkCore

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
    private var lastShown: (overlay: OverlayState, anchorRect: NSRect, showsEnglishActions: Bool)?
    private var lastReadingShown: (panel: ReadingLookupPanel, anchorRect: NSRect)?
    private var lastAnchorRect: NSRect?

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

        // 雙軌與反查共用同一個浮窗容器與同一套定位，同一時間只顯示其中一個。
        // 外層用 NSStackView，被隱藏的那個才會整個脫離版面。
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 0
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(stackView)
        rootStack.addArrangedSubview(readingView)
        readingView.isHidden = true

        visualEffectView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])

        contentView = visualEffectView
    }

    static func formatTracks(for overlay: OverlayState, showsEnglishActions: Bool) -> (english: NSAttributedString, cangjie: NSAttributedString?) {
        let engAttr = NSMutableAttributedString()
        var typedAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let completionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let selectionFill = NSColor(srgbRed: 0.13, green: 0.36, blue: 0.32, alpha: 1)
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
        let focus = engTrack.predictions.indices.contains(engTrack.selectedIndex) ? engTrack.selectedIndex : 0
        if !showsEnglishActions {
            engAttr.append(NSAttributedString(string: engTrack.typed, attributes: typedAttrs))
        } else if engTrack.predictions.indices.contains(focus),
           engTrack.predictions[focus].lowercased().hasPrefix(engTrack.typed.lowercased()) {
            // Show the prediction's own casing: `usestate` commits as `useState`.
            let word = engTrack.predictions[focus]
            engAttr.append(NSAttributedString(string: String(word.prefix(engTrack.typed.count)), attributes: typedAttrs))
            let suffix = String(word.dropFirst(engTrack.typed.count))
            if !suffix.isEmpty {
                engAttr.append(NSAttributedString(string: suffix, attributes: completionAttrs))
            }
            engAttr.append(NSAttributedString(string: "  Tab", attributes: hintAttrs))
            let extras = engTrack.predictions.enumerated()
                .filter { $0.offset != focus }
                .prefix(3)
                .map { "⇧\($0.offset + 1) \($0.element)" }
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
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let candidateAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .medium),
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
                    wordAttrs[.font] = NSFont.systemFont(ofSize: 17, weight: .bold)
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
        readingPanel: ReadingLookupPanel?,
        cursorRect: NSRect,
        showsEnglishActions: Bool,
        revertHint: String? = nil
    ) {
        if let readingPanel {
            shownRevertHint = nil
            updateReading(readingPanel, cursorRect: cursorRect)
            return
        }
        lastReadingShown = nil
        readingView.isHidden = true
        // 只有反查需要滑鼠；雙軌維持點不到，才不會搶走宿主的點擊。
        ignoresMouseEvents = true

        guard let overlay else {
            lastShown = nil
            if let revertHint {
                showRevertHint(revertHint, cursorRect: cursorRect)
                return
            }
            shownRevertHint = nil
            lastAnchorRect = nil
            orderOut(nil)
            return
        }
        shownRevertHint = nil

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

        let formatted = Self.formatTracks(for: overlay, showsEnglishActions: showsEnglishActions)
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

    /// 浮窗目前顯示的反悔提示。沒有顯示時為 nil。
    private(set) var shownRevertHint: String?

    /// 可反悔的送出之後那一行提示：「⇧空白 改成 my」。`preview` 是對調後的字詞。
    static func revertHintText(preview: String) -> String {
        UIText.revertHint.text(preview)
    }

    /// 可反悔的送出之後：同一個浮窗只留一行提示，停在剛才組字的位置，下一個按鍵就收掉。
    private func showRevertHint(_ preview: String, cursorRect: NSRect) {
        let anchorRect = Self.resolveAnchorRect(
            reported: cursorRect,
            lastKnown: lastAnchorRect,
            mouseLocation: NSEvent.mouseLocation
        )
        let previousLeft = lastAnchorRect == anchorRect && isVisible ? frame.minX : nil
        lastAnchorRect = anchorRect
        let text = Self.revertHintText(preview: preview)
        if shownRevertHint == text, isVisible, !stackView.isHidden {
            return
        }
        shownRevertHint = text
        stackView.isHidden = false
        englishLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
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
        lastReadingShown = (panel, anchorRect)

        stackView.isHidden = true
        readingView.isHidden = false
        // 面板上的列與分段按鈕要點得到。面板本身不會成為 key window，鍵盤焦點仍在宿主。
        ignoresMouseEvents = false

        readingView.render(panel)
        place(anchorRect: anchorRect, previousLeft: previousLeft)
        readingView.announceIfFocusMoved(from: previousPanel, to: panel)
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
