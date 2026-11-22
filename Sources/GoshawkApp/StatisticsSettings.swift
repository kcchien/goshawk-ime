import AppKit
import UniformTypeIdentifiers

@MainActor
final class StatisticsSettings: NSObject {
    private let store: LocalUsageStatistics
    let toggle: NSButton
    let note: NSTextField
    let inspect: NSButton
    let erase: NSButton

    init(store: LocalUsageStatistics, note: NSTextField) {
        self.note = note
        self.store = store
        toggle = NSButton(checkboxWithTitle: UIText.statisticsToggle.text, target: nil, action: nil)
        inspect = NSButton(title: UIText.statisticsInspect.text, target: nil, action: nil)
        erase = NSButton(title: UIText.statisticsErase.text, target: nil, action: nil)
        super.init()
        toggle.target = self
        toggle.action = #selector(changeConsent)
        inspect.target = self
        inspect.action = #selector(showReport)
        erase.target = self
        erase.action = #selector(clearData)
        reload()
    }

    func reload() {
        store.retryLoadingIfNeeded()
        toggle.state = store.recordingRequested ? .on : .off
        note.stringValue = (store.fileUnavailable ? UIText.statisticsFileUnavailable : .statisticsNote).text
        inspect.isEnabled = !store.fileUnavailable
    }

    @objc private func changeConsent() {
        store.setEnabled(toggle.state == .on)
    }

    @objc private func clearData() {
        let alert = NSAlert()
        alert.messageText = UIText.statisticsEraseQuestion.text
        alert.addButton(withTitle: UIText.settingsCancel.text)
        alert.addButton(withTitle: UIText.settingsClearHistoryConfirm.text)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store.clear(); reload() } catch { NSAlert(error: error).runModal() }
    }

    @objc private func showReport() {
        let rows = store.rows()
        let summary = Self.report(rows: rows)
        let alert = NSAlert()
        alert.messageText = UIText.statisticsTitle.text
        alert.accessoryView = textView(summary)
        alert.addButton(withTitle: UIText.installClose.text)
        if !rows.isEmpty { alert.addButton(withTitle: UIText.statisticsPreview.text) }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            // 預覽與寫出的都是同一份快照，選檔期間的新事件不會混進去。
            let data = try LocalUsageStatistics.encode(rows)
            let preview = NSAlert()
            preview.messageText = UIText.statisticsPreviewTitle.text
            preview.accessoryView = textView(String(decoding: data, as: UTF8.self))
            preview.addButton(withTitle: UIText.settingsCancel.text)
            preview.addButton(withTitle: UIText.statisticsSave.text)
            guard preview.runModal() == .alertSecondButtonReturn else { return }
            let dialog = NSSavePanel()
            dialog.allowedContentTypes = [.json]
            dialog.nameFieldStringValue = "goshawk-statistics.json"
            if dialog.runModal() == .OK, let url = dialog.url { try data.write(to: url, options: .atomic) }
        } catch { NSAlert(error: error).runModal() }
    }

    static func report(rows: [StatisticsRow]) -> String {
        guard !rows.isEmpty else { return UIText.statisticsEmpty.text }
        let byBuild = Dictionary(grouping: rows, by: { $0.group.build })
        return byBuild.keys.sorted().map { version in
            var totals = StatisticsTotals()
            for row in byBuild[version] ?? [] { totals.merge(row.totals) }
            let track = totals.count(.stagedTrackSwaps) + totals.count(.committedTrackSwaps)
            let punctuation = totals.count(.stagedPunctuationSwaps) + totals.count(.committedPunctuationSwaps)
            let ranks = totals.englishRanks.map(String.init).joined(separator: ", ")
            var lines = [
                UIText.settingsVersion.text(version),
                UIText.statisticsTrack.text(track, totals.count(.trackOpportunities), totals.count(.stagedTrackSwaps),
                                            totals.count(.committedTrackSwaps), totals.count(.refusedTrackSwaps)),
                UIText.statisticsPunctuation.text(punctuation, totals.count(.punctuationOpportunities), totals.count(.stagedPunctuationSwaps),
                                                  totals.count(.committedPunctuationSwaps), totals.count(.refusedPunctuationSwaps)),
                UIText.statisticsSelection.text(totals.count(.candidateNavigationKeys), totals.count(.ambiguousChineseCommits)),
                UIText.statisticsEnglish.text(ranks, totals.count(.completionsWithEnglishPredictions)),
                UIText.statisticsContinuations.text(totals.count(.chineseContinuationAcceptances), totals.count(.chineseContinuationOffers)),
                UIText.statisticsPersonalTerms.text(totals.count(.personalTermAcceptances), totals.count(.compositionsWithPersonalTermOffer)),
                UIText.statisticsLookup.text(totals.count(.lookupOpens), totals.count(.lookupPageTurns),
                                             totals.count(.lookupSelections), totals.count(.lookupCancellations))
            ]
            for (route, name) in [(StatisticsRoute.composing, UIText.statisticsComposing),
                                  (.lookup, .settingsGroupReadingLookup), (.commit, .statisticsCommit)] {
                guard let buckets = totals.latency[route.rawValue] else { continue }
                lines.append(UIText.statisticsLatency.text(name.text, buckets.reduce(0, +),
                    StatisticsTotals.percentile(95, buckets: buckets), StatisticsTotals.percentile(99, buckets: buckets)))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func textView(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isEditable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = .width
        view.textContainer?.widthTracksTextView = true
        view.font = .systemFont(ofSize: 12)
        view.string = text
        scroll.documentView = view
        return scroll
    }
}
